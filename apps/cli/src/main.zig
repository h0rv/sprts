/// `sprts-tui` entrypoint: parse args, dispatch to `app.run`.
///
/// Wave 2 is one-shot only (`--plain` default, `--json` raw dump). Any
/// failure prints one readable line to stderr and exits nonzero — never a
/// stack trace.
const std = @import("std");
const cli_app = @import("sprts_cli");
const core = @import("sprts_core");
const sprts_client = @import("sprts_client");

const LiveState = struct {
    http: *std.http.Client,
    io: std.Io,

    fn fetch(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!sprts_client.FetchResult {
        const self: *LiveState = @ptrCast(@alignCast(ptr));
        const uri = try std.Uri.parse(url);
        var body: std.Io.Writer.Allocating = .init(arena);
        defer body.deinit();
        const res = try self.http.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .extra_headers = extra_headers,
            .payload = null,
            .response_writer = &body.writer,
        });
        return .{ .status = res.status, .body = try body.toOwnedSlice() };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var err_buf: [4096]u8 = undefined;
    var err_file = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_file.interface;

    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, gpa) catch {
        err.writeAll("sprts-tui: out of memory\n") catch {};
        err.flush() catch {};
        std.process.exit(1);
    };
    defer args_iter.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (args_iter.next()) |arg| argv.append(gpa, arg) catch {
        err.writeAll("sprts-tui: out of memory\n") catch {};
        err.flush() catch {};
        std.process.exit(1);
    };

    const opts = cli_app.cli.parseArgs(argv.items) catch |parse_err| {
        err.print("sprts-tui: {t} (see --help)\n", .{parse_err}) catch {};
        err.flush() catch {};
        std.process.exit(1);
    };

    var out_buf: [8192]u8 = undefined;
    var out_file = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_file.interface;

    if (opts.help) {
        cli_app.cli.printUsage(out) catch {
            err.writeAll("sprts-tui: failed to write help\n") catch {};
            err.flush() catch {};
            std.process.exit(1);
        };
        out.flush() catch {};
        return;
    }

    const base_url = opts.host orelse sprts_client.default_base_url;
    const epoch = std.Io.Clock.real.now(io).toSeconds();
    const today = core.date.todayET(gpa, epoch) catch null;
    defer if (today) |t| gpa.free(t);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var live = LiveState{ .http = &http, .io = io };
    const transport: sprts_client.HttpTransport = .{ .ptr = &live, .fetchFn = LiveState.fetch };

    // Interactive loop by default on a real terminal; pipes stay one-shot.
    const tty = cli_app.tui.stdioIsTerminal();

    cli_app.app.run(gpa, arena, transport, base_url, opts, today, out, err, io, tty) catch {
        out.flush() catch {};
        err.flush() catch {};
        std.process.exit(1);
    };
    out.flush() catch {};
    err.flush() catch {};
}
