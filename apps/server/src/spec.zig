const core = @import("sprts_core");
const z = @import("zchema");

const ScoreboardPath = struct {
    league: []const u8,
};

const ScoreboardQuery = struct {
    date: ?[]const u8 = null,

    pub const jsonschema = .{
        .fields = .{ .date = .{ .format = "date" } },
    };
};

pub const ApiSpec = z.Spec(.{
    z.endpoint(.GET, "/api/v1/leagues", .{
        .operation_id = "listLeagues",
        .summary = "List supported leagues",
        .responses = .{z.case(.ok, core.leagues.LeagueList)},
    }),
    z.endpoint(.GET, "/api/v1/{league}", .{
        .operation_id = "getScoreboard",
        .summary = "Scores for one league and date",
        .path = ScoreboardPath,
        .query = ScoreboardQuery,
        .responses = .{
            z.case(.ok, core.domain.Scoreboard),
            z.case(.bad_request, z.ErrorBody),
            z.case(.not_found, z.ErrorBody),
            z.case(.bad_gateway, z.ErrorBody),
        },
    }),
});

pub fn openApiJson(allocator: std.mem.Allocator) ![]u8 {
    return z.openApiJson(ApiSpec, allocator, .{
        .title = "sprts API",
        .version = "1.0.0",
        .description = "Provider-neutral sports scores and schedules.",
    });
}

const std = @import("std");

test "spec emits listLeagues and getScoreboard operations" {
    const doc = try openApiJson(std.testing.allocator);
    defer std.testing.allocator.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "listLeagues") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "getScoreboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "Scoreboard") != null);
}
