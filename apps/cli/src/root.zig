pub const cli = @import("cli.zig");
pub const plain = @import("plain.zig");
pub const app = @import("app.zig");
pub const sse = @import("sse.zig");
pub const tui = @import("tui.zig");

test {
    _ = cli;
    _ = plain;
    _ = app;
    _ = sse;
    _ = tui;
}
