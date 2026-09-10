pub const date = @import("date.zig");
pub const detail = @import("detail.zig");
pub const domain = @import("domain.zig");
pub const leagues = @import("leagues.zig");
pub const art = @import("art.zig");
pub const schedule = @import("schedule.zig");
pub const standings = @import("standings.zig");
pub const cache = @import("cache.zig");
pub const errors = @import("errors.zig");

/// Authoritative-404 predicate (`GameNotFound`/`TeamNotFound`/
/// `UnsupportedLeague`); see `errors.zig`.
pub const isNotFound = errors.isNotFound;

test {
    _ = date;
    _ = detail;
    _ = leagues;
    _ = art;
    _ = schedule;
    _ = standings;
    _ = cache;
    _ = errors;
}
