/// Argument parsing for `sprts-tui` (wave 2: one-shot `--plain` mode).
///
/// Grammar: `sprts-tui [league] [--date YYYY-MM-DD|today|tomorrow|yesterday]
/// [--plain] [--host URL] [--json] [--tui] [--help]`. `--plain` is the
/// default one-shot path; `--tui` parses so `app.run` can report its wave-3
/// stub instead of an unknown-flag error.

const std = @import("std");
const core = @import("sprts_core");
const sprts_client = @import("sprts_client");

pub const Options = struct {
    league: ?[]const u8 = null,
    date: ?[]const u8 = null,
    host: ?[]const u8 = null,
    json: bool = false,
    plain: bool = false,
    tui: bool = false,
    help: bool = false,
};

pub const ParseError = error{ UnknownArgument, MissingValue, InvalidDate };

/// Parse `argv` including `argv[0]` (skipped, pts-style). Borrows slices.
pub fn parseArgs(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var positional: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--plain")) {
            opts.plain = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            opts.tui = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--date")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (!core.date.validate(args[i]) and !core.date.isRelativeToken(args[i])) return error.InvalidDate;
            opts.date = args[i];
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.host = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            if (positional > 0) return error.UnknownArgument;
            opts.league = arg;
            positional += 1;
        }
    }
    return opts;
}

/// Resolve the `--date` value to the `YYYY-MM-DD` the API wants: plain dates
/// pass through, relative tokens shift off `today`. Null in, null out.
/// Pure; no clock reads (the caller supplies `today`).
pub fn resolveQueryDate(allocator: std.mem.Allocator, raw: ?[]const u8, today: ?[]const u8) !?[]u8 {
    const r = raw orelse return null;
    if (core.date.validate(r)) return try allocator.dupe(u8, r);
    const t = today orelse return error.InvalidDate;
    const resolved = try core.date.resolveDate(allocator, r, t);
    return resolved;
}

pub fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\sprts-tui - one-shot scores from the sprts API
        \\
        \\Usage:
        \\  sprts-tui [league] [--date DATE] [--plain] [--host URL] [--json]
        \\  sprts-tui --help
        \\
        \\Leagues:
        \\
    );
    for (&core.leagues.all) |*league| {
        try w.print("  {s}\n", .{league.slug});
    }
    try w.writeAll("  (omit the league to show every league)\n\nFlags:\n");
    try w.writeAll(
        \\  --date DATE   Scoreboard date: YYYY-MM-DD, today, tomorrow or yesterday (default: today)
        \\  --plain       Print a compact text scoreboard and exit (default one-shot mode)
        \\
    );
    try w.print("  --host URL    API base URL (default: {s})\n", .{sprts_client.default_base_url});
    try w.writeAll(
        \\  --json        Dump the raw API response body and exit
        \\  --tui         Interactive mode (not yet: coming in wave 3)
        \\  --help, -h    Print this help
        \\
        \\Keys (coming in wave 3): j/down move · k/up move · h/left prev day · l/right next day · enter open · r refresh · / filter · a auto · ? help · b back · q quit
        \\
    );
}

test "defaults: bare invocation" {
    const opts = try parseArgs(&.{"sprts-tui"});
    try std.testing.expect(opts.league == null);
    try std.testing.expect(opts.date == null);
    try std.testing.expect(opts.host == null);
    try std.testing.expect(!opts.json and !opts.plain and !opts.tui and !opts.help);
}

test "league positional plus date tokens are accepted" {
    const dated = try parseArgs(&.{ "sprts-tui", "mlb", "--date", "2026-09-06" });
    try std.testing.expectEqualStrings("mlb", dated.league.?);
    try std.testing.expectEqualStrings("2026-09-06", dated.date.?);
    for ([_][]const u8{ "today", "tomorrow", "yesterday" }) |token| {
        const opts = try parseArgs(&.{ "sprts-tui", "--date", token });
        try std.testing.expectEqualStrings(token, opts.date.?);
    }
}

test "host json plain tui help flags" {
    const opts = try parseArgs(&.{ "sprts-tui", "nfl", "--host", "http://localhost:8080", "--json", "--plain", "--tui" });
    try std.testing.expectEqualStrings("nfl", opts.league.?);
    try std.testing.expectEqualStrings("http://localhost:8080", opts.host.?);
    try std.testing.expect(opts.json and opts.plain and opts.tui);
    try std.testing.expect((try parseArgs(&.{ "sprts-tui", "--help" })).help);
    try std.testing.expect((try parseArgs(&.{ "sprts-tui", "-h" })).help);
}

test "bad dates and missing values error" {
    try std.testing.expectError(error.InvalidDate, parseArgs(&.{ "sprts-tui", "--date", "not-a-date" }));
    try std.testing.expectError(error.InvalidDate, parseArgs(&.{ "sprts-tui", "--date", "Tomorrow" }));
    try std.testing.expectError(error.InvalidDate, parseArgs(&.{ "sprts-tui", "--date", "2026-13-01" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "sprts-tui", "--date" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "sprts-tui", "--host" }));
}

test "unknown flags and extra positionals error" {
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "sprts-tui", "--refresh" }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "sprts-tui", "--color" }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "sprts-tui", "--url", "http://x" }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "sprts-tui", "mlb", "nfl" }));
}

test "date forms resolve to query URLs" {
    const alloc = std.testing.allocator;
    const base = "https://sprts.horv.co";
    const today = "2026-09-06";

    const tomorrow = try resolveQueryDate(alloc, "tomorrow", today);
    defer if (tomorrow) |d| alloc.free(d);
    try std.testing.expectEqualStrings("2026-09-07", tomorrow.?);
    const yesterday = try resolveQueryDate(alloc, "yesterday", today);
    defer if (yesterday) |d| alloc.free(d);
    try std.testing.expectEqualStrings("2026-09-05", yesterday.?);
    const passthrough = try resolveQueryDate(alloc, "2026-09-01", today);
    defer if (passthrough) |d| alloc.free(d);
    try std.testing.expectEqualStrings("2026-09-01", passthrough.?);
    try std.testing.expect(try resolveQueryDate(alloc, null, today) == null);
    try std.testing.expectError(error.InvalidDate, resolveQueryDate(alloc, "tomorrow", null));

    const dated = try sprts_client.buildScoreboardUrl(alloc, base, "mlb", tomorrow, null);
    defer alloc.free(dated);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/mlb?date=2026-09-07", dated);
    const bare = try sprts_client.buildScoreboardUrl(alloc, base, "mlb", null, null);
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/mlb", bare);
    const all_dated = try sprts_client.buildAllUrl(alloc, base, yesterday);
    defer alloc.free(all_dated);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/all?date=2026-09-05", all_dated);
    const all_bare = try sprts_client.buildAllUrl(alloc, base, null);
    defer alloc.free(all_bare);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/all", all_bare);
}

test "usage names the binary plus wave-3 keys" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try printUsage(&out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "sprts-tui [league]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--host") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--json") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coming in wave 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "j/down") != null);
}
