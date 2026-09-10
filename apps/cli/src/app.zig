/// One-shot dispatch for `sprts-tui` (wave 2).
///
/// Pure orchestration over the client's `HttpTransport` seam: resolve the
/// date, fetch typed structs (or the raw body for `--json`), render with
/// `plain`. Diagnostics go to `err`; success output to `out`. The entrypoint
/// maps any error to a nonzero exit without stack traces.

const std = @import("std");
const core = @import("sprts_core");
const sprts_client = @import("sprts_client");
const cli = @import("cli.zig");
const plain = @import("plain.zig");

pub fn run(
    arena: std.mem.Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    opts: cli.Options,
    today: ?[]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    if (opts.tui) {
        try err.writeAll("sprts-tui: tui mode is not yet implemented (coming in wave 3)\n");
        return error.TuiNotImplemented;
    }
    if (opts.league) |slug| {
        if (core.leagues.find(slug) == null) {
            try err.print("sprts-tui: unknown league '{s}' (see --help)\n", .{slug});
            return error.UnknownLeague;
        }
    }
    const date = cli.resolveQueryDate(arena, opts.date, today) catch {
        try err.writeAll("sprts-tui: invalid date (want YYYY-MM-DD, today, tomorrow, yesterday)\n");
        return error.InvalidDate;
    };

    if (opts.league) |slug| {
        const url = try sprts_client.buildScoreboardUrl(arena, base_url, slug, date, null);
        const res = transport.fetch(arena, url, sprts_client.default_headers) catch |fetch_err| {
            try err.print("sprts-tui: fetch failed: {t}\n", .{fetch_err});
            return error.FetchFailed;
        };
        if (res.status.class() != .success) {
            try err.print("sprts-tui: request failed: HTTP {d}\n", .{@intFromEnum(res.status)});
            return error.BadResponse;
        }
        if (opts.json) return out.writeAll(res.body);
        var result = try sprts_client.gen.parseRawResponse(
            sprts_client.Scoreboard,
            .{ .allocator = arena, .status = res.status, .body = res.body },
        );
        defer result.deinit();
        switch (result) {
            .ok => |*ok| try out.writeAll(try plain.renderScoreboard(arena, ok.value().*)),
            .api_error => unreachable, // non-2xx returned above
            .parse_error => |*parse| {
                try err.print("sprts-tui: bad response: {s}\n", .{parse.error_name});
                return error.BadResponse;
            },
        }
    } else {
        const url = try sprts_client.buildAllUrl(arena, base_url, date);
        const res = transport.fetch(arena, url, sprts_client.default_headers) catch |fetch_err| {
            try err.print("sprts-tui: fetch failed: {t}\n", .{fetch_err});
            return error.FetchFailed;
        };
        if (res.status.class() != .success) {
            try err.print("sprts-tui: request failed: HTTP {d}\n", .{@intFromEnum(res.status)});
            return error.BadResponse;
        }
        if (opts.json) return out.writeAll(res.body);
        var result = try sprts_client.gen.parseRawResponse(
            sprts_client.DigestJson,
            .{ .allocator = arena, .status = res.status, .body = res.body },
        );
        defer result.deinit();
        switch (result) {
            .ok => |*ok| try out.writeAll(try plain.renderDigest(arena, ok.value().*)),
            .api_error => unreachable, // non-2xx returned above
            .parse_error => |*parse| {
                try err.print("sprts-tui: bad response: {s}\n", .{parse.error_name});
                return error.BadResponse;
            },
        }
    }
}

const FakeTransportState = struct {
    seen_url: ?[]const u8 = null,
    body: []const u8 = "",
    status: std.http.Status = .ok,
    fail: ?anyerror = null,

    fn dispatch(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!sprts_client.FetchResult {
        _ = extra_headers;
        const self: *FakeTransportState = @ptrCast(@alignCast(ptr));
        self.seen_url = try arena.dupe(u8, url);
        if (self.fail) |e| return e;
        return .{ .status = self.status, .body = try arena.dupe(u8, self.body) };
    }

    fn asTransport(self: *FakeTransportState) sprts_client.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

const canned_scoreboard =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","date":"2026-09-06","source":"test","games":[
    \\{"id":"1","name":"","starts_at":"2026-09-06T17:00Z","state":"post","status":"Final","participants":[
    \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":"10-5"},
    \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"5","winner":true,"home_away":"home","record":"12-3"}]},
    \\{"id":"2","name":"","starts_at":"2026-09-06T19:00Z","state":"in","status":"Top 7th","participants":[
    \\{"id":"b","name":"Bee Club","abbreviation":"BEE","score":"0","winner":false,"home_away":"away","record":null},
    \\{"id":"c","name":"Cee Club","abbreviation":"CEE","score":"3","winner":false,"home_away":"home","record":null}]}]}
;

const canned_digest =
    \\{"date":"2026-09-06","schema_version":"1","degraded":[],"leagues":[
    \\{"source":"test","date":"2026-09-06","games":[],"schema_version":"1","league":"mlb","league_name":"MLB"},
    \\{"source":"test","date":"2026-09-06","games":[{"id":"7","name":"","starts_at":"2026-09-06T17:00Z","state":"post","status":"Final","participants":[
    \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":null},
    \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"5","winner":true,"home_away":"home","record":null}]}],"schema_version":"1","league":"nfl","league_name":"NFL"}]}
;

fn runCase(
    arena: std.mem.Allocator,
    fake: *FakeTransportState,
    opts: cli.Options,
    today: ?[]const u8,
) !struct { out: []u8, err: []u8 } {
    var out_alloc: std.Io.Writer.Allocating = .init(arena);
    var err_alloc: std.Io.Writer.Allocating = .init(arena);
    run(arena, fake.asTransport(), "https://example.test", opts, today, &out_alloc.writer, &err_alloc.writer) catch |e| {
        return e;
    };
    return .{ .out = out_alloc.written(), .err = err_alloc.written() };
}

test "one-shot scoreboard fetches the dated URL and prints rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_scoreboard };
    const got = try runCase(arena, &fake, .{ .league = "mlb", .date = "tomorrow" }, "2026-09-06");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb?date=2026-09-07", fake.seen_url.?);
    try std.testing.expect(std.mem.indexOf(u8, got.out, "MLB (mlb) — 2026-09-06") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.out, "AWY (10-5) 2 @ HME (12-3) 5  Final") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.out, "BEE 0 @ CEE 3  Top 7th") != null);
}

test "omitted league fans out to the digest URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_digest };
    const got = try runCase(arena, &fake, .{}, "2026-09-06");
    try std.testing.expectEqualStrings("https://example.test/api/v1/all", fake.seen_url.?);
    try std.testing.expect(std.mem.indexOf(u8, got.out, "NFL (nfl)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.out, "AWY 2 @ HME 5  Final") != null);
}

test "json dumps the raw body verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_scoreboard };
    const got = try runCase(arena, &fake, .{ .league = "mlb", .json = true }, "2026-09-06");
    try std.testing.expectEqualStrings(canned_scoreboard, got.out);
}

test "fetch failure exits nonzero with a readable message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .fail = error.ConnectionRefused };
    var out_alloc: std.Io.Writer.Allocating = .init(arena);
    var err_alloc: std.Io.Writer.Allocating = .init(arena);
    const result = run(arena, fake.asTransport(), "https://example.test", .{ .league = "mlb" }, "2026-09-06", &out_alloc.writer, &err_alloc.writer);
    try std.testing.expectError(error.FetchFailed, result);
    try std.testing.expect(std.mem.indexOf(u8, err_alloc.written(), "fetch failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_alloc.written(), "ConnectionRefused") != null);
}

test "http error status exits nonzero with the status code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = "oops", .status = .bad_gateway };
    var out_alloc: std.Io.Writer.Allocating = .init(arena);
    var err_alloc: std.Io.Writer.Allocating = .init(arena);
    const result = run(arena, fake.asTransport(), "https://example.test", .{ .league = "mlb" }, "2026-09-06", &out_alloc.writer, &err_alloc.writer);
    try std.testing.expectError(error.BadResponse, result);
    try std.testing.expect(std.mem.indexOf(u8, err_alloc.written(), "HTTP 502") != null);
}

test "tui flag is a not-yet stub error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{};
    var out_alloc: std.Io.Writer.Allocating = .init(arena);
    var err_alloc: std.Io.Writer.Allocating = .init(arena);
    const result = run(arena, fake.asTransport(), "https://example.test", .{ .tui = true }, "2026-09-06", &out_alloc.writer, &err_alloc.writer);
    try std.testing.expectError(error.TuiNotImplemented, result);
    try std.testing.expect(std.mem.indexOf(u8, err_alloc.written(), "not yet") != null);
    try std.testing.expect(fake.seen_url == null);
}

test "unknown league never touches the network" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_scoreboard };
    var out_alloc: std.Io.Writer.Allocating = .init(arena);
    var err_alloc: std.Io.Writer.Allocating = .init(arena);
    const result = run(arena, fake.asTransport(), "https://example.test", .{ .league = "quidditch" }, "2026-09-06", &out_alloc.writer, &err_alloc.writer);
    try std.testing.expectError(error.UnknownLeague, result);
    try std.testing.expect(std.mem.indexOf(u8, err_alloc.written(), "unknown league") != null);
    try std.testing.expect(fake.seen_url == null);
}
