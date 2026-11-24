//! CLDR 48 Gregorian date and time formatting.

const std = @import("std");
const data = @import("dates_data.zig");
const timezone = @import("../timezone/root.zig");
const week = @import("week.zig");
const day_periods = @import("day_periods.zig");
const timezone_names = @import("../timezone/names.zig");
const calendar_mod = @import("calendar.zig");
const calendars = @import("calendars.zig");
const misc = @import("misc.zig");
const numbering_systems = @import("numbering_systems.zig");

pub const cldr_version = "48";
pub const weekend = @import("weekend.zig");

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

/// Format a custom CLDR date/time pattern and report the byte range of
/// every expanded pattern field in `fields`.
pub fn formatPatternFieldsAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_time: DateTime,
    locale_name: []const u8,
    zone_name: []const u8,
    fields: *std.ArrayList(DateFieldPosition),
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    return formatPatternWithLocaleFields(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        .{ .label = zone_name },
        .{},
        fields,
    );
}

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

// ICU UDateTimePatternField order: era, year, quarter, month, week-of-year,
// week-of-month, weekday, day-of-year, day-of-week-in-month, day, dayperiod,
// hour, minute, second, fractional second, zone.
const skeleton_order = "GyYuUrUQqMLlwWEecDFdgabBHkhKJjCmsASvzZOVXx";

/// Canonicalize an ICU date skeleton (fields sorted by ICU's canonical
/// order) into `buffer`.
pub fn canonicalSkeleton(
    skeleton: []const u8,
    buffer: []u8,
) ?[]const u8 {
    const Field = struct {
        letter: u8,
        count: u8,
        order: u16,
    };
    var fields: [32]Field = undefined;
    var count: usize = 0;
    var index: usize = 0;
    while (index < skeleton.len) {
        const letter = skeleton[index];
        if (!std.ascii.isAlphabetic(letter)) return null;
        var end = index;
        while (end < skeleton.len and skeleton[end] == letter) end += 1;
        const position = std.mem.indexOfScalar(u8, skeleton_order, letter);
        const order: u16 = if (position) |value|
            @intCast(value)
        else
            @intCast(skeleton_order.len + index);
        const entry = Field{
            .letter = letter,
            .count = @intCast(end - index),
            .order = order,
        };
        // ICU keeps the last letter provided for a field.
        var existing: ?usize = null;
        for (fields[0..count], 0..) |field, slot| {
            if (field.order == order) {
                existing = slot;
                break;
            }
        }
        if (existing) |slot| {
            fields[slot] = entry;
        } else {
            if (count == fields.len) return null;
            fields[count] = entry;
            count += 1;
        }
        index = end;
    }
    if (count == 0) return null;

    var sorted: usize = 1;
    while (sorted < count) : (sorted += 1) {
        const current = fields[sorted];
        var position = sorted;
        while (position > 0 and fields[position - 1].order > current.order) {
            fields[position] = fields[position - 1];
            position -= 1;
        }
        fields[position] = current;
    }

    var length: usize = 0;
    for (fields[0..count]) |field| {
        var repetition: u8 = 0;
        while (repetition < field.count) : (repetition += 1) {
            if (length == buffer.len) return null;
            buffer[length] = field.letter;
            length += 1;
        }
    }
    return buffer[0..length];
}

fn skeletonFieldSet(canonical: []const u8, buffer: []u8) ?[]const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < canonical.len) {
        const letter = canonical[index];
        if (length == buffer.len) return null;
        buffer[length] = letter;
        length += 1;
        while (index < canonical.len and canonical[index] == letter) index += 1;
    }
    return buffer[0..length];
}

/// Resolve the locale pattern for an ICU date skeleton. Patterns that need
/// their field widths adjusted for the request are built into `buffer`.
pub fn skeletonPattern(
    locale_name: []const u8,
    skeleton: []const u8,
    buffer: []u8,
) ?[]const u8 {
    var canonical_buffer: [64]u8 = undefined;
    const canonical = canonicalSkeleton(skeleton, &canonical_buffer) orelse
        return null;
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    for (locale.skeletons) |item| {
        if (std.mem.eql(u8, item.id, canonical)) return item.pattern;
    }
    var request_buffer: [64]u8 = undefined;
    const request_set = skeletonFieldSet(canonical, &request_buffer) orelse
        return null;
    var best_pattern: ?[]const u8 = null;
    var best_skeleton: ?[]const u8 = null;
    var best_distance: u32 = std.math.maxInt(u32);
    for (locale.skeletons) |item| {
        var item_buffer: [64]u8 = undefined;
        const item_set = skeletonFieldSet(item.id, &item_buffer) orelse
            continue;
        if (!std.mem.eql(u8, item_set, request_set)) continue;
        const distance = skeletonDistance(canonical, item.id);
        if (distance < best_distance) {
            best_distance = distance;
            best_pattern = item.pattern;
            best_skeleton = item.id;
            if (distance == 0) break;
        }
    }
    if (best_pattern) |pattern| {
        return adjustSkeletonWidths(
            pattern,
            canonical,
            best_skeleton.?,
            buffer,
        ) orelse pattern;
    }
    return null;
}

/// Resolve an ICU date/time skeleton to the locale's CLDR pattern. Skeletons
/// that contain both date and time fields are split and joined with the
/// locale's date-time glue pattern, mirroring `formatSkeletonAlloc`.
pub fn skeletonPatternAlloc(
    allocator: std.mem.Allocator,
    locale_name: []const u8,
    skeleton: []const u8,
) Error!?[]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    var pattern_buffer: [128]u8 = undefined;
    if (skeletonPattern(locale_name, skeleton, &pattern_buffer)) |pattern| {
        return try allocator.dupe(u8, pattern);
    }
    var date_part_buffer: [32]u8 = undefined;
    var time_part_buffer: [32]u8 = undefined;
    const split = splitSkeleton(
        locale,
        skeleton,
        &date_part_buffer,
        &time_part_buffer,
    );
    if (split.date.len > 0 and split.time.len > 0) {
        var date_pattern_buffer: [128]u8 = undefined;
        var time_pattern_buffer: [128]u8 = undefined;
        const date_pattern = skeletonPattern(
            locale_name,
            split.date,
            &date_pattern_buffer,
        ) orelse locale.date_medium;
        const time_pattern = skeletonPattern(
            locale_name,
            split.time,
            &time_pattern_buffer,
        ) orelse locale.time_medium;
        return try substituteDateTimePatterns(
            allocator,
            dateTimeGlue(locale, split.date),
            date_pattern,
            time_pattern,
        );
    }
    if (split.time.len > 0) {
        var time_only_buffer: [128]u8 = undefined;
        const pattern = skeletonPattern(
            locale_name,
            split.time,
            &time_only_buffer,
        ) orelse locale.time_medium;
        return try allocator.dupe(u8, pattern);
    }
    if (split.date.len > 0) {
        var date_only_buffer: [128]u8 = undefined;
        const pattern = skeletonPattern(
            locale_name,
            split.date,
            &date_only_buffer,
        ) orelse locale.date_medium;
        return try allocator.dupe(u8, pattern);
    }
    return null;
}

/// Join two CLDR patterns with a date-time glue pattern while preserving the
/// pattern syntax of both sides (quoted literals included).
fn substituteDateTimePatterns(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_pattern: []const u8,
    time_pattern: []const u8,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '{' and index + 2 < pattern.len and
            pattern[index + 2] == '}')
        {
            const placeholder = pattern[index + 1];
            if (placeholder == '1') {
                try output.appendSlice(allocator, date_pattern);
                index += 3;
                continue;
            }
            if (placeholder == '0') {
                try output.appendSlice(allocator, time_pattern);
                index += 3;
                continue;
            }
        }
        try output.append(allocator, pattern[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

/// ICU DateTimePatternGenerator::getBestPattern width distance: field width
/// differences plus a penalty when numeric and textual month forms compete.
fn skeletonDistance(request: []const u8, candidate: []const u8) u32 {
    var distance: u32 = 0;
    var letter: u8 = 'A';
    while (letter <= 'Z') : (letter += 1) {
        distance += skeletonFieldDistance(request, candidate, letter);
    }
    letter = 'a';
    while (letter <= 'z') : (letter += 1) {
        distance += skeletonFieldDistance(request, candidate, letter);
    }
    return distance;
}

fn skeletonFieldDistance(request: []const u8, candidate: []const u8, letter: u8) u32 {
    const request_width = requestedWidth(request, letter) orelse 0;
    const candidate_width = requestedWidth(candidate, letter) orelse 0;
    if (request_width == candidate_width) return 0;
    if (request_width == 0 or candidate_width == 0) return 0x1000;
    if (letter == 'M' and (request_width <= 2) != (candidate_width <= 2)) {
        return 0x100;
    }
    return if (request_width > candidate_width)
        request_width - candidate_width
    else
        candidate_width - request_width;
}

fn requestedWidth(canonical: []const u8, letter: u8) ?u8 {
    var index: usize = 0;
    while (index < canonical.len) {
        if (canonical[index] != letter) {
            index += 1;
            continue;
        }
        var end = index;
        while (end < canonical.len and canonical[end] == letter) end += 1;
        return @intCast(end - index);
    }
    return null;
}

/// Select the locale's date-time glue pattern for a date skeleton the way
/// ICU DateTimePatternGenerator::getBestPattern does: the month width picks
/// the style, and a wide month with a weekday requests the full style.
pub fn dateTimeGlue(locale: *const data.Locale, date_skeleton: []const u8) []const u8 {
    const month_width = requestedWidth(date_skeleton, 'M') orelse
        requestedWidth(date_skeleton, 'L') orelse 0;
    if (month_width == 4) {
        if (skeletonHasAny(date_skeleton, "Eec")) {
            return locale.date_time_full;
        }
        return locale.date_time_long;
    }
    if (month_width == 3) return locale.date_time_medium;
    return locale.date_time_short;
}

/// Adjust the field widths of a resolved pattern to the requested skeleton
/// (ICU DateTimePatternGenerator::adjustFieldTypes). Fields whose width in
/// the matched skeleton already equals the request keep the pattern width,
/// as do numeric/textual mismatches and fixed-width time fields.
fn adjustSkeletonWidths(
    pattern: []const u8,
    canonical: []const u8,
    matched: []const u8,
    buffer: []u8,
) ?[]const u8 {
    var length: usize = 0;
    var index: usize = 0;
    var quoted = false;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '\'') {
            quoted = !quoted;
            if (length == buffer.len) return null;
            buffer[length] = byte;
            length += 1;
            index += 1;
            continue;
        }
        if (quoted or !std.ascii.isAlphabetic(byte)) {
            if (length == buffer.len) return null;
            buffer[length] = byte;
            length += 1;
            index += 1;
            continue;
        }
        var end = index;
        while (end < pattern.len and pattern[end] == byte) end += 1;
        const pattern_width = end - index;
        var width = pattern_width;
        const letter: u8 = if (byte == 'L') 'M' else byte;
        if (!fixedWidthField(byte)) {
            if (requestedWidth(canonical, letter)) |requested_raw| {
                var requested = requested_raw;
                if (letter == 'E' and requested < 3) requested = 3;
                var adjust = true;
                if (requestedWidth(matched, letter)) |matched_raw| {
                    var matched_length = matched_raw;
                    if (letter == 'E' and matched_length < 3) matched_length = 3;
                    if (matched_length == requested) adjust = false;
                }
                if (adjust and
                    fieldIsNumeric(letter, @intCast(pattern_width)) !=
                        fieldIsNumeric(letter, requested))
                {
                    adjust = false;
                }
                if (adjust) width = requested;
            }
        }
        if (length + width > buffer.len) return null;
        var repetition: usize = 0;
        while (repetition < width) : (repetition += 1) {
            buffer[length] = byte;
            length += 1;
        }
        index = end;
    }
    return buffer[0..length];
}

fn fixedWidthField(byte: u8) bool {
    return switch (byte) {
        'H', 'h', 'K', 'k', 'J', 'j', 'C', 'm', 's', 'S', 'A', 'a', 'b', 'B' => true,
        else => false,
    };
}

fn numericTextMismatch(letter: u8, requested: u8, matched: u8) bool {
    if (letter != 'M') return false;
    return (requested <= 2) != (matched <= 2);
}

/// Whether a field width selects the numeric (rather than textual) form.
fn fieldIsNumeric(letter: u8, width: u8) bool {
    return switch (letter) {
        'M', 'L', 'l' => width <= 2,
        'd', 'y', 'Y', 'u', 'r', 'U', 'D', 'A', 'F', 'g' => true,
        else => false,
    };
}

pub const SplitSkeleton = struct {
    date: []const u8,
    time: []const u8,
};

pub fn splitSkeleton(
    locale: *const data.Locale,
    skeleton: []const u8,
    date_buffer: []u8,
    time_buffer: []u8,
) SplitSkeleton {
    const date_letters = "GyYuUrUQqMLlwWEecDFdg";
    const time_letters = "abBhHKJCkmsASzZOVvXx";
    const preferred_hour: u8 = if (std.mem.indexOfAny(
        u8,
        locale.time_short,
        "hK",
    ) != null) 'h' else 'H';
    var date_length: usize = 0;
    var time_length: usize = 0;
    for (skeleton) |letter| {
        if (std.mem.indexOfScalar(u8, date_letters, letter) != null) {
            if (date_length < date_buffer.len) {
                date_buffer[date_length] = letter;
                date_length += 1;
            }
        } else if (letter == 'j') {
            if (time_length < time_buffer.len) {
                time_buffer[time_length] = preferred_hour;
                time_length += 1;
            }
        } else if (std.mem.indexOfScalar(u8, time_letters, letter) != null) {
            if (time_length < time_buffer.len) {
                time_buffer[time_length] = letter;
                time_length += 1;
            }
        }
    }
    return .{
        .date = date_buffer[0..date_length],
        .time = time_buffer[0..time_length],
    };
}

fn skeletonHasAny(skeleton: []const u8, letters: []const u8) bool {
    for (skeleton) |byte| {
        if (std.mem.indexOfScalar(u8, letters, byte) != null) return true;
    }
    return false;
}

/// Format a date/time value using an ICU date skeleton.
pub fn formatSkeletonAlloc(
    allocator: std.mem.Allocator,
    date_time: DateTime,
    locale_name: []const u8,
    skeleton: []const u8,
) Error![]u8 {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;
    var pattern_buffer: [128]u8 = undefined;
    if (skeletonPattern(locale_name, skeleton, &pattern_buffer)) |pattern| {
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
    // Split date and time skeletons and combine their resolved patterns
    // with the locale's date-time glue pattern.
    var date_part_buffer: [32]u8 = undefined;
    var time_part_buffer: [32]u8 = undefined;
    const split = splitSkeleton(
        locale,
        skeleton,
        &date_part_buffer,
        &time_part_buffer,
    );
    if (split.date.len > 0 and split.time.len > 0) {
        var date_pattern_buffer: [128]u8 = undefined;
        var time_pattern_buffer: [128]u8 = undefined;
        const date_pattern = skeletonPattern(
            locale_name,
            split.date,
            &date_pattern_buffer,
        ) orelse locale.date_medium;
        const time_pattern = skeletonPattern(
            locale_name,
            split.time,
            &time_pattern_buffer,
        ) orelse locale.time_medium;
        const date_text = try formatPatternWithLocale(
            allocator,
            date_pattern,
            date_time,
            locale,
            locale_name,
            .{ .label = "UTC" },
            .{},
        );
        defer allocator.free(date_text);
        const time_text = try formatPatternWithLocale(
            allocator,
            time_pattern,
            date_time,
            locale,
            locale_name,
            .{ .label = "UTC" },
            .{},
        );
        defer allocator.free(time_text);
        return substituteDateTimePattern(
            allocator,
            dateTimeGlue(locale, split.date),
            date_text,
            time_text,
        );
    }
    if (split.time.len > 0) {
        var time_pattern_buffer: [128]u8 = undefined;
        const pattern = skeletonPattern(
            locale_name,
            split.time,
            &time_pattern_buffer,
        ) orelse locale.time_medium;
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
    if (split.date.len > 0) {
        var date_only_buffer: [128]u8 = undefined;
        const pattern = skeletonPattern(
            locale_name,
            split.date,
            &date_only_buffer,
        ) orelse locale.date_medium;
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
    return formatDateAlloc(allocator, date_time, locale_name, .medium);
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

/// Byte range of one pattern field in formatted output.
pub const DateFieldPosition = struct {
    /// CLDR pattern letter, for example 'y', 'M', 'd', 'H', 'm', 's', or 'a'.
    field: u8,
    start: usize,
    end: usize,
};

fn formatPatternWithLocale(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_time: DateTime,
    locale: *const data.Locale,
    locale_name: []const u8,
    zone: ZoneInfo,
    overrides: FieldOverrides,
) Error![]u8 {
    return formatPatternWithLocaleFields(
        allocator,
        pattern,
        date_time,
        locale,
        locale_name,
        zone,
        overrides,
        null,
    );
}

fn formatPatternWithLocaleFields(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_time: DateTime,
    locale: *const data.Locale,
    locale_name: []const u8,
    zone: ZoneInfo,
    overrides: FieldOverrides,
    fields: ?*std.ArrayList(DateFieldPosition),
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    // A formatted date is short; reserving once keeps the field appends from
    // growing the list step by step.
    output.ensureTotalCapacity(allocator, 64) catch {};

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
            const field_start = output.items.len;
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
            if (fields) |list| {
                const field_end = output.items.len;
                if (field_end > field_start) {
                    try list.append(allocator, .{
                        .field = byte,
                        .start = field_start,
                        .end = field_end,
                    });
                }
            }
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
        'Y' => {
            const settings = weekSettingsFor(locale, locale_name);
            const info = weekOfYear(
                date_time,
                settings.first_day,
                settings.minimal_days,
            );
            const year: u64 = @intCast(@max(info.year, 0));
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
        'u', 'r', 'U' => {
            // Proleptic Gregorian year aliases; ICU renders the cyclic year
            // (U) as the Gregorian year for this calendar.
            const year: u64 = @intCast(@max(
                overrides.year orelse date_time.year,
                0,
            ));
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
        'w' => {
            const settings = weekSettingsFor(locale, locale_name);
            const info = weekOfYear(
                date_time,
                settings.first_day,
                settings.minimal_days,
            );
            try appendPaddedNumber(
                allocator,
                output,
                info.week,
                if (length >= 2) 2 else 1,
                locale,
            );
        },
        'W' => {
            const settings = weekSettingsFor(locale, locale_name);
            try appendPaddedNumber(
                allocator,
                output,
                weekOfMonth(
                    date_time,
                    settings.first_day,
                    settings.minimal_days,
                ),
                if (length >= 2) 2 else 1,
                locale,
            );
        },
        'M', 'L', 'l' => {
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
                const standalone = (field == 'L' or field == 'l') and
                    overrides.months == null;
                const names: []const []const u8 = if (overrides.months) |months|
                    if (length == 3)
                        months.abbreviated[0..]
                    else if (length == 4)
                        months.wide[0..]
                    else
                        months.narrow[0..]
                else if (standalone)
                    if (length == 3)
                        locale.months_standalone_abbreviated[0..]
                    else if (length == 4)
                        locale.months_standalone_wide[0..]
                    else
                        locale.months_standalone_narrow[0..]
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
        'E', 'c', 'e' => {
            const day = dayOfWeek(date_time);
            const standalone = field == 'c';
            const value = if (length >= 6)
                if (standalone) locale.days_standalone_short[day] else locale.days_short[day]
            else if (length == 5)
                if (standalone) locale.days_standalone_narrow[day] else locale.days_narrow[day]
            else if (length == 4)
                if (standalone) locale.days_standalone_wide[day] else locale.days_wide[day]
            else if (standalone)
                locale.days_standalone_abbreviated[day]
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
        'b', 'B' => {
            const width: day_periods.Width = if (length >= 5)
                .narrow
            else if (length == 4)
                .wide
            else
                .abbreviated;
            const value = day_periods.nameForTime(
                locale_name,
                date_time.hour,
                date_time.minute,
                width,
                field == 'B',
            );
            if (value.len != 0) {
                try output.appendSlice(allocator, value);
            } else {
                const is_pm = date_time.hour >= 12;
                try output.appendSlice(allocator, if (length >= 5)
                    (if (is_pm) locale.pm_narrow else locale.am_narrow)
                else if (length == 4)
                    (if (is_pm) locale.pm_wide else locale.am_wide)
                else
                    (if (is_pm) locale.pm_abbreviated else locale.am_abbreviated));
            }
        },
        'H', 'J' => try appendPaddedNumber(
            allocator,
            output,
            date_time.hour,
            if (length >= 2) 2 else 1,
            locale,
        ),
        'h' => try appendHour12(allocator, output, date_time, length, locale),
        'C', 'j' => {
            const preferred_hour: u8 = if (std.mem.indexOfAny(
                u8,
                locale.time_short,
                "hK",
            ) != null) 'h' else 'H';
            if (preferred_hour == 'h') {
                try appendHour12(allocator, output, date_time, length, locale);
            } else {
                try appendPaddedNumber(
                    allocator,
                    output,
                    date_time.hour,
                    if (length >= 2) 2 else 1,
                    locale,
                );
            }
        },
        'K' => try appendPaddedNumber(
            allocator,
            output,
            date_time.hour % 12,
            if (length >= 2) 2 else 1,
            locale,
        ),
        'k' => try appendPaddedNumber(
            allocator,
            output,
            if (date_time.hour == 0) 24 else date_time.hour,
            if (length >= 2) 2 else 1,
            locale,
        ),
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
        'A' => {
            const millis: u64 =
                (@as(u64, date_time.hour) * 3600 +
                    @as(u64, date_time.minute) * 60 +
                    date_time.second) * 1000 +
                date_time.nanosecond / 1_000_000;
            try appendPaddedNumber(
                allocator,
                output,
                millis,
                @max(length, 1),
                locale,
            );
        },
        'F' => try appendPaddedNumber(
            allocator,
            output,
            (@as(u64, date_time.day) - 1) / 7 + 1,
            @max(length, 1),
            locale,
        ),
        'g' => {
            const days = daysFromCivil(
                date_time.year,
                date_time.month,
                date_time.day,
            );
            try appendPaddedNumber(
                allocator,
                output,
                @intCast(@max(days + 40587, 0)),
                @max(length, 1),
                locale,
            );
        },
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
                const standalone = field == 'q';
                const names: []const []const u8 = if (standalone)
                    if (length == 3)
                        locale.quarters_standalone_abbreviated[0..]
                    else if (length == 4)
                        locale.quarters_standalone_wide[0..]
                    else
                        locale.quarters_standalone_narrow[0..]
                else if (length == 3)
                    locale.quarters_abbreviated[0..]
                else if (length == 4)
                    locale.quarters_wide[0..]
                else
                    locale.quarters_narrow[0..];
                const index = @min(quarter - 1, names.len - 1);
                try output.appendSlice(allocator, names[index]);
            }
        },
        else => {},
    }
}

fn appendHour12(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    date_time: DateTime,
    length: usize,
    locale: *const data.Locale,
) Error!void {
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
}

/// Append a one- to four-byte sequence with inline stores; the list slice
/// helpers call memcpy for every runtime length.
inline fn appendShort(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
) Error!void {
    if (output.unusedCapacitySlice().len < bytes.len) {
        try output.ensureUnusedCapacity(allocator, bytes.len);
    }
    const dest = output.unusedCapacitySlice();
    const length = bytes.len;
    if (length != 0) {
        dest[0] = bytes[0];
        if (length > 1) {
            dest[1] = bytes[1];
            if (length > 2) {
                dest[2] = bytes[2];
                if (length > 3) dest[3] = bytes[3];
            }
        }
    }
    output.items.len += length;
}

fn appendPaddedNumber(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: u64,
    min_digits: usize,
    locale: *const data.Locale,
) Error!void {
    // Small decimal conversion; the generic formatter's setup costs more
    // than the digit loop for the field widths date patterns use.
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(remaining % 10));
        count += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }
    var padding = if (count < min_digits) min_digits - count else 0;
    while (padding > 0) : (padding -= 1) {
        try appendDigit(allocator, output, 0, locale);
    }
    while (count > 0) {
        count -= 1;
        try appendDigit(allocator, output, digits[count] - '0', locale);
    }
}

fn appendDigit(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    digit: u8,
    locale: *const data.Locale,
) Error!void {
    const codepoint = locale.digits[@as(usize, digit)];
    if (codepoint < 0x80) {
        try appendShort(allocator, output, &[_]u8{@intCast(codepoint)});
        return;
    }
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        unreachable;
    try appendShort(allocator, output, buffer[0..length]);
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

pub fn substituteDateTimePattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    date_text: []const u8,
    time_text: []const u8,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    // A formatted date is short; reserving once keeps the field appends from
    // growing the list step by step.
    output.ensureTotalCapacity(allocator, 64) catch {};

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

/// Start (as a day number) of the week containing `days`, where week days
/// begin at `first_day` (Sunday = 0).
fn weekStart(days: i64, first_day: u8) i64 {
    const offset = @mod(days + 4 - @as(i64, first_day) + 7, 7);
    return days - offset;
}

/// First day of week 1 of `year` under the locale's first-day/min-days rules.
fn weekOneStart(year: i32, first_day: u8, min_days: u8) i64 {
    const jan1 = daysFromCivil(year, 1, 1);
    const offset = @mod(jan1 + 4 - @as(i64, first_day) + 7, 7);
    var start = jan1 - offset;
    if (7 - offset < min_days) start += 7;
    return start;
}

pub const WeekInfo = struct {
    year: i32,
    week: u8,
};

/// CLDR/ICU week-based year and week-of-year for a date.
fn weekOfYear(date_time: DateTime, first_day: u8, min_days: u8) WeekInfo {
    const days = daysFromCivil(date_time.year, date_time.month, date_time.day);
    const start = weekStart(days, first_day);
    const current = weekOneStart(date_time.year, first_day, min_days);
    if (start < current) {
        const previous = weekOneStart(date_time.year - 1, first_day, min_days);
        return .{
            .year = date_time.year - 1,
            .week = @intCast(@divFloor(start - previous, 7) + 1),
        };
    }
    const next = weekOneStart(date_time.year + 1, first_day, min_days);
    if (start >= next) {
        return .{ .year = date_time.year + 1, .week = 1 };
    }
    return .{
        .year = date_time.year,
        .week = @intCast(@divFloor(start - current, 7) + 1),
    };
}

/// Week of month under the locale's first-day/min-days rules; days before the
/// first full week are week 0.
fn weekOfMonth(date_time: DateTime, first_day: u8, min_days: u8) u8 {
    const month_start = daysFromCivil(date_time.year, date_time.month, 1);
    const offset = @mod(month_start + 4 - @as(i64, first_day) + 7, 7);
    var week_one = month_start - offset;
    if (7 - offset < min_days) week_one += 7;
    const days = daysFromCivil(date_time.year, date_time.month, date_time.day);
    if (days < week_one) return 0;
    const start = weekStart(days, first_day);
    return @intCast(@divFloor(start - week_one, 7) + 1);
}

/// Region subtag of a locale tag, when one is present. Language-only tags
/// keep the likely-region week settings baked into the date data.
fn regionFromLocale(locale_name: []const u8) ?[]const u8 {
    var index: usize = 0;
    var first = true;
    while (index < locale_name.len) {
        const start = index;
        while (index < locale_name.len and locale_name[index] != '-' and
            locale_name[index] != '_')
        {
            index += 1;
        }
        const subtag = locale_name[start..index];
        if (index < locale_name.len) index += 1;
        if (first) {
            first = false;
            continue;
        }
        if (subtag.len == 4 and std.ascii.isAlphabetic(subtag[0])) continue;
        if ((subtag.len == 2 and std.ascii.isAlphabetic(subtag[0]) and
            std.ascii.isAlphabetic(subtag[1])) or
            (subtag.len == 3 and std.ascii.isDigit(subtag[0]) and
                std.ascii.isDigit(subtag[1]) and
                std.ascii.isDigit(subtag[2])))
        {
            return subtag;
        }
        break;
    }
    return null;
}

fn weekSettingsFor(
    locale: *const data.Locale,
    locale_name: []const u8,
) week.WeekData {
    if (regionFromLocale(locale_name)) |region| {
        return week.weekDataForRegion(region);
    }
    return .{
        .first_day = locale.first_day_of_week,
        .minimal_days = locale.minimal_days,
    };
}

/// Week-based year and week-of-year for a date under a region's CLDR rules.
pub fn weekOfYearForRegion(date_time: DateTime, region: []const u8) WeekInfo {
    const settings = week.weekDataForRegion(region);
    return weekOfYear(date_time, settings.first_day, settings.minimal_days);
}

/// Week of month under a region's CLDR rules; days before the first full
/// week are week 0.
pub fn weekOfMonthForRegion(date_time: DateTime, region: []const u8) u8 {
    const settings = week.weekDataForRegion(region);
    return weekOfMonth(date_time, settings.first_day, settings.minimal_days);
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

/// ICU `UDateFormatSymbolType` values backed by the Gregorian data.
pub const DateSymbolType = enum(u8) {
    eras = 0,
    months = 1,
    short_months = 2,
    weekdays = 3,
    short_weekdays = 4,
    am_pms = 5,
    era_names = 7,
    narrow_months = 8,
    narrow_weekdays = 9,
    standalone_months = 10,
    standalone_short_months = 11,
    standalone_narrow_months = 12,
    standalone_weekdays = 13,
    standalone_short_weekdays = 14,
    standalone_narrow_weekdays = 15,
    quarters = 16,
    short_quarters = 17,
    standalone_quarters = 18,
    standalone_short_quarters = 19,
    shorter_weekdays = 20,
    standalone_shorter_weekdays = 21,
};

pub fn dateSymbolTypeFromInt(value: u8) ?DateSymbolType {
    return switch (value) {
        0 => .eras,
        1 => .months,
        2 => .short_months,
        3 => .weekdays,
        4 => .short_weekdays,
        5 => .am_pms,
        7 => .era_names,
        8 => .narrow_months,
        9 => .narrow_weekdays,
        10 => .standalone_months,
        11 => .standalone_short_months,
        12 => .standalone_narrow_months,
        13 => .standalone_weekdays,
        14 => .standalone_short_weekdays,
        15 => .standalone_narrow_weekdays,
        16 => .quarters,
        17 => .short_quarters,
        18 => .standalone_quarters,
        19 => .standalone_short_quarters,
        20 => .shorter_weekdays,
        21 => .standalone_shorter_weekdays,
        else => null,
    };
}

fn twoSymbolsAt(
    values: *const [2][]const u8,
    index: usize,
) ?[]const u8 {
    return if (index < 2) values[index] else null;
}

fn monthSymbolAt(
    values: *const [12][]const u8,
    index: usize,
) ?[]const u8 {
    return if (index < 12) values[index] else null;
}

fn quarterSymbolAt(
    values: *const [4][]const u8,
    index: usize,
) ?[]const u8 {
    return if (index < 4) values[index] else null;
}

/// ICU indexes weekdays with a leading empty entry (Sunday = 1).
fn weekdaySymbolAt(
    values: *const [7][]const u8,
    index: usize,
) ?[]const u8 {
    if (index == 0) return "";
    if (index > 7) return null;
    return values[index - 1];
}

/// ICU `udat_countSymbols` for the supported Gregorian symbol types.
pub fn dateSymbolCount(symbol: DateSymbolType) usize {
    return switch (symbol) {
        .eras, .era_names, .am_pms => 2,
        .months,
        .short_months,
        .narrow_months,
        .standalone_months,
        .standalone_short_months,
        .standalone_narrow_months,
        => 12,
        .weekdays,
        .short_weekdays,
        .narrow_weekdays,
        .shorter_weekdays,
        .standalone_weekdays,
        .standalone_short_weekdays,
        .standalone_narrow_weekdays,
        .standalone_shorter_weekdays,
        => 8,
        .quarters,
        .short_quarters,
        .standalone_quarters,
        .standalone_short_quarters,
        => 4,
    };
}

/// ICU `udat_getSymbols` for the supported Gregorian symbol types.
pub fn dateSymbolAt(
    locale_name: []const u8,
    symbol: DateSymbolType,
    index: usize,
) ?[]const u8 {
    const entry = findLocale(locale_name) orelse
        findLocale("en") orelse return null;
    return switch (symbol) {
        .eras => twoSymbolsAt(&entry.era_abbreviated, index),
        .era_names => twoSymbolsAt(&entry.era_wide, index),
        .am_pms => switch (index) {
            0 => entry.am_abbreviated,
            1 => entry.pm_abbreviated,
            else => null,
        },
        .months => monthSymbolAt(&entry.months_wide, index),
        .short_months => monthSymbolAt(&entry.months_abbreviated, index),
        .narrow_months => monthSymbolAt(&entry.months_narrow, index),
        .standalone_months => monthSymbolAt(
            &entry.months_standalone_wide,
            index,
        ),
        .standalone_short_months => monthSymbolAt(
            &entry.months_standalone_abbreviated,
            index,
        ),
        .standalone_narrow_months => monthSymbolAt(
            &entry.months_standalone_narrow,
            index,
        ),
        .weekdays => weekdaySymbolAt(&entry.days_wide, index),
        .short_weekdays => weekdaySymbolAt(&entry.days_abbreviated, index),
        .narrow_weekdays => weekdaySymbolAt(&entry.days_narrow, index),
        .shorter_weekdays => weekdaySymbolAt(&entry.days_short, index),
        .standalone_weekdays => weekdaySymbolAt(
            &entry.days_standalone_wide,
            index,
        ),
        .standalone_short_weekdays => weekdaySymbolAt(
            &entry.days_standalone_abbreviated,
            index,
        ),
        .standalone_narrow_weekdays => weekdaySymbolAt(
            &entry.days_standalone_narrow,
            index,
        ),
        .standalone_shorter_weekdays => weekdaySymbolAt(
            &entry.days_standalone_short,
            index,
        ),
        .quarters => quarterSymbolAt(&entry.quarters_wide, index),
        .short_quarters => quarterSymbolAt(&entry.quarters_abbreviated, index),
        .standalone_quarters => quarterSymbolAt(
            &entry.quarters_standalone_wide,
            index,
        ),
        .standalone_short_quarters => quarterSymbolAt(
            &entry.quarters_standalone_abbreviated,
            index,
        ),
    };
}

/// CLDR first day of the week for the locale's region (0 = Sunday).
pub fn dateFirstDayOfWeek(locale_name: []const u8) ?u8 {
    const entry = findLocale(locale_name) orelse
        findLocale("en") orelse return null;
    return entry.first_day_of_week;
}

/// CLDR minimal days in the first week for the locale's region.
pub fn dateMinimalDaysInFirstWeek(locale_name: []const u8) ?u8 {
    const entry = findLocale(locale_name) orelse
        findLocale("en") orelse return null;
    return entry.minimal_days;
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

pub const ParseDefaults = struct {
    year: i32 = 1970,
    month: u8 = 1,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    nanosecond: u32 = 0,
};

const ParseState = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    pm: ?bool = null,
    hour12: ?u8 = null,
    bc: bool = false,
    day_of_year: ?u16 = null,
    offset_seconds: i32 = 0,
};

/// Parse `text` according to a localized date/time pattern.
///
/// Supports era, year, month (numeric and names), day, day of year,
/// weekday names, day periods, 12/24-hour clocks, minutes, seconds,
/// fractional seconds, quarter names, and numeric zone offsets (`Z`, `X`,
/// `x`, `O`). Named zone fields (`z`, `v`, `V`) and week fields are not
/// supported and make the parse fail. Fields absent from the pattern keep
/// their `defaults` value; a two-digit year maps to 2000-2079 or 1900-1999.
pub fn parsePattern(
    text: []const u8,
    pattern: []const u8,
    locale_name: []const u8,
    defaults: ParseDefaults,
) ?DateTime {
    var locale_storage: data.Locale = undefined;
    const locale = resolveLocale(locale_name, &locale_storage) orelse
        findLocale("en").?;

    var state = ParseState{
        .year = defaults.year,
        .month = defaults.month,
        .day = defaults.day,
        .hour = defaults.hour,
        .minute = defaults.minute,
        .second = defaults.second,
        .nanosecond = defaults.nanosecond,
    };

    var text_index: usize = 0;
    var index: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                if (!matchPatternLiteral(text, &text_index, '\'')) return null;
                index += 2;
                continue;
            }
            index += 1;
            while (index < pattern.len) {
                if (pattern[index] == '\'') {
                    if (index + 1 < pattern.len and
                        pattern[index + 1] == '\'')
                    {
                        if (!matchPatternLiteral(text, &text_index, '\'')) {
                            return null;
                        }
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                if (!matchPatternLiteral(text, &text_index, pattern[index])) {
                    return null;
                }
                index += 1;
            }
            continue;
        }
        if (isAsciiLetter(byte)) {
            var end = index;
            while (end < pattern.len and pattern[end] == byte) end += 1;
            if (!parsePatternField(
                &state,
                text,
                &text_index,
                byte,
                end - index,
                locale,
                locale_name,
            )) {
                return null;
            }
            index = end;
            continue;
        }
        if (!matchPatternLiteral(text, &text_index, byte)) return null;
        index += 1;
    }

    skipDateSpace(text, &text_index);
    if (text_index != text.len) return null;
    return finishParsedDate(&state);
}

/// Parse `text` using the locale's best pattern for `skeleton`.
pub fn parseSkeleton(
    text: []const u8,
    skeleton: []const u8,
    locale_name: []const u8,
    defaults: ParseDefaults,
) ?DateTime {
    var buffer: [64]u8 = undefined;
    const pattern = skeletonPattern(locale_name, skeleton, &buffer) orelse
        return null;
    return parsePattern(text, pattern, locale_name, defaults);
}

fn matchPatternLiteral(text: []const u8, index: *usize, byte: u8) bool {
    if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
        skipDateSpace(text, index);
        return true;
    }
    if (index.* >= text.len or text[index.*] != byte) return false;
    index.* += 1;
    return true;
}

fn skipDateSpace(text: []const u8, index: *usize) void {
    while (index.* < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index.*]) catch
            return;
        if (index.* + length > text.len) return;
        const codepoint = std.unicode.utf8Decode(
            text[index.*..][0..length],
        ) catch return;
        if (!(codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or
            codepoint == '\r' or codepoint == 0x00A0 or codepoint == 0x2009 or
            codepoint == 0x202F))
        {
            return;
        }
        index.* += length;
    }
}

fn dateDigit(locale: *const data.Locale, codepoint: u21) ?u8 {
    if (codepoint >= '0' and codepoint <= '9') {
        return @intCast(codepoint - '0');
    }
    for (locale.digits, 0..) |digit, index| {
        if (digit == codepoint) return @intCast(index);
    }
    return null;
}

fn parseDateNumber(
    locale: *const data.Locale,
    text: []const u8,
    index: *usize,
    max_digits: usize,
) ?u32 {
    var value: u32 = 0;
    var digits: usize = 0;
    while (digits < max_digits and index.* < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index.*]) catch
            break;
        if (index.* + length > text.len) break;
        const codepoint = std.unicode.utf8Decode(
            text[index.*..][0..length],
        ) catch break;
        const digit = dateDigit(locale, codepoint) orelse break;
        value = value * 10 + digit;
        digits += 1;
        index.* += length;
    }
    if (digits == 0) return null;
    return value;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (prefix, 0..) |byte, index| {
        if (std.ascii.toLower(text[index]) != std.ascii.toLower(byte)) {
            return false;
        }
    }
    return true;
}

fn matchName(
    text: []const u8,
    index: *usize,
    names: []const []const u8,
) ?usize {
    var best: ?usize = null;
    var best_length: usize = 0;
    for (names, 0..) |name, name_index| {
        if (name.len == 0 or name.len <= best_length) continue;
        if (!startsWithIgnoreCase(text[index.*..], name)) continue;
        best = name_index;
        best_length = name.len;
    }
    if (best) |name_index| {
        index.* += best_length;
        return name_index;
    }
    return null;
}

fn parsePatternField(
    state: *ParseState,
    text: []const u8,
    index: *usize,
    field: u8,
    length: usize,
    locale: *const data.Locale,
    locale_name: []const u8,
) bool {
    switch (field) {
        'y', 'u', 'U', 'r' => {
            const value = parseDateNumber(
                locale,
                text,
                index,
                if (length == 2) 2 else 6,
            ) orelse return false;
            if (length == 2 and value < 100) {
                state.year = if (value < 80)
                    2000 + @as(i32, @intCast(value))
                else
                    1900 + @as(i32, @intCast(value));
            } else {
                state.year = @intCast(value);
            }
            return true;
        },
        'M', 'L', 'l' => {
            if (length <= 2) {
                const value = parseDateNumber(locale, text, index, 2) orelse
                    return false;
                if (value < 1 or value > 12) return false;
                state.month = @intCast(value);
                return true;
            }
            return parseMonthName(state, text, index, length, locale);
        },
        'd' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value < 1 or value > 31) return false;
            state.day = @intCast(value);
            return true;
        },
        'D' => {
            const value = parseDateNumber(locale, text, index, 3) orelse
                return false;
            if (value < 1 or value > 366) return false;
            state.day_of_year = @intCast(value);
            return true;
        },
        'E', 'e', 'c' => return parseWeekdayName(text, index, length, locale),
        'a', 'b', 'B' => return parseDayPeriod(
            state,
            text,
            index,
            locale,
            locale_name,
            field,
            length,
        ),
        'h' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value < 1 or value > 12) return false;
            state.hour12 = @intCast(value % 12);
            return true;
        },
        'H', 'J' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value > 23) return false;
            state.hour = @intCast(value);
            return true;
        },
        'C', 'j' => {
            const preferred_hour: u8 = if (std.mem.indexOfAny(
                u8,
                locale.time_short,
                "hK",
            ) != null) 'h' else 'H';
            if (preferred_hour == 'h') {
                const value = parseDateNumber(locale, text, index, 2) orelse
                    return false;
                if (value < 1 or value > 12) return false;
                state.hour12 = @intCast(value % 12);
                return true;
            }
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value > 23) return false;
            state.hour = @intCast(value);
            return true;
        },
        'K' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value > 11) return false;
            state.hour12 = @intCast(value);
            return true;
        },
        'k' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value < 1 or value > 24) return false;
            state.hour = @intCast(value % 24);
            return true;
        },
        'm' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value > 59) return false;
            state.minute = @intCast(value);
            return true;
        },
        's' => {
            const value = parseDateNumber(locale, text, index, 2) orelse
                return false;
            if (value > 59) return false;
            state.second = @intCast(value);
            return true;
        },
        'S' => {
            var value: u32 = 0;
            var digits: usize = 0;
            while (digits < length and index.* < text.len and
                text[index.*] >= '0' and text[index.*] <= '9')
            {
                value = value * 10 + (text[index.*] - '0');
                digits += 1;
                index.* += 1;
            }
            if (digits == 0) return false;
            var nanos = value;
            var scale = digits;
            while (scale < 9) : (scale += 1) nanos *= 10;
            state.nanosecond = nanos;
            return true;
        },
        'G' => return parseEra(state, text, index, length, locale),
        'Z', 'X', 'x', 'O' => {
            return parseZoneOffset(state, text, index, field, length);
        },
        'Q', 'q' => {
            if (length <= 2) {
                const value = parseDateNumber(locale, text, index, 1) orelse
                    return false;
                if (value < 1 or value > 4) return false;
                state.month = @intCast((value - 1) * 3 + 1);
                return true;
            }
            return parseQuarterName(state, text, index, length, locale);
        },
        else => return false,
    }
}

fn parseMonthName(
    state: *ParseState,
    text: []const u8,
    index: *usize,
    length: usize,
    locale: *const data.Locale,
) bool {
    const format_names: []const []const u8 = switch (length) {
        3 => &locale.months_abbreviated,
        4 => &locale.months_wide,
        else => &locale.months_narrow,
    };
    if (matchName(text, index, format_names)) |month_index| {
        state.month = @intCast(month_index + 1);
        return true;
    }
    const standalone_names: []const []const u8 = switch (length) {
        3 => &locale.months_standalone_abbreviated,
        4 => &locale.months_standalone_wide,
        else => &locale.months_standalone_narrow,
    };
    if (matchName(text, index, standalone_names)) |month_index| {
        state.month = @intCast(month_index + 1);
        return true;
    }
    return false;
}

fn parseWeekdayName(
    text: []const u8,
    index: *usize,
    length: usize,
    locale: *const data.Locale,
) bool {
    const format_names: []const []const u8 = switch (length) {
        3 => &locale.days_abbreviated,
        4 => &locale.days_wide,
        5 => &locale.days_narrow,
        6 => &locale.days_short,
        else => &locale.days_abbreviated,
    };
    if (matchName(text, index, format_names) != null) return true;
    const standalone_names: []const []const u8 = switch (length) {
        3 => &locale.days_standalone_abbreviated,
        4 => &locale.days_standalone_wide,
        5 => &locale.days_standalone_narrow,
        6 => &locale.days_standalone_short,
        else => &locale.days_standalone_abbreviated,
    };
    return matchName(text, index, standalone_names) != null;
}

fn parseDayPeriod(
    state: *ParseState,
    text: []const u8,
    index: *usize,
    locale: *const data.Locale,
    locale_name: []const u8,
    field: u8,
    length: usize,
) bool {
    const names = [_][]const u8{
        locale.am_wide,
        locale.pm_wide,
        locale.am_abbreviated,
        locale.pm_abbreviated,
        locale.am_narrow,
        locale.pm_narrow,
    };
    if (matchName(text, index, &names)) |period| {
        state.pm = period % 2 == 1;
        return true;
    }
    if (field != 'b' and field != 'B') return false;

    const width: day_periods.Width = if (length >= 5)
        .narrow
    else if (length == 4)
        .wide
    else
        .abbreviated;
    const day_names = day_periods.localeNames(locale_name);
    var best: ?day_periods.Period = null;
    var best_length: usize = 0;
    var period_index: u8 = 0;
    while (period_index < 12) : (period_index += 1) {
        const period: day_periods.Period = @enumFromInt(period_index);
        if (field == 'b' and period != .am and period != .pm and
            period != .noon and period != .midnight)
        {
            continue;
        }
        const name = day_periods.nameAt(day_names, period, width);
        if (name.len == 0 or name.len <= best_length) continue;
        if (!startsWithIgnoreCase(text[index.*..], name)) continue;
        best = period;
        best_length = name.len;
    }
    const period = best orelse return false;
    index.* += best_length;
    switch (period) {
        .am, .midnight, .morning1, .morning2, .night1, .night2 => {
            state.pm = false;
        },
        .pm, .noon, .afternoon1, .afternoon2, .evening1, .evening2 => {
            state.pm = true;
        },
    }
    // The 12-hour parsers store 12 o'clock as 0, so noon and midnight use
    // the same representation and rely on the pm flag.
    if (period == .noon or period == .midnight) state.hour12 = 0;
    return true;
}

fn parseEra(
    state: *ParseState,
    text: []const u8,
    index: *usize,
    length: usize,
    locale: *const data.Locale,
) bool {
    const names: []const []const u8 = switch (length) {
        4 => &locale.era_wide,
        5 => &locale.era_narrow,
        else => &locale.era_abbreviated,
    };
    const era = matchName(text, index, names) orelse return false;
    state.bc = era == 0;
    return true;
}

fn parseZoneOffset(
    state: *ParseState,
    text: []const u8,
    index: *usize,
    field: u8,
    length: usize,
) bool {
    if (field == 'O' or (field == 'Z' and length == 4)) {
        if (startsWithIgnoreCase(text[index.*..], "GMT")) {
            index.* += 3;
        } else if (startsWithIgnoreCase(text[index.*..], "UTC")) {
            index.* += 3;
        } else {
            return false;
        }
    }
    if (index.* < text.len and (text[index.*] == 'Z' or text[index.*] == 'z')) {
        index.* += 1;
        state.offset_seconds = 0;
        return true;
    }
    var sign: i32 = 1;
    if (index.* < text.len and text[index.*] == '+') {
        index.* += 1;
    } else if (index.* < text.len and text[index.*] == '-') {
        sign = -1;
        index.* += 1;
    } else {
        return false;
    }
    var hours: i32 = 0;
    var hour_digits: usize = 0;
    while (hour_digits < 2 and index.* < text.len and
        text[index.*] >= '0' and text[index.*] <= '9')
    {
        hours = hours * 10 + (text[index.*] - '0');
        hour_digits += 1;
        index.* += 1;
    }
    if (hour_digits == 0) return false;
    var minutes: i32 = 0;
    if (index.* < text.len and text[index.*] == ':') {
        index.* += 1;
        var minute_digits: usize = 0;
        while (minute_digits < 2 and index.* < text.len and
            text[index.*] >= '0' and text[index.*] <= '9')
        {
            minutes = minutes * 10 + (text[index.*] - '0');
            minute_digits += 1;
            index.* += 1;
        }
        if (minute_digits != 2) return false;
    } else if (index.* + 2 <= text.len and
        text[index.*] >= '0' and text[index.*] <= '9' and
        text[index.* + 1] >= '0' and text[index.* + 1] <= '9')
    {
        minutes = @as(i32, text[index.*] - '0') * 10 +
            (text[index.* + 1] - '0');
        index.* += 2;
    }
    if (hours > 23 or minutes > 59) return false;
    state.offset_seconds = sign * (hours * 3600 + minutes * 60);
    return true;
}

fn parseQuarterName(
    state: *ParseState,
    text: []const u8,
    index: *usize,
    length: usize,
    locale: *const data.Locale,
) bool {
    const format_names: []const []const u8 = switch (length) {
        3 => &locale.quarters_abbreviated,
        4 => &locale.quarters_wide,
        else => &locale.quarters_narrow,
    };
    if (matchName(text, index, format_names)) |quarter| {
        state.month = @intCast(quarter * 3 + 1);
        return true;
    }
    const standalone_names: []const []const u8 = switch (length) {
        3 => &locale.quarters_standalone_abbreviated,
        4 => &locale.quarters_standalone_wide,
        else => &locale.quarters_standalone_narrow,
    };
    if (matchName(text, index, standalone_names)) |quarter| {
        state.month = @intCast(quarter * 3 + 1);
        return true;
    }
    return false;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or
        @mod(year, 400) == 0;
}

fn finishParsedDate(state: *ParseState) ?DateTime {
    var year = state.year;
    if (state.bc) year = 1 - year;
    var month = state.month;
    var day = state.day;
    if (state.day_of_year) |day_of_year| {
        const start = daysFromCivil(year, 1, 1);
        const civil = civilFromDays(start + @as(i64, day_of_year) - 1);
        if (civil.year != year) return null;
        month = civil.month;
        day = civil.day;
    }
    if (state.hour12) |hour12| {
        state.hour = if (state.pm orelse false)
            (if (hour12 == 0) 12 else hour12 + 12)
        else
            hour12;
    }
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    if (state.hour > 23 or state.minute > 59 or state.second > 59) {
        return null;
    }
    if (state.nanosecond > 999_999_999) return null;
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = state.hour,
        .minute = state.minute,
        .second = state.second,
        .nanosecond = state.nanosecond,
        .offset_seconds = state.offset_seconds,
    };
}

test "date pattern parsing" {
    const testing = @import("std").testing;

    const medium = parsePattern(
        "Mar 5, 2024",
        "MMM d, y",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 2024), medium.year);
    try testing.expectEqual(@as(u8, 3), medium.month);
    try testing.expectEqual(@as(u8, 5), medium.day);

    const full = parsePattern(
        "Tuesday, March 5, 2024",
        "EEEE, MMMM d, y",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 2024), full.year);
    try testing.expectEqual(@as(u8, 3), full.month);

    const german = parsePattern(
        "05.03.2024",
        "dd.MM.y",
        "de",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 2024), german.year);
    try testing.expectEqual(@as(u8, 3), german.month);
    try testing.expectEqual(@as(u8, 5), german.day);

    const afternoon = parsePattern(
        "2:30:45 PM",
        "h:mm:ss a",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(u8, 14), afternoon.hour);
    try testing.expectEqual(@as(u8, 30), afternoon.minute);
    try testing.expectEqual(@as(u8, 45), afternoon.second);

    const midnight = parsePattern("12:05 AM", "h:mm a", "en", .{}).?;
    try testing.expectEqual(@as(u8, 0), midnight.hour);
    const noon = parsePattern("12:05 PM", "h:mm a", "en", .{}).?;
    try testing.expectEqual(@as(u8, 12), noon.hour);

    const iso = parsePattern(
        "2024-03-05T14:30:45.123",
        "y-MM-dd'T'HH:mm:ss.SSS",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(u8, 14), iso.hour);
    try testing.expectEqual(@as(u32, 123_000_000), iso.nanosecond);

    const persian = parsePattern(
        "\u{06f1}\u{06f4}\u{06f0}\u{06f2}/\u{06f1}\u{06f2}/\u{06f0}\u{06f5}",
        "y/M/d",
        "fa",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 1402), persian.year);
    try testing.expectEqual(@as(u8, 12), persian.month);
    try testing.expectEqual(@as(u8, 5), persian.day);

    const bc = parsePattern("5 BC", "y G", "en", .{}).?;
    try testing.expectEqual(@as(i32, -4), bc.year);

    const day_of_year = parsePattern("60 2024", "D y", "en", .{}).?;
    try testing.expectEqual(@as(u8, 2), day_of_year.month);
    try testing.expectEqual(@as(u8, 29), day_of_year.day);

    try testing.expect(parsePattern("2024-02-30", "y-MM-dd", "en", .{}) == null);
    try testing.expect(parsePattern("13/45/2024", "MM/dd/y", "en", .{}) == null);
    try testing.expect(parsePattern("2024-03-05", "y-MM-dd z", "en", .{}) == null);
    try testing.expect(parsePattern("", "y", "en", .{}) == null);

    const offset = parsePattern(
        "2024-03-05T14:30:45+08:00",
        "y-MM-dd'T'HH:mm:ssXXX",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 8 * 3600), offset.offset_seconds);
    const utc = parsePattern(
        "2024-03-05T14:30:45Z",
        "y-MM-dd'T'HH:mm:ssX",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 0), utc.offset_seconds);
    const west = parsePattern(
        "2024-03-05 14:30 -0500",
        "y-MM-dd HH:mm Z",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, -5 * 3600), west.offset_seconds);
    const gmt = parsePattern(
        "2024-03-05 14:30 GMT+08:00",
        "y-MM-dd HH:mm ZZZZ",
        "en",
        .{},
    ).?;
    try testing.expectEqual(@as(i32, 8 * 3600), gmt.offset_seconds);

    const skeleton = parseSkeleton("Mar 5, 2024", "yMMMd", "en", .{}).?;
    try testing.expectEqual(@as(i32, 2024), skeleton.year);
    try testing.expectEqual(@as(u8, 3), skeleton.month);
    try testing.expectEqual(@as(u8, 5), skeleton.day);
    try testing.expect(parseSkeleton("x", "not-a-skeleton", "en", .{}) == null);
}

test "date pattern round trips" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const date_time = DateTime{
        .year = 2024,
        .month = 3,
        .day = 5,
        .hour = 14,
        .minute = 30,
        .second = 45,
    };
    const defaults = ParseDefaults{
        .year = date_time.year,
        .month = date_time.month,
        .day = date_time.day,
        .hour = date_time.hour,
        .minute = date_time.minute,
        .second = date_time.second,
    };
    const cases = [_]struct { locale: []const u8, pattern: []const u8 }{
        .{ .locale = "en", .pattern = "y-MM-dd" },
        .{ .locale = "en", .pattern = "MMM d, y" },
        .{ .locale = "en", .pattern = "EEEE, MMMM d, y" },
        .{ .locale = "de", .pattern = "dd.MM.y" },
        .{ .locale = "fr", .pattern = "d MMMM y" },
        .{ .locale = "ja", .pattern = "y\u{5e74}M\u{6708}d\u{65e5}" },
        .{ .locale = "en", .pattern = "h:mm:ss a" },
        .{ .locale = "en", .pattern = "HH:mm:ss" },
        .{ .locale = "en", .pattern = "y-MM-dd'T'HH:mm:ss.SSS" },
        .{ .locale = "fa", .pattern = "y/M/d" },
        .{ .locale = "ar", .pattern = "d/M/y" },
        .{ .locale = "ru", .pattern = "d MMMM y '\u{433}'." },
    };
    for (cases) |case| {
        const formatted = try formatPatternAlloc(
            allocator,
            case.pattern,
            date_time,
            case.locale,
            "UTC",
        );
        defer allocator.free(formatted);
        const parsed = parsePattern(
            formatted,
            case.pattern,
            case.locale,
            defaults,
        ) orelse {
            std.debug.print("round trip failed: {s} '{s}' -> '{s}'\n", .{
                case.locale,
                case.pattern,
                formatted,
            });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(date_time.year, parsed.year);
        try testing.expectEqual(date_time.month, parsed.month);
        try testing.expectEqual(date_time.day, parsed.day);
        try testing.expectEqual(date_time.hour, parsed.hour);
        try testing.expectEqual(date_time.minute, parsed.minute);
        try testing.expectEqual(date_time.second, parsed.second);
    }
}

/// Calendar field for `fieldDifference`.
pub const CalendarField = enum { year, month, day, hour, minute, second };

/// Add whole days, keeping the time of day.
pub fn addDays(date_time: DateTime, days: i64) DateTime {
    const civil = civilFromDays(
        daysFromCivil(date_time.year, date_time.month, date_time.day) + days,
    );
    var result = date_time;
    result.year = civil.year;
    result.month = civil.month;
    result.day = civil.day;
    return result;
}

/// Add whole months, clamping the day to the target month's length.
pub fn addMonths(date_time: DateTime, months: i64) DateTime {
    const total = @as(i64, date_time.year) * 12 +
        @as(i64, date_time.month) - 1 + months;
    const year: i32 = @intCast(@divFloor(total, 12));
    const month: u8 = @intCast(@mod(total, 12) + 1);
    var result = date_time;
    result.year = year;
    result.month = month;
    const limit = daysInMonth(year, month);
    if (result.day > limit) result.day = limit;
    return result;
}

/// Add whole years, clamping February 29 to February 28 in common years.
pub fn addYears(date_time: DateTime, years: i64) DateTime {
    return addMonths(date_time, years * 12);
}

fn timeOfDaySeconds(date_time: DateTime) i64 {
    return @as(i64, date_time.hour) * 3600 +
        @as(i64, date_time.minute) * 60 + date_time.second;
}

/// Whole-field difference from `start` to `end`, truncated toward zero.
/// A partial unit at the end of the range is not counted.
pub fn fieldDifference(start: DateTime, end: DateTime, field: CalendarField) i64 {
    const start_days = daysFromCivil(start.year, start.month, start.day);
    const end_days = daysFromCivil(end.year, end.month, end.day);
    const start_time = timeOfDaySeconds(start);
    const end_time = timeOfDaySeconds(end);
    switch (field) {
        .year => return @divTrunc(
            fieldDifference(start, end, .month),
            12,
        ),
        .month => {
            var months = (@as(i64, end.year) - start.year) * 12 +
                (@as(i64, end.month) - start.month);
            if (months > 0 and
                (end.day < start.day or
                    (end.day == start.day and end_time < start_time)))
            {
                months -= 1;
            } else if (months < 0 and
                (end.day > start.day or
                    (end.day == start.day and end_time > start_time)))
            {
                months += 1;
            }
            return months;
        },
        .day => {
            var days = end_days - start_days;
            if (days > 0 and end_time < start_time) days -= 1;
            if (days < 0 and end_time > start_time) days += 1;
            return days;
        },
        .hour, .minute, .second => {
            const seconds = (end_days - start_days) * 86400 +
                end_time - start_time;
            return switch (field) {
                .hour => @divTrunc(seconds, 3600),
                .minute => @divTrunc(seconds, 60),
                else => seconds,
            };
        },
    }
}

test "calendar arithmetic" {
    const testing = @import("std").testing;

    const february = DateTime{
        .year = 2024,
        .month = 2,
        .day = 28,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const march = addDays(february, 2);
    try testing.expectEqual(@as(u8, 3), march.month);
    try testing.expectEqual(@as(u8, 1), march.day);

    const january_end = DateTime{
        .year = 2024,
        .month = 1,
        .day = 31,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const february_end = addMonths(january_end, 1);
    try testing.expectEqual(@as(u8, 2), february_end.month);
    try testing.expectEqual(@as(u8, 29), february_end.day);

    const leap_day = DateTime{
        .year = 2024,
        .month = 2,
        .day = 29,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const next_year = addYears(leap_day, 1);
    try testing.expectEqual(@as(i32, 2025), next_year.year);
    try testing.expectEqual(@as(u8, 2), next_year.month);
    try testing.expectEqual(@as(u8, 28), next_year.day);

    const start = DateTime{
        .year = 2024,
        .month = 1,
        .day = 15,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    try testing.expectEqual(
        @as(i64, 1),
        fieldDifference(start, .{
            .year = 2024,
            .month = 3,
            .day = 14,
            .hour = 0,
            .minute = 0,
            .second = 0,
        }, .month),
    );
    try testing.expectEqual(
        @as(i64, 2),
        fieldDifference(start, .{
            .year = 2024,
            .month = 3,
            .day = 15,
            .hour = 0,
            .minute = 0,
            .second = 0,
        }, .month),
    );
    try testing.expectEqual(
        @as(i64, 61),
        fieldDifference(start, .{
            .year = 2024,
            .month = 3,
            .day = 16,
            .hour = 0,
            .minute = 0,
            .second = 0,
        }, .day),
    );
    const morning = DateTime{
        .year = 2024,
        .month = 1,
        .day = 15,
        .hour = 10,
        .minute = 0,
        .second = 0,
    };
    const earlier = DateTime{
        .year = 2024,
        .month = 3,
        .day = 15,
        .hour = 9,
        .minute = 0,
        .second = 0,
    };
    try testing.expectEqual(@as(i64, 1), fieldDifference(morning, earlier, .month));
    try testing.expectEqual(
        @as(i64, 59),
        fieldDifference(morning, earlier, .day),
    );
    try testing.expectEqual(
        @as(i64, 1439),
        fieldDifference(morning, earlier, .hour),
    );
}

test "date parsing conformance" {
    const testing = @import("std").testing;
    const fixture = @embedFile("date_parse_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJXD", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const year = std.mem.readInt(i32, fixture[cursor..][0..4], .little);
        const month = fixture[cursor + 4];
        const day = fixture[cursor + 5];
        const hour = fixture[cursor + 6];
        const minute = fixture[cursor + 7];
        const second = fixture[cursor + 8];
        const locale_len = fixture[cursor + 9];
        const pattern_len = fixture[cursor + 10];
        const text_len = std.mem.readInt(
            u16,
            fixture[cursor + 11 ..][0..2],
            .little,
        );
        cursor += 13;
        const locale = fixture[cursor..][0..locale_len];
        cursor += locale_len;
        const pattern = fixture[cursor..][0..pattern_len];
        cursor += pattern_len;
        const text = fixture[cursor..][0..text_len];
        cursor += text_len;

        const defaults = ParseDefaults{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
        };
        const parsed = parsePattern(text, pattern, locale, defaults);
        if (parsed) |value| {
            if (value.year != year or value.month != month or
                value.day != day or value.hour != hour or
                value.minute != minute or value.second != second)
            {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "date parse mismatch {s} '{s}' '{s}': " ++
                            "{d}-{d}-{d} {d}:{d}:{d}\n",
                        .{
                            locale,
                            pattern,
                            text,
                            value.year,
                            value.month,
                            value.day,
                            value.hour,
                            value.minute,
                            value.second,
                        },
                    );
                }
            }
        } else {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "date parse failed {s} '{s}' '{s}'\n",
                    .{ locale, pattern, text },
                );
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
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

test "date field positions" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var fields = std.ArrayList(DateFieldPosition).empty;
    defer fields.deinit(allocator);
    const text = try formatPatternFieldsAlloc(
        allocator,
        "yyyy-MM-dd HH:mm:ss",
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
        &fields,
    );
    defer allocator.free(text);
    try testing.expectEqualStrings("2026-11-18 15:04:05", text);
    try testing.expectEqual(@as(usize, 6), fields.items.len);
    const expected = [_]struct { field: u8, value: []const u8 }{
        .{ .field = 'y', .value = "2026" },
        .{ .field = 'M', .value = "11" },
        .{ .field = 'd', .value = "18" },
        .{ .field = 'H', .value = "15" },
        .{ .field = 'm', .value = "04" },
        .{ .field = 's', .value = "05" },
    };
    for (expected, fields.items) |item, position| {
        try testing.expectEqual(item.field, position.field);
        try testing.expectEqualStrings(
            item.value,
            text[position.start..position.end],
        );
    }
}

test "parse flexible day periods" {
    const testing = @import("std").testing;

    const defaults = ParseDefaults{
        .year = 2026,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const morning = parsePattern("9 in the morning", "h B", "en", defaults).?;
    try testing.expectEqual(@as(u8, 9), morning.hour);
    const afternoon = parsePattern("3 in the afternoon", "h B", "en", defaults).?;
    try testing.expectEqual(@as(u8, 15), afternoon.hour);
    const noon = parsePattern("12 noon", "h b", "en", defaults).?;
    try testing.expectEqual(@as(u8, 12), noon.hour);
    const midnight = parsePattern("12 midnight", "h b", "en", defaults).?;
    try testing.expectEqual(@as(u8, 0), midnight.hour);
}

test "flexible day period pattern fields" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const morning = try formatPatternAlloc(
        allocator,
        "h B",
        .{
            .year = 2026,
            .month = 1,
            .day = 1,
            .hour = 9,
            .minute = 0,
            .second = 0,
        },
        "en",
        "UTC",
    );
    defer allocator.free(morning);
    try testing.expectEqualStrings("9 in the morning", morning);

    const noon = try formatPatternAlloc(
        allocator,
        "h b",
        .{
            .year = 2026,
            .month = 1,
            .day = 1,
            .hour = 12,
            .minute = 0,
            .second = 0,
        },
        "en",
        "UTC",
    );
    defer allocator.free(noon);
    try testing.expectEqualStrings("12 noon", noon);

    const afternoon = try formatPatternAlloc(
        allocator,
        "h B",
        .{
            .year = 2026,
            .month = 1,
            .day = 1,
            .hour = 15,
            .minute = 0,
            .second = 0,
        },
        "en",
        "UTC",
    );
    defer allocator.free(afternoon);
    try testing.expectEqualStrings("3 in the afternoon", afternoon);

    const german = try formatPatternAlloc(
        allocator,
        "h BBBB",
        .{
            .year = 2026,
            .month = 1,
            .day = 1,
            .hour = 11,
            .minute = 0,
            .second = 0,
        },
        "de",
        "UTC",
    );
    defer allocator.free(german);
    try testing.expectEqualStrings("11 vormittags", german);
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

test "date skeleton patterns" {
    const testing = @import("std").testing;
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "MMM d, y",
        skeletonPattern("en", "yMMMd", &buffer).?,
    );
    try testing.expectEqualStrings(
        "M/d/y",
        skeletonPattern("en", "yMd", &buffer).?,
    );
    try testing.expectEqualStrings(
        "d. MMM y",
        skeletonPattern("de", "yMMMd", &buffer).?,
    );
    try testing.expectEqualStrings(
        "y\u{5e74}M\u{6708}d\u{65e5}",
        skeletonPattern("ja", "yMMMd", &buffer).?,
    );
    // Canonical field order resolves the same pattern.
    try testing.expectEqualStrings(
        "MMM d, y",
        skeletonPattern("en", "dMMMy", &buffer).?,
    );
    // Field-set fallback widens textual fields to the requested skeleton.
    try testing.expectEqualStrings(
        "MMMM d, y",
        skeletonPattern("en", "yMMMMd", &buffer).?,
    );
    // Weekday widths follow the requested skeleton (E through EEEE are
    // equivalent for the base pattern; EEEE renders the wide name).
    try testing.expectEqualStrings(
        "EEEE, MMMM d, y",
        skeletonPattern("en", "yMMMMEEEEd", &buffer).?,
    );
}

test "date skeleton formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const date_time = DateTime{
        .year = 2026,
        .month = 11,
        .day = 19,
        .hour = 13,
        .minute = 45,
        .second = 30,
    };
    const en = try formatSkeletonAlloc(allocator, date_time, "en", "yMMMd");
    defer allocator.free(en);
    try testing.expectEqualStrings("Nov 19, 2026", en);
    const wide = try formatSkeletonAlloc(allocator, date_time, "en", "yMMMMd");
    defer allocator.free(wide);
    try testing.expectEqualStrings("November 19, 2026", wide);
    const de = try formatSkeletonAlloc(allocator, date_time, "de", "yMMMd");
    defer allocator.free(de);
    try testing.expectEqualStrings("19. Nov. 2026", de);
    const time = try formatSkeletonAlloc(allocator, date_time, "en", "Hm");
    defer allocator.free(time);
    try testing.expectEqualStrings("13:45", time);
    const ja = try formatSkeletonAlloc(allocator, date_time, "ja", "yMMMd");
    defer allocator.free(ja);
    try testing.expectEqualStrings("2026\u{5e74}11\u{6708}19\u{65e5}", ja);
}

test "date skeleton conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("date_skeleton_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGJ", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    const date_time = DateTime{
        .year = 2026,
        .month = 11,
        .day = 19,
        .hour = 13,
        .minute = 45,
        .second = 30,
    };
    var cursor: usize = 12;
    var failures: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const locale_length = fixture[cursor];
        const skeleton_length = fixture[cursor + 1];
        const expected_length = std.mem.readInt(
            u16,
            fixture[cursor + 2 ..][0..2],
            .little,
        );
        cursor += 6;
        const locale = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const skeleton = fixture[cursor .. cursor + skeleton_length];
        cursor += skeleton_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        const actual = formatSkeletonAlloc(
            allocator,
            date_time,
            locale,
            skeleton,
        ) catch |err| {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "date skeleton error {s} {s}: {s}\n",
                    .{ locale, skeleton, @errorName(err) },
                );
            }
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "date skeleton mismatch {s} {s}: got '{s}' expected '{s}'\n",
                    .{ locale, skeleton, actual, expected },
                );
            }
        }
    }
    std.debug.print("date skeleton conformance: {d}/{d} passed\n", .{
        case_count - failures,
        case_count,
    });
    try testing.expect(failures == 0);
}

test "region week of year and month" {
    const testing = @import("std").testing;

    const jan1_2023 = DateTime{
        .year = 2023,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const us = weekOfYearForRegion(jan1_2023, "US");
    try testing.expectEqual(@as(i32, 2023), us.year);
    try testing.expectEqual(@as(u8, 1), us.week);
    const gb = weekOfYearForRegion(jan1_2023, "GB");
    try testing.expectEqual(@as(i32, 2022), gb.year);
    try testing.expectEqual(@as(u8, 52), gb.week);

    try testing.expectEqual(@as(u8, 1), weekOfMonthForRegion(jan1_2023, "US"));
    try testing.expectEqual(@as(u8, 0), weekOfMonthForRegion(jan1_2023, "GB"));
}

test "quarter and week pattern fields" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const Case = struct {
        locale: []const u8,
        year: i32,
        month: u8,
        day: u8,
        pattern: []const u8,
        expected: []const u8,
    };
    // Expected strings verified against ICU 78 SimpleDateFormat.
    const cases = [_]Case{
        // Sunday-start, minimal days 1 (en).
        .{ .locale = "en", .year = 2021, .month = 1, .day = 1, .pattern = "Y-MM-dd", .expected = "2021-01-01" },
        .{ .locale = "en", .year = 2024, .month = 12, .day = 30, .pattern = "Y-MM-dd", .expected = "2025-12-30" },
        .{ .locale = "en", .year = 2021, .month = 1, .day = 1, .pattern = "w", .expected = "1" },
        .{ .locale = "en", .year = 2026, .month = 11, .day = 19, .pattern = "ww", .expected = "47" },
        .{ .locale = "en", .year = 2024, .month = 12, .day = 30, .pattern = "W", .expected = "5" },
        // Monday-start, minimal days 4 (de, fr, ru).
        .{ .locale = "de", .year = 2021, .month = 1, .day = 1, .pattern = "Y-MM-dd", .expected = "2020-01-01" },
        .{ .locale = "de", .year = 2021, .month = 1, .day = 1, .pattern = "w", .expected = "53" },
        .{ .locale = "de", .year = 2021, .month = 1, .day = 1, .pattern = "W", .expected = "0" },
        .{ .locale = "de", .year = 2021, .month = 1, .day = 4, .pattern = "w", .expected = "1" },
        .{ .locale = "fr", .year = 2024, .month = 12, .day = 30, .pattern = "Y-MM-dd", .expected = "2025-12-30" },
        .{ .locale = "ru", .year = 2021, .month = 1, .day = 3, .pattern = "w", .expected = "53" },
        // Monday-start, minimal days 1 (zh).
        .{ .locale = "zh", .year = 2021, .month = 1, .day = 3, .pattern = "w", .expected = "1" },
        .{ .locale = "zh", .year = 2026, .month = 11, .day = 19, .pattern = "W", .expected = "4" },
        // Quarter names.
        .{ .locale = "en", .year = 2026, .month = 11, .day = 19, .pattern = "QQQ y", .expected = "Q4 2026" },
        .{ .locale = "en", .year = 2026, .month = 11, .day = 19, .pattern = "QQQQ y", .expected = "4th quarter 2026" },
        .{ .locale = "de", .year = 2026, .month = 11, .day = 19, .pattern = "QQQQ y", .expected = "4. Quartal 2026" },
        .{ .locale = "ja", .year = 2026, .month = 11, .day = 19, .pattern = "QQQQ y", .expected = "\u{7b2c}4\u{56db}\u{534a}\u{671f} 2026" },
        .{ .locale = "fr", .year = 2026, .month = 11, .day = 19, .pattern = "QQQ y", .expected = "T4 2026" },
        .{ .locale = "zh", .year = 2026, .month = 11, .day = 19, .pattern = "QQQQ y", .expected = "\u{7b2c}\u{56db}\u{5b63}\u{5ea6} 2026" },
        // Proleptic year aliases.
        .{ .locale = "en", .year = 2026, .month = 11, .day = 19, .pattern = "u r U", .expected = "2026 2026 2026" },
    };
    for (cases) |case| {
        const date_time = DateTime{
            .year = case.year,
            .month = case.month,
            .day = case.day,
            .hour = 12,
            .minute = 0,
            .second = 0,
        };
        const text = try formatPatternAlloc(
            allocator,
            case.pattern,
            date_time,
            case.locale,
            "UTC",
        );
        defer allocator.free(text);
        try testing.expectEqualStrings(case.expected, text);
    }
}

test "regional week fields use the locale region" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const date = DateTime{
        .year = 2023,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const us = try formatPatternAlloc(allocator, "w", date, "en", "UTC");
    defer allocator.free(us);
    try testing.expectEqualStrings("1", us);
    const us_region = try formatPatternAlloc(
        allocator,
        "w",
        date,
        "en-US",
        "UTC",
    );
    defer allocator.free(us_region);
    try testing.expectEqualStrings("1", us_region);
    const gb = try formatPatternAlloc(allocator, "w", date, "en-GB", "UTC");
    defer allocator.free(gb);
    try testing.expectEqualStrings("52", gb);
    const de = try formatPatternAlloc(allocator, "w", date, "de", "UTC");
    defer allocator.free(de);
    try testing.expectEqualStrings("52", de);
}

test "J and C hour pattern fields" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const date = DateTime{
        .year = 2026,
        .month = 1,
        .day = 1,
        .hour = 15,
        .minute = 0,
        .second = 0,
    };
    const j = try formatPatternAlloc(allocator, "J", date, "en", "UTC");
    defer allocator.free(j);
    try testing.expectEqualStrings("15", j);
    const c_en = try formatPatternAlloc(allocator, "C", date, "en", "UTC");
    defer allocator.free(c_en);
    try testing.expectEqualStrings("3", c_en);
    const c_de = try formatPatternAlloc(allocator, "C", date, "de", "UTC");
    defer allocator.free(c_de);
    try testing.expectEqualStrings("15", c_de);

    const defaults = ParseDefaults{
        .year = 2026,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const parsed_j = parsePattern("15", "J", "en", defaults).?;
    try testing.expectEqual(@as(u8, 15), parsed_j.hour);
    const parsed_c = parsePattern("3 PM", "C a", "en", defaults).?;
    try testing.expectEqual(@as(u8, 15), parsed_c.hour);
    const parsed_c_de = parsePattern("15", "C", "de", defaults).?;
    try testing.expectEqual(@as(u8, 15), parsed_c_de.hour);
}

test "A, F, and g pattern fields" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const date = DateTime{
        .year = 2026,
        .month = 1,
        .day = 15,
        .hour = 1,
        .minute = 2,
        .second = 3,
        .nanosecond = 4_000_000,
    };
    const a = try formatPatternAlloc(allocator, "A", date, "en", "UTC");
    defer allocator.free(a);
    try testing.expectEqualStrings("3723004", a);
    const f = try formatPatternAlloc(allocator, "F", date, "en", "UTC");
    defer allocator.free(f);
    try testing.expectEqualStrings("3", f);
    const g = try formatPatternAlloc(allocator, "g", date, "en", "UTC");
    defer allocator.free(g);
    try testing.expectEqualStrings("61055", g);

    const epoch = DateTime{
        .year = 1970,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const mjd = try formatPatternAlloc(allocator, "g", epoch, "en", "UTC");
    defer allocator.free(mjd);
    try testing.expectEqualStrings("40587", mjd);
}

test "deprecated lowercase l month field" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const date = DateTime{
        .year = 2026,
        .month = 11,
        .day = 18,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const text = try formatPatternAlloc(allocator, "d llll", date, "en", "UTC");
    defer allocator.free(text);
    try testing.expectEqualStrings("18 November", text);
    const defaults = ParseDefaults{
        .year = 2026,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    const parsed = parsePattern("18 November", "d llll", "en", defaults).?;
    try testing.expectEqual(@as(u8, 11), parsed.month);
}

test "date symbols" {
    const testing = @import("std").testing;

    try testing.expectEqual(@as(usize, 12), dateSymbolCount(.months));
    try testing.expectEqual(@as(usize, 8), dateSymbolCount(.weekdays));
    try testing.expectEqualStrings(
        "January",
        dateSymbolAt("en", .months, 0).?,
    );
    try testing.expectEqualStrings(
        "Jan",
        dateSymbolAt("en", .short_months, 0).?,
    );
    try testing.expectEqualStrings(
        "Sunday",
        dateSymbolAt("en", .weekdays, 1).?,
    );
    try testing.expectEqualStrings("", dateSymbolAt("en", .weekdays, 0).?);
    try testing.expectEqualStrings("BC", dateSymbolAt("en", .eras, 0).?);
    try testing.expectEqualStrings(
        "Before Christ",
        dateSymbolAt("en", .era_names, 0).?,
    );
    try testing.expectEqualStrings("AM", dateSymbolAt("en", .am_pms, 0).?);
    try testing.expectEqualStrings(
        "Q1",
        dateSymbolAt("en", .short_quarters, 0).?,
    );
    try testing.expectEqualStrings(
        "1月",
        dateSymbolAt("ja", .months, 0).?,
    );
    try testing.expectEqual(@as(?[]const u8, null), dateSymbolAt(
        "en",
        .months,
        12,
    ));
    try testing.expectEqual(@as(u8, 0), dateFirstDayOfWeek("en").?);
    try testing.expectEqual(@as(u8, 1), dateMinimalDaysInFirstWeek("en").?);
}

test "ICU date symbols conformance fixture" {
    const testing = @import("std").testing;
    const fixture = @embedFile("date_symbols_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJYS", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const type_value = fixture[cursor];
        const locale_len = std.mem.readInt(
            u16,
            fixture[cursor + 1 ..][0..2],
            .little,
        );
        const count = fixture[cursor + 3];
        cursor += 4;
        const locale = fixture[cursor..][0..locale_len];
        cursor += locale_len;
        const symbol = dateSymbolTypeFromInt(type_value) orelse
            return error.InvalidFixture;
        if (dateSymbolCount(symbol) != count) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "date symbol count mismatch: {s} type {d} got {d} want {d}\n",
                    .{ locale, type_value, dateSymbolCount(symbol), count },
                );
            }
        }
        var value_index: usize = 0;
        while (value_index < count) : (value_index += 1) {
            const value_len = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
            const expected = fixture[cursor..][0..value_len];
            cursor += value_len;
            const actual = dateSymbolAt(locale, symbol, value_index) orelse "";
            if (!std.mem.eql(u8, actual, expected)) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "date symbol mismatch: {s} type {d} index {d} got {s} want {s}\n",
                        .{ locale, type_value, value_index, actual, expected },
                    );
                }
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "date symbol conformance: {}/{} records passed\n",
        .{ record_count - failures, record_count },
    );
}
