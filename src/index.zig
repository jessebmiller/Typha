const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

// Sentinel value for IndexValue.next and EntityBucket.values_head/values_tail.
// u32 max is used (not 0) so that 0 is a valid index into the values pool.
pub const null_index: u32 = std.math.maxInt(u32);

pub const EntityBucket = struct {
    occupied: bool = false,
    _pad: [3]u8 = .{0} ** 3,
    entity_type_len: u32 = 0,
    entity_type: [constants.entity_type_size_max]u8 = undefined,
    entity_id_len: u32 = 0,
    entity_id: [constants.entity_id_size_max]u8 = undefined,
    // Head and tail are indices into the Index.values pool. Both are null_index
    // iff no events have been recorded for this entity.
    values_head: u32 = null_index,
    values_tail: u32 = null_index,
    values_count: u32 = 0,
};

// Each IndexValue node represents one (seq, offset) entry in an entity's event
// list. The next field threads a singly-linked list through the values pool.
pub const IndexValue = struct {
    seq: u64 = 0,
    offset: u64 = 0,
    next: u32 = null_index,
    _pad: u32 = 0,
};

pub const Index = struct {
    buckets: []EntityBucket,
    values: []IndexValue,
    entity_count: u32,
    values_count: u32,

    // Caller owns the backing slices and must ensure they outlive the Index.
    // buckets.len must be > 2 * expected entity count (load factor < 0.5).
    pub fn init(buckets: []EntityBucket, values: []IndexValue) Index {
        assert(buckets.len >= 2);
        assert(values.len >= 1);
        // Mark all buckets unoccupied; other fields are undefined until occupied = true.
        for (buckets) |*b| b.occupied = false;
        return .{
            .buckets = buckets,
            .values = values,
            .entity_count = 0,
            .values_count = 0,
        };
    }

    // Records that the event with (seq, offset) belongs to (entity_type, entity_id).
    // Asserts I-1 (seq is exactly values_count + 1 for this entity) and
    // I-2 (no duplicate seq within an entity, guaranteed by I-1 + monotone puts).
    pub fn put(
        self: *Index,
        entity_type: []const u8,
        entity_id: []const u8,
        seq: u64,
        offset: u64,
    ) void {
        assert(entity_type.len > 0 and entity_type.len <= constants.entity_type_size_max);
        assert(entity_id.len > 0 and entity_id.len <= constants.entity_id_size_max);
        assert(seq >= constants.sequence_no_min);
        assert(self.values_count < self.values.len);

        const bi = index_find_or_create_bucket(self, entity_type, entity_id);
        const bucket = &self.buckets[bi];

        assert(seq == bucket.values_count + 1); // I-1: seq must be exactly the next position, no gaps.
        assert((bucket.values_head == null_index) == (bucket.values_tail == null_index));

        const vi = self.values_count;
        self.values[vi] = .{ .seq = seq, .offset = offset, .next = null_index };
        self.values_count += 1;

        if (bucket.values_tail == null_index) {
            bucket.values_head = vi;
        } else {
            self.values[bucket.values_tail].next = vi;
        }
        bucket.values_tail = vi;
        bucket.values_count += 1;

        assert(bucket.values_count == seq); // I-1: post-condition, count equals highest seq.
    }

    // Returns the next sequence number to assign for the given entity (1 if new).
    pub fn next_seq(
        self: *const Index,
        entity_type: []const u8,
        entity_id: []const u8,
    ) u64 {
        assert(entity_type.len > 0 and entity_type.len <= constants.entity_type_size_max);
        assert(entity_id.len > 0 and entity_id.len <= constants.entity_id_size_max);

        const bi = index_find_bucket(self, entity_type, entity_id) orelse return 1;
        const count = self.buckets[bi].values_count;
        assert(count < std.math.maxInt(u64)); // ensure +1 won't overflow
        return count + 1;
    }

    // Returns the index of the first IndexValue for the entity, or null if no events.
    pub fn get_head_index(
        self: *const Index,
        entity_type: []const u8,
        entity_id: []const u8,
    ) ?u32 {
        assert(entity_type.len > 0);
        assert(entity_id.len > 0);

        const bi = index_find_bucket(self, entity_type, entity_id) orelse return null;
        const head = self.buckets[bi].values_head;
        if (head == null_index) return null;
        return head;
    }

    // Returns a copy of the IndexValue at the given pool index.
    pub fn get_value(self: *const Index, value_index: u32) IndexValue {
        assert(value_index < self.values_count);
        return self.values[value_index];
    }
};

// --- private helpers ---

fn index_hash_key(entity_type: []const u8, entity_id: []const u8) u64 {
    // Lengths are hashed before content so that "AB"+"CD" != "A"+"BCD".
    var h = std.hash.Fnv1a_64.init();
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(entity_type.len), .little);
    h.update(&len_buf);
    h.update(entity_type);
    std.mem.writeInt(u32, &len_buf, @intCast(entity_id.len), .little);
    h.update(&len_buf);
    h.update(entity_id);
    return h.final();
}

fn index_keys_equal(
    bucket: *const EntityBucket,
    entity_type: []const u8,
    entity_id: []const u8,
) bool {
    assert(bucket.occupied);
    if (bucket.entity_type_len != @as(u32, @intCast(entity_type.len))) return false;
    if (bucket.entity_id_len != @as(u32, @intCast(entity_id.len))) return false;
    if (!std.mem.eql(u8, bucket.entity_type[0..bucket.entity_type_len], entity_type)) return false;
    if (!std.mem.eql(u8, bucket.entity_id[0..bucket.entity_id_len], entity_id)) return false;
    return true;
}

// Linear-probe search. Returns null if the key is absent (empty slot encountered).
fn index_find_bucket(
    self: *const Index,
    entity_type: []const u8,
    entity_id: []const u8,
) ?u32 {
    assert(self.buckets.len > 0);

    const n = @as(u32, @intCast(self.buckets.len));
    const start: u32 = @intCast(index_hash_key(entity_type, entity_id) % n);
    var probe: u32 = 0;
    while (probe < n) : (probe += 1) {
        const i = (start + probe) % n;
        const bucket = &self.buckets[i];
        if (!bucket.occupied) return null;
        if (index_keys_equal(bucket, entity_type, entity_id)) return i;
    }
    return null;
}

// Linear-probe insert. Returns the index of an existing matching bucket, or
// initializes and returns a new empty one. Asserts load factor < 0.5.
fn index_find_or_create_bucket(
    self: *Index,
    entity_type: []const u8,
    entity_id: []const u8,
) u32 {
    const n = @as(u32, @intCast(self.buckets.len));
    assert(self.entity_count * 2 < n); // load factor must stay below 0.5

    const start: u32 = @intCast(index_hash_key(entity_type, entity_id) % n);
    var probe: u32 = 0;
    while (probe < n) : (probe += 1) {
        const i = (start + probe) % n;
        const bucket = &self.buckets[i];
        if (bucket.occupied and index_keys_equal(bucket, entity_type, entity_id)) return i;
        if (!bucket.occupied) {
            bucket.occupied = true;
            bucket.entity_type_len = @intCast(entity_type.len);
            @memcpy(bucket.entity_type[0..entity_type.len], entity_type);
            bucket.entity_id_len = @intCast(entity_id.len);
            @memcpy(bucket.entity_id[0..entity_id.len], entity_id);
            bucket.values_head = null_index;
            bucket.values_tail = null_index;
            bucket.values_count = 0;
            self.entity_count += 1;
            return i;
        }
    }
    unreachable; // load factor assertion above guarantees a free slot exists
}

// --- tests ---

test "index: next_seq returns 1 for new entity" {
    const testing = std.testing;
    var buckets: [16]EntityBucket = undefined;
    var values: [64]IndexValue = undefined;
    const idx = Index.init(&buckets, &values);
    try testing.expectEqual(@as(u64, 1), idx.next_seq("Order", "42"));
}

test "index: put advances next_seq and links values" {
    const testing = std.testing;
    var buckets: [16]EntityBucket = undefined;
    var values: [64]IndexValue = undefined;
    var idx = Index.init(&buckets, &values);

    idx.put("Order", "42", 1, 100);
    idx.put("Order", "42", 2, 200);
    idx.put("Order", "42", 3, 300);

    try testing.expectEqual(@as(u64, 4), idx.next_seq("Order", "42"));
    try testing.expectEqual(@as(u64, 1), idx.next_seq("Order", "99")); // different entity

    // Walk the linked list and verify all three offsets.
    var vi = idx.get_head_index("Order", "42") orelse return error.MissingHead;
    var seen: u32 = 0;
    while (vi != null_index) {
        const v = idx.get_value(vi);
        seen += 1;
        try testing.expectEqual(@as(u64, seen), v.seq);
        try testing.expectEqual(@as(u64, seen) * 100, v.offset);
        vi = v.next;
    }
    try testing.expectEqual(@as(u32, 3), seen);
}

test "index: multiple entities are independent" {
    const testing = std.testing;
    var buckets: [32]EntityBucket = undefined;
    var values: [64]IndexValue = undefined;
    var idx = Index.init(&buckets, &values);

    idx.put("Order", "A", 1, 10);
    idx.put("Account", "B", 1, 20);
    idx.put("Order", "A", 2, 30);

    try testing.expectEqual(@as(u64, 3), idx.next_seq("Order", "A"));
    try testing.expectEqual(@as(u64, 2), idx.next_seq("Account", "B"));
    try testing.expectEqual(@as(u64, 1), idx.next_seq("Order", "B")); // new entity
}

test "index: get_head_index returns null for unknown entity" {
    const testing = std.testing;
    var buckets: [8]EntityBucket = undefined;
    var values: [8]IndexValue = undefined;
    const idx = Index.init(&buckets, &values);
    try testing.expectEqual(@as(?u32, null), idx.get_head_index("T", "x"));
}
