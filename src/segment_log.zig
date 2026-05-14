const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const constants = @import("constants.zig");

pub const record_header_size: u32 = 32;
pub const record_size_max: u32 = record_header_size +
    constants.entity_type_size_max +
    constants.entity_id_size_max +
    constants.payload_size_max;

// Practical upper bound on segment count: 1M segments × 128 MB = 128 TB per node.
const segment_count_max: u32 = 1_000_000;

// Segment files are named "NNNNNNNNNN.seg" (10 zero-padded decimal digits).
// Zero-padding keeps filenames lexicographically sortable without special handling.
pub const segment_name_len: usize = 14;

// On-disk record header. extern struct guarantees no compiler padding so the layout
// is deterministic across compilations.
const RecordHeader = extern struct {
    // CRC32 of the full record (header with this field zeroed, then body bytes).
    checksum: u32,
    entity_type_len: u16,
    entity_id_len: u16,
    payload_len: u32,
    _reserved: u32,
    seq: u64,
    timestamp: i64,
};

comptime {
    assert(@sizeOf(RecordHeader) == record_header_size);
}

// RecordInfo slices point into the owning SegmentLog's read_buf. They are valid
// only until the next call to read_at or iterate on the same SegmentLog instance.
pub const RecordInfo = struct {
    entity_type: []const u8,
    entity_id: []const u8,
    seq: u64,
    timestamp: i64,
    payload: []const u8,
    // Byte offset of this record in the virtual log.
    // global_offset = segment_index * segment_size + offset_within_segment
    global_offset: u64,
};

pub const SegmentLog = struct {
    dir: Dir,
    // Parameterized to allow small values in tests; production must use
    // constants.segment_file_size.
    segment_size: u64,
    segment_index: u32,
    segment_file: File,
    // Next write position within the current segment file.
    segment_offset: u32,
    // Total segments including the current write segment. Always >= 1 after open.
    segment_count: u32,
    write_buf: *[record_size_max]u8,
    read_buf: *[record_size_max]u8,

    // Opens or creates a segment log in dir. segment_size controls rollover point
    // and must satisfy record_size_max <= segment_size <= constants.segment_file_size.
    // dir must be opened with OpenOptions.iterate = true; open() scans it for existing
    // segment files on startup.
    pub fn open(
        io: Io,
        dir: Dir,
        segment_size: u64,
        write_buf: *[record_size_max]u8,
        read_buf: *[record_size_max]u8,
    ) !SegmentLog {
        // segment_size must be large enough to hold at least the smallest possible record.
        // Each record needs at least the fixed header plus 1 byte each for entity_type,
        // entity_id, and payload. The per-record check in append() enforces the upper limit.
        assert(segment_size > record_header_size + 3);
        assert(segment_size <= constants.segment_file_size);

        var max_index: u32 = 0;
        var count: u32 = 0;
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const index = segment_log_parse_name(entry.name) orelse continue;
            if (index > max_index) max_index = index;
            count += 1;
        }
        // Segments must be a contiguous sequence 0..count-1 with no gaps.
        assert(count == 0 or max_index == count - 1);
        assert(count < segment_count_max);

        var name_buf: [segment_name_len]u8 = undefined;
        if (count == 0) {
            segment_log_format_name(0, &name_buf);
            const file = try dir.createFile(io, &name_buf, .{ .truncate = true });
            return .{
                .dir = dir,
                .segment_size = segment_size,
                .segment_index = 0,
                .segment_file = file,
                .segment_offset = 0,
                .segment_count = 1,
                .write_buf = write_buf,
                .read_buf = read_buf,
            };
        }

        segment_log_format_name(max_index, &name_buf);
        // Read access is required here so that segment_log_recover_offset can scan
        // the file to find the last valid record after a potential crash.
        const file = try dir.createFile(io, &name_buf, .{ .truncate = false, .read = true });
        const offset = try segment_log_recover_offset(io, file, segment_size, read_buf);
        return .{
            .dir = dir,
            .segment_size = segment_size,
            .segment_index = max_index,
            .segment_file = file,
            .segment_offset = offset,
            .segment_count = count,
            .write_buf = write_buf,
            .read_buf = read_buf,
        };
    }

    pub fn close(self: *SegmentLog, io: Io) void {
        assert(self.segment_count > 0);
        self.segment_file.close(io);
        self.* = undefined;
    }

    // Appends one event record and returns its global_offset (the value to store in
    // the index). Rolls over to a new segment if the record would exceed segment_size.
    pub fn append(
        self: *SegmentLog,
        io: Io,
        entity_type: []const u8,
        entity_id: []const u8,
        seq: u64,
        timestamp: i64,
        payload: []const u8,
    ) !u64 {
        assert(entity_type.len > 0 and entity_type.len <= constants.entity_type_size_max);
        assert(entity_id.len > 0 and entity_id.len <= constants.entity_id_size_max);
        assert(payload.len > 0 and payload.len <= constants.payload_size_max);
        assert(seq >= constants.sequence_no_min); // I-1: seq starts at 1

        const record_len: u32 = record_header_size +
            @as(u32, @intCast(entity_type.len)) +
            @as(u32, @intCast(entity_id.len)) +
            @as(u32, @intCast(payload.len));
        assert(record_len <= record_size_max);
        // A record that exceeds segment_size can never be written; it would trigger
        // an infinite rollover loop. Catch it here rather than silently looping.
        assert(record_len <= self.segment_size);

        if (@as(u64, self.segment_offset) + record_len > self.segment_size) {
            try segment_log_roll(self, io);
        }

        const global_offset: u64 = @as(u64, self.segment_index) * self.segment_size +
            @as(u64, self.segment_offset);

        const bytes = segment_log_encode(
            self.write_buf,
            entity_type,
            entity_id,
            seq,
            timestamp,
            payload,
        );
        assert(bytes.len == record_len);

        try self.segment_file.writePositionalAll(io, bytes, self.segment_offset);
        self.segment_offset += record_len;
        assert(self.segment_offset <= self.segment_size);
        return global_offset;
    }

    // Reads the record at global_offset. Returned slices point into self.read_buf
    // and are invalidated by the next read_at or iterate call.
    pub fn read_at(self: *SegmentLog, io: Io, global_offset: u64) !RecordInfo {
        assert(global_offset < @as(u64, self.segment_count) * self.segment_size);

        const seg_index: u32 = @intCast(global_offset / self.segment_size);
        const local_offset: u32 = @intCast(global_offset % self.segment_size);
        assert(seg_index < self.segment_count);

        var name_buf: [segment_name_len]u8 = undefined;
        segment_log_format_name(seg_index, &name_buf);
        const file = try self.dir.openFile(io, &name_buf, .{ .mode = .read_only });
        defer file.close(io);

        return segment_log_read_record(io, file, local_offset, global_offset, self.read_buf);
    }

    // Calls callback for every valid record in the log, in write order.
    // Skips any crash-partial tail on the last segment.
    pub fn iterate(
        self: *SegmentLog,
        io: Io,
        comptime Context: type,
        context: Context,
        comptime callback: fn (ctx: Context, record: RecordInfo) anyerror!void,
    ) !void {
        assert(self.segment_count > 0);
        assert(self.segment_count <= segment_count_max);

        var seg_index: u32 = 0;
        while (seg_index < self.segment_count) : (seg_index += 1) {
            try segment_log_iterate_segment(
                io,
                self.dir,
                self.segment_size,
                self.read_buf,
                seg_index,
                Context,
                context,
                callback,
            );
        }
    }
};

// --- private helpers ---

fn segment_log_roll(log: *SegmentLog, io: Io) !void {
    assert(log.segment_count < segment_count_max);
    log.segment_file.close(io);
    log.segment_index += 1;
    log.segment_count += 1;
    log.segment_offset = 0;
    var name_buf: [segment_name_len]u8 = undefined;
    segment_log_format_name(log.segment_index, &name_buf);
    log.segment_file = try log.dir.createFile(io, &name_buf, .{ .truncate = true });
    assert(log.segment_offset == 0);
}

pub fn segment_log_format_name(segment_index: u32, buf: *[segment_name_len]u8) void {
    _ = std.fmt.bufPrint(buf, "{d:0>10}.seg", .{segment_index}) catch unreachable;
}

fn segment_log_parse_name(name: []const u8) ?u32 {
    if (name.len != segment_name_len) return null;
    if (!std.mem.eql(u8, name[10..], ".seg")) return null;
    return std.fmt.parseInt(u32, name[0..10], 10) catch null;
}

fn segment_log_compute_checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

fn segment_log_encode(
    buf: *[record_size_max]u8,
    entity_type: []const u8,
    entity_id: []const u8,
    seq: u64,
    timestamp: i64,
    payload: []const u8,
) []u8 {
    assert(entity_type.len > 0 and entity_type.len <= constants.entity_type_size_max);
    assert(entity_id.len > 0 and entity_id.len <= constants.entity_id_size_max);
    assert(payload.len > 0 and payload.len <= constants.payload_size_max);

    const header = RecordHeader{
        .checksum = 0,
        .entity_type_len = @intCast(entity_type.len),
        .entity_id_len = @intCast(entity_id.len),
        .payload_len = @intCast(payload.len),
        ._reserved = 0,
        .seq = seq,
        .timestamp = timestamp,
    };

    const et_end: usize = record_header_size + entity_type.len;
    const ei_end: usize = et_end + entity_id.len;
    const pl_end: usize = ei_end + payload.len;
    assert(pl_end <= record_size_max);

    @memcpy(buf[0..record_header_size], std.mem.asBytes(&header));
    @memcpy(buf[record_header_size..et_end], entity_type);
    @memcpy(buf[et_end..ei_end], entity_id);
    @memcpy(buf[ei_end..pl_end], payload);

    // Overwrite the checksum field (bytes 0..4) with the CRC32 of the full record.
    // The header bytes already have checksum=0, so this is consistent with how
    // the verifier re-computes it (by zeroing the field before hashing).
    const checksum = segment_log_compute_checksum(buf[0..pl_end]);
    std.mem.writeInt(u32, buf[0..4], checksum, .little);
    return buf[0..pl_end];
}

fn segment_log_read_record(
    io: Io,
    file: File,
    local_offset: u32,
    global_offset: u64,
    read_buf: *[record_size_max]u8,
) !RecordInfo {
    const header_read = try file.readPositionalAll(io, read_buf[0..record_header_size], local_offset);
    if (header_read < record_header_size) return error.RecordTruncated;

    var header: RecordHeader = undefined;
    @memcpy(std.mem.asBytes(&header), read_buf[0..record_header_size]);

    const et_len: u32 = header.entity_type_len;
    const ei_len: u32 = header.entity_id_len;
    const pl_len: u32 = header.payload_len;

    if (et_len == 0 or et_len > constants.entity_type_size_max) return error.RecordCorrupt;
    if (ei_len == 0 or ei_len > constants.entity_id_size_max) return error.RecordCorrupt;
    if (pl_len == 0 or pl_len > constants.payload_size_max) return error.RecordCorrupt;

    const body_len: u32 = et_len + ei_len + pl_len;
    const total: u32 = record_header_size + body_len;
    assert(total <= record_size_max);

    const body_read = try file.readPositionalAll(
        io,
        read_buf[record_header_size..total],
        local_offset + record_header_size,
    );
    if (body_read < body_len) return error.RecordTruncated;

    // Verify: zero the checksum field, recompute, compare.
    const stored = header.checksum;
    std.mem.writeInt(u32, read_buf[0..4], 0, .little);
    if (segment_log_compute_checksum(read_buf[0..total]) != stored) return error.RecordChecksumMismatch;

    const et_start: u32 = record_header_size;
    const ei_start: u32 = et_start + et_len;
    const pl_start: u32 = ei_start + ei_len;

    return .{
        .entity_type = read_buf[et_start..][0..et_len],
        .entity_id = read_buf[ei_start..][0..ei_len],
        .seq = header.seq,
        .timestamp = header.timestamp,
        .payload = read_buf[pl_start..][0..pl_len],
        .global_offset = global_offset,
    };
}

// Scans a segment file from offset 0, reading and checksum-verifying each record.
// Returns the offset just past the last valid record — the correct write position
// after a crash that may have left a partial record at the tail.
fn segment_log_recover_offset(
    io: Io,
    file: File,
    segment_size: u64,
    read_buf: *[record_size_max]u8,
) !u32 {
    assert(segment_size <= constants.segment_file_size);
    var offset: u32 = 0;
    while (@as(u64, offset) < segment_size) {
        const n = try file.readPositionalAll(io, read_buf[0..record_header_size], offset);
        if (n < record_header_size) break;

        var header: RecordHeader = undefined;
        @memcpy(std.mem.asBytes(&header), read_buf[0..record_header_size]);

        const et_len: u32 = header.entity_type_len;
        const ei_len: u32 = header.entity_id_len;
        const pl_len: u32 = header.payload_len;

        if (et_len == 0 or et_len > constants.entity_type_size_max) break;
        if (ei_len == 0 or ei_len > constants.entity_id_size_max) break;
        if (pl_len == 0 or pl_len > constants.payload_size_max) break;

        const body_len: u32 = et_len + ei_len + pl_len;
        const total: u32 = record_header_size + body_len;

        const body_n = try file.readPositionalAll(
            io,
            read_buf[record_header_size..total],
            offset + record_header_size,
        );
        if (body_n < body_len) break;

        const stored = header.checksum;
        std.mem.writeInt(u32, read_buf[0..4], 0, .little);
        if (segment_log_compute_checksum(read_buf[0..total]) != stored) break;

        offset += total;
    }
    assert(@as(u64, offset) <= segment_size);
    return offset;
}

// Iterates all valid records in one segment file, invoking callback for each.
// Uses segment_log_recover_offset to find the valid end of the segment, which
// handles both normal ends (file size = written bytes) and crash-partial tails.
fn segment_log_iterate_segment(
    io: Io,
    dir: Dir,
    segment_size: u64,
    read_buf: *[record_size_max]u8,
    seg_index: u32,
    comptime Context: type,
    context: Context,
    comptime callback: fn (ctx: Context, record: RecordInfo) anyerror!void,
) !void {
    var name_buf: [segment_name_len]u8 = undefined;
    segment_log_format_name(seg_index, &name_buf);
    const file = try dir.openFile(io, &name_buf, .{ .mode = .read_only });
    defer file.close(io);

    // Scan once to find where valid records end. For completed segments the file
    // size is exactly the amount written (not padded to segment_size), so we must
    // detect the end rather than relying on a hard byte bound.
    const valid_bytes = try segment_log_recover_offset(io, file, segment_size, read_buf);
    assert(@as(u64, valid_bytes) <= segment_size);

    const global_base: u64 = @as(u64, seg_index) * segment_size;
    var local_offset: u32 = 0;
    while (local_offset < valid_bytes) {
        const record = try segment_log_read_record(
            io,
            file,
            local_offset,
            global_base + local_offset,
            read_buf,
        );
        try callback(context, record);

        const record_len: u32 = record_header_size +
            @as(u32, @intCast(record.entity_type.len)) +
            @as(u32, @intCast(record.entity_id.len)) +
            @as(u32, @intCast(record.payload.len));
        local_offset += record_len;
    }
    assert(local_offset == valid_bytes);
}

// --- tests ---

test "segment_log: append and read_at round-trip" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var write_buf: [record_size_max]u8 = undefined;
    var read_buf: [record_size_max]u8 = undefined;
    var log = try SegmentLog.open(testing.io, tmp.dir, constants.segment_file_size, &write_buf, &read_buf);
    defer log.close(testing.io);

    const off1 = try log.append(testing.io, "Order", "abc", 1, 1000, "payload1");
    const off2 = try log.append(testing.io, "Order", "abc", 2, 2000, "payload2");
    const off3 = try log.append(testing.io, "Account", "xyz", 1, 3000, "payload3");

    const r1 = try log.read_at(testing.io, off1);
    try testing.expectEqualStrings("Order", r1.entity_type);
    try testing.expectEqualStrings("abc", r1.entity_id);
    try testing.expectEqual(@as(u64, 1), r1.seq);
    try testing.expectEqualStrings("payload1", r1.payload);

    const r2 = try log.read_at(testing.io, off2);
    try testing.expectEqual(@as(u64, 2), r2.seq);
    try testing.expectEqualStrings("payload2", r2.payload);

    const r3 = try log.read_at(testing.io, off3);
    try testing.expectEqualStrings("Account", r3.entity_type);
    try testing.expectEqual(@as(u64, 1), r3.seq);
}

test "segment_log: crash recovery stops at partial record" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const small_seg: u64 = 65760 * 10; // fits ~10 max-size records

    var write_buf: [record_size_max]u8 = undefined;
    var read_buf: [record_size_max]u8 = undefined;

    // Write 3 complete events.
    {
        var log = try SegmentLog.open(testing.io, tmp.dir, small_seg, &write_buf, &read_buf);
        _ = try log.append(testing.io, "T", "A", 1, 100, "x");
        _ = try log.append(testing.io, "T", "A", 2, 200, "y");
        _ = try log.append(testing.io, "T", "A", 3, 300, "z");
        const crash_at = log.segment_offset;
        log.close(testing.io);

        // Simulate a crash: truncate to just past the 3rd record + half a header.
        // The partial header should be discarded on recovery.
        const seg_file = try tmp.dir.createFile(testing.io, "0000000000.seg", .{ .truncate = false });
        defer seg_file.close(testing.io);
        try seg_file.setLength(testing.io, crash_at + record_header_size / 2);
    }

    // Reopen: recovery should find exactly 3 valid events.
    var log2 = try SegmentLog.open(testing.io, tmp.dir, small_seg, &write_buf, &read_buf);
    defer log2.close(testing.io);

    const Ctx = struct { count: u32 = 0 };
    var ctx = Ctx{};
    try log2.iterate(testing.io, *Ctx, &ctx, struct {
        fn cb(c: *Ctx, _: RecordInfo) !void {
            c.count += 1;
        }
    }.cb);
    try testing.expectEqual(@as(u32, 3), ctx.count);
}

test "segment_log: segment rollover" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Segment size just large enough for 2 small records. A third record triggers rollover.
    const small_record_size: u32 = record_header_size + 1 + 1 + 1; // entity_type=1, entity_id=1, payload=1
    const tiny_seg: u64 = small_record_size * 2 + 1; // fits exactly 2 records

    var write_buf: [record_size_max]u8 = undefined;
    var read_buf: [record_size_max]u8 = undefined;
    var log = try SegmentLog.open(testing.io, tmp.dir, tiny_seg, &write_buf, &read_buf);
    defer log.close(testing.io);

    _ = try log.append(testing.io, "T", "A", 1, 1, "p");
    _ = try log.append(testing.io, "T", "A", 2, 2, "p");
    try testing.expectEqual(@as(u32, 1), log.segment_count);

    _ = try log.append(testing.io, "T", "A", 3, 3, "p"); // triggers rollover
    try testing.expectEqual(@as(u32, 2), log.segment_count);
    try testing.expectEqual(@as(u32, 1), log.segment_index);
}

test "segment_log: iterate delivers all records in order" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var write_buf: [record_size_max]u8 = undefined;
    var read_buf: [record_size_max]u8 = undefined;
    var log = try SegmentLog.open(testing.io, tmp.dir, constants.segment_file_size, &write_buf, &read_buf);
    defer log.close(testing.io);

    _ = try log.append(testing.io, "T", "A", 1, 10, "a");
    _ = try log.append(testing.io, "T", "B", 1, 20, "b");
    _ = try log.append(testing.io, "T", "A", 2, 30, "c");

    const Ctx = struct { seqs: [3]u64 = undefined, count: u32 = 0 };
    var ctx = Ctx{};
    try log.iterate(testing.io, *Ctx, &ctx, struct {
        fn cb(c: *Ctx, r: RecordInfo) !void {
            c.seqs[c.count] = r.seq;
            c.count += 1;
        }
    }.cb);

    try testing.expectEqual(@as(u32, 3), ctx.count);
    try testing.expectEqual(@as(u64, 1), ctx.seqs[0]);
    try testing.expectEqual(@as(u64, 1), ctx.seqs[1]);
    try testing.expectEqual(@as(u64, 2), ctx.seqs[2]);
}
