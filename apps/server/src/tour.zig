//! Read-only terminal tour page (`/{league}/tour`, plus the all-leagues
//! `/tour`): the live TUI experience in a browser via xterm.js fed by the
//! text SSE streams (`?stream=sse`), server-driven like the `curl -N`
//! repaint (haxy-style) — NOT WASM. A prior spike proved WASM compilation
//! dead: `std.Io.Threaded`/termios don't exist freestanding, so the player
//! is a thin same-origin page: vendored xterm.js renders frames pushed by
//! `EventSource`, and there is deliberately no keyboard passthrough
//! (`onData`/`onKey` never appear here) — the tour cannot change server
//! state. `game:`/`team:` rows are clickable via a link list under the
//! terminal, rebuilt from each frame.
//!
//! Vendoring: `assets/xterm.min.js` (xterm.js 5.5.0 UMD, ~290KB) plus
//! `assets/xterm.css` (~5.5KB), both fetched once from jsDelivr and
//! checked in. The pair totals under the 300KB CDN-reconsider bar, so the
//! page is fully same-origin (no CORS, no CDN, no npm build step): it works
//! from a plain `zig build run` because the bytes `@embedFile` into the
//! binary. Served at `/tour-assets/xterm.min.js` + `/tour-assets/xterm.css`
//! with long-cache headers (favicon pattern); the page itself is per-league
//! static HTML on the shared cache headers.
//!
//! Wiring is NOT done here: `main.zig`/`worker.zig` own the exhaustive
//! `switch (route)`, so they gain the `.tour` + `.tour_asset` arms (the
//! tour ignores content negotiation and always serves HTML).

const std = @import("std");

/// Vendored xterm.js 5.5.0 UMD build (`Terminal` global). MIT licensed,
/// see the header comment inside the file.
pub const xterm_js = @embedFile("assets/xterm.min.js");
/// Vendored xterm.css companion for the build above.
pub const xterm_css = @embedFile("assets/xterm.css");

pub const js_content_type = "text/javascript; charset=utf-8";
pub const css_content_type = "text/css; charset=utf-8";
pub const html_content_type = "text/html; charset=utf-8";

pub const js_path = "/tour-assets/xterm.min.js";
pub const css_path = "/tour-assets/xterm.css";

/// Full tour page for one league slug, or the digest tour when null (the
/// player opens `/all?stream=sse...` then). The stream base rides in `BASE`
/// so the page JS stays static: cols come from the terminal width, color
/// is always on (xterm renders ANSI), and resize refetches debounced.
pub fn tourHtml(arena: std.mem.Allocator, league: ?[]const u8) ![]u8 {
    const base = if (league) |slug| try std.fmt.allocPrint(arena, "/{s}", .{slug}) else try arena.dupe(u8, "/all");
    defer arena.free(base);
    const title = if (league) |slug| try std.fmt.allocPrint(arena, "sprts tour — {s}", .{slug}) else try arena.dupe(u8, "sprts tour — all leagues");
    defer arena.free(title);
    const curl_url = try std.fmt.allocPrint(arena, "{s}?stream=sse", .{base});
    defer arena.free(curl_url);

    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<link rel=\"icon\" type=\"image/svg+xml\" href=\"/favicon.svg\">" ++
        "<title>");
    try escapeInto(w, title);
    try w.writeAll("</title><link rel=\"stylesheet\" href=\"" ++ css_path ++ "\">" ++
        "<style>" ++
        "html,body{margin:0;background:#10140f;color:#e6ebe7}" ++
        "main{max-width:900px;margin:auto;padding:20px 14px;font:16px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}" ++
        "header{color:#8b968f;margin-bottom:12px}header strong{color:#e6ebe7}" ++
        "header a,.hint a,#links a{color:#6fd3a0}" ++
        "#term{border:1px solid #2a332c;min-height:240px;background:#10140f}" ++
        "#term .xterm{padding:8px}" ++
        ".hint{color:#8b968f;font-size:14px}.hint code{color:#e6ebe7}" ++
        "#links{margin-top:10px;font-size:14px}#links a{margin:0 14px 6px 0;display:inline-block}" ++
        ".dim{color:#8b968f}" ++
        "</style></head><body><main><header><strong>");
    try escapeInto(w, title);
    try w.writeAll("</strong> &middot; live &middot; read-only &middot; <a href=\"/\">leagues</a> <a href=\"/:help\">help</a></header>" ++
        "<div id=\"term\" role=\"img\" aria-label=\"Live scores terminal\"></div>" ++
        "<noscript><p>No JavaScript: this tour needs JS for the terminal. Same feed in curl: <code>curl -N '");
    try escapeInto(w, curl_url);
    try w.writeAll("'</code></p></noscript>" ++
        "<p class=\"hint\">Live feed, no input: resize refetches the width. Same frames in curl: <code>curl -N '");
    try escapeInto(w, curl_url);
    try w.writeAll("'</code></p><nav id=\"links\" aria-label=\"Games and teams in this frame\"></nav>" ++
        "<script src=\"" ++ js_path ++ "\"></script><script>(function(){\n" ++
        "var BASE='");
    try escapeInto(w, base);
    try w.writeAll("';\n" ++
        \\var el=document.getElementById('term');
        \\var list=document.getElementById('links');
        \\var es=null,retry=null;
        \\var term=new Terminal({cursorBlink:false,theme:{background:'#10140f',foreground:'#e6ebe7',cursor:'#e6ebe7'}});
        \\term.open(el);
        \\function cols(){
        \\var w=Math.floor(el.clientWidth/8.4);
        \\return Math.max(52,Math.min(200,w||80));
        \\}
        \\function links(text){
        \\var seen={},html='',m;
        \\var re=/\b(game|team):\s*(\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+)/g;
        \\while((m=re.exec(text))){
        \\if(!seen[m[2]]){seen[m[2]]=1;html+='<a href="'+m[2]+'">'+m[1]+': '+m[2]+'</a>';}
        \\}
        \\list.innerHTML=html||'<span class="dim">no games in this frame</span>';
        \\}
        \\function connect(){
        \\if(es){es.close();es=null;}
        \\term.clear();
        \\es=new EventSource(BASE+'?stream=sse&width='+cols()+'&color=1');
        \\es.onmessage=function(e){term.write(e.data.split('\n').join('\r\n'));links(e.data);};
        \\}
        \\window.addEventListener('resize',function(){
        \\if(retry)clearTimeout(retry);
        \\retry=setTimeout(connect,400);
        \\});
        \\connect();
        \\})();
    );
    try w.writeAll("</script></main></body></html>");
    return out.toOwnedSlice();
}

fn escapeInto(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    };
}

test "vendored xterm assets are present with pinned content types" {
    // The page only works when both vendored blobs ship real bytes: an
    // empty embed (missing asset file) must fail here, not in a browser.
    try std.testing.expect(xterm_js.len > 100_000);
    try std.testing.expect(xterm_css.len > 1_000);
    try std.testing.expect(std.mem.indexOf(u8, xterm_js, "Terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, xterm_css, ".xterm") != null);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", js_content_type);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", css_content_type);
}

test "tour page wires xterm to the SSE stream with a no-JS fallback" {
    const page = try tourHtml(std.testing.allocator, "mlb");
    defer std.testing.allocator.free(page);
    _ = try std.unicode.Utf8View.init(page);
    // Player wiring: vendored xterm script + css, Terminal open, and an
    // EventSource pointed at this league's SSE stream with width+color.
    for ([_][]const u8{
        "/tour-assets/xterm.min.js",
        "/tour-assets/xterm.css",
        "new Terminal",
        "EventSource",
        "BASE='/mlb'",
        "'?stream=sse&width='",
        "'&color=1'",
        ".split('\\n').join('\\r\\n')",
        "setTimeout(connect,400)",
        "id=\"term\"",
        "id=\"links\"",
        "game|team",
    }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, page, token) != null);
    }
    // No-JS fallback: the tour explains itself plus the curl twin.
    try std.testing.expect(std.mem.indexOf(u8, page, "<noscript>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "curl -N") != null);
    // Read-only pin: no keyboard passthrough into server state, ever.
    try std.testing.expect(std.mem.indexOf(u8, page, "onData") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "onKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "read-only") != null);
}

test "digest tour streams the all-leagues feed" {
    const page = try tourHtml(std.testing.allocator, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "BASE='/all'") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "all leagues") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "EventSource") != null);
    // League tour keeps its own base; slugs never leak between pages.
    const league_page = try tourHtml(std.testing.allocator, "nba");
    defer std.testing.allocator.free(league_page);
    try std.testing.expect(std.mem.indexOf(u8, league_page, "BASE='/nba'") != null);
    try std.testing.expect(std.mem.indexOf(u8, league_page, "BASE='/all'") == null);
}
