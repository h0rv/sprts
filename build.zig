const std = @import("std");
const workers_zig = @import("workers-zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("sprts_core", .{ .target = target, .optimize = optimize }).module("sprts_core");
    const espn = b.dependency("espn_client", .{ .target = target, .optimize = optimize }).module("espn_client");
    const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize }).module("zchema");
    const server_module = b.createModule(.{
        .root_source_file = b.path("apps/server/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sprts_core", .module = core },
            .{ .name = "espn_client", .module = espn },
            .{ .name = "zchema", .module = zchema },
        },
    });
    const exe = b.addExecutable(.{
        .name = "sprts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/server/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sprts_server", .module = server_module },
                .{ .name = "sprts_core", .module = core },
                .{ .name = "zchema", .module = zchema },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the sprts server").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = server_module });
    b.step("test", "Run all monorepo tests").dependOn(&b.addRunArtifact(tests).step);

    // Cloudflare Worker (wasm32+wasi, ReleaseSmall). Imported ONLY by the
    // worker entry; native exe above is unaffected. workers-zig's addWorker
    // post-processes to worker.wasm + entry.js + shim.js in zig-out/bin.
    const workers_dep = b.dependency("workers-zig", .{});
    const worker_exe = workers_zig.addWorker(b, workers_dep, b.path("apps/server/src/worker.zig"), .{
        .name = "worker",
        .optimize = .ReleaseSmall,
    });

    // Worker-only imports. addWorker seeds the user module with just
    // workers-zig, so attach wasm-target instances of the portable modules
    // here.
    //
    // NOTE on granularity: per-file zchema submodules (validation/openapi/…)
    // are not expressible — Zig 0.16 requires every file to belong to exactly
    // one module, and zchema's sources import each other relatively
    // (validation→errors, routes→errors/markers/contract,
    // openapi→routes/validation), so any split fails with "file exists in
    // modules …". The worker therefore imports the full zchema root compiled
    // for wasm. This is still free of non-portable code: zchema's server
    // files only ever touch `std.http.Server` as parameter/return types (no
    // socket/thread/posix imports), and the worker only ever reaches the
    // portable entry points (`serializeAndValidate`, `openApiJson`, `Spec`,
    // `endpoint`, `case`, `ErrorBody`) — dispatch/app/helpers bodies are
    // never instantiated and are eliminated from the artifact.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasm_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const core_wasm = b.dependency("sprts_core", .{ .target = wasm_target, .optimize = wasm_optimize }).module("sprts_core");
    const espn_wasm = b.dependency("espn_client", .{ .target = wasm_target, .optimize = wasm_optimize }).module("espn_client");
    const zchema_wasm = b.dependency("zchema", .{ .target = wasm_target, .optimize = wasm_optimize }).module("zchema");
    const worker_user = worker_exe.root_module.import_table.get("worker_main") orelse
        @panic("workers-zig addWorker user module missing");
    worker_user.addImport("sprts_core", core_wasm);
    worker_user.addImport("espn_client", espn_wasm);
    worker_user.addImport("zchema", zchema_wasm);
    const wasm_step = b.step("wasm", "Build the Cloudflare Worker (wasm32+wasi)");
    wasm_step.dependOn(&worker_exe.step);
    wasm_step.dependOn(b.getInstallStep());
}
