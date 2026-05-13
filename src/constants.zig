// NOTE let's not duplicate justifications in these comments
// Segment files are fixed at 128 MB. At ~1 GB/s NVMe sequential read speed, replaying
// one segment on crash recovery takes ~130ms. Smaller than Kafka (1 GB) or Bitcask
// (2 GB) because Typha never compacts — no benefit to amortizing over larger files.
pub const segment_file_size: u64 = 134_217_728;

// 64 KB per payload. Covers real-world event payloads (e.g. a complex FedEx webhook
// with 24 scan events is ~31 KB). Clients with larger payloads use the Claim Check
// pattern: store the content in object storage, append a content-addressed reference.
pub const payload_size_max: u32 = 65_536;

// Entity type names are short by nature ("Order", "ShipmentEvent"). 128 bytes is
// generous headroom that keeps static key buffers cheap.
pub const entity_type_size_max: u32 = 128;

// Double a hyphenated UUID string (36 bytes), covering UUID, ULID (26), NanoID (21),
// and all common natural domain ID schemes. Binary IDs can be hex-encoded in one line.
pub const entity_id_size_max: u32 = 64;

// R=2 is excluded (floor(2/2)+1 = 2 requires both nodes, giving zero fault tolerance
// at double the cost of R=1). R>9 is excluded to keep simulation surface bounded.
// NOTE is min used anywhere?
pub const replication_factor_min: u32 = 1;
pub const replication_factor_max: u32 = 9;

// Sequence numbers start at 1. Zero is the sentinel for "no events yet", usable
// without a nullable type at call sites.
pub const sequence_no_min: u64 = 1;

// NOTE these functions aren't really constants. maybe they go somewhere else?
pub fn quorum(replication_factor: u32) u32 {
    return replication_factor / 2 + 1;
}

pub fn is_valid_replication_factor(r: u32) bool {
    return r == 1 or (r >= 3 and r <= replication_factor_max);
}

test "segment_file_size matches spec" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 134_217_728), segment_file_size);
}

test "payload_size_max matches spec" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 65_536), payload_size_max);
}

test "entity size limits match spec" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 128), entity_type_size_max);
    try std.testing.expectEqual(@as(u32, 64), entity_id_size_max);
}

test "quorum formula matches spec: floor(R/2) + 1" {
    const std = @import("std");
    // R=1: floor(1/2)+1 = 1  (single node, always quorum)
    try std.testing.expectEqual(@as(u32, 1), quorum(1));
    // R=3: floor(3/2)+1 = 2  (standard 3-node cluster)
    try std.testing.expectEqual(@as(u32, 2), quorum(3));
    // R=4: floor(4/2)+1 = 3
    try std.testing.expectEqual(@as(u32, 3), quorum(4));
    // R=5: floor(5/2)+1 = 3
    try std.testing.expectEqual(@as(u32, 3), quorum(5));
    // R=6: floor(6/2)+1 = 4  (3-AZ deployment: 2 nodes/AZ, lose any AZ = 4/6 survive)
    try std.testing.expectEqual(@as(u32, 4), quorum(6));
    // R=7: floor(7/2)+1 = 4
    try std.testing.expectEqual(@as(u32, 4), quorum(7));
    // R=8: floor(8/2)+1 = 5
    try std.testing.expectEqual(@as(u32, 5), quorum(8));
    // R=9: floor(9/2)+1 = 5
    try std.testing.expectEqual(@as(u32, 5), quorum(9));
}

test "replication factor validation excludes R=2 and R>9" {
    const std = @import("std");
    try std.testing.expect(!is_valid_replication_factor(0));
    try std.testing.expect(is_valid_replication_factor(1));
    try std.testing.expect(!is_valid_replication_factor(2));
    try std.testing.expect(is_valid_replication_factor(3));
    try std.testing.expect(is_valid_replication_factor(9));
    try std.testing.expect(!is_valid_replication_factor(10));
}
