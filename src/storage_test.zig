// Integration test: segment_log + index recovery.
//
// Goal: verify that after a crash (simulated by truncating the last segment),
// replaying the segment log rebuilds an index identical to the pre-crash state,
// and that I-1 (gapless seq from 1) and I-2 (no duplicates) hold throughout.
//
// Method: write N events across multiple entities, optionally crash-truncate,
// reopen and replay into a fresh Index, then assert per-entity seq sequences
// are exactly {1, 2, ..., n} with no gaps or duplicates.

const std = @import("std");
const testing = std.testing;
const segment_log = @import("segment_log.zig");
const index = @import("index.zig");
const constants = @import("constants.zig");

const SegmentLog = segment_log.SegmentLog;
const Index = index.Index;
const EntityBucket = index.EntityBucket;
const IndexValue = index.IndexValue;

const entity_count = 10;
const events_per_entity = 100;
const total_events = entity_count * events_per_entity;

// Rebuild the index by replaying the segment log. Called after a fresh open().
fn rebuild_index(log: *SegmentLog, idx: *Index) !void {
    try log.iterate(testing.io, *Index, idx, struct {
        fn cb(i: *Index, r: segment_log.RecordInfo) !void {
            i.put(r.entity_type, r.entity_id, r.seq, r.global_offset);
        }
    }.cb);
}

// Verify that the index holds exactly {1..n} events for every entity.
fn verify_index(idx: *const Index) !void {
    const entity_types = [_][]const u8{ "Order", "Account", "Shipment", "Invoice", "Product",
                                       "Customer", "Payment", "Return", "Warehouse", "Carrier" };
    for (entity_types) |etype| {
        var expected_seq: u64 = 1;
        var vi_opt = idx.get_head_index(etype, "id");
        while (vi_opt) |vi| {
            const v = idx.get_value(vi);
            // I-1: seq is exactly the expected next value — gapless, starting at 1.
            try testing.expectEqual(expected_seq, v.seq);
            expected_seq += 1;
            vi_opt = if (v.next == index.null_index) null else v.next;
        }
        // I-1: every entity has exactly events_per_entity events after full write.
        try testing.expectEqual(@as(u64, events_per_entity + 1), expected_seq);
    }
}

test "storage: segment_log + index recovery after crash" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const small_seg: u64 = 4096; // forces multiple rollovers across 1000 events

    var write_buf: [segment_log.record_size_max]u8 = undefined;
    var read_buf: [segment_log.record_size_max]u8 = undefined;

    const entity_types = [_][]const u8{ "Order", "Account", "Shipment", "Invoice", "Product",
                                        "Customer", "Payment", "Return", "Warehouse", "Carrier" };

    // Phase 1: write all events.
    {
        var log = try SegmentLog.open(testing.io, tmp.dir, small_seg, &write_buf, &read_buf);
        for (1..events_per_entity + 1) |seq_usize| {
            const seq: u64 = @intCast(seq_usize);
            for (entity_types) |etype| {
                _ = try log.append(testing.io, etype, "id", seq, @intCast(seq), "p");
            }
        }
        const crash_at = log.segment_offset;
        const seg_count = log.segment_count;
        log.close(testing.io);

        // Simulate a crash: truncate the last segment to half a record header.
        var name_buf: [segment_log.segment_name_len]u8 = undefined;
        segment_log.segment_log_format_name(@intCast(seg_count - 1), &name_buf);
        const f = try tmp.dir.createFile(testing.io, &name_buf, .{ .truncate = false });
        defer f.close(testing.io);
        try f.setLength(testing.io, crash_at + segment_log.record_header_size / 2);
    }

    // Phase 2: reopen and rebuild index.
    var log2 = try SegmentLog.open(testing.io, tmp.dir, small_seg, &write_buf, &read_buf);
    defer log2.close(testing.io);

    var buckets: [entity_count * 4]EntityBucket = undefined;
    var values: [total_events + 1]IndexValue = undefined;
    var idx = Index.init(&buckets, &values);
    try rebuild_index(&log2, &idx);

    // Phase 3: verify I-1 and I-2 on the recovered index.
    try testing.expectEqual(@as(u32, total_events), idx.values_count);
    try verify_index(&idx);
}
