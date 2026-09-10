/// Interactive TUI loop for `sprts-tui` (wave 3), ported from pts `ui.zig`.
///
/// Same bones: raw-mode stdin, poll-based key reads, alternate screen,
/// per-frame render, footer with freshness. The data layer differs: pts
/// scrapes pages over HTTP, this TUI fetches typed JSON over the sprts
/// client's injectable `HttpTransport` (tests inject fakes; no network) and
/// consumes `?stream=sse` snapshots (see `sse.zig`) to drive live refreshes
/// instead of re-polling.
///
/// Views: leagues picker -> scoreboard -> game detail -> team schedule, plus
/// standings off `s`. `enter` opens the selected row (game, or a team row
/// inside game/standings); `b`/esc pops back and refetches like pts. Pure
/// helpers (keys, viewport, filter, age, navigation, loaders, row text) are
/// unit-tested; only the terminal loop itself needs a live TTY.
const std = @import("std");
const core = @import("sprts_core");
const sprts_client = @import("sprts_client");
const gen = sprts_client.gen;
const cli = @import("cli.zig");
const sse = @import("sse.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Keys (vim-first, pts conventions)
// ---------------------------------------------------------------------------

pub const Key = enum {
    none,
    quit,
    down,
    up,
    page_down,
    page_up,
    prev_day,
    next_day,
    top,
    bottom,
    enter,
    back,
    refresh,
    standings,
    auto,
    help,
    filter,
};

/// Single-byte key decoding. Lone ESC decodes to back; escape sequences
/// (`ESC [ A` ...) are resolved by `decodeEscapeTail` in the loop.
pub fn decodeByte(b: u8) Key {
    return switch (b) {
        'q' => .quit,
        'j' => .down,
        'k' => .up,
        'd', ' ' => .page_down,
        'u' => .page_up,
        'h' => .prev_day,
        'l' => .next_day,
        'g' => .top,
        'G' => .bottom,
        '\r', '\n' => .enter,
        'b' => .back,
        27 => .back,
        'r' => .refresh,
        's' => .standings,
        'a' => .auto,
        '?' => .help,
        '/' => .filter,
        else => .none,
    };
}

/// Decode the bytes after an ESC: `A`/`B` arrows, `C`/`D` day steps,
/// `5`/`6` page steps (optional `~` terminator). Anything else is back.
pub fn decodeEscapeTail(tail: []const u8) Key {
    if (tail.len == 0) return .back;
    if (tail[0] != '[') return .back;
    const code = if (tail.len > 1) tail[1] else return .back;
    return switch (code) {
        'A' => .up,
        'B' => .down,
        'C' => .next_day,
        'D' => .prev_day,
        '5' => .page_up,
        '6' => .page_down,
        else => .back,
    };
}

// ---------------------------------------------------------------------------
// Viewport / scroll math (pts: header row + clamped scroll window)
// ---------------------------------------------------------------------------

pub const header_rows: usize = 2;
pub const footer_rows: usize = 2;
pub const min_body_rows: usize = 1;
pub const list_header_rows: usize = 1;

/// Body rows available for list content given a terminal height.
pub fn bodyRows(term_rows: usize) usize {
    const reserved = header_rows + footer_rows;
    if (term_rows > reserved + min_body_rows) return term_rows - reserved;
    return min_body_rows;
}

/// Selectable rows visible at once (one header line above the list).
pub fn visibleRows(body_rows: usize) usize {
    if (body_rows > list_header_rows) return body_rows - list_header_rows;
    return min_body_rows;
}

/// Scroll offset keeping `selected` on screen.
pub fn ensureVisible(selected: usize, scroll: usize, visible: usize) usize {
    if (visible == 0) return 0;
    if (selected < scroll) return selected;
    if (selected >= scroll + visible) return selected - visible + 1;
    return scroll;
}

/// Clamp a selection into `[0, count)`.
pub fn clampSelected(selected: usize, count: usize) usize {
    if (count == 0) return 0;
    if (selected >= count) return count - 1;
    return selected;
}

pub fn moveDown(selected: usize, count: usize, amount: usize) usize {
    if (count == 0) return 0;
    return @min(count - 1, selected + amount);
}

pub fn moveUp(selected: usize, amount: usize) usize {
    if (selected > amount) return selected - amount;
    return 0;
}

// ---------------------------------------------------------------------------
// Filter matching (case-insensitive substring over row fields)
// ---------------------------------------------------------------------------

pub fn matchesFilter(query: []const u8, fields: []const []const u8) bool {
    if (query.len == 0) return true;
    for (fields) |field| {
        if (std.ascii.indexOfIgnoreCase(field, query) != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Last-updated footer age ("updated 12s ago", minutes/hours graduation)
// ---------------------------------------------------------------------------

/// Human age of the latest fetch or SSE `:mtime` frame. Future timestamps
/// clamp to zero; graduation is seconds < minutes < hours.
pub fn formatAge(allocator: Allocator, now_s: i64, updated_s: i64) ![]u8 {
    const age: i64 = if (now_s > updated_s) now_s - updated_s else 0;
    if (age < 60) return std.fmt.allocPrint(allocator, "updated {d}s ago", .{age});
    if (age < 3600) return std.fmt.allocPrint(allocator, "updated {d}m ago", .{@divTrunc(age, 60)});
    return std.fmt.allocPrint(allocator, "updated {d}h ago", .{@divTrunc(age, 3600)});
}

// ---------------------------------------------------------------------------
// Navigation state (history stack of lightweight frames; back refetches)
// ---------------------------------------------------------------------------

pub const ViewTag = enum { leagues, board, game, team, standings };

pub const Frame = struct {
    view: ViewTag,
    league: []const u8,
    target: []const u8,
    date: ?[]const u8,
};

pub const Navigator = struct {
    alloc: Allocator,
    current: Frame,
    history: std.ArrayList(Frame) = .empty,

    pub fn init(alloc: Allocator, root: Frame) !Navigator {
        return .{ .alloc = alloc, .current = try dupeFrame(alloc, root) };
    }

    pub fn deinit(self: *Navigator) void {
        freeFrame(self.alloc, &self.current);
        for (self.history.items) |*frame| freeFrame(self.alloc, frame);
        self.history.deinit(self.alloc);
    }

    /// Push `current` and move to `next`; selection resets at the call site.
    pub fn open(self: *Navigator, next: Frame) !void {
        try self.history.append(self.alloc, try dupeFrame(self.alloc, self.current));
        freeFrame(self.alloc, &self.current);
        self.current = try dupeFrame(self.alloc, next);
    }

    /// Pop back; false when already at the root (caller stays put).
    pub fn back(self: *Navigator) bool {
        const prev = self.history.pop() orelse return false;
        freeFrame(self.alloc, &self.current);
        self.current = prev;
        return true;
    }

    fn dupeFrame(alloc: Allocator, frame: Frame) !Frame {
        return .{
            .view = frame.view,
            .league = try alloc.dupe(u8, frame.league),
            .target = try alloc.dupe(u8, frame.target),
            .date = if (frame.date) |d| try alloc.dupe(u8, d) else null,
        };
    }

    fn freeFrame(alloc: Allocator, frame: *Frame) void {
        alloc.free(frame.league);
        alloc.free(frame.target);
        if (frame.date) |d| alloc.free(d);
    }
};

// ---------------------------------------------------------------------------
// Typed loaders over the transport seam (fake-friendly, no network)
// ---------------------------------------------------------------------------

pub const LoadError = error{ FetchFailed, BadStatus, BadBody, OutOfMemory };

/// Fetch a league scoreboard; arena owns the returned slices.
pub fn loadBoard(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    date: ?[]const u8,
) LoadError!sprts_client.Scoreboard {
    var result = sprts_client.fetchScoreboard(arena, transport, base_url, league, date, null) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch one game detail; arena owns the returned slices.
pub fn loadGame(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    id: []const u8,
) LoadError!sprts_client.DetailGame {
    var result = sprts_client.fetchGame(arena, transport, base_url, league, id) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch one team schedule view; arena owns the returned slices.
pub fn loadTeam(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    abbr: []const u8,
) LoadError!sprts_client.ScheduleTeamView {
    var result = sprts_client.fetchTeam(arena, transport, base_url, league, abbr) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch league standings; arena owns the returned slices.
pub fn loadStandings(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
) LoadError!sprts_client.LeagueStandings {
    var result = sprts_client.fetchStandings(arena, transport, base_url, league) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch the league picker list; arena owns the returned slices.
pub fn loadLeagues(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
) LoadError!sprts_client.LeagueList {
    var result = sprts_client.fetchLeagues(arena, transport, base_url) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// True while any board game is live (`state == "in"`, the server's cadence key).
pub fn boardHasLive(board: sprts_client.Scoreboard) bool {
    for (board.games) |game| {
        if (std.mem.eql(u8, game.state, "in")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Row text (compact `AWY 2 @ HME 5  Final` rows, plain.zig shape)
// ---------------------------------------------------------------------------

pub fn gameRowText(allocator: Allocator, game: gen.ScoreboardGamesItem) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    const away = pickSide(game.participants, "away", 0);
    const home = pickSide(game.participants, "home", 1);
    if (away == null or home == null) {
        const label = if (game.name.len > 0) game.name else game.id;
        try w.print("{s}  {s}", .{ label, game.status });
        return out.toOwnedSlice();
    }
    try teamChunk(w, away.?);
    try w.writeAll(" @ ");
    try teamChunk(w, home.?);
    try w.print("  {s}", .{game.status});
    return out.toOwnedSlice();
}

fn teamChunk(w: *std.Io.Writer, p: gen.ScoreboardGamesItemParticipantsItem) !void {
    try w.writeAll(p.abbreviation);
    if (p.record) |record| try w.print(" ({s})", .{record});
    if (p.score.len > 0) try w.print(" {s}", .{p.score});
}

fn pickSide(
    parts: []const gen.ScoreboardGamesItemParticipantsItem,
    want: []const u8,
    fallback: usize,
) ?gen.ScoreboardGamesItemParticipantsItem {
    for (parts) |p| {
        if (p.home_away) |ha| if (std.mem.eql(u8, ha, want)) return p;
    }
    if (fallback < parts.len) return parts[fallback];
    return null;
}

pub fn gameFilterFields(game: gen.ScoreboardGamesItem) [5][]const u8 {
    const away = pickSide(game.participants, "away", 0);
    const home = pickSide(game.participants, "home", 1);
    return .{
        if (away) |a| a.name else "",
        if (away) |a| a.abbreviation else "",
        if (home) |h| h.name else "",
        if (home) |h| h.abbreviation else "",
        game.status,
    };
}

pub fn standingsRowText(allocator: Allocator, group: []const u8, entry: gen.LeagueStandingsGroupsItemEntriesItem) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(entry.abbrev);
    const wins = entry.wins orelse "";
    const losses = entry.losses orelse "";
    if (wins.len > 0 or losses.len > 0) {
        try w.writeAll(" ");
        try w.writeAll(wins);
        try w.writeByte('-');
        try w.writeAll(losses);
        if (entry.ties) |ties| {
            try w.writeByte('-');
            try w.writeAll(ties);
        }
    }
    try w.print("  {s}  {s}", .{ entry.name, group });
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Screen renderers (header + scroll window + footer; help overlay)
// ---------------------------------------------------------------------------

pub const ViewContext = struct {
    league_name: []const u8 = "",
    league: []const u8 = "",
    date: []const u8 = "",
    view_label: []const u8 = "",
    age_text: []const u8 = "",
    auto_refresh: bool = false,
    filter: []const u8 = "",
    err: ?[]const u8 = null,
};

pub fn renderHeader(w: *std.Io.Writer, ctx: ViewContext) !void {
    if (ctx.league_name.len > 0) {
        try w.print("{s} ({s}) — {s}  [{s}]\n", .{ ctx.league_name, ctx.league, ctx.date, ctx.view_label });
    } else {
        try w.print("sprts  [{s}]\n", .{ctx.view_label});
    }
    if (ctx.filter.len > 0) try w.print("filter: {s}\n", .{ctx.filter}) else try w.writeByte('\n');
}

pub fn renderBoardRows(
    w: *std.Io.Writer,
    allocator: Allocator,
    games: []const gen.ScoreboardGamesItem,
    filter: []const u8,
    selected: usize,
    scroll: usize,
    visible: usize,
) !void {
    try w.writeAll("GAMES\n");
    var filtered: usize = 0;
    var emitted: usize = 0;
    for (games) |game| {
        const fields = gameFilterFields(game);
        if (!matchesFilter(filter, &fields)) continue;
        if (filtered < scroll) {
            filtered += 1;
            continue;
        }
        if (emitted >= visible) return;
        const row = try gameRowText(allocator, game);
        defer allocator.free(row);
        const live = std.mem.eql(u8, game.state, "in");
        try w.print("{s}{s}{s}\n", .{ if (filtered == selected) "> " else "  ", if (live) "LIVE " else "", row });
        filtered += 1;
        emitted += 1;
    }
    if (filtered == 0) try w.writeAll("No games match filter. Press / to change.\n");
}

pub fn renderFooter(w: *std.Io.Writer, ctx: ViewContext) !void {
    if (ctx.err) |msg| try w.print("ERROR: {s}\n", .{msg});
    try w.print("{s} · auto:{s} · j/k move · h/l day · enter open · s standings · / filter · r refresh · a auto · ? help · b back · q quit\n", .{
        ctx.age_text,
        if (ctx.auto_refresh) "on" else "off",
    });
}

pub fn renderHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\sprts-tui - Help
        \\
        \\j/down       Move down            k/up         Move up
        \\h/left       Previous day         l/right      Next day
        \\enter        Open game or team    b/esc        Back
        \\s            Standings            /            Filter
        \\r            Refresh              a            Toggle auto-refresh
        \\?            This help            q            Quit
        \\
        \\Live boards and live games auto-refresh from the server SSE
        \\stream while auto is on; anything else polls on refresh.
        \\
        \\Press ? or b to close.
        \\
    );
}

// ---------------------------------------------------------------------------
// Terminal plumbing (ported from pts ui.zig: raw mode, poll, alt screen)
// ---------------------------------------------------------------------------

const escape_key: u8 = 27;
const delete_key: u8 = 127;
const backspace_key: u8 = 8;
const poll_tick_ms: i32 = 1000;
const refresh_interval_s: i64 = 15;

pub const RawMode = struct {
    active: bool = false,
    original: if (@import("builtin").os.tag == .linux) std.posix.termios else void = if (@import("builtin").os.tag == .linux) undefined else {},

    pub fn init() RawMode {
        if (@import("builtin").os.tag != .linux) return .{};
        var self: RawMode = .{};
        self.original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return .{};
        var raw = self.original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return .{};
        self.active = true;
        return self;
    }

    pub fn deinit(self: *RawMode) void {
        if (@import("builtin").os.tag != .linux) return;
        if (self.active) std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

/// True when `fd` is a terminal (tcgetattr fails on pipes/files).
/// No `isatty` in this Zig version; termios probing is the equivalent.
pub fn fdIsTerminal(fd: std.posix.fd_t) bool {
    if (@import("builtin").os.tag != .linux) return false;
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

pub fn stdioIsTerminal() bool {
    return fdIsTerminal(std.posix.STDIN_FILENO) and fdIsTerminal(std.posix.STDOUT_FILENO);
}

fn inputReady(timeout_ms: i32) !bool {
    if (@import("builtin").os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, timeout_ms) != 0;
}

fn readByte(io: std.Io) !u8 {
    var b: [1]u8 = undefined;
    while (true) {
        const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
        if (n != 0) return b[0];
    }
}

fn readEscapeTail(io: std.Io) !Key {
    if (!try inputReady(0)) return .back;
    const b1 = try readByte(io);
    if (b1 != '[') return .back;
    if (!try inputReady(0)) return .back;
    const b2 = try readByte(io);
    // Consume a trailing `~` on `5`/`6` when present.
    if ((b2 == '5' or b2 == '6') and try inputReady(0)) {
        const b3 = try readByte(io);
        if (b3 == '~') return if (b2 == '5') .page_up else .page_down;
        return decodeEscapeTail(&.{ '[', b2 });
    }
    return decodeEscapeTail(&.{ '[', b2 });
}

fn readKey(io: std.Io, timeout_ms: i32) !Key {
    if (!try inputReady(timeout_ms)) return .none;
    const first = try readByte(io);
    if (first == escape_key) return readEscapeTail(io);
    return decodeByte(first);
}

fn promptFilter(io: std.Io, allocator: Allocator, old: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print("\x1b[?25h\nfilter [{s}]: ", .{old});
    try writeStdout(io, out.written());

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        var b: [1]u8 = undefined;
        const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
        if (n == 0) continue;
        if (b[0] == '\r' or b[0] == '\n') break;
        if (b[0] == escape_key) break;
        if (b[0] == delete_key or b[0] == backspace_key) {
            if (list.items.len > 0) {
                list.shrinkRetainingCapacity(list.items.len - 1);
                try writeStdout(io, "\x08 \x08");
            }
            continue;
        }
        if (b[0] < ' ') continue;
        try list.append(allocator, b[0]);
        try writeStdout(io, &b);
    }
    try writeStdout(io, "\x1b[?25l");
    if (list.items.len == 0) return allocator.dupe(u8, "");
    return list.toOwnedSlice(allocator);
}

fn terminalSize() struct { rows: usize, cols: usize } {
    if (@import("builtin").os.tag == .linux) {
        var ws: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        return .{
            .rows = if (rc == 0 and ws.row > 0) ws.row else 24,
            .cols = if (rc == 0 and ws.col > 0) ws.col else 80,
        };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeFrame(io: std.Io, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b != '\n') continue;
        if (i > start) try writeStdout(io, bytes[start..i]);
        try writeStdout(io, "\x1b[K\n");
        start = i + 1;
    }
    if (start < bytes.len) try writeStdout(io, bytes[start..]);
    try writeStdout(io, "\x1b[K\x1b[J");
}

// ---------------------------------------------------------------------------
// Interactive session
// ---------------------------------------------------------------------------

const Tui = struct {
    gpa: Allocator,
    io: std.Io,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    view_arena: std.heap.ArenaAllocator,
    nav: Navigator,
    selected: usize = 0,
    scroll: usize = 0,
    filter: []u8,
    auto_refresh: bool = true,
    show_help: bool = false,
    last_update_s: ?i64 = null,
    last_fetch_s: ?i64 = null,
    last_error: ?[]u8 = null,
    sse_hash: ?u64 = null,
    leagues: ?sprts_client.LeagueList = null,
    board: ?sprts_client.Scoreboard = null,
    game: ?sprts_client.DetailGame = null,
    team: ?sprts_client.ScheduleTeamView = null,
    standings: ?sprts_client.LeagueStandings = null,

    fn init(
        gpa: Allocator,
        io: std.Io,
        transport: sprts_client.HttpTransport,
        base_url: []const u8,
        root: Frame,
    ) !Tui {
        const filter = try gpa.dupe(u8, "");
        errdefer gpa.free(filter);
        var nav = try Navigator.init(gpa, root);
        errdefer nav.deinit();
        return .{
            .gpa = gpa,
            .io = io,
            .transport = transport,
            .base_url = base_url,
            .view_arena = std.heap.ArenaAllocator.init(gpa),
            .nav = nav,
            .filter = filter,
        };
    }

    fn deinit(self: *Tui) void {
        self.view_arena.deinit();
        self.nav.deinit();
        self.gpa.free(self.filter);
        if (self.last_error) |msg| self.gpa.free(msg);
    }

    fn viewAlloc(self: *Tui) Allocator {
        return self.view_arena.allocator();
    }

    /// Wipe per-view fetched data (all view slices are arena-owned).
    fn resetView(self: *Tui) void {
        self.view_arena.deinit();
        self.view_arena = std.heap.ArenaAllocator.init(self.gpa);
        self.leagues = null;
        self.board = null;
        self.game = null;
        self.team = null;
        self.standings = null;
        self.selected = 0;
        self.scroll = 0;
    }

    fn setError(self: *Tui, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error) |msg| self.gpa.free(msg);
        self.last_error = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    }

    fn clearError(self: *Tui) void {
        if (self.last_error) |msg| self.gpa.free(msg);
        self.last_error = null;
    }

    fn nowS(self: *Tui) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    fn markUpdated(self: *Tui) void {
        const now = self.nowS();
        self.last_update_s = now;
        self.last_fetch_s = now;
    }

    fn frameDate(self: *Tui) ?[]const u8 {
        return self.nav.current.date;
    }

    fn loadCurrent(self: *Tui) void {
        const frame = self.nav.current;
        switch (frame.view) {
            .leagues => self.reloadLeagues(),
            .board => self.reloadBoard(),
            .game => self.reloadGame(frame.league, frame.target),
            .team => self.reloadTeam(frame.league, frame.target),
            .standings => self.reloadStandings(frame.league),
        }
    }

    fn reloadLeagues(self: *Tui) void {
        self.resetView();
        self.leagues = loadLeagues(self.viewAlloc(), self.transport, self.base_url) catch |err| {
            self.setError("leagues failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn reloadBoard(self: *Tui) void {
        const frame = self.nav.current;
        self.resetView();
        self.board = loadBoard(self.viewAlloc(), self.transport, self.base_url, frame.league, frame.date) catch |err| {
            self.setError("scoreboard failed: {t}", .{err});
            return;
        };
        // Server-canonical date keeps h/l stepping exact.
        if (self.board) |board| {
            const owned = self.gpa.dupe(u8, board.date) catch null;
            if (owned) |day| {
                if (self.nav.current.date) |old| self.gpa.free(old);
                self.nav.current.date = day;
            }
        }
        self.clearError();
        self.markUpdated();
    }

    fn reloadGame(self: *Tui, league: []const u8, id: []const u8) void {
        self.resetView();
        self.game = loadGame(self.viewAlloc(), self.transport, self.base_url, league, id) catch |err| {
            self.setError("game failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn reloadTeam(self: *Tui, league: []const u8, abbr: []const u8) void {
        self.resetView();
        self.team = loadTeam(self.viewAlloc(), self.transport, self.base_url, league, abbr) catch |err| {
            self.setError("team failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn reloadStandings(self: *Tui, league: []const u8) void {
        self.resetView();
        self.standings = loadStandings(self.viewAlloc(), self.transport, self.base_url, league) catch |err| {
            self.setError("standings failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn openFrame(self: *Tui, next: Frame) void {
        self.nav.open(next) catch {
            self.setError("out of memory", .{});
            return;
        };
        self.resetView();
        self.setFilter("");
        self.sse_hash = null;
        self.loadCurrent();
    }

    fn goBack(self: *Tui) void {
        if (self.show_help) {
            self.show_help = false;
            return;
        }
        if (!self.nav.back()) return;
        self.resetView();
        self.setFilter("");
        self.sse_hash = null;
        self.loadCurrent();
    }

    fn setFilter(self: *Tui, value: []const u8) void {
        self.gpa.free(self.filter);
        self.filter = self.gpa.dupe(u8, value) catch self.gpa.dupe(u8, "") catch unreachable;
        self.selected = 0;
        self.scroll = 0;
        self.selected = clampSelected(self.selected, self.rowCount());
    }

    fn rowCount(self: *Tui) usize {
        const frame = self.nav.current;
        var n: usize = 0;
        switch (frame.view) {
            .leagues => {
                const list = self.leagues orelse return 0;
                for (list.leagues) |entry| {
                    if (matchesFilter(self.filter, &.{ entry.slug, entry.name })) n += 1;
                }
            },
            .board => {
                const board = self.board orelse return 0;
                for (board.games) |game| {
                    const fields = gameFilterFields(game);
                    if (matchesFilter(self.filter, &fields)) n += 1;
                }
            },
            .game => {
                const game = self.game orelse return 0;
                for (game.participants) |p| {
                    if (matchesFilter(self.filter, &.{ p.abbreviation, p.name })) n += 1;
                }
            },
            .team => return 0,
            .standings => {
                const table = self.standings orelse return 0;
                for (table.groups) |group| {
                    for (group.entries) |entry| {
                        if (matchesFilter(self.filter, &.{ entry.abbrev, entry.name, group.name })) n += 1;
                    }
                }
            },
        }
        return n;
    }

    fn clampSelection(self: *Tui) void {
        self.selected = clampSelected(self.selected, self.rowCount());
        if (self.scroll > self.selected) self.scroll = self.selected;
    }

    fn selectedGame(self: *Tui) ?gen.ScoreboardGamesItem {
        const board = self.board orelse return null;
        var n: usize = 0;
        for (board.games) |game| {
            const fields = gameFilterFields(game);
            if (!matchesFilter(self.filter, &fields)) continue;
            if (n == self.selected) return game;
            n += 1;
        }
        return null;
    }

    fn selectedLeague(self: *Tui) ?gen.LeagueListLeaguesItem {
        const list = self.leagues orelse return null;
        var n: usize = 0;
        for (list.leagues) |entry| {
            if (!matchesFilter(self.filter, &.{ entry.slug, entry.name })) continue;
            if (n == self.selected) return entry;
            n += 1;
        }
        return null;
    }

    fn selectedParticipant(self: *Tui) ?gen.DetailGameParticipantsItem {
        const game = self.game orelse return null;
        var n: usize = 0;
        for (game.participants) |p| {
            if (!matchesFilter(self.filter, &.{ p.abbreviation, p.name })) continue;
            if (n == self.selected) return p;
            n += 1;
        }
        return null;
    }

    fn selectedStanding(self: *Tui) ?gen.LeagueStandingsGroupsItemEntriesItem {
        const table = self.standings orelse return null;
        var n: usize = 0;
        for (table.groups) |group| {
            for (group.entries) |entry| {
                if (!matchesFilter(self.filter, &.{ entry.abbrev, entry.name, group.name })) continue;
                if (n == self.selected) return entry;
                n += 1;
            }
        }
        return null;
    }

    fn openSelected(self: *Tui) void {
        const frame = self.nav.current;
        switch (frame.view) {
            .leagues => {
                const entry = self.selectedLeague() orelse return;
                self.openFrame(.{ .view = .board, .league = entry.slug, .target = "", .date = frame.date });
            },
            .board => {
                const game = self.selectedGame() orelse return;
                self.openFrame(.{ .view = .game, .league = frame.league, .target = game.id, .date = frame.date });
            },
            .game => {
                const p = self.selectedParticipant() orelse return;
                self.openFrame(.{ .view = .team, .league = frame.league, .target = p.abbreviation, .date = frame.date });
            },
            .standings => {
                const entry = self.selectedStanding() orelse return;
                self.openFrame(.{ .view = .team, .league = frame.league, .target = entry.abbrev, .date = frame.date });
            },
            .team => {},
        }
    }

    fn openStandings(self: *Tui) void {
        const frame = self.nav.current;
        if (frame.view == .leagues or frame.league.len == 0) {
            self.setError("pick a league first", .{});
            return;
        }
        if (frame.view == .standings) return;
        self.openFrame(.{ .view = .standings, .league = frame.league, .target = "", .date = frame.date });
    }

    fn stepDay(self: *Tui, delta: i32) void {
        const frame = self.nav.current;
        if (frame.view != .board) return;
        const day = frame.date orelse {
            self.setError("no date loaded yet", .{});
            return;
        };
        const shifted = core.date.shift(self.gpa, day, delta) catch {
            self.setError("bad date '{s}'", .{day});
            return;
        };
        defer self.gpa.free(shifted);
        self.gpa.free(self.nav.current.date.?);
        self.nav.current.date = self.gpa.dupe(u8, shifted) catch {
            self.setError("out of memory", .{});
            return;
        };
        self.sse_hash = null;
        self.reloadBoard();
    }

    /// Auto-refresh tick: live boards/games consume the SSE stream and only
    /// refetch typed JSON when a fresh frame lands; SSE errors fall back to
    /// plain polling. Quiet views refresh on the same cadence.
    fn tick(self: *Tui) void {
        if (!self.auto_refresh) return;
        const now = self.nowS();
        const last = self.last_fetch_s orelse 0;
        if (self.last_fetch_s != null and now - last < refresh_interval_s) return;
        self.last_fetch_s = now;
        const frame = self.nav.current;
        switch (frame.view) {
            .board => self.tickBoard(),
            .game => {
                const game = self.game orelse return;
                if (std.mem.eql(u8, game.state, "in")) self.tickGame(frame.league, frame.target);
            },
            else => {},
        }
    }

    fn tickBoard(self: *Tui) void {
        const frame = self.nav.current;
        const board = self.board;
        const live = if (board) |b| boardHasLive(b) else true;
        if (!live) {
            // Settled slate: cheap poll keeps day boundaries exact.
            self.reloadBoard();
            return;
        }
        const snap = sse.fetchSnapshot(self.viewAlloc(), self.transport, self.base_url, frame.league, frame.date) catch {
            self.reloadBoard(); // polling fallback
            return;
        };
        if (self.sse_hash != null and self.sse_hash.? == snap.hash) {
            if (snap.mtime) |m| {
                if (self.last_update_s == null or m > self.last_update_s.?) self.last_update_s = m;
            }
            return;
        }
        self.sse_hash = snap.hash;
        if (snap.mtime) |m| self.last_update_s = m;
        self.reloadBoard();
    }

    fn tickGame(self: *Tui, league: []const u8, id: []const u8) void {
        const frame = self.nav.current;
        const snap = sse.fetchSnapshot(self.viewAlloc(), self.transport, self.base_url, league, frame.date) catch {
            self.reloadGame(league, id); // polling fallback
            return;
        };
        if (self.sse_hash != null and self.sse_hash.? == snap.hash) {
            if (snap.mtime) |m| {
                if (self.last_update_s == null or m > self.last_update_s.?) self.last_update_s = m;
            }
            return;
        }
        self.sse_hash = snap.hash;
        if (snap.mtime) |m| self.last_update_s = m;
        self.reloadGame(league, id);
    }

    fn timeoutMs(self: *Tui) i32 {
        if (!self.auto_refresh) return poll_tick_ms;
        const last = self.last_fetch_s orelse return 0;
        const due = last + refresh_interval_s;
        const now = self.nowS();
        if (now >= due) return 0;
        const delta = due - now;
        if (delta > poll_tick_ms) return poll_tick_ms;
        return @intCast(delta);
    }

    fn render(self: *Tui) !void {
        var aw = std.Io.Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("\x1b[H");

        if (self.show_help) {
            try renderHelp(w);
            return try writeFrame(self.io, aw.written());
        }

        const size = terminalSize();
        const visible = visibleRows(bodyRows(size.rows));
        self.clampSelection();
        const scroll = ensureVisible(self.selected, self.scroll, visible);
        self.scroll = scroll;

        const now = self.nowS();
        const age_text = if (self.last_update_s) |updated|
            try formatAge(self.gpa, now, updated)
        else
            try self.gpa.dupe(u8, "not updated yet");
        defer self.gpa.free(age_text);

        const frame = self.nav.current;
        const label: []const u8 = switch (frame.view) {
            .leagues => "leagues",
            .board => "scores",
            .game => "game",
            .team => "team",
            .standings => "standings",
        };
        const league_name: []const u8 = switch (frame.view) {
            .board => if (self.board) |b| b.league_name else "",
            .game => if (self.game) |g| g.league_name else "",
            .team => if (self.team) |t| t.league_name else "",
            .standings => if (self.standings) |s| s.league_name else "",
            .leagues => "",
        };
        try renderHeader(w, .{
            .league_name = league_name,
            .league = frame.league,
            .date = frame.date orelse "",
            .view_label = label,
            .filter = self.filter,
        });

        switch (frame.view) {
            .leagues => try self.renderLeagues(w, scroll, visible),
            .board => try self.renderBoard(w, scroll, visible),
            .game => try self.renderGame(w, scroll, visible),
            .team => try self.renderTeam(w),
            .standings => try self.renderStandings(w, scroll, visible),
        }

        try renderFooter(w, .{
            .age_text = age_text,
            .auto_refresh = self.auto_refresh,
            .err = self.last_error,
        });
        try writeFrame(self.io, aw.written());
    }

    fn renderLeagues(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        try w.writeAll("LEAGUES\n");
        const list = self.leagues orelse {
            try w.writeAll("No leagues loaded. Press r to retry.\n");
            return;
        };
        var filtered: usize = 0;
        var emitted: usize = 0;
        for (list.leagues) |entry| {
            if (!matchesFilter(self.filter, &.{ entry.slug, entry.name })) continue;
            if (filtered < scroll) {
                filtered += 1;
                continue;
            }
            if (emitted >= visible) return;
            try w.print("{s}{s} — {s}\n", .{ if (filtered == self.selected) "> " else "  ", entry.slug, entry.name });
            filtered += 1;
            emitted += 1;
        }
        if (filtered == 0) try w.writeAll("No leagues match filter. Press / to change.\n");
    }

    fn renderBoard(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        const board = self.board orelse {
            try w.writeAll("GAMES\nNo games loaded. Press r to retry.\n");
            return;
        };
        try renderBoardRows(w, self.gpa, board.games, self.filter, self.selected, scroll, visible);
    }

    fn renderGame(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        const game = self.game orelse {
            try w.writeAll("GAME\nNo game loaded. Press r to retry.\n");
            return;
        };
        const away = pickDetailSide(game.participants, "away", 0);
        const home = pickDetailSide(game.participants, "home", 1);
        if (away != null and home != null) {
            try w.print("{s} {s} @ {s} {s}  {s}\n", .{
                away.?.abbreviation, away.?.score, home.?.abbreviation, home.?.score, game.status,
            });
        } else {
            try w.print("{s}  {s}\n", .{ game.id, game.status });
        }
        if (game.venue) |venue| try w.print("venue: {s}\n", .{venue});
        if (game.series) |series| try w.print("series: {s}\n", .{series});
        try w.writeAll("TEAMS (enter opens schedule)\n");
        var filtered: usize = 0;
        var emitted: usize = 0;
        for (game.participants) |p| {
            if (!matchesFilter(self.filter, &.{ p.abbreviation, p.name })) continue;
            if (filtered < scroll) {
                filtered += 1;
                continue;
            }
            if (emitted >= visible) return;
            try w.print("{s}{s} ({s})", .{ if (filtered == self.selected) "> " else "  ", p.abbreviation, p.name });
            if (p.record) |record| try w.print(" {s}", .{record});
            if (p.score.len > 0) try w.print(" {s}", .{p.score});
            try w.writeByte('\n');
            filtered += 1;
            emitted += 1;
        }
        if (filtered == 0) try w.writeAll("No teams match filter. Press / to change.\n");
    }

    fn renderTeam(self: *Tui, w: *std.Io.Writer) !void {
        const view = self.team orelse {
            try w.writeAll("TEAM\nNo team loaded. Press r to retry.\n");
            return;
        };
        try w.print("{s} ({s})", .{ view.team.name, view.team.abbrev });
        if (view.team.record_summary) |record| try w.print("  {s}", .{record});
        try w.writeByte('\n');
        if (view.team.standing_summary) |standing| try w.print("{s}\n", .{standing});
        try w.writeAll("LAST\n");
        for (view.last) |row| {
            try w.print("  {s} vs {s} {s}-{s}  {s}\n", .{ row.date, row.opponent_abbrev, row.our_score, row.opp_score, row.status });
        }
        try w.writeAll("NEXT\n");
        for (view.next) |row| {
            try w.print("  {s} vs {s}  {s}\n", .{ row.date, row.opponent_abbrev, row.status });
        }
    }

    fn renderStandings(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        try w.writeAll("STANDINGS (enter opens team)\n");
        const table = self.standings orelse {
            try w.writeAll("No standings loaded. Press r to retry.\n");
            return;
        };
        var filtered: usize = 0;
        var emitted: usize = 0;
        for (table.groups) |group| {
            for (group.entries) |entry| {
                if (!matchesFilter(self.filter, &.{ entry.abbrev, entry.name, group.name })) continue;
                if (filtered < scroll) {
                    filtered += 1;
                    continue;
                }
                if (emitted >= visible) return;
                const row = try standingsRowText(self.gpa, group.name, entry);
                defer self.gpa.free(row);
                try w.print("{s}{s}\n", .{ if (filtered == self.selected) "> " else "  ", row });
                filtered += 1;
                emitted += 1;
            }
        }
        if (filtered == 0) try w.writeAll("No teams match filter. Press / to change.\n");
    }
};

fn pickDetailSide(
    parts: []const gen.DetailGameParticipantsItem,
    want: []const u8,
    fallback: usize,
) ?gen.DetailGameParticipantsItem {
    for (parts) |p| {
        if (p.home_away) |ha| if (std.mem.eql(u8, ha, want)) return p;
    }
    if (fallback < parts.len) return parts[fallback];
    return null;
}

/// Interactive entry: initial fetch, raw-mode loop, screen restore on exit.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    opts: cli.Options,
    today: ?[]const u8,
) !void {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const resolved = cli.resolveQueryDate(tmp_arena.allocator(), opts.date, today) catch null;

    const root: Frame = if (opts.league) |slug| .{
        .view = .board,
        .league = slug,
        .target = "",
        .date = resolved,
    } else .{
        .view = .leagues,
        .league = "",
        .target = "",
        .date = resolved,
    };
    var tui = try Tui.init(gpa, io, transport, base_url, root);
    defer tui.deinit();
    tui.loadCurrent();

    var raw = RawMode.init();
    defer raw.deinit();
    try writeStdout(io, "\x1b[?1049h\x1b[?25l\x1b[2J");
    defer writeStdout(io, "\x1b[?25h\x1b[0m\x1b[?1049l") catch {};

    var running = true;
    while (running) {
        try tui.render();
        const key = readKey(io, tui.timeoutMs()) catch .none;
        switch (key) {
            .none => tui.tick(),
            .quit => running = false,
            .down => tui.selected = moveDown(tui.selected, tui.rowCount(), 1),
            .up => tui.selected = moveUp(tui.selected, 1),
            .page_down => tui.selected = moveDown(tui.selected, tui.rowCount(), visibleRows(bodyRows(terminalSize().rows))),
            .page_up => tui.selected = moveUp(tui.selected, visibleRows(bodyRows(terminalSize().rows))),
            .prev_day => tui.stepDay(-1),
            .next_day => tui.stepDay(1),
            .top => {
                tui.selected = 0;
                tui.scroll = 0;
            },
            .bottom => {
                const count = tui.rowCount();
                if (count > 0) tui.selected = count - 1;
            },
            .enter => tui.openSelected(),
            .back => tui.goBack(),
            .refresh => tui.loadCurrent(),
            .standings => tui.openStandings(),
            .auto => tui.auto_refresh = !tui.auto_refresh,
            .help => tui.show_help = !tui.show_help,
            .filter => {
                const q = try promptFilter(io, gpa, tui.filter);
                defer gpa.free(q);
                tui.setFilter(q);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (fake transport + fixture JSON only, no network)
// ---------------------------------------------------------------------------

const FakeTransportState = struct {
    seen_url: ?[]const u8 = null,
    body: []const u8 = "",
    status: std.http.Status = .ok,
    fail: ?anyerror = null,

    fn dispatch(
        ptr: *anyopaque,
        arena: Allocator,
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

test "key decoder covers the vim table plus enter back and quit" {
    try std.testing.expectEqual(Key.down, decodeByte('j'));
    try std.testing.expectEqual(Key.up, decodeByte('k'));
    try std.testing.expectEqual(Key.prev_day, decodeByte('h'));
    try std.testing.expectEqual(Key.next_day, decodeByte('l'));
    try std.testing.expectEqual(Key.top, decodeByte('g'));
    try std.testing.expectEqual(Key.bottom, decodeByte('G'));
    try std.testing.expectEqual(Key.page_down, decodeByte('d'));
    try std.testing.expectEqual(Key.page_down, decodeByte(' '));
    try std.testing.expectEqual(Key.page_up, decodeByte('u'));
    try std.testing.expectEqual(Key.enter, decodeByte('\r'));
    try std.testing.expectEqual(Key.enter, decodeByte('\n'));
    try std.testing.expectEqual(Key.back, decodeByte('b'));
    try std.testing.expectEqual(Key.back, decodeByte(27));
    try std.testing.expectEqual(Key.refresh, decodeByte('r'));
    try std.testing.expectEqual(Key.standings, decodeByte('s'));
    try std.testing.expectEqual(Key.auto, decodeByte('a'));
    try std.testing.expectEqual(Key.help, decodeByte('?'));
    try std.testing.expectEqual(Key.filter, decodeByte('/'));
    try std.testing.expectEqual(Key.quit, decodeByte('q'));
    try std.testing.expectEqual(Key.none, decodeByte('x'));
    try std.testing.expectEqual(Key.none, decodeByte('o'));
    try std.testing.expectEqual(Key.none, decodeByte(0));
}

test "key decoder resolves arrow and page escape tails" {
    try std.testing.expectEqual(Key.up, decodeEscapeTail("[A"));
    try std.testing.expectEqual(Key.down, decodeEscapeTail("[B"));
    try std.testing.expectEqual(Key.next_day, decodeEscapeTail("[C"));
    try std.testing.expectEqual(Key.prev_day, decodeEscapeTail("[D"));
    try std.testing.expectEqual(Key.page_up, decodeEscapeTail("[5"));
    try std.testing.expectEqual(Key.page_up, decodeEscapeTail("[5~"));
    try std.testing.expectEqual(Key.page_down, decodeEscapeTail("[6"));
    try std.testing.expectEqual(Key.page_down, decodeEscapeTail("[6~"));
    try std.testing.expectEqual(Key.back, decodeEscapeTail(""));
    try std.testing.expectEqual(Key.back, decodeEscapeTail("["));
    try std.testing.expectEqual(Key.back, decodeEscapeTail("OA"));
    try std.testing.expectEqual(Key.back, decodeEscapeTail("[Z"));
}

test "viewport math clamps scroll windows and selections" {
    try std.testing.expectEqual(@as(usize, 20), bodyRows(24));
    try std.testing.expectEqual(@as(usize, 1), bodyRows(4));
    try std.testing.expectEqual(@as(usize, 19), visibleRows(20));
    try std.testing.expectEqual(@as(usize, 1), visibleRows(1));

    // Selected below the window scrolls just enough to reveal it.
    try std.testing.expectEqual(@as(usize, 0), ensureVisible(0, 0, 10));
    try std.testing.expectEqual(@as(usize, 0), ensureVisible(9, 0, 10));
    try std.testing.expectEqual(@as(usize, 1), ensureVisible(10, 0, 10));
    try std.testing.expectEqual(@as(usize, 5), ensureVisible(14, 5, 10));
    // Selected above the window jumps the window back.
    try std.testing.expectEqual(@as(usize, 3), ensureVisible(3, 8, 10));

    try std.testing.expectEqual(@as(usize, 0), clampSelected(0, 0));
    try std.testing.expectEqual(@as(usize, 0), clampSelected(7, 0));
    try std.testing.expectEqual(@as(usize, 2), clampSelected(2, 3));
    try std.testing.expectEqual(@as(usize, 2), clampSelected(9, 3));

    try std.testing.expectEqual(@as(usize, 3), moveDown(1, 5, 2));
    try std.testing.expectEqual(@as(usize, 4), moveDown(3, 5, 9));
    try std.testing.expectEqual(@as(usize, 0), moveDown(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), moveUp(3, 2));
    try std.testing.expectEqual(@as(usize, 0), moveUp(1, 9));
}

test "filter matches case-insensitively across fields" {
    try std.testing.expect(matchesFilter("", &.{"Anything"}));
    try std.testing.expect(matchesFilter("mlb", &.{"MLB (mlb)"}));
    try std.testing.expect(matchesFilter("yank", &.{ "New York Yankees", "NYY", "Final" }));
    try std.testing.expect(matchesFilter("FINAL", &.{ "NYY 2 @ BOS 5", "Final" }));
    try std.testing.expect(!matchesFilter("nfl", &.{ "MLB", "Final" }));
    try std.testing.expect(!matchesFilter("x", &.{}));
}

test "last-updated age graduates seconds minutes hours" {
    const alloc = std.testing.allocator;
    const now = 1_000_000;

    const secs = try formatAge(alloc, now, now - 12);
    defer alloc.free(secs);
    try std.testing.expectEqualStrings("updated 12s ago", secs);

    const zero = try formatAge(alloc, now, now);
    defer alloc.free(zero);
    try std.testing.expectEqualStrings("updated 0s ago", zero);

    const future = try formatAge(alloc, now, now + 30);
    defer alloc.free(future);
    try std.testing.expectEqualStrings("updated 0s ago", future);

    const edge = try formatAge(alloc, now, now - 59);
    defer alloc.free(edge);
    try std.testing.expectEqualStrings("updated 59s ago", edge);

    const minute = try formatAge(alloc, now, now - 90);
    defer alloc.free(minute);
    try std.testing.expectEqualStrings("updated 1m ago", minute);

    const hour_edge = try formatAge(alloc, now, now - 3599);
    defer alloc.free(hour_edge);
    try std.testing.expectEqualStrings("updated 59m ago", hour_edge);

    const hour = try formatAge(alloc, now, now - 3700);
    defer alloc.free(hour);
    try std.testing.expectEqualStrings("updated 1h ago", hour);

    const hours = try formatAge(alloc, now, now - 9000);
    defer alloc.free(hours);
    try std.testing.expectEqualStrings("updated 2h ago", hours);
}

test "navigator walks league board to game and back" {
    var nav = try Navigator.init(std.testing.allocator, .{ .view = .board, .league = "mlb", .target = "", .date = "2026-09-06" });
    defer nav.deinit();

    try std.testing.expect(nav.current.view == .board);
    try nav.open(.{ .view = .game, .league = "mlb", .target = "1", .date = "2026-09-06" });
    try std.testing.expect(nav.current.view == .game);
    try std.testing.expectEqualStrings("1", nav.current.target);

    try nav.open(.{ .view = .team, .league = "mlb", .target = "AWY", .date = "2026-09-06" });
    try std.testing.expect(nav.current.view == .team);

    try std.testing.expect(nav.back());
    try std.testing.expect(nav.current.view == .game);
    try std.testing.expectEqualStrings("mlb", nav.current.league);
    try std.testing.expect(nav.back());
    try std.testing.expect(nav.current.view == .board);
    try std.testing.expect(!nav.back());
    try std.testing.expect(nav.current.view == .board);
}

test "navigator standings detour returns to the board" {
    var nav = try Navigator.init(std.testing.allocator, .{ .view = .board, .league = "nfl", .target = "", .date = null });
    defer nav.deinit();
    try nav.open(.{ .view = .standings, .league = "nfl", .target = "", .date = null });
    try std.testing.expect(nav.current.view == .standings);
    try std.testing.expect(nav.back());
    try std.testing.expect(nav.current.view == .board);
    try std.testing.expectEqualStrings("nfl", nav.current.league);
}

const canned_board =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","date":"2026-09-06","source":"test","games":[
    \\{"id":"1","name":"","starts_at":"2026-09-06T17:00Z","state":"post","status":"Final","participants":[
    \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":"10-5"},
    \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"5","winner":true,"home_away":"home","record":"12-3"}]},
    \\{"id":"2","name":"","starts_at":"2026-09-06T19:00Z","state":"in","status":"Top 7th","participants":[
    \\{"id":"b","name":"Bee Club","abbreviation":"BEE","score":"0","winner":false,"home_away":"away","record":null},
    \\{"id":"c","name":"Cee Club","abbreviation":"CEE","score":"3","winner":false,"home_away":"home","record":null}]}]}
;

const canned_game =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","id":"1","date":"2026-09-06","state":"in","status":"Top 7th",
    \\"venue":"Test Park","series":null,"attendance":null,"situation":null,
    \\"participants":[
    \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":"10-5","probable":null,"hits":null,"errors":null,"lines":[]},
    \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"3","winner":false,"home_away":"home","record":"12-3","probable":null,"hits":null,"errors":null,"lines":[]}],
    \\"scoring_plays":[{"text":"Someone homered","period":"7","home_score":"3","away_score":"2"}],
    \\"decisions":[],"lineups":[],"team_stats":[],"leaders":[]}
;

const canned_team =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","live":null,
    \\"team":{"abbrev":"AWY","id":"a","name":"Away Club","record_summary":"10-5","standing_summary":"1st AL East"},
    \\"next":[{"opponent_name":"Home Club","result":"","state":"pre","today":false,"our_score":"","status":"Scheduled","date":"2026-09-07","opponent_abbrev":"HME","home_away":"away","id":"9","opp_score":"","probable":""}],
    \\"last":[{"opponent_name":"Home Club","result":"L","state":"post","today":false,"our_score":"2","status":"Final","date":"2026-09-05","opponent_abbrev":"HME","home_away":"home","id":"8","opp_score":"5","probable":""}],
    \\"extra_past":[],"extra_next":[]}
;

const canned_standings =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","season":"2026","source":"test",
    \\"groups":[{"name":"AL East","entries":[
    \\{"wins":"10","team_id":"a","ties":null,"losses":"5","points":null,"abbrev":"AWY","name":"Away Club"},
    \\{"wins":"8","team_id":"h","ties":null,"losses":"7","points":null,"abbrev":"HME","name":"Home Club"}]}]}
;

const canned_leagues =
    \\{"schema_version":"1","leagues":[
    \\{"name":"MLB","sport":"baseball","slug":"mlb"},
    \\{"name":"NFL","sport":"football","slug":"nfl"}]}
;

test "loaders fetch typed views over the fake transport" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var board_fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, board_fake.asTransport(), "https://example.test", "mlb", "2026-09-06");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb?date=2026-09-06", board_fake.seen_url.?);
    try std.testing.expectEqualStrings("MLB", board.league_name);
    try std.testing.expectEqual(@as(usize, 2), board.games.len);
    try std.testing.expect(boardHasLive(board));

    var game_fake = FakeTransportState{ .body = canned_game };
    const game = try loadGame(arena, game_fake.asTransport(), "https://example.test", "mlb", "1");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/1", game_fake.seen_url.?);
    try std.testing.expectEqualStrings("Top 7th", game.status);
    try std.testing.expectEqual(@as(usize, 2), game.participants.len);

    var team_fake = FakeTransportState{ .body = canned_team };
    const team = try loadTeam(arena, team_fake.asTransport(), "https://example.test", "mlb", "AWY");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/AWY", team_fake.seen_url.?);
    try std.testing.expectEqualStrings("Away Club", team.team.name);
    try std.testing.expectEqual(@as(usize, 1), team.next.len);

    var standings_fake = FakeTransportState{ .body = canned_standings };
    const table = try loadStandings(arena, standings_fake.asTransport(), "https://example.test", "mlb");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/standings", standings_fake.seen_url.?);
    try std.testing.expectEqualStrings("AL East", table.groups[0].name);
    try std.testing.expectEqual(@as(usize, 2), table.groups[0].entries.len);

    var leagues_fake = FakeTransportState{ .body = canned_leagues };
    const list = try loadLeagues(arena, leagues_fake.asTransport(), "https://example.test");
    try std.testing.expectEqualStrings("https://example.test/api/v1/leagues", leagues_fake.seen_url.?);
    try std.testing.expectEqual(@as(usize, 2), list.leagues.len);
}

test "loader failures surface without network" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var refused = FakeTransportState{ .fail = error.ConnectionRefused };
    try std.testing.expectError(error.FetchFailed, loadBoard(arena, refused.asTransport(), "https://example.test", "mlb", null));

    var missing = FakeTransportState{ .body = "nope", .status = .not_found };
    try std.testing.expectError(error.BadStatus, loadGame(arena, missing.asTransport(), "https://example.test", "mlb", "1"));

    var corrupt = FakeTransportState{ .body = "{not json" };
    try std.testing.expectError(error.BadBody, loadStandings(arena, corrupt.asTransport(), "https://example.test", "mlb"));
}

test "settled boards report no live games" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body =
        \\{"schema_version":"1","league":"nfl","league_name":"NFL","date":"2026-09-06","source":"test","games":[
        \\{"id":"1","name":"","starts_at":"2026-09-06T17:00Z","state":"post","status":"Final","participants":[]}]}
    };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "nfl", null);
    try std.testing.expect(!boardHasLive(board));
}

test "board rows render compact scores with a live marker" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "mlb", null);

    const first = try gameRowText(arena, board.games[0]);
    try std.testing.expectEqualStrings("AWY (10-5) 2 @ HME (12-3) 5  Final", first);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try renderBoardRows(&out.writer, arena, board.games, "", 1, 0, 10);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "> LIVE BEE 0 @ CEE 3  Top 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  AWY (10-5) 2 @ HME (12-3) 5  Final") != null);
}

test "board rows honor filter and scroll windows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "mlb", null);

    var filtered: std.Io.Writer.Allocating = .init(arena);
    defer filtered.deinit();
    try renderBoardRows(&filtered.writer, arena, board.games, "bee", 0, 0, 10);
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "BEE") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "AWY") == null);

    var scrolled: std.Io.Writer.Allocating = .init(arena);
    defer scrolled.deinit();
    try renderBoardRows(&scrolled.writer, arena, board.games, "", 1, 1, 1);
    try std.testing.expect(std.mem.indexOf(u8, scrolled.written(), "BEE") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled.written(), "AWY") == null);

    var empty: std.Io.Writer.Allocating = .init(arena);
    defer empty.deinit();
    try renderBoardRows(&empty.writer, arena, board.games, "quidditch", 0, 0, 10);
    try std.testing.expect(std.mem.indexOf(u8, empty.written(), "No games match filter") != null);
}

test "standings rows carry records and groups" {
    const entry = gen.LeagueStandingsGroupsItemEntriesItem{
        .wins = "10",
        .team_id = "a",
        .ties = null,
        .losses = "5",
        .points = null,
        .abbrev = "AWY",
        .name = "Away Club",
    };
    const row = try standingsRowText(std.testing.allocator, "AL East", entry);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("AWY 10-5  Away Club  AL East", row);
}

test "help overlay documents every required key" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderHelp(&out.writer);
    const text = out.written();
    for ([_][]const u8{ "j/down", "k/up", "h/left", "l/right", "enter", "b/esc", "s", "Standings", "/", "Filter", "r", "Refresh", "a", "auto-refresh", "?", "q", "Quit", "SSE" }) |want| {
        try std.testing.expect(std.mem.indexOf(u8, text, want) != null);
    }
}

test "footer carries age auto state and the key line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderFooter(&out.writer, .{ .age_text = "updated 12s ago", .auto_refresh = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "updated 12s ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto:on") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "q quit") != null);

    var off: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer off.deinit();
    try renderFooter(&off.writer, .{ .age_text = "updated 2h ago", .auto_refresh = false, .err = "boom" });
    try std.testing.expect(std.mem.indexOf(u8, off.written(), "auto:off") != null);
    try std.testing.expect(std.mem.indexOf(u8, off.written(), "ERROR: boom") != null);
}
