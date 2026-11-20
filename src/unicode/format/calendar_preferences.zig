//! CLDR default calendar selection for a locale or territory.
//!
//! The preference order comes from `supplementalData.xml`
//! (`calendarPreferenceData`). Unsupported calendars are skipped so callers
//! get the first calendar this library can format.

const std = @import("std");
const data = @import("calendar_preferences_data.zig");
const calendar_mod = @import("calendar.zig");
const likely_subtags = @import("likely_subtags.zig");

pub const Calendar = calendar_mod.Calendar;

/// First supported calendar for a territory, defaulting to Gregorian.
pub fn forRegion(region: []const u8) Calendar {
    var low: usize = 0;
    var high = data.preferences.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const preference = data.preferences[middle];
        switch (std.mem.order(u8, preference.region, region)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => {
                for (preference.calendars) |name| {
                    if (calendarFromName(name)) |calendar| return calendar;
                }
                return .gregorian;
            },
        }
    }
    return .gregorian;
}

/// First supported calendar for a locale, resolving the territory through
/// likely subtags (for example `fa` resolves to IR and returns Persian).
pub fn forLocale(locale_name: []const u8) Calendar {
    const region = likely_subtags.regionForLocale(locale_name) orelse
        return forRegion("001");
    return forRegion(region);
}

fn calendarFromName(name: []const u8) ?Calendar {
    const names = [_]struct { name: []const u8, calendar: Calendar }{
        .{ .name = "gregorian", .calendar = .gregorian },
        .{ .name = "buddhist", .calendar = .buddhist },
        .{ .name = "japanese", .calendar = .japanese },
        .{ .name = "roc", .calendar = .roc },
        .{ .name = "islamic", .calendar = .islamic_civil },
        .{ .name = "islamic-civil", .calendar = .islamic_civil },
        .{ .name = "islamic-tbla", .calendar = .islamic_tbla },
        .{ .name = "islamic-umalqura", .calendar = .islamic_umalqura },
        .{ .name = "hebrew", .calendar = .hebrew },
        .{ .name = "chinese", .calendar = .chinese },
        .{ .name = "persian", .calendar = .persian },
        .{ .name = "indian", .calendar = .indian },
        .{ .name = "coptic", .calendar = .coptic },
        .{ .name = "ethiopic", .calendar = .ethiopic },
        .{ .name = "ethiopic-amete-alem", .calendar = .ethiopic_amete_alem },
        .{ .name = "iso8601", .calendar = .iso8601 },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.calendar;
    }
    return null;
}

test "default calendar preferences" {
    const testing = @import("std").testing;
    try testing.expectEqual(Calendar.persian, forRegion("IR"));
    try testing.expectEqual(Calendar.buddhist, forRegion("TH"));
    try testing.expectEqual(Calendar.gregorian, forRegion("SA"));
    try testing.expectEqual(Calendar.gregorian, forRegion("US"));
    try testing.expectEqual(Calendar.persian, forLocale("fa"));
    try testing.expectEqual(Calendar.buddhist, forLocale("th"));
    try testing.expectEqual(Calendar.gregorian, forLocale("ar-SA"));
    try testing.expectEqual(Calendar.gregorian, forLocale("en-US"));
    try testing.expectEqual(Calendar.gregorian, forLocale("und"));
}
