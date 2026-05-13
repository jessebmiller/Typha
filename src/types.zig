// Logical types for Typha's data model, wire protocol, and operations.
// Storage and wire representations are separate concerns handled by
// segment_log.zig and wire.zig respectively.

pub const Event = struct {
    entity_type: []const u8,
    entity_id: []const u8,
    seq: u64,
    timestamp: i64,
    payload: []const u8,
};

pub const Filter = union(enum) {
    all: void,
    by_type: []const u8,
    by_entity: struct {
        entity_type: []const u8,
        entity_id: []const u8,
    },
};

// SequenceCursor is valid only with a by_entity filter.
// TimestampCursor is valid only with by_type or all filters.
pub const Cursor = union(enum) {
    sequence: u64,
    timestamp: i64,
};

pub const MessageType = enum(u8) {
    append_req = 0,
    append_resp = 1,
    read_req = 2,
    read_event = 3,
    read_end = 4,
    subscribe_req = 5,
    sub_event = 6,
    credits = 7,
    cancel = 8,
    ping = 9,
    pong = 10,
    @"error" = 11,
};

// Wire frame header. stream_id=0 is reserved for connection-level messages.
pub const Frame = struct {
    stream_id: u32,
    msg_type: MessageType,
    length: u32,
};

test "Filter tagged union" {
    const std = @import("std");
    const f_all = Filter{ .all = {} };
    const f_type = Filter{ .by_type = "Order" };
    const f_entity = Filter{ .by_entity = .{ .entity_type = "Order", .entity_id = "123" } };

    try std.testing.expect(f_all == .all);
    try std.testing.expect(f_type == .by_type);
    try std.testing.expect(f_entity == .by_entity);
}

test "Cursor tagged union" {
    const std = @import("std");
    const seq_cursor = Cursor{ .sequence = 42 };
    const ts_cursor = Cursor{ .timestamp = 1_000_000_000 };

    try std.testing.expect(seq_cursor == .sequence);
    try std.testing.expect(ts_cursor == .timestamp);
    try std.testing.expectEqual(@as(u64, 42), seq_cursor.sequence);
}

test "MessageType exhaustive coverage" {
    const std = @import("std");
    // Verify the enum discriminant values match the wire protocol spec.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(MessageType.append_req));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(MessageType.@"error"));
}
