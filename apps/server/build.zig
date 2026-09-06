const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("sprts_core", .{ .target = target, .optimize = optimize }).module("sprts_core");
    const espn = b.dependency("espn_client", .{ .target = target, .optimize = optimize }).module("espn_client");
    const server = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "sprts_core", .module = core }, .{ .name = "espn_client", .module = espn } },
    });
    const exe = b.addExecutable(.{
        .name = "sprts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "sprts_server", .module = server }, .{ .name = "sprts_core", .module = core } },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the server").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = server });
    b.step("test", "Run server tests").dependOn(&b.addRunArtifact(tests).step);
}
