/// SSE live snapshots for the CLI TUI (wave 3).
///
/// The server renders scoreboard streams as SSE text frames on the short
/// route (`/{league}?stream=sse`, text-only: the JSON API answers `stream`
/// with a single document). One frame is a `:mtime <epoch>` comment line
/// followed by one `data:` line per text row and a blank terminator; the
/// first data line opens with a clear-screen prefix so `curl -N` repaints.
///
/// The TUI consumes snapshots over the client's one-shot `HttpTransport`
/// seam (tests inject canned frames; no network): a fresh frame hash drives
/// a typed JSON refetch, a failed/empty SSE read falls back to plain
/// polling. A future deadline-capable transport can read frames
/// incrementally; until then any stall surfaces as a fetch error and the
/// caller polls.
const std = @import("std");
const sprts_client = @import("sprts_client");

/// Accept header selecting the server's text SSE stream.
pub const sse_accept_value = "text/event-stream";
pub const sse_headers: []const std.http.Header = &.{.{ .name = "accept", .value = sse_accept_value }};

/// Clear-screen prefix the server opens the first data line with so naive
/// viewers repaint in place. Stripped before display; the TUI repaints via
/// its own alternate-screen frame.
pub const clear_prefix = "\x1b[2J\x1b[H";

/// Latest consumable event parsed out of an SSE body.
pub const Snapshot = struct {
    text: []u8,
    mtime: ?i64,
    has_data: bool,
    hash: u64,
};

/// Pure URL builder for the text stream: `{base}/{league}[?date=][&stream=sse]`.
pub fn buildSseUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    league: []const u8,
    date: ?[]const u8,
) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print("{s}/{s}", .{ base_url, league });
    var first = true;
    if (date) |day| {
        try url.writer.print("{c}date={s}", .{ if (first) @as(u8, '?') else @as(u8, '&'), day });
        first = false;
    }
    try url.writer.print("{c}stream=sse", .{if (first) @as(u8, '?') else @as(u8, '&')});
    return url.toOwnedSlice();
}

/// Parse an SSE body into the latest event: `data:` lines joined with
/// newlines, `:` comments ignored except `:mtime <epoch>`. Later events win;
/// keepalive-only bodies (`: ping`) yield `has_data == false`.
pub fn parseBody(allocator: std.mem.Allocator, body: []const u8) !Snapshot {
    var latest_text: ?[][]const u8 = null;
    var latest_mtime: ?i64 = null;
    var has_data = false;

    var cur_lines: std.ArrayList([]const u8) = .empty;
    defer cur_lines.deinit(allocator);
    var cur_mtime: ?i64 = null;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (cur_lines.items.len > 0) {
                if (latest_text) |old| allocator.free(old);
                latest_text = try allocator.dupe([]const u8, cur_lines.items);
                if (cur_mtime) |m| latest_mtime = m;
                has_data = true;
                cur_lines.clearRetainingCapacity();
                cur_mtime = null;
            } else if (cur_mtime) |m| {
                // Timestamp-only event: freshness without visible change.
                latest_mtime = m;
                cur_mtime = null;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, ":")) {
            if (parseMtime(line)) |m| cur_mtime = m;
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            var payload = line["data:".len..];
            if (std.mem.startsWith(u8, payload, " ")) payload = payload[1..];
            if (std.mem.startsWith(u8, payload, clear_prefix)) payload = payload[clear_prefix.len..];
            try cur_lines.append(allocator, payload);
            continue;
        }
        // Non-SSE line: not part of the stream; ignore for robustness.
    }
    // Unterminated trailing event still commits (one-shot bodies may trim it).
    if (cur_lines.items.len > 0) {
        if (latest_text) |old| allocator.free(old);
        latest_text = try allocator.dupe([]const u8, cur_lines.items);
        if (cur_mtime) |m| latest_mtime = m;
        has_data = true;
    } else if (cur_mtime) |m| {
        latest_mtime = m;
    }

    const parts = latest_text orelse &.{};
    defer if (latest_text) |owned| allocator.free(owned);
    const text = try std.mem.join(allocator, "\n", parts);
    var h = std.hash.Wyhash.init(0);
    h.update(text);
    return .{ .text = text, .mtime = latest_mtime, .has_data = has_data, .hash = h.final() };
}

fn parseMtime(line: []const u8) ?i64 {
    const prefix = ":mtime ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const digits = std.mem.trim(u8, line[prefix.len..], " \t");
    if (digits.len == 0) return null;
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

/// Fetch one SSE snapshot over any transport. Non-2xx, empty, or
/// keepalive-only bodies are errors so the caller falls back to polling.
pub fn fetchSnapshot(
    arena: std.mem.Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    date: ?[]const u8,
) !Snapshot {
    const url = try buildSseUrl(arena, base_url, league, date);
    const res = transport.fetch(arena, url, sse_headers) catch return error.SseFetchFailed;
    if (res.status.class() != .success) return error.SseBadStatus;
    const snap = try parseBody(arena, res.body);
    if (!snap.has_data) {
        arena.free(snap.text);
        return error.SseEmpty;
    }
    return snap;
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

fn parseCase(allocator: std.mem.Allocator, body: []const u8) !Snapshot {
    return parseBody(allocator, body);
}

test "sse data lines join into one text body" {
    const snap = try parseCase(std.testing.allocator,
        \\:mtime 1757328000
        \\data: line one
        \\data: line two
        \\
    );
    defer std.testing.allocator.free(snap.text);
    try std.testing.expect(snap.has_data);
    try std.testing.expectEqualStrings("line one\nline two", snap.text);
    try std.testing.expectEqual(@as(?i64, 1757328000), snap.mtime);
}

test "sse comments are ignored but mtime is captured" {
    const snap = try parseCase(std.testing.allocator,
        \\: ping
        \\:mtime 42
        \\data: hello
        \\
    );
    defer std.testing.allocator.free(snap.text);
    try std.testing.expect(snap.has_data);
    try std.testing.expectEqualStrings("hello", snap.text);
    try std.testing.expectEqual(@as(?i64, 42), snap.mtime);
}

test "sse clear-screen prefix is stripped from the first data line" {
    const snap = try parseCase(std.testing.allocator, ":mtime 7\ndata: \x1b[2J\x1b[HMLB (mlb)\ndata: AWY 2 @ HME 5\n\n");
    defer std.testing.allocator.free(snap.text);
    try std.testing.expectEqualStrings("MLB (mlb)\nAWY 2 @ HME 5", snap.text);
    try std.testing.expectEqual(@as(?i64, 7), snap.mtime);
}

test "sse bare data markers and missing space are tolerated" {
    const snap = try parseCase(std.testing.allocator, "data:one\ndata:\ndata: two\n\n");
    defer std.testing.allocator.free(snap.text);
    try std.testing.expectEqualStrings("one\n\ntwo", snap.text);
    try std.testing.expect(snap.mtime == null);
}

test "sse latest event wins and keepalives never clobber" {
    const snap = try parseCase(std.testing.allocator,
        \\:mtime 1
        \\data: old frame
        \\
        \\: ping
        \\
        \\:mtime 2
        \\data: new frame
        \\
        \\: ping
        \\
    );
    defer std.testing.allocator.free(snap.text);
    try std.testing.expectEqualStrings("new frame", snap.text);
    try std.testing.expectEqual(@as(?i64, 2), snap.mtime);
}

test "sse unterminated trailing event still commits" {
    const snap = try parseCase(std.testing.allocator, ":mtime 9\ndata: partial");
    defer std.testing.allocator.free(snap.text);
    try std.testing.expect(snap.has_data);
    try std.testing.expectEqualStrings("partial", snap.text);
    try std.testing.expectEqual(@as(?i64, 9), snap.mtime);
}

test "sse keepalive-only body has no data" {
    const snap = try parseCase(std.testing.allocator, ": ping\n\n: ping\n\n");
    defer std.testing.allocator.free(snap.text);
    try std.testing.expect(!snap.has_data);
    try std.testing.expectEqualStrings("", snap.text);
}

test "sse frame hash moves with the text" {
    const a = try parseCase(std.testing.allocator, "data: same\n\n");
    defer std.testing.allocator.free(a.text);
    const b = try parseCase(std.testing.allocator, "data: same\n\n");
    defer std.testing.allocator.free(b.text);
    const c = try parseCase(std.testing.allocator, "data: changed\n\n");
    defer std.testing.allocator.free(c.text);
    try std.testing.expectEqual(a.hash, b.hash);
    try std.testing.expect(a.hash != c.hash);
}

test "sse url builder carries league date and stream flag" {
    const dated = try buildSseUrl(std.testing.allocator, "https://example.test", "mlb", "2026-09-06");
    defer std.testing.allocator.free(dated);
    try std.testing.expectEqualStrings("https://example.test/mlb?date=2026-09-06&stream=sse", dated);
    const bare = try buildSseUrl(std.testing.allocator, "https://example.test", "nfl", null);
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("https://example.test/nfl?stream=sse", bare);
}

test "sse fetch hits the stream url and parses frames without network" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = ":mtime 100\ndata: \x1b[2J\x1b[HMLB\ndata: row\n\n" };
    const snap = try fetchSnapshot(arena, fake.asTransport(), "https://example.test", "mlb", "2026-09-06");
    try std.testing.expectEqualStrings("https://example.test/mlb?date=2026-09-06&stream=sse", fake.seen_url.?);
    try std.testing.expectEqualStrings("MLB\nrow", snap.text);
    try std.testing.expectEqual(@as(?i64, 100), snap.mtime);
}

test "sse fetch failures and empty streams fall back to polling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var down = FakeTransportState{ .body = "oops", .status = .bad_gateway };
    try std.testing.expectError(error.SseBadStatus, fetchSnapshot(arena, down.asTransport(), "https://example.test", "mlb", null));

    var quiet = FakeTransportState{ .body = ": ping\n\n" };
    try std.testing.expectError(error.SseEmpty, fetchSnapshot(arena, quiet.asTransport(), "https://example.test", "mlb", null));

    var refused = FakeTransportState{ .fail = error.ConnectionRefused };
    try std.testing.expectError(error.SseFetchFailed, fetchSnapshot(arena, refused.asTransport(), "https://example.test", "mlb", null));
}
