//! Provider error classification shared by the serve layers and caches.
//!
//! `GameNotFound`/`TeamNotFound`/`UnsupportedLeague` are authoritative
//! 404s: they bypass even the stale path (a 404 is never staleable) and
//! map to 404 responses instead of 502s. One predicate keeps every site
//! in agreement about which errors those are.

/// True for the authoritative 404 set: a missing game, a missing team, or
/// a league the provider has no endpoint for. Everything else (timeouts,
/// upstream 5xx, parse failures) is a transient upstream failure.
pub fn isNotFound(err: anyerror) bool {
    return err == error.GameNotFound or err == error.TeamNotFound or err == error.UnsupportedLeague;
}

test "isNotFound matches only the authoritative 404 set" {
    try std.testing.expect(isNotFound(error.GameNotFound));
    try std.testing.expect(isNotFound(error.TeamNotFound));
    try std.testing.expect(isNotFound(error.UnsupportedLeague));
    try std.testing.expect(!isNotFound(error.UpstreamResponse));
    try std.testing.expect(!isNotFound(error.Timeout));
    try std.testing.expect(!isNotFound(error.OutOfMemory));
}

const std = @import("std");
