//! CLDR weekend start and end weekdays per region.
//!
//! Weekdays use CLDR's numbering: Sunday = 0 through Saturday = 6. Regions
//! without an explicit rule use the world default (Saturday through Sunday).

const std = @import("std");

const data = @import("weekend_data.zig");

pub const Weekend = struct {
    /// First weekend day (Sunday = 0).
    start: u8,
    /// Last weekend day, inclusive. May be before `start` when the weekend
    /// wraps around the end of the week.
    end: u8,
};

pub const default = Weekend{
    .start = data.default_start,
    .end = data.default_end,
};

/// Weekend range for an ISO 3166 region code, falling back to the default.
pub fn weekendForRegion(region: []const u8) Weekend {
    for (data.regions) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, region)) {
            return .{ .start = entry.start, .end = entry.end };
        }
    }
    return default;
}

/// True when `weekday` (Sunday = 0) is a weekend day in `region`.
pub fn isWeekend(region: []const u8, weekday: u8) bool {
    if (weekday > 6) return false;
    const weekend = weekendForRegion(region);
    if (weekend.start <= weekend.end) {
        return weekday >= weekend.start and weekday <= weekend.end;
    }
    return weekday >= weekend.start or weekday <= weekend.end;
}

test "weekend ranges match CLDR" {
    const testing = @import("std").testing;

    try testing.expectEqual(Weekend{ .start = 6, .end = 0 }, weekendForRegion("US"));
    try testing.expectEqual(Weekend{ .start = 4, .end = 5 }, weekendForRegion("AF"));
    try testing.expectEqual(Weekend{ .start = 5, .end = 6 }, weekendForRegion("EG"));
    try testing.expectEqual(Weekend{ .start = 5, .end = 5 }, weekendForRegion("IR"));
    try testing.expectEqual(Weekend{ .start = 0, .end = 0 }, weekendForRegion("IN"));
    try testing.expectEqual(Weekend{ .start = 6, .end = 0 }, weekendForRegion("zz"));

    try testing.expect(isWeekend("US", 6));
    try testing.expect(isWeekend("US", 0));
    try testing.expect(!isWeekend("US", 5));
    try testing.expect(isWeekend("AF", 4));
    try testing.expect(isWeekend("AF", 5));
    try testing.expect(!isWeekend("AF", 6));
    try testing.expect(isWeekend("IR", 5));
    try testing.expect(!isWeekend("IR", 4));
    try testing.expect(isWeekend("IN", 0));
    try testing.expect(!isWeekend("IN", 6));
    try testing.expect(!isWeekend("US", 7));
}
