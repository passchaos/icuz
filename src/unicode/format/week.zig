//! CLDR week data: first day of the week and minimal days in the first week.
//!
//! Weekdays use CLDR's numbering: Sunday = 0 through Saturday = 6. Regions
//! without an explicit rule use the CLDR world default (Monday, 1 day).

const std = @import("std");

const data = @import("week_data.zig");

pub const WeekData = struct {
    /// First day of the week (Sunday = 0).
    first_day: u8,
    /// Minimum days in the first week of the year.
    minimal_days: u8,
};

pub const default = WeekData{
    .first_day = data.default_first_day,
    .minimal_days = data.default_minimal_days,
};

/// Week data for an ISO 3166 region code, falling back to the default.
pub fn weekDataForRegion(region: []const u8) WeekData {
    for (data.regions) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, region)) {
            return .{
                .first_day = entry.first_day,
                .minimal_days = entry.minimal_days,
            };
        }
    }
    return default;
}

/// First day of the week for a region (Sunday = 0).
pub fn firstDayOfWeek(region: []const u8) u8 {
    return weekDataForRegion(region).first_day;
}

/// Minimum days in the first week of the year for a region.
pub fn minimalDaysInFirstWeek(region: []const u8) u8 {
    return weekDataForRegion(region).minimal_days;
}

test "CLDR week data" {
    const testing = @import("std").testing;

    try testing.expectEqual(
        WeekData{ .first_day = 0, .minimal_days = 1 },
        weekDataForRegion("US"),
    );
    try testing.expectEqual(
        WeekData{ .first_day = 1, .minimal_days = 4 },
        weekDataForRegion("GB"),
    );
    try testing.expectEqual(
        WeekData{ .first_day = 1, .minimal_days = 4 },
        weekDataForRegion("de"),
    );
    try testing.expectEqual(
        WeekData{ .first_day = 6, .minimal_days = 1 },
        weekDataForRegion("IR"),
    );
    try testing.expectEqual(default, weekDataForRegion("zz"));
    try testing.expectEqual(@as(u8, 0), firstDayOfWeek("US"));
    try testing.expectEqual(@as(u8, 4), minimalDaysInFirstWeek("GB"));
}
