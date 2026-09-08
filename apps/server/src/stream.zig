//! Pure SSE streaming helpers shared by the native server entry.
//!
//! No sockets, no threads, no clock, no mutex here: everything is a pure
//! function of its inputs so it is unit-tested natively via the server
//! module and can be reused verbatim by the worker entry. `main.zig` wires
//! these pieces to `std.http.Server` chunked responses plus a mutex-guarded
//! subscriber registry keyed by (league, day, render params).

const std = @import("std");
const core = @import("sprts_core");
const domain = core.domain;

/// Prefix for every SSE payload: clear the terminal and home the cursor so
/// plain `curl -N` redraws the scoreboard in place with zero client logic
/// (the terminal just interprets escape codes it received).
pub const clear_prefix = "\x1b[2J\x1b[H";

/// Keepalive comment frame, sent when no scoreboard change is due. SSE
/// comments (`:`) are ignored by event parsers but keep the connection alive
/// and surface dead peers on the next flush.
pub const keepalive_frame = ": ping\n\n";

/// Seconds between client-visible keepalive comments when nothing changed.
pub const keepalive_s: u64 = 15;

/// Poll cadence in seconds while at least one game is live.
pub const live_poll_s: u64 = 12;
/// Poll cadence in seconds when games are scheduled but none has started.
pub const idle_poll_s: u64 = 120;
/// Poll cadence in seconds when everything is final (or the slate is empty).
pub const final_poll_s: u64 = 300;

/// SSE wire headers for a scoreboard stream.
pub const content_type = "text/event-stream";
pub const cache_control = "no-cache";

/// How often the server re-polls ESPN for this board: fast while any game
/// state is "in", slow for scheduled slates, slowest when all final. Pure so
/// the cadence table is unit-testable without timers.
pub fn pollIntervalSec(board: domain.Scoreboard) u64 {
    var saw_pre = false;
    for (board.games) |game| {
        if (std.mem.eql(u8, game.state, "in")) return live_poll_s;
        if (std.mem.eql(u8, game.state, "pre")) saw_pre = true;
    }
    if (saw_pre) return idle_poll_s;
    return final_poll_s;
}

/// Fingerprint of everything a text render shows: league, day, and per game
/// the identity/state/status plus every participant's identity, score, and
/// winner mark. Equal boards render equal text, so the server only pushes an
/// SSE frame when the fingerprint moves.
pub fn fingerprint(board: domain.Scoreboard) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(board.league);
    h.update(board.league_name);
    h.update(board.date);
    for (board.games) |game| {
        h.update(game.id);
        h.update(game.name);
        h.update(game.state);
        h.update(game.status);
        h.update(game.starts_at);
        for (game.participants) |participant| {
            h.update(participant.id);
            h.update(participant.name);
            h.update(participant.abbreviation);
            h.update(participant.score);
            h.update(if (participant.winner) "1" else "0");
            h.update(participant.home_away orelse "");
        }
    }
    return h.final();
}

/// True when the board changed between two fingerprints.
pub fn changed(previous: u64, current: u64) bool {
    return previous != current;
}

/// Frame one full render as SSE `data:` lines terminated by a blank line.
/// The clear-screen prefix opens the first data line so `curl -N` repaints
/// in place. Multi-line bodies become one `data:` line each; empty lines
/// become bare `data:` markers.
pub fn frame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var first = true;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (first) {
            first = false;
            if (line.len == 0) {
                try w.writeAll("data: " ++ clear_prefix ++ "\n");
            } else {
                try w.print("data: {s}{s}\n", .{ clear_prefix, line });
            }
        } else if (line.len == 0) {
            try w.writeAll("data:\n");
        } else {
            try w.print("data: {s}\n", .{line});
        }
    }
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

/// Subscriber-registry key: lowercase league slug, concrete day, and render
/// params. Frames are cached per distinct render, so subscribers that render
/// identically share one ESPN poll; a different color/width/height is a
/// different resource with its own poll timer.
pub fn subKey(
    allocator: std.mem.Allocator,
    slug: []const u8,
    day: []const u8,
    color: bool,
    width: ?u16,
    height: ?u16,
) ![]u8 {
    const lower = try allocator.dupe(u8, slug);
    defer allocator.free(lower);
    for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
    const color_tag: []const u8 = if (color) "1" else "0";
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{s}|{s}|{s}|", .{ lower, day, color_tag });
    if (width) |value| {
        try w.print("{d}|", .{value});
    } else {
        try w.writeAll("-|");
    }
    if (height) |value| {
        try w.print("{d}", .{value});
    } else {
        try w.writeAll("-");
    }
    return out.toOwnedSlice();
}

/// Per-resource refcounts shared by the subscriber registry in `main.zig`.
/// The live map itself (`std.StringHashMap(usize)` plus a mutex) lives in
/// the server entry because locks are not worker-portable; this type only
/// owns the pure transitions so they stay unit-testable here. Each SSE
/// connection attaches on entry and detaches on exit (including write
/// failure): while at least one subscriber is attached the serve loop keeps
/// polling ESPN for that resource, and the last disconnect stops the timer
/// because the count drops to zero.
pub const Subscribers = struct {
    counts: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) Subscribers {
        return .{ .counts = .init(allocator) };
    }

    pub fn deinit(self: *Subscribers, allocator: std.mem.Allocator) void {
        var it = self.counts.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.counts.deinit();
    }

    /// Attach one subscriber; returns the new count for the key. The first
    /// attach dupes the key so it lives as long as the entry.
    pub fn attach(self: *Subscribers, allocator: std.mem.Allocator, key: []const u8) !usize {
        const entry = try self.counts.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, key);
            entry.value_ptr.* = 1;
        } else {
            entry.value_ptr.* += 1;
        }
        return entry.value_ptr.*;
    }

    /// Detach one subscriber; returns the remaining count (0 when the last
    /// subscriber left and polling must stop). Frees the owned key at zero.
    /// Detaching an unknown key is a no-op returning 0.
    pub fn detach(self: *Subscribers, allocator: std.mem.Allocator, key: []const u8) usize {
        const entry = self.counts.getEntry(key) orelse return 0;
        if (entry.value_ptr.* > 1) {
            entry.value_ptr.* -= 1;
            return entry.value_ptr.*;
        }
        const owned = entry.key_ptr.*;
        self.counts.removeByPtr(entry.key_ptr);
        allocator.free(owned);
        return 0;
    }

    pub fn count(self: *const Subscribers, key: []const u8) usize {
        return self.counts.get(key) orelse 0;
    }
};

/// Shared per-resource poll state for SSE fan-out. Lock-free: the mutex lives
/// in `main.zig` (locks are not worker-portable); this type only owns the
/// pure transitions plus owned frame bytes so the single-fetch rule stays
/// unit-testable here.
///
/// Contract used by `serveSse` (all calls under the server mutex):
/// - `needsPoll` / `claim`: at most one connection fetches per interval.
///   `claim` marks `last_poll_s = now` before the fetch, so concurrent ticks
///   from other subscribers see "not due" while the fetch is in flight, and
///   a failed fetch still backs off (no cache update, next attempt only after
///   the interval).
/// - `store`: the fetcher publishes the rendered frame (duped into the
///   long-lived cache allocator), fingerprint, and next interval.
/// - Non-fetchers `get` the entry and push a copy when `changed(last, fp)`.
pub const SharedCache = struct {
    entries: std.StringHashMap(Entry),

    pub const Entry = struct {
        last_poll_s: i64,
        fingerprint: u64,
        interval_s: u64,
        frame: []u8,
        ready: bool,
    };

    pub fn init(allocator: std.mem.Allocator) SharedCache {
        return .{ .entries = .init(allocator) };
    }

    pub fn deinit(self: *SharedCache, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.frame);
        }
        self.entries.deinit();
    }

    /// True when the resource needs a fresh ESPN poll: no entry yet, or the
    /// shared interval has elapsed since the last claim.
    pub fn needsPoll(self: *const SharedCache, key: []const u8, now_s: i64) bool {
        const entry = self.entries.get(key) orelse return true;
        return now_s - entry.last_poll_s >= @as(i64, @intCast(entry.interval_s));
    }

    /// Claim fetchership if due. Returns true when the caller must fetch;
    /// marks `last_poll_s = now` so other ticks back off until the interval
    /// elapses (including when the fetch later fails). A missing entry
    /// inserts a not-ready placeholder with a live-rate fallback interval.
    pub fn claim(self: *SharedCache, allocator: std.mem.Allocator, key: []const u8, now_s: i64) !bool {
        const res = try self.entries.getOrPut(key);
        if (!res.found_existing) {
            errdefer self.entries.removeByPtr(res.key_ptr);
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            const owned_frame = try allocator.dupe(u8, "");
            res.key_ptr.* = owned_key;
            res.value_ptr.* = .{
                .last_poll_s = now_s,
                .fingerprint = 0,
                .interval_s = live_poll_s,
                .frame = owned_frame,
                .ready = false,
            };
            return true;
        }
        const current = res.value_ptr;
        if (now_s - current.last_poll_s >= @as(i64, @intCast(current.interval_s))) {
            current.last_poll_s = now_s;
            return true;
        }
        return false;
    }

    /// Publish a fetched frame. Dupes key and frame into the cache allocator,
    /// freeing the previous frame. Overwrites placeholders and stale entries.
    pub fn store(
        self: *SharedCache,
        allocator: std.mem.Allocator,
        key: []const u8,
        now_s: i64,
        fp: u64,
        interval_s: u64,
        event: []const u8,
    ) !void {
        const res = try self.entries.getOrPut(key);
        if (!res.found_existing) {
            errdefer self.entries.removeByPtr(res.key_ptr);
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            const owned_frame = try allocator.dupe(u8, event);
            res.key_ptr.* = owned_key;
            res.value_ptr.* = .{
                .last_poll_s = now_s,
                .fingerprint = fp,
                .interval_s = interval_s,
                .frame = owned_frame,
                .ready = true,
            };
            return;
        }
        const owned_frame = try allocator.dupe(u8, event);
        allocator.free(res.value_ptr.frame);
        res.value_ptr.* = .{
            .last_poll_s = now_s,
            .fingerprint = fp,
            .interval_s = interval_s,
            .frame = owned_frame,
            .ready = true,
        };
    }

    /// Copy of the entry for locked reads. The frame slice still points at
    /// cache-owned memory: dupe it before unlocking.
    pub fn get(self: *const SharedCache, key: []const u8) ?Entry {
        return self.entries.get(key);
    }

    /// Drop an entry, freeing its owned key and frame. Used when the last
    /// subscriber for a resource disconnects so idle keys don't accumulate.
    pub fn remove(self: *SharedCache, allocator: std.mem.Allocator, key: []const u8) void {
        const entry = self.entries.getEntry(key) orelse return;
        const owned_key = entry.key_ptr.*;
        allocator.free(entry.value_ptr.frame);
        self.entries.removeByPtr(entry.key_ptr);
        allocator.free(owned_key);
    }
};

fn liveBoard() domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false },
                },
            },
            .{
                .id = "2",
                .name = "Second at Third",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "c", .name = "Second", .abbreviation = "SEC", .score = "", .winner = false },
                },
            },
        },
    };
}

test "poll interval follows game state" {
    // Any live game polls fast, even next to scheduled ones.
    try std.testing.expectEqual(live_poll_s, pollIntervalSec(liveBoard()));

    const pre_only: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "2",
                .name = "Second at Third",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{},
            },
        },
    };
    try std.testing.expectEqual(idle_poll_s, pollIntervalSec(pre_only));

    const all_final: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{},
            },
        },
    };
    try std.testing.expectEqual(final_poll_s, pollIntervalSec(all_final));

    const empty: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{},
    };
    try std.testing.expectEqual(final_poll_s, pollIntervalSec(empty));
}

test "fingerprint is stable and moves on visible change" {
    const first = fingerprint(liveBoard());
    const same = fingerprint(liveBoard());
    try std.testing.expectEqual(first, same);
    try std.testing.expect(!changed(first, same));

    var scored = liveBoard();
    var games = [_]domain.Game{scored.games[0]};
    var participants = [_]domain.Participant{
        .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "1", .winner = false },
        .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false },
    };
    games[0].participants = &participants;
    scored.games = &games;
    const moved = fingerprint(scored);
    try std.testing.expect(changed(first, moved));

    var final_board = liveBoard();
    var final_games = [_]domain.Game{final_board.games[0]};
    final_games[0].state = "post";
    final_games[0].status = "Final";
    final_board.games = &final_games;
    try std.testing.expect(changed(first, fingerprint(final_board)));
}

test "SSE frame carries clear prefix, data lines, and blank terminator" {
    const event = try frame(std.testing.allocator, "line one\nline two\n");
    defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, clear_prefix) != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "data:") != null);
    try std.testing.expect(std.mem.endsWith(u8, event, "\n\n"));
    try std.testing.expect(std.mem.startsWith(u8, event, "data: " ++ clear_prefix ++ "line one\n"));
    try std.testing.expect(std.mem.indexOf(u8, event, "data: line two\n") != null);
}

test "SSE frame handles empty lines and empty bodies" {
    const event = try frame(std.testing.allocator, "a\n\nb");
    defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "data:\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, event, "\n\n"));

    const empty = try frame(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, clear_prefix) != null);
    try std.testing.expect(std.mem.endsWith(u8, empty, "\n\n"));
}

test "keepalive is an SSE comment frame" {
    try std.testing.expectEqualStrings(": ping\n\n", keepalive_frame);
    try std.testing.expect(std.mem.startsWith(u8, keepalive_frame, ":"));
    try std.testing.expect(std.mem.endsWith(u8, keepalive_frame, "\n\n"));
}

test "subscriber key separates leagues, days, and renders" {
    const arena = std.testing.allocator;
    const a = try subKey(arena, "MLB", "2026-09-06", true, null, null);
    defer arena.free(a);
    try std.testing.expectEqualStrings("mlb|2026-09-06|1|-|-", a);

    const b = try subKey(arena, "mlb", "2026-09-06", true, null, null);
    defer arena.free(b);
    try std.testing.expectEqualStrings(a, b);

    const other_day = try subKey(arena, "mlb", "2026-09-07", true, null, null);
    defer arena.free(other_day);
    try std.testing.expect(!std.mem.eql(u8, a, other_day));

    const other_render = try subKey(arena, "mlb", "2026-09-06", false, 80, 10);
    defer arena.free(other_render);
    try std.testing.expectEqualStrings("mlb|2026-09-06|0|80|10", other_render);
    try std.testing.expect(!std.mem.eql(u8, a, other_render));
}

test "subscriber counts track attach and detach per key" {
    const allocator = std.testing.allocator;
    var subscribers = Subscribers.init(allocator);
    defer subscribers.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), subscribers.count("mlb|2026-09-06|1|-|-"));
    try std.testing.expectEqual(@as(usize, 1), try subscribers.attach(allocator, "mlb|2026-09-06|1|-|-"));
    try std.testing.expectEqual(@as(usize, 1), subscribers.count("mlb|2026-09-06|1|-|-"));
    try std.testing.expectEqual(@as(usize, 2), try subscribers.attach(allocator, "mlb|2026-09-06|1|-|-"));
    try std.testing.expectEqual(@as(usize, 2), subscribers.count("mlb|2026-09-06|1|-|-"));
    // A different resource is untouched by the first key's subscribers.
    try std.testing.expectEqual(@as(usize, 0), subscribers.count("nba|2026-09-06|1|-|-"));

    try std.testing.expectEqual(@as(usize, 1), subscribers.detach(allocator, "mlb|2026-09-06|1|-|-"));
    // The last disconnect drops the count to zero: polling for the resource
    // must stop here.
    try std.testing.expectEqual(@as(usize, 0), subscribers.detach(allocator, "mlb|2026-09-06|1|-|-"));
    try std.testing.expectEqual(@as(usize, 0), subscribers.count("mlb|2026-09-06|1|-|-"));
    // Detaching an unknown key is a no-op.
    try std.testing.expectEqual(@as(usize, 0), subscribers.detach(allocator, "mlb|2026-09-06|1|-|-"));
}

test "shared cache: one fetch per interval across subscribers" {
    const allocator = std.testing.allocator;
    var cache = SharedCache.init(allocator);
    defer cache.deinit(allocator);
    const key = "mlb|2026-09-06|1|-|-";

    // No entry yet: first subscriber must fetch.
    try std.testing.expect(cache.needsPoll(key, 1000));
    try std.testing.expect(try cache.claim(allocator, key, 1000));

    // Second tick before the interval elapsed: not due, no refetch.
    // A failed fetch leaves the placeholder without updating the cache, but
    // the claim already advanced last_poll, so the next tick backs off.
    try std.testing.expect(!cache.needsPoll(key, 1001));
    try std.testing.expect(!try cache.claim(allocator, key, 1001));

    // Interval elapsed: due again, exactly one claimant wins.
    try std.testing.expect(cache.needsPoll(key, 1000 + @as(i64, @intCast(live_poll_s))));
    try std.testing.expect(try cache.claim(allocator, key, 1000 + @as(i64, @intCast(live_poll_s))));
    try std.testing.expect(!try cache.claim(allocator, key, 1000 + @as(i64, @intCast(live_poll_s))));
}

test "shared cache: store publishes frame for lagging subscribers" {
    const allocator = std.testing.allocator;
    var cache = SharedCache.init(allocator);
    defer cache.deinit(allocator);
    const key = "mlb|2026-09-06|1|-|-";

    try cache.store(allocator, key, 1000, 0xABCD, 12, "data: hello\n\n");
    try std.testing.expect(!cache.needsPoll(key, 1005));
    try std.testing.expect(cache.needsPoll(key, 1012));

    const entry = cache.get(key).?;
    try std.testing.expect(entry.ready);
    try std.testing.expectEqual(@as(u64, 0xABCD), entry.fingerprint);
    try std.testing.expectEqual(@as(u64, 12), entry.interval_s);
    try std.testing.expectEqualStrings("data: hello\n\n", entry.frame);

    // A lagging subscriber sees the change against its own last fingerprint.
    try std.testing.expect(changed(0, entry.fingerprint));
    // Re-storing replaces the frame without leaking the old bytes.
    try cache.store(allocator, key, 1012, 0x1234, 300, "data: final\n\n");
    const next = cache.get(key).?;
    try std.testing.expectEqual(@as(u64, 0x1234), next.fingerprint);
    try std.testing.expectEqualStrings("data: final\n\n", next.frame);

    // Dropping the entry when the last subscriber leaves frees key+frame.
    cache.remove(allocator, key);
    try std.testing.expect(cache.get(key) == null);
    try std.testing.expect(cache.needsPoll(key, 1013));
}
