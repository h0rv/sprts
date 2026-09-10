const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("sprts_core", .{ .target = target, .optimize = optimize }).module("sprts_core");
    const sprts_client = b.dependency("sprts_client", .{ .target = target, .optimize = optimize }).module("sprts_client");
    const cli = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sprts_core", .module = core },
            .{ .name = "sprts_client", .module = sprts_client },
        },
    });
    const exe = b.addExecutable(.{
        .name = "sprts-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sprts_cli", .module = cli },
                .{ .name = "sprts_core", .module = core },
                .{ .name = "sprts_client", .module = sprts_client },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = cli });
    b.step("test", "Run CLI tests").dependOn(&b.addRunArtifact(tests).step);
}
