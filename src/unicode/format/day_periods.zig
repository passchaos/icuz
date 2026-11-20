//! CLDR day-period rules and names for the `b` and `B` date pattern fields.

const std = @import("std");

const data = @import("day_periods_data.zig");

pub const Period = data.Period;
pub const Width = enum { abbreviated, wide, narrow };

fn normalizeLocale(locale: []const u8, buffer: *[64]u8) []const u8 {
    const length = @min(locale.len, buffer.len);
    for (locale[0..length], 0..) |byte, index| {
        buffer[index] = if (byte == '-') '_' else byte;
    }
    return buffer[0..length];
}

fn findRules(id: []const u8) ?[]const data.Rule {
    var low: usize = 0;
    var high = data.locale_rules.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.locale_rules[middle];
        switch (std.mem.order(u8, entry.id, id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return entry.rules,
        }
    }
    return null;
}

fn findNames(id: []const u8) ?*const data.LocaleNames {
    var low: usize = 0;
    var high = data.locale_names.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = &data.locale_names[middle];
        switch (std.mem.order(u8, entry.id, id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return entry,
        }
    }
    return null;
}

fn rulesFor(locale: []const u8) []const data.Rule {
    var buffer: [64]u8 = undefined;
    const id = normalizeLocale(locale, &buffer);
    if (findRules(id)) |rules| return rules;
    if (std.mem.indexOfScalar(u8, id, '_')) |position| {
        if (findRules(id[0..position])) |rules| return rules;
    }
    return findRules("root").?;
}

fn namesFor(locale: []const u8) *const data.LocaleNames {
    var buffer: [64]u8 = undefined;
    const id = normalizeLocale(locale, &buffer);
    if (findNames(id)) |names| return names;
    if (std.mem.indexOfScalar(u8, id, '_')) |position| {
        if (findNames(id[0..position])) |names| return names;
    }
    return findNames("root").?;
}

pub fn nameAt(
    names: *const data.LocaleNames,
    period: Period,
    width: Width,
) []const u8 {
    const index = @intFromEnum(period);
    return switch (width) {
        .abbreviated => names.abbreviated[index],
        .wide => names.wide[index],
        .narrow => names.narrow[index],
    };
}

/// Flexible day period for a minute of the day, or null when the locale has
/// no rule for that time.
pub fn periodForMinutes(locale: []const u8, minutes: u16) ?Period {
    for (rulesFor(locale)) |rule| {
        if (rule.start == rule.end) {
            if (minutes == rule.start) return rule.period;
        } else if (minutes >= rule.start and minutes < rule.end) {
            return rule.period;
        }
    }
    return null;
}

/// Localized day-period name for a time. `flexible` selects the `B` field
/// (morning/afternoon/evening/night); false selects `b`
/// (am/pm/noon/midnight). Returns an empty slice when the locale has no name.
pub fn nameForTime(
    locale: []const u8,
    hour: u8,
    minute: u8,
    width: Width,
    flexible: bool,
) []const u8 {
    const minutes = @as(u16, hour) * 60 + @as(u16, minute);
    const period: Period = if (flexible)
        periodForMinutes(locale, minutes) orelse
            (if (minutes < 720) .am else .pm)
    else if (minutes == 0)
        .midnight
    else if (minutes == 720)
        .noon
    else if (minutes < 720)
        .am
    else
        .pm;
    const names = namesFor(locale);
    var value = nameAt(names, period, width);
    if (value.len == 0 and period != .am and period != .pm) {
        value = nameAt(names, if (minutes < 720) .am else .pm, width);
    }
    return value;
}

/// Locale names for a day period, for reverse matching in date parsing.
pub fn localeNames(locale: []const u8) *const data.LocaleNames {
    return namesFor(locale);
}

test "day period names and rules" {
    const testing = @import("std").testing;

    try testing.expectEqualStrings(
        "in the morning",
        nameForTime("en", 9, 0, .wide, true),
    );
    try testing.expectEqualStrings(
        "at night",
        nameForTime("en", 23, 0, .wide, true),
    );
    try testing.expectEqualStrings(
        "noon",
        nameForTime("en", 12, 0, .wide, false),
    );
    try testing.expectEqualStrings(
        "PM",
        nameForTime("en", 15, 0, .abbreviated, false),
    );
    try testing.expectEqualStrings(
        "vormittags",
        nameForTime("de", 11, 0, .wide, true),
    );
    try testing.expectEqualStrings(
        "morgens",
        nameForTime("de", 7, 0, .wide, true),
    );
    try testing.expectEqualStrings(
        "PM",
        nameForTime("zz", 15, 0, .abbreviated, false),
    );
    try testing.expectEqual(Period.morning1, periodForMinutes("en", 9 * 60).?);
    try testing.expectEqual(Period.night1, periodForMinutes("en", 23 * 60).?);
}
