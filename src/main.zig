const std = @import("std");

pub fn main() !void {}

// Pull all module tests into the test binary.
test {
    _ = @import("types.zig");
    _ = @import("constants.zig");
    _ = @import("segment_log.zig");
    _ = @import("index.zig");
    _ = @import("storage_test.zig");
}
