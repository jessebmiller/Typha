const std = @import("std");

pub fn main() !void {}

// Pull all module tests into the test binary.
test {
    _ = @import("types.zig");
    _ = @import("constants.zig");
}
