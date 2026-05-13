const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // typha: the server node.
    const typha_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const typha = b.addExecutable(.{
        .name = "typha",
        .root_module = typha_mod,
    });
    b.installArtifact(typha);

    // typha_sim: deterministic simulation harness for VSR correctness testing.
    const sim_mod = b.createModule(.{
        .root_source_file = b.path("src/sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const typha_sim = b.addExecutable(.{
        .name = "typha_sim",
        .root_module = sim_mod,
    });
    b.installArtifact(typha_sim);

    // test: runs all unit tests reachable from main.zig.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
