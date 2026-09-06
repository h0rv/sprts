const std = @import("std");
const core = @import("sprts_core");
const domain = core.domain;
const leagues = core.leagues;
const dates = core.date;
const router = @import("router.zig");

pub fn json(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(board, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn text(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("sprts  {s}  {s}\n", .{ board.league_name, board.date });
    try w.writeAll("────────────────────────────────────────\n");
    if (board.games.len == 0) {
        try w.writeAll("No games scheduled.\n");
    }
    for (board.games, 0..) |game, index| {
        if (index != 0) try w.writeByte('\n');
        try w.print("{s}\n", .{game.status});
        if (game.participants.len == 0) try w.print("{s}\n", .{game.name});
        for (game.participants) |participant| try writeParticipantLine(w, participant);
    }
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    try w.print("\n← /{s}?date={s}    /{s}?date={s} →\n", .{
        board.league,
        previous,
        board.league,
        next,
    });
    return out.toOwnedSlice();
}

fn writeParticipantLine(w: *std.Io.Writer, participant: domain.Participant) !void {
    try w.print("{s: <5} {s: <28} {s: >3}{s}\n", .{
        participant.abbreviation,
        participant.name,
        participant.score,
        if (participant.winner) "  ✓" else "",
    });
}

pub fn html(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} scores · sprts</title>", .{board.league_name});
    try w.writeAll(style ++ "</head><body><main><header><a class=\"brand\" href=\"/\">sprts</a><span>scores without the noise</span></header>");
    try w.print("<section class=\"title\"><h1>{s}</h1><time>{s}</time></section>", .{ board.league_name, board.date });
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    try w.print("<nav><a href=\"/{s}?date={s}\" rel=\"prev\">← Previous</a><a href=\"/{s}\">Today</a><a href=\"/{s}?date={s}\" rel=\"next\">Next →</a></nav>", .{ board.league, previous, board.league, board.league, next });
    if (board.games.len == 0) try w.writeAll("<p class=\"empty\">No games scheduled.</p>");
    for (board.games) |game| {
        try w.writeAll("<article><div class=\"status\">");
        try escape(w, game.status);
        try w.writeAll("</div>");
        if (game.participants.len == 0) {
            try w.writeAll("<div class=\"team\"><span>");
            try escape(w, game.name);
            try w.writeAll("</span></div>");
        }
        for (game.participants) |participant| try htmlParticipant(w, participant);
        try w.writeAll("</article>");
    }
    try w.print("<footer>Data: {s} · <a href=\"/api/v1/{s}?date={s}\">JSON API</a></footer></main></body></html>", .{ board.source, board.league, board.date });
    return out.toOwnedSlice();
}

fn htmlParticipant(w: *std.Io.Writer, participant: domain.Participant) !void {
    try w.writeAll("<div class=\"team\"><b>");
    try escape(w, participant.abbreviation);
    try w.writeAll("</b><span>");
    try escape(w, participant.name);
    try w.writeAll("</span><strong>");
    try escape(w, participant.score);
    if (participant.winner) try w.writeAll(" ✓");
    try w.writeAll("</strong></div>");
}

pub fn home(allocator: std.mem.Allocator, format: router.Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    switch (format) {
        .text => {
            try w.writeAll("sprts — live scores without the noise\n\n");
            for (leagues.all) |league| try w.print("{s: <13} {s}\n", .{ league.slug, league.name });
            try w.writeAll("\nTry: curl localhost:8080/mlb\n");
        },
        .html => {
            try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>sprts</title>" ++ style ++ "</head><body><main><header><span class=\"brand\">sprts</span><span>scores without the noise</span></header><section class=\"title\"><h1>Leagues</h1></section><div class=\"leagues\">");
            for (leagues.all) |league| try w.print("<a href=\"/{s}\"><b>{s}</b><span>{s}</span></a>", .{ league.slug, league.name, league.sport });
            try w.writeAll("</div><footer><a href=\"/api/v1/leagues\">JSON API</a> · curl-friendly by default</footer></main></body></html>");
        },
        .json => try writeLeaguesJson(w),
    }
    return out.toOwnedSlice();
}

pub fn leaguesJson(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeLeaguesJson(&out.writer);
    return out.toOwnedSlice();
}

fn writeLeaguesJson(w: *std.Io.Writer) !void {
    try w.writeAll("{\n  \"schema_version\": \"1\",\n  \"leagues\": [\n");
    for (leagues.all, 0..) |league, i| {
        if (i != 0) try w.writeAll(",\n");
        try w.writeAll("    {\"slug\":");
        try std.json.Stringify.value(league.slug, .{}, w);
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(league.name, .{}, w);
        try w.writeAll(",\"sport\":");
        try std.json.Stringify.value(league.sport, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("\n  ]\n}\n");
}

pub fn errorBody(allocator: std.mem.Allocator, message: []const u8, format: router.Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    switch (format) {
        .text => try out.writer.print("sprts: {s}\n", .{message}),
        .html => {
            try out.writer.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>sprts error</title>");
            try out.writer.writeAll(style);
            try out.writer.print("</head><body><main><h1>sprts</h1><p>{s}</p><p><a href=\"/\">View leagues</a></p></main></body></html>", .{message});
        },
        .json => {
            try out.writer.writeAll("{\"error\":");
            try std.json.Stringify.value(message, .{}, &out.writer);
            try out.writer.writeAll("}\n");
        },
    }
    return out.toOwnedSlice();
}

fn escape(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    };
}

const style =
    \\<style>
    \\:root{color-scheme:light dark;--bg:#f5f1e8;--ink:#17201c;--muted:#68716b;--card:#fffdf7;--line:#d7d2c6;--accent:#087f5b}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 ui-monospace,SFMono-Regular,Consolas,monospace}main{max-width:760px;margin:auto;padding:28px 18px}header{display:flex;align-items:baseline;gap:18px;border-bottom:2px solid var(--ink);padding-bottom:12px}.brand{color:var(--ink);font-size:28px;font-weight:900;text-decoration:none}header span:last-child,.status,footer,.leagues span{color:var(--muted)}.title{display:flex;align-items:baseline;justify-content:space-between;margin:28px 0 12px}.title h1{margin:0;font:700 26px ui-sans-serif,system-ui,sans-serif}nav{display:flex;justify-content:space-between;margin-bottom:20px}a{color:var(--accent)}article{background:var(--card);border:1px solid var(--line);margin:10px 0;padding:14px 16px}.status{font-size:13px;margin-bottom:7px}.team{display:grid;grid-template-columns:4em 1fr auto;gap:8px;padding:5px 0}.team strong{font-size:19px}.empty{padding:30px 0}.leagues{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:10px}.leagues a{display:flex;flex-direction:column;background:var(--card);border:1px solid var(--line);padding:13px;text-decoration:none}.leagues a:hover{border-color:var(--accent)}footer{font-size:13px;margin-top:28px}@media(prefers-color-scheme:dark){:root{--bg:#111714;--ink:#edf2ec;--muted:#99a49d;--card:#18201c;--line:#354039;--accent:#69dbad}}
    \\</style>
;

test "JSON renderer exposes stable schema marker" {
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const output = try json(std.testing.allocator, board);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
}
