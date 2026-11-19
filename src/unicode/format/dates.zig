//! CLDR 48 Gregorian date and time formatting.

const std = @import("std");
const data = @import("dates_data.zig");
const timezone = @import("../timezone/root.zig");
const timezone_names = @import("../timezone/names.zig");
const calendar_mod = @import("calendar.zig");
const calendars = @import("calendars.zig");
const misc = @import("misc.zig");
const numbering_systems = @import("numbering_systems.zig");

pub const cldr_version = "48";

pub const Style = enum { full, long, medium, short };

pub const DateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,
    offset_seconds: i32 = 0,
};

pub const Error = error{ InvalidDate, OutOfMemory };

/// Zone identity used by the `z`, `v`, `V`, and `O` pattern fields.
pub const ZoneInfo = struct {
    /// IANA zone ID; empty when only a display label is available.
    id: []const u8 = "",
    /// Abbreviation or caller-provided label used as the final fallback.
    label: []const u8 = "",
    daylight: bool = false,
    uses_daylight: bool = false,
    unix_seconds: i64 = 0,
};

/// Calendar field overrides used when formatting a non-Gregorian date.
const FieldOverrides = struct {
    year: ?i32 = null,
    month: ?u8 = null,
    day: ?u8 = null,
    gannen: bool = false,
    leap_month: bool = false,
    era_numeric: bool = false,
    leap_wide: []const u8 = "",
    leap_abbreviated: []const u8 = "",
    leap_narrow: []const u8 = "",
    leap_numeric: []const u8 = "",
    era: ?u16 = null,
    months: ?calendars.MonthTable = null,
    era_wide: ?[]const u8 = null,
    era_abbreviated: ?[]const u8 = null,
    era_narrow: ?[]const u8 = null,
};

/// Format a date using the locale's full/long/medium/short date pattern.
pub fn formatDateAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    style: Style,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const pattern = switch (style) {
        .full => locale.date_full,
        .long => locale.date_long,
        .medium => locale.date_medium,
        .short => locale.date_short,
    };
    return formatPatternWithLocale(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = "UTC" },
        .{},
    );
}

/// Format a time using the locale's time pattern. The zone name defaults to
/// `UTC`; use `formatTimeWithZoneAlloc` to supply another label.
pub fn formatTimeAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    style: Style,
) Error![]u8 {
    return formatTimeWithZoneAlloc(
        allocator,
        date_time,
        locale_name,
        style,
        "UTC",
    );
}

pub fn formatTimeWithZoneAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    style: Style,
    zone_name: []const u8,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const pattern = switch (style) {
        .full => locale.time_full,
        .long => locale.time_long,
        .medium => locale.time_medium,
        .short => locale.time_short,
    };
    return formatPatternWithLocale(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
    );
}

pub fn formatDateTimeAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    style: Style,
    zone_name: []const u8,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const date_pattern = switch (style) {
        .full => locale.date_full,
        .long => locale.date_long,
        .medium => locale.date_medium,
        .short => locale.date_short,
    };
    const time_pattern = switch (style) {
        .full => locale.time_full,
        .long => locale.time_long,
        .medium => locale.time_medium,
        .short => locale.time_short,
    };
    const date_time_pattern = switch (style) {
        .full => locale.date_time_full,
        .long => locale.date_time_long,
        .medium => locale.date_time_medium,
        .short => locale.date_time_short,
    };

    const date_text = try formatPatternWithLocale(
        allocator,
        date_pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
    );
    defer allocator.free(date_text);
    const time_text = try formatPatternWithLocale(
        allocator,
        time_pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
    );
    defer allocator.free(time_text);

    return substituteDateTimePattern(
        allocator,
        date_time_pattern,
        date_text,
        time_text,
    );
}

/// Format a custom CLDR date/time pattern.
pub fn formatPatternAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_time: DateTime,
    locale_name: []const u8,
    zone_name: []const u8,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    return formatPatternWithLocale(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
    );
}

fn isJapaneseLocale(name: []const u8) bool {
    return name.len >= 2 and name[0] == 'j' and name[1] == 'a' and
        (name.len == 2 or name[2] == '-' or name[2] == '_');
}

fn calendarOverrides(
    locale_name: []const u8,
    calendar: calendar_mod.Calendar,
    date_time: DateTime,
) FieldOverrides {
    const days = daysFromCivil(date_time.year, date_time.month, date_time.day);
    const value = calendar_mod.fromDays(calendar, days);
    const index: u8 = @intFromEnum(calendar);
    return .{
        .year = value.year,
        .month = value.month,
        .day = value.day,
        .era = value.era,
        .gannen = calendar == .japanese and value.year == 1 and
            isJapaneseLocale(locale_name),
        .leap_month = value.leap_month,
        .era_numeric = calendar == .chinese,
        .leap_wide = if (value.leap_month)
            calendars.leapPattern(locale_name, index, .wide)
        else
            "",
        .leap_abbreviated = if (value.leap_month)
            calendars.leapPattern(locale_name, index, .abbreviated)
        else
            "",
        .leap_narrow = if (value.leap_month)
            calendars.leapPattern(locale_name, index, .narrow)
        else
            "",
        .leap_numeric = if (value.leap_month)
            calendars.numericLeapPattern(locale_name, index)
        else
            "",
        .months = calendars.monthTable(locale_name, index, value.leap_year),
        .era_wide = calendars.eraName(locale_name, index, value.era, .wide),
        .era_abbreviated = calendars.eraName(locale_name, index, value.era, .abbreviated),
        .era_narrow = calendars.eraName(locale_name, index, value.era, .narrow),
    };
}

/// Format a civil date using a non-Gregorian calendar's localized pattern.
pub fn formatDateInCalendarAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    calendar: calendar_mod.Calendar,
    style: Style,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const index: u8 = @intFromEnum(calendar);
    const calendar_style: calendars.Style = switch (style) {
        .full => .full,
        .long => .long,
        .medium => .medium,
        .short => .short,
    };
    const pattern = calendars.pattern(locale_name, index, calendar_style) orelse
        switch (style) {
            .full => locale.date_full,
            .long => locale.date_long,
            .medium => locale.date_medium,
            .short => locale.date_short,
        };
    return formatPatternWithLocale(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = "UTC" },
        calendarOverrides(locale_name, calendar, date_time),
    );
}

/// Format a civil date and time using a non-Gregorian calendar.
pub fn formatDateTimeInCalendarAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    calendar: calendar_mod.Calendar,
    style: Style,
    zone_name: []const u8,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const date_text = try formatDateInCalendarAlloc(
        allocator,
        date_time,
        locale_name,
        calendar,
        style,
    );
    defer allocator.free(date_text);
    const time_pattern = switch (style) {
        .full => locale.time_full,
        .long => locale.time_long,
        .medium => locale.time_medium,
        .short => locale.time_short,
    };
    const time_text = try formatPatternWithLocale(
        allocator,
        time_pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
    );
    defer allocator.free(time_text);
    const date_time_pattern = switch (style) {
        .full => locale.date_time_full,
        .long => locale.date_time_long,
        .medium => locale.date_time_medium,
        .short => locale.date_time_short,
    };
    return substituteDateTimePattern(
        allocator,
        date_time_pattern,
        date_text,
        time_text,
    );
}

/// Format a custom pattern using a non-Gregorian calendar's fields.
pub fn formatPatternInCalendarAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_time: DateTime,
    locale_name: []const u8,
    calendar: calendar_mod.Calendar,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    return formatPatternWithLocale(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = "UTC" },
        calendarOverrides(locale_name, calendar, date_time),
    );
}

/// Convert a Unix timestamp to civil date/time fields in an IANA zone.
/// Unknown zone IDs fall back to UTC.
pub fn dateTimeFromUnixSecondsInZone(
    seconds: i64,
    zone_name: []const u8,
) DateTime {
    const zone = timezone.find(zone_name) orelse return fromUnixSeconds(seconds, 0);
    return fromUnixSeconds(seconds, timezone.offsetAt(zone, seconds).seconds);
}

/// Format a Unix timestamp as a time in an IANA zone, using the zone's
/// abbreviation for the `z` pattern field.
pub fn formatUnixTimeInZoneAlloc(
    allocator: std.mem.Allocator,
    unix_seconds: i64,
    locale_name: []const u8,
    style: Style,
    zone_name: []const u8,
) Error![]u8 {
    const zone = timezone.find(zone_name) orelse
        return formatTimeWithZoneAlloc(
            allocator,
            fromUnixSeconds(unix_seconds, 0),
            locale_name,
            style,
            zone_name,
        );
    const offset = timezone.offsetAt(zone, unix_seconds);
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const pattern = switch (style) {
        .full => locale.time_full,
        .long => locale.time_long,
        .medium => locale.time_medium,
        .short => locale.time_short,
    };
    return formatPatternWithLocale(
        allocator,
        pattern,
        fromUnixSeconds(unix_seconds, offset.seconds),
        locale,
        locale_name,
        .{
            .id = zone_name,
            .label = offset.abbreviation,
            .daylight = offset.daylight,
            .uses_daylight = timezone.usesDaylight(zone, unix_seconds),
            .unix_seconds = unix_seconds,
        },
        .{},
    );
}

/// Format a civil date/time in an IANA zone, selecting localized zone names
/// from the zone ID and recomputing the offset for the instant.
pub fn formatTimeInZoneAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    style: Style,
    zone_name: []const u8,
) Error![]u8 {
    const zone = timezone.find(zone_name) orelse
        return formatTimeWithZoneAlloc(
            allocator,
            date_time,
            locale_name,
            style,
            zone_name,
        );
    const unix_seconds = unixSeconds(date_time);
    const offset = timezone.offsetAt(zone, unix_seconds);
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const pattern = switch (style) {
        .full => locale.time_full,
        .long => locale.time_long,
        .medium => locale.time_medium,
        .short => locale.time_short,
    };
    return formatPatternWithLocale(
        allocator,
        pattern,
        fromUnixSeconds(unix_seconds, offset.seconds),
        locale,
        locale_name,
        .{
            .id = zone_name,
            .label = offset.abbreviation,
            .daylight = offset.daylight,
            .uses_daylight = timezone.usesDaylight(zone, unix_seconds),
            .unix_seconds = unix_seconds,
        },
        .{},
    );
}

/// Format a custom CLDR pattern for a Unix instant in an IANA zone.
pub fn formatPatternInZoneAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    unix_seconds: i64,
    locale_name: []const u8,
    zone_name: []const u8,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    const zone = timezone.find(zone_name) orelse return formatPatternWithLocale(
        allocator,
        pattern,
        fromUnixSeconds(unix_seconds, 0),
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
    );
    const offset = timezone.offsetAt(zone, unix_seconds);
    return formatPatternWithLocale(
        allocator,
        pattern,
        fromUnixSeconds(unix_seconds, offset.seconds),
        locale,
        locale_name,
        .{
            .id = zone_name,
            .label = offset.abbreviation,
            .daylight = offset.daylight,
            .uses_daylight = timezone.usesDaylight(zone, unix_seconds),
            .unix_seconds = unix_seconds,
        },
        .{},
    );
}

/// Unix seconds for civil fields interpreted with `offset_seconds`.
pub fn unixSeconds(date_time: DateTime) i64 {
    const days = daysFromCivil(date_time.year, date_time.month, date_time.day);
    return days * 86400 +
        @as(i64, date_time.hour) * 3600 +
        @as(i64, date_time.minute) * 60 +
        date_time.second -
        date_time.offset_seconds;
}

/// Convert a Unix timestamp plus UTC offset into civil date/time fields.
pub fn fromUnixSeconds(seconds: i64, offset_seconds: i32) DateTime {
    const local = seconds + offset_seconds;
    const days = @divFloor(local, 86400);
    const seconds_of_day = @mod(local, 86400);
    const civil = civilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @intCast(@divFloor(seconds_of_day, 3600)),
        .minute = @intCast(@divFloor(@mod(seconds_of_day, 3600), 60)),
        .second = @intCast(@mod(seconds_of_day, 60)),
        .offset_seconds = offset_seconds,
    };
}

fn resolveLocale(
    name: []const u8,
    storage: *data.Locale,
) ?*const data.Locale {
    const split = misc.splitNumberingSystem(name);
    const base = findLocale(split.locale) orelse return null;
    const system_name = split.system orelse return base;
    const system = numbering_systems.find(system_name) orelse return base;
    if (std.mem.eql(u21, &system.digits, &base.digits)) return base;
    storage.* = base.*;
    storage.digits = system.digits;
    return storage;
}

fn formatPatternWithLocale(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_time: DateTime,
    locale: *const data.Locale,
    locale_name: []const u8,
    zone: ZoneInfo,
    overrides: FieldOverrides,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                try output.append(allocator, '\'');
                index += 2;
                continue;
            }
            index += 1;
            while (index < pattern.len) {
                if (pattern[index] == '\'') {
                    if (index + 1 < pattern.len and
                        pattern[index + 1] == '\'')
                    {
                        try output.append(allocator, '\'');
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                try output.append(allocator, pattern[index]);
                index += 1;
            }
            continue;
        }

        if (isAsciiLetter(byte)) {
            var end = index;
            while (end < pattern.len and pattern[end] == byte) end += 1;
            if (byte == 'y' and overrides.gannen and
                std.mem.startsWith(u8, pattern[end..], "\xe5\xb9\xb4"))
            {
                try output.appendSlice(allocator, "\xe5\x85\x83");
                index = end;
                continue;
            }
            try appendField(
                allocator,
                &output,
                byte,
                end - index,
                date_time,
                locale,
                locale_name,
                zone,
                overrides,
            );
            index = end;
            continue;
        }

        try output.append(allocator, byte);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn appendPatternValue(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    pattern: []const u8,
    value: []const u8,
) Error!void {
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '{' and index + 2 < pattern.len and
            pattern[index + 1] == '0' and pattern[index + 2] == '}')
        {
            try output.appendSlice(allocator, value);
            index += 3;
            continue;
        }
        try output.append(allocator, pattern[index]);
        index += 1;
    }
}

fn appendField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    field: u8,
    length: usize,
    date_time: DateTime,
    locale: *const data.Locale,
    locale_name: []const u8,
    zone: ZoneInfo,
    overrides: FieldOverrides,
) Error!void {
    switch (field) {
        'G' => {
            if (overrides.era_numeric) {
                try appendPaddedNumber(
                    allocator,
                    output,
                    overrides.era orelse 0,
                    1,
                    locale,
                );
                return;
            }
            const value = if (overrides.era != null)
                if (length >= 5)
                    overrides.era_narrow orelse ""
                else if (length == 4)
                    overrides.era_wide orelse ""
                else
                    overrides.era_abbreviated orelse ""
            else blk: {
                const era: usize = if (date_time.year <= 0) 0 else 1;
                break :blk if (length >= 5)
                    locale.era_narrow[era]
                else if (length == 4)
                    locale.era_wide[era]
                else
                    locale.era_abbreviated[era];
            };
            try output.appendSlice(allocator, value);
        },
        'y' => {
            const year_value: i64 = if (overrides.year) |value|
                value
            else if (date_time.year <= 0)
                1 - @as(i64, date_time.year)
            else
                date_time.year;
            const year: u64 = @intCast(@max(year_value, 0));
            if (length == 2) {
                try appendPaddedNumber(allocator, output, year % 100, 2, locale);
            } else {
                try appendPaddedNumber(
                    allocator,
                    output,
                    year,
                    @max(length, 1),
                    locale,
                );
            }
        },
        'M', 'L' => {
            const month = @min(@max(overrides.month orelse date_time.month, 1), 13);
            if (length <= 2) {
                if (overrides.leap_month and overrides.leap_numeric.len != 0) {
                    var number = std.ArrayList(u8).empty;
                    defer number.deinit(allocator);
                    try appendPaddedNumber(allocator, &number, month, length, locale);
                    try appendPatternValue(
                        allocator,
                        output,
                        overrides.leap_numeric,
                        number.items,
                    );
                } else {
                    try appendPaddedNumber(
                        allocator,
                        output,
                        month,
                        length,
                        locale,
                    );
                }
            } else {
                const names: []const []const u8 = if (overrides.months) |months|
                    if (length == 3)
                        months.abbreviated[0..]
                    else if (length == 4)
                        months.wide[0..]
                    else
                        months.narrow[0..]
                else if (length == 3)
                    locale.months_abbreviated[0..]
                else if (length == 4)
                    locale.months_wide[0..]
                else
                    locale.months_narrow[0..];
                const index = @min(month - 1, names.len - 1);
                const name = names[index];
                const leap_pattern = if (length == 3)
                    overrides.leap_abbreviated
                else if (length == 4)
                    overrides.leap_wide
                else
                    overrides.leap_narrow;
                if (overrides.leap_month and leap_pattern.len != 0) {
                    try appendPatternValue(allocator, output, leap_pattern, name);
                } else {
                    try output.appendSlice(allocator, name);
                }
            }
        },
        'd' => try appendPaddedNumber(
            allocator,
            output,
            overrides.day orelse date_time.day,
            if (length >= 2) 2 else 1,
            locale,
        ),
        'E' => {
            const day = dayOfWeek(date_time);
            const value = if (length >= 6)
                locale.days_short[day]
            else if (length == 5)
                locale.days_narrow[day]
            else if (length == 4)
                locale.days_wide[day]
            else
                locale.days_abbreviated[day];
            try output.appendSlice(allocator, value);
        },
        'a' => {
            const is_pm = date_time.hour >= 12;
            const value = if (length >= 5)
                if (is_pm) locale.pm_narrow else locale.am_narrow
            else if (length == 4)
                if (is_pm) locale.pm_wide else locale.am_wide
            else if (is_pm) locale.pm_abbreviated else locale.am_abbreviated;
            try output.appendSlice(allocator, value);
        },
        'H' => try appendPaddedNumber(
            allocator,
            output,
            date_time.hour,
            if (length >= 2) 2 else 1,
            locale,
        ),
        'h' => {
            const hour = if (date_time.hour % 12 == 0)
                12
            else
                date_time.hour % 12;
            try appendPaddedNumber(
                allocator,
                output,
                hour,
                if (length >= 2) 2 else 1,
                locale,
            );
        },
        'm' => try appendPaddedNumber(
            allocator,
            output,
            date_time.minute,
            if (length >= 2) 2 else 1,
            locale,
        ),
        's' => try appendPaddedNumber(
            allocator,
            output,
            date_time.second,
            if (length >= 2) 2 else 1,
            locale,
        ),
        'S' => {
            const digits = @min(length, 9);
            const divisor = std.math.pow(u32, 10, @intCast(9 - digits));
            try appendPaddedNumber(
                allocator,
                output,
                date_time.nanosecond / divisor,
                digits,
                locale,
            );
        },
        'z' => {
            if (zone.id.len != 0) {
                const width: timezone_names.Width = if (length >= 4) .long else .short;
                if (try timezone_names.zoneNameAlloc(
                    allocator,
                    locale_name,
                    zone.id,
                    zone.unix_seconds,
                    zone.daylight,
                    zone.uses_daylight,
                    width,
                    .specific,
                )) |value| {
                    defer allocator.free(value);
                    try output.appendSlice(allocator, value);
                } else {
                    const value = try timezone_names.gmtOffsetAlloc(
                        allocator,
                        locale_name,
                        date_time.offset_seconds,
                        width,
                    );
                    defer allocator.free(value);
                    try output.appendSlice(allocator, value);
                }
            } else {
                try output.appendSlice(allocator, zone.label);
            }
        },
        'v' => {
            if (zone.id.len != 0) {
                const width: timezone_names.Width = if (length >= 4) .long else .short;
                if (try timezone_names.zoneNameAlloc(
                    allocator,
                    locale_name,
                    zone.id,
                    zone.unix_seconds,
                    zone.daylight,
                    zone.uses_daylight,
                    width,
                    .generic,
                )) |value| {
                    defer allocator.free(value);
                    try output.appendSlice(allocator, value);
                } else {
                    const value = try timezone_names.gmtOffsetAlloc(
                        allocator,
                        locale_name,
                        date_time.offset_seconds,
                        width,
                    );
                    defer allocator.free(value);
                    try output.appendSlice(allocator, value);
                }
            } else {
                try output.appendSlice(allocator, zone.label);
            }
        },
        'V' => {
            if (zone.id.len != 0) {
                try output.appendSlice(allocator, zone.id);
            } else {
                try output.appendSlice(allocator, zone.label);
            }
        },
        'O' => {
            const width: timezone_names.Width = if (length >= 4) .long else .short;
            const value = try timezone_names.gmtOffsetAlloc(
                allocator,
                locale_name,
                date_time.offset_seconds,
                width,
            );
            defer allocator.free(value);
            try output.appendSlice(allocator, value);
        },
        'Z' => {
            if (length == 4) {
                const value = try timezone_names.gmtOffsetAlloc(
                    allocator,
                    locale_name,
                    date_time.offset_seconds,
                    .long,
                );
                defer allocator.free(value);
                try output.appendSlice(allocator, value);
            } else if (length >= 5) {
                try appendIsoOffset(
                    allocator,
                    output,
                    date_time.offset_seconds,
                    length,
                    true,
                    locale,
                );
            } else {
                try appendOffset(
                    allocator,
                    output,
                    date_time.offset_seconds,
                    length,
                    locale,
                );
            }
        },
        'X', 'x' => try appendIsoOffset(
            allocator,
            output,
            date_time.offset_seconds,
            length,
            field == 'X',
            locale,
        ),
        'D' => try appendPaddedNumber(
            allocator,
            output,
            dayOfYear(date_time),
            if (length >= 3) 3 else 1,
            locale,
        ),
        'Q', 'q' => {
            const quarter = ((overrides.month orelse date_time.month) - 1) / 3 + 1;
            if (length <= 2) {
                try appendPaddedNumber(
                    allocator,
                    output,
                    quarter,
                    length,
                    locale,
                );
            } else {
                try output.append(allocator, 'Q');
                try appendPaddedNumber(allocator, output, quarter, 1, locale);
            }
        },
        else => {},
    }
}

fn appendPaddedNumber(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: u64,
    min_digits: usize,
    locale: *const data.Locale,
) Error!void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch
        return error.OutOfMemory;
    var padding = if (text.len < min_digits) min_digits - text.len else 0;
    while (padding > 0) : (padding -= 1) {
        try appendDigit(allocator, output, 0, locale);
    }
    for (text) |byte| {
        try appendDigit(allocator, output, byte - '0', locale);
    }
}

fn appendDigit(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    digit: u8,
    locale: *const data.Locale,
) Error!void {
    const codepoint = locale.digits[@as(usize, digit)];
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        unreachable;
    try output.appendSlice(allocator, buffer[0..length]);
}

fn appendOffset(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    offset_seconds: i32,
    length: usize,
    locale: *const data.Locale,
) Error!void {
    const negative = offset_seconds < 0;
    const total: u32 = @intCast(if (negative) -offset_seconds else offset_seconds);
    const hours = total / 3600;
    const minutes = (total % 3600) / 60;

    if (length == 4) {
        try output.appendSlice(allocator, "GMT");
    } else if (length >= 5) {
        try output.appendSlice(allocator, if (negative) "-" else "+");
        try appendPaddedNumber(allocator, output, hours, 2, locale);
        try output.append(allocator, ':');
        try appendPaddedNumber(allocator, output, minutes, 2, locale);
        return;
    }

    try output.append(allocator, if (negative) '-' else '+');
    try appendPaddedNumber(allocator, output, hours, 2, locale);
    try appendPaddedNumber(allocator, output, minutes, 2, locale);
}

fn appendIsoOffset(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    offset_seconds: i32,
    length: usize,
    use_z: bool,
    locale: *const data.Locale,
) Error!void {
    if (offset_seconds == 0 and use_z) {
        try output.append(allocator, 'Z');
        return;
    }
    const negative = offset_seconds < 0;
    const total: u32 = @intCast(if (negative) -offset_seconds else offset_seconds);
    const hours = total / 3600;
    const minutes = (total % 3600) / 60;
    const seconds = total % 60;

    try output.append(allocator, if (negative) '-' else '+');
    try appendPaddedNumber(allocator, output, hours, 2, locale);
    if (length == 1) return;
    if (length == 2 or length == 4) {
        try appendPaddedNumber(allocator, output, minutes, 2, locale);
        if (length == 4) {
            try appendPaddedNumber(allocator, output, seconds, 2, locale);
        }
        return;
    }
    try output.append(allocator, ':');
    try appendPaddedNumber(allocator, output, minutes, 2, locale);
    if (length >= 5) {
        try output.append(allocator, ':');
        try appendPaddedNumber(allocator, output, seconds, 2, locale);
    }
}

fn substituteDateTimePattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_text: []const u8,
    time_text: []const u8,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                try output.append(allocator, '\'');
                index += 2;
                continue;
            }
            index += 1;
            while (index < pattern.len) {
                if (pattern[index] == '\'') {
                    if (index + 1 < pattern.len and
                        pattern[index + 1] == '\'')
                    {
                        try output.append(allocator, '\'');
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                try output.append(allocator, pattern[index]);
                index += 1;
            }
            continue;
        }
        if (byte == '{' and index + 2 < pattern.len and
            pattern[index + 2] == '}')
        {
            const placeholder = pattern[index + 1];
            if (placeholder == '1') {
                try output.appendSlice(allocator, date_text);
                index += 3;
                continue;
            }
            if (placeholder == '0') {
                try output.appendSlice(allocator, time_text);
                index += 3;
                continue;
            }
        }
        try output.append(allocator, byte);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn isAsciiLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn dayOfWeek(date_time: DateTime) usize {
    const days = daysFromCivil(date_time.year, date_time.month, date_time.day);
    return @intCast(@mod(days + 4, 7));
}

fn dayOfYear(date_time: DateTime) u64 {
    const start = daysFromCivil(date_time.year, 1, 1);
    const current = daysFromCivil(
        date_time.year,
        date_time.month,
        date_time.day,
    );
    return @intCast(current - start + 1);
}

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y: i64 = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) -
            @divFloor(doe, 146096),
        365,
    );
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    if (month <= 2) year += 1;
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn findLocale(locale: []const u8) ?*const data.Locale {
    if (lookup(locale)) |result| return result;

    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    for (locale) |byte| {
        if (len == buffer.len) break;
        buffer[len] = if (byte == '-') '_' else byte;
        len += 1;
    }
    if (lookup(buffer[0..len])) |result| return result;
    if (std.mem.indexOfAny(u8, locale, "-_")) |position| {
        if (lookup(locale[0..position])) |result| return result;
    }
    return null;
}

fn lookup(locale: []const u8) ?*const data.Locale {
    var low: usize = 0;
    var high = data.locales.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = data.locales[mid];
        switch (std.mem.order(u8, entry.id, locale)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &data.locales[mid],
        }
    }
    return null;
}

test "date and time formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const date_time = DateTime{
        .year = 2026,
        .month = 11,
        .day = 18,
        .hour = 15,
        .minute = 4,
        .second = 5,
    };

    const en_date = try formatDateAlloc(allocator, date_time, "en", .medium);
    defer allocator.free(en_date);
    try testing.expectEqualStrings("Nov 18, 2026", en_date);

    const en_full = try formatDateAlloc(allocator, date_time, "en", .full);
    defer allocator.free(en_full);
    try testing.expectEqualStrings("Wednesday, November 18, 2026", en_full);

    const en_time = try formatTimeAlloc(allocator, date_time, "en", .medium);
    defer allocator.free(en_time);
    try testing.expectEqualStrings("3:04:05\u{202f}PM", en_time);

    const de_date = try formatDateAlloc(allocator, date_time, "de", .medium);
    defer allocator.free(de_date);
    try testing.expectEqualStrings("18.11.2026", de_date);

    const de_time = try formatTimeAlloc(allocator, date_time, "de", .medium);
    defer allocator.free(de_time);
    try testing.expectEqualStrings("15:04:05", de_time);

    const fr_date = try formatDateAlloc(allocator, date_time, "fr", .medium);
    defer allocator.free(fr_date);
    try testing.expectEqualStrings("18 nov. 2026", fr_date);

    const ja_date = try formatDateAlloc(allocator, date_time, "ja", .medium);
    defer allocator.free(ja_date);
    try testing.expectEqualStrings("2026/11/18", ja_date);
}

test "date formatting covers additional locales" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const date_time = DateTime{
        .year = 2026,
        .month = 11,
        .day = 18,
        .hour = 15,
        .minute = 4,
        .second = 5,
    };

    const cases = [_]struct {
        locale: []const u8,
        expected: []const u8,
    }{
        .{ .locale = "es", .expected = "18 nov 2026" },
        .{ .locale = "it", .expected = "18 nov 2026" },
        .{ .locale = "pl", .expected = "18 lis 2026" },
        .{ .locale = "tr", .expected = "18 Kas 2026" },
        .{ .locale = "ko", .expected = "2026. 11. 18." },
        .{ .locale = "hi", .expected = "18 \u{0928}\u{0935}\u{0970} 2026" },
        .{ .locale = "fr-CA", .expected = "18 nov. 2026" },
        .{ .locale = "en-IN", .expected = "18 Nov 2026" },
        .{ .locale = "ru", .expected = "18 \u{043D}\u{043E}\u{044F}\u{0431}. 2026\u{202F}\u{0433}." },
        .{ .locale = "pt-PT", .expected = "18/11/2026" },
        .{ .locale = "nl-BE", .expected = "18 nov 2026" },
        .{ .locale = "cs", .expected = "18. 11. 2026" },
        .{ .locale = "da", .expected = "18. nov. 2026" },
        .{ .locale = "vi", .expected = "18 thg 11, 2026" },
        .{ .locale = "zh-Hant", .expected = "2026\u{5E74}11\u{6708}18\u{65E5}" },
    };
    for (cases) |case| {
        const result = try formatDateAlloc(
            allocator,
            date_time,
            case.locale,
            .medium,
        );
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }

    const full = [_]struct {
        locale: []const u8,
        expected: []const u8,
    }{
        .{ .locale = "de", .expected = "Mittwoch, 18. November 2026" },
        .{ .locale = "es", .expected = "mi\u{00E9}rcoles, 18 de noviembre de 2026" },
        .{ .locale = "ko", .expected = "2026\u{B144} 11\u{C6D4} 18\u{C77C} \u{C218}\u{C694}\u{C77C}" },
        .{ .locale = "zh-Hant", .expected = "2026\u{5E74}11\u{6708}18\u{65E5} \u{661F}\u{671F}\u{4E09}" },
    };
    for (full) |case| {
        const result = try formatDateAlloc(
            allocator,
            date_time,
            case.locale,
            .full,
        );
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "custom patterns and Unix timestamps" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const epoch = fromUnixSeconds(0, 0);
    try testing.expectEqual(@as(i32, 1970), epoch.year);
    try testing.expectEqual(@as(u8, 1), epoch.month);
    try testing.expectEqual(@as(u8, 1), epoch.day);
    try testing.expectEqual(@as(usize, 4), dayOfWeek(epoch));

    const pattern = try formatPatternAlloc(
        allocator,
        "yyyy-MM-dd'T'HH:mm:ss",
        .{
            .year = 2026,
            .month = 11,
            .day = 18,
            .hour = 15,
            .minute = 4,
            .second = 5,
        },
        "en",
        "UTC",
    );
    defer allocator.free(pattern);
    try testing.expectEqualStrings("2026-11-18T15:04:05", pattern);

    const date_time = try formatDateTimeAlloc(
        allocator,
        .{
            .year = 2026,
            .month = 11,
            .day = 18,
            .hour = 15,
            .minute = 4,
            .second = 5,
        },
        "en",
        .medium,
        "UTC",
    );
    defer allocator.free(date_time);
    try testing.expectEqualStrings("Nov 18, 2026, 3:04:05\u{202f}PM", date_time);
}

test "time zone name conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("../timezone/names_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJZQ", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const locale_length = fixture[cursor];
        const zone_length = fixture[cursor + 1];
        const expected_length = std.mem.readInt(u16, fixture[cursor + 2 ..][0..2], .little);
        const unix_seconds = std.mem.readInt(i64, fixture[cursor + 4 ..][0..8], .little);
        const field = fixture[cursor + 12];
        cursor += 16;
        const locale_name = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const zone_name = fixture[cursor .. cursor + zone_length];
        cursor += zone_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        const pattern = switch (field) {
            0 => "z",
            1 => "zzzz",
            2 => "v",
            3 => "vvvv",
            4 => "O",
            5 => "OOOO",
            else => "ZZZZ",
        };
        total += 1;
        const actual = formatPatternInZoneAlloc(
            allocator,
            pattern,
            unix_seconds,
            locale_name,
            zone_name,
        ) catch |err| {
            failures += 1;
            if (printed < 40) {
                printed += 1;
                std.debug.print("zone name mismatch {s} {s} {s}: {s}\n", .{ locale_name, zone_name, pattern, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 40) {
                printed += 1;
                std.debug.print(
                    "zone name mismatch {s} {s} {s}: got '{s}' expected '{s}'\n",
                    .{ locale_name, zone_name, pattern, actual, expected },
                );
            }
        }
    }
    std.debug.print("zone name conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}

test "calendar formatting conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("calendar_format_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJKF", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    const patterns = [_][]const u8{
        "G y-MM-dd",
        "MMMM d, y",
        "EEEE, MMMM d, y",
        "MMM d, y",
    };
    var cursor: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const locale_length = fixture[cursor];
        const calendar_index = fixture[cursor + 1];
        const kind = fixture[cursor + 2];
        const unix_seconds = std.mem.readInt(i64, fixture[cursor + 4 ..][0..8], .little);
        const expected_length = std.mem.readInt(u16, fixture[cursor + 12 ..][0..2], .little);
        cursor += 16;
        const locale_name = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        const calendar: calendar_mod.Calendar = @enumFromInt(calendar_index);
        const date_time = fromUnixSeconds(unix_seconds, 0);
        total += 1;
        const result = if (kind < 0x80)
            formatPatternInCalendarAlloc(
                allocator,
                patterns[kind],
                date_time,
                locale_name,
                calendar,
            )
        else blk: {
            const style: Style = switch (kind & 0x7F) {
                0 => .full,
                1 => .long,
                2 => .medium,
                else => .short,
            };
            break :blk formatDateInCalendarAlloc(
                allocator,
                date_time,
                locale_name,
                calendar,
                style,
            );
        };
        const actual = result catch |err| {
            failures += 1;
            if (printed < 40) {
                printed += 1;
                std.debug.print(
                    "calendar format mismatch {s} {s} kind {d}: {s}\n",
                    .{ locale_name, @tagName(calendar), kind, @errorName(err) },
                );
            }
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 40) {
                printed += 1;
                std.debug.print(
                    "calendar format mismatch {s} {s} kind {d}: got '{s}' expected '{s}'\n",
                    .{ locale_name, @tagName(calendar), kind, actual, expected },
                );
            }
        }
    }
    std.debug.print(
        "calendar format conformance: {d}/{d} passed\n",
        .{ total - failures, total },
    );
    try testing.expect(failures == 0);
}

test "numbering system conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const number = @import("number.zig");
    const fixture = @embedFile("numbering_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJNS", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const kind = fixture[cursor];
        const locale_length = fixture[cursor + 1];
        const system_length = fixture[cursor + 2];
        const bits = std.mem.readInt(u64, fixture[cursor + 4 ..][0..8], .little);
        const expected_length = std.mem.readInt(u16, fixture[cursor + 12 ..][0..2], .little);
        cursor += 16;
        const locale_name = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const system = fixture[cursor .. cursor + system_length];
        cursor += system_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        var tag_buffer: [96]u8 = undefined;
        const tag = std.fmt.bufPrint(
            &tag_buffer,
            "{s}@numbers={s}",
            .{ locale_name, system },
        ) catch continue;
        const value: f64 = @bitCast(bits);
        total += 1;
        const actual = if (kind == 0)
            number.formatAlloc(allocator, value, tag, .{}) catch |err| {
                failures += 1;
                if (printed < 30) {
                    printed += 1;
                    std.debug.print("numbering mismatch {s} {s}: {s}\n", .{ locale_name, system, @errorName(err) });
                }
                continue;
            }
        else
            formatPatternAlloc(
                allocator,
                "y-MM-dd",
                fromUnixSeconds(@intFromFloat(value), 0),
                tag,
                "UTC",
            ) catch |err| {
                failures += 1;
                if (printed < 30) {
                    printed += 1;
                    std.debug.print("numbering mismatch {s} {s}: {s}\n", .{ locale_name, system, @errorName(err) });
                }
                continue;
            };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "numbering mismatch {s} {s} kind {d}: got '{s}' expected '{s}'\n",
                    .{ locale_name, system, kind, actual, expected },
                );
            }
        }
    }
    std.debug.print("numbering conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}
