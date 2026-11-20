//! CLDR duration formatting.
//!
//! Numeric patterns come from `units/durationUnit` data; long, short, and
//! narrow styles reuse the unit and list formatters with the duration units.

const std = @import("std");
const number_data = @import("numbers_data.zig");
const misc = @import("misc.zig");
const units = @import("units.zig");
const list = @import("list.zig");

const blob = @embedFile("durations_data.bin");

const header_len = 16;
const locale_count = readU16(8);
const string_length = readU32(12);
const locale_offset = header_len;
const strings_offset = locale_offset + locale_count * 22;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJQ0") or
        blob[4] != 1)
    {
        @compileError("invalid duration data");
    }
    if (strings_offset + @as(usize, string_length) != blob.len) {
        @compileError("invalid duration data lengths");
    }
}

pub const Style = enum { long, short, narrow, numeric };

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn strAt(offset: u32) []const u8 {
    if (offset == 0) return "";
    return std.mem.sliceTo(blob[strings_offset + @as(usize, offset) ..], 0);
}

const LocaleRecord = struct {
    patterns: [3][]const u8,
};

fn localeAt(index: usize) LocaleRecord {
    const base = locale_offset + index * 22;
    const id_offset = readU32(base);
    const id_length = blob[base + 4];
    _ = id_offset;
    _ = id_length;
    return .{
        .patterns = .{
            strAt(readU32(base + 10)),
            strAt(readU32(base + 14)),
            strAt(readU32(base + 18)),
        },
    };
}

fn lookupLocale(name: []const u8) ?LocaleRecord {
    var low: usize = 0;
    var high: usize = locale_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = locale_offset + middle * 22;
        const id_offset = readU32(base);
        const id_length = blob[base + 4];
        const id = blob[strings_offset + @as(usize, id_offset) ..][0..id_length];
        switch (std.mem.order(u8, id, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return localeAt(middle),
        }
    }
    return null;
}

fn findLocale(name: []const u8) ?LocaleRecord {
    if (lookupLocale(name)) |record| return record;
    if (std.mem.indexOfAny(u8, name, "-_")) |position| {
        if (lookupLocale(name[0..position])) |record| return record;
    }
    return lookupLocale("en");
}

fn localeDigits(name: []const u8) [10]u21 {
    const locale = misc.findLocale(number_data.locales, name) orelse
        misc.findLocale(number_data.locales, "en").?;
    return locale.digits;
}

fn appendPadded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: u64,
    digits: usize,
    locale_digits: [10]u21,
) !void {
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
    var padding = if (text.len < digits) digits - text.len else 0;
    while (padding > 0) : (padding -= 1) {
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(locale_digits[0], &encoded) catch 0;
        try output.appendSlice(allocator, encoded[0..length]);
    }
    for (text) |character| {
        const digit = locale_digits[character - '0'];
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(digit, &encoded) catch 0;
        try output.appendSlice(allocator, encoded[0..length]);
    }
}

fn formatNumeric(
    allocator: std.mem.Allocator,
    total_seconds: u64,
    locale_name: []const u8,
    pattern: []const u8,
) ![]u8 {
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    const digits = localeDigits(locale_name);
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) {
        const character = pattern[index];
        if (character == 'h' or character == 'm' or character == 's') {
            var end = index;
            while (end < pattern.len and pattern[end] == character) end += 1;
            const width = end - index;
            const value = switch (character) {
                'h' => hours,
                'm' => minutes,
                else => seconds,
            };
            try appendPadded(allocator, &output, value, width, digits);
            index = end;
            continue;
        }
        try output.append(allocator, character);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn formatUnits(
    allocator: std.mem.Allocator,
    total_seconds: u64,
    locale_name: []const u8,
    style: Style,
) ![]u8 {
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    var items: [3][]u8 = undefined;
    var count: usize = 0;
    defer {
        for (items[0..count]) |item| allocator.free(item);
    }
    const unit_style: units.Style = if (style == .long) .long else .short;
    if (hours != 0) {
        items[count] = try units.formatAlloc(
            allocator,
            @floatFromInt(hours),
            .hour,
            locale_name,
            .{ .style = unit_style },
        );
        count += 1;
    }
    if (minutes != 0) {
        items[count] = try units.formatAlloc(
            allocator,
            @floatFromInt(minutes),
            .minute,
            locale_name,
            .{ .style = unit_style },
        );
        count += 1;
    }
    if (seconds != 0 or count == 0) {
        items[count] = try units.formatAlloc(
            allocator,
            @floatFromInt(seconds),
            .second,
            locale_name,
            .{ .style = unit_style },
        );
        count += 1;
    }
    const list_style: list.Style = switch (style) {
        .long => .unit,
        .short => .unit_short,
        else => .unit_narrow,
    };
    return list.formatAlloc(allocator, items[0..count], locale_name, .{
        .style = list_style,
    });
}

/// Duration broken into individual calendar and clock units.
pub const Duration = struct {
    years: f64 = 0,
    months: f64 = 0,
    weeks: f64 = 0,
    days: f64 = 0,
    hours: f64 = 0,
    minutes: f64 = 0,
    seconds: f64 = 0,
    milliseconds: f64 = 0,
    microseconds: f64 = 0,
    nanoseconds: f64 = 0,
};

/// Format a multi-unit duration. Numeric style falls back to short units for
/// calendar units; the numeric `h:mm:ss` patterns only cover clock units.
pub fn formatDurationUnitsAlloc(
    allocator: std.mem.Allocator,
    duration: Duration,
    locale_name: []const u8,
    style: Style,
) ![]u8 {
    const values = [_]struct { value: f64, unit: units.Unit }{
        .{ .value = duration.years, .unit = .year },
        .{ .value = duration.months, .unit = .month },
        .{ .value = duration.weeks, .unit = .week },
        .{ .value = duration.days, .unit = .day },
        .{ .value = duration.hours, .unit = .hour },
        .{ .value = duration.minutes, .unit = .minute },
        .{ .value = duration.seconds, .unit = .second },
        .{ .value = duration.milliseconds, .unit = .millisecond },
        .{ .value = duration.microseconds, .unit = .microsecond },
        .{ .value = duration.nanoseconds, .unit = .nanosecond },
    };
    const unit_style: units.Style = switch (style) {
        .long => .long,
        .short => .short,
        .narrow => .short,
        .numeric => .short,
    };
    var items: [values.len][]u8 = undefined;
    var count: usize = 0;
    defer for (items[0..count]) |item| allocator.free(item);
    for (values) |entry| {
        if (entry.value == 0) continue;
        items[count] = try units.formatAlloc(
            allocator,
            entry.value,
            entry.unit,
            locale_name,
            .{ .style = unit_style },
        );
        count += 1;
    }
    if (count == 0) {
        items[0] = try units.formatAlloc(
            allocator,
            0,
            .second,
            locale_name,
            .{ .style = unit_style },
        );
        count = 1;
    }
    const list_style: list.Style = switch (style) {
        .long => .unit,
        .short => .unit_short,
        .narrow => .unit_narrow,
        .numeric => .unit_short,
    };
    return list.formatAlloc(allocator, items[0..count], locale_name, .{
        .style = list_style,
    });
}

/// Format a duration in seconds with CLDR duration patterns.
pub fn formatDurationAlloc(
    allocator: std.mem.Allocator,
    seconds: f64,
    locale_name: []const u8,
    style: Style,
) ![]u8 {
    const negative = seconds < 0;
    const absolute = @abs(seconds);
    const total_seconds: u64 = if (absolute < 9.2e18)
        @intFromFloat(@floor(absolute + 0.5))
    else
        std.math.maxInt(u64);
    const locale = findLocale(locale_name) orelse return error.UnknownLocale;
    const body = if (style == .numeric) blk: {
        const pattern = if (total_seconds >= 3600)
            locale.patterns[1]
        else
            locale.patterns[2];
        break :blk try formatNumeric(allocator, total_seconds, locale_name, pattern);
    } else try formatUnits(allocator, total_seconds, locale_name, style);
    if (!negative) return body;
    defer allocator.free(body);
    const number_locale = misc.findLocale(number_data.locales, locale_name) orelse
        misc.findLocale(number_data.locales, "en").?;
    return std.mem.concat(allocator, u8, &.{ number_locale.minus, body });
}

test "duration formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const numeric = try formatDurationAlloc(allocator, 3661, "en", .numeric);
    defer allocator.free(numeric);
    try testing.expectEqualStrings("1:01:01", numeric);
    const numeric_short = try formatDurationAlloc(allocator, 61, "en", .numeric);
    defer allocator.free(numeric_short);
    try testing.expectEqualStrings("1:01", numeric_short);
    const numeric_padded = try formatDurationAlloc(allocator, 3661, "af", .numeric);
    defer allocator.free(numeric_padded);
    try testing.expectEqualStrings("01:01:01", numeric_padded);
    const numeric_minutes = try formatDurationAlloc(allocator, 5, "af", .numeric);
    defer allocator.free(numeric_minutes);
    try testing.expectEqualStrings("00:05", numeric_minutes);

    const long = try formatDurationAlloc(allocator, 3661, "en", .long);
    defer allocator.free(long);
    try testing.expectEqualStrings("1 hour, 1 minute, 1 second", long);
    const short = try formatDurationAlloc(allocator, 3661, "en", .short);
    defer allocator.free(short);
    try testing.expectEqualStrings("1 hr, 1 min, 1 sec", short);

    const french = try formatDurationAlloc(allocator, 3661, "fr", .long);
    defer allocator.free(french);
    try testing.expectEqualStrings("1\u{a0}heure, 1 minute, 1\u{a0}seconde", french);

    const russian = try formatDurationAlloc(allocator, 125, "ru", .long);
    defer allocator.free(russian);
    try testing.expectEqualStrings("2 минуты, 5 секунд", russian);

    const zero = try formatDurationAlloc(allocator, 0, "en", .long);
    defer allocator.free(zero);
    try testing.expectEqualStrings("0 seconds", zero);
    const zero_numeric = try formatDurationAlloc(allocator, 0, "en", .numeric);
    defer allocator.free(zero_numeric);
    try testing.expectEqualStrings("0:00", zero_numeric);
}

test "duration conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("duration_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJQK", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const locale_length = fixture[cursor];
        const width = fixture[cursor + 1];
        const seconds = @as(f64, @bitCast(std.mem.readInt(u64, fixture[cursor + 4 ..][0..8], .little)));
        const expected_length = std.mem.readInt(u16, fixture[cursor + 12 ..][0..2], .little);
        cursor += 16;
        const locale_name = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        const style: Style = if (width == 0) .long else .short;
        total += 1;
        const actual = formatDurationAlloc(allocator, seconds, locale_name, style) catch |err| {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print("duration mismatch {s} width {d}: {s}\n", .{ locale_name, width, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "duration mismatch {s} width {d}: got '{s}' expected '{s}'\n",
                    .{ locale_name, width, actual, expected },
                );
            }
        }
    }
    std.debug.print("duration conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}

test "multi-unit duration formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const long = try formatDurationUnitsAlloc(
        allocator,
        .{ .days = 1, .hours = 2, .minutes = 3 },
        "en",
        .long,
    );
    defer allocator.free(long);
    try testing.expectEqualStrings("1 day, 2 hours, 3 minutes", long);
    const short = try formatDurationUnitsAlloc(
        allocator,
        .{ .days = 1, .hours = 2, .minutes = 3 },
        "en",
        .short,
    );
    defer allocator.free(short);
    try testing.expectEqualStrings("1 day, 2 hr, 3 min", short);
    const de = try formatDurationUnitsAlloc(
        allocator,
        .{ .days = 1, .hours = 2, .minutes = 3 },
        "de",
        .long,
    );
    defer allocator.free(de);
    try testing.expectEqualStrings("1 Tag, 2 Stunden, 3 Minuten", de);
    const zero = try formatDurationUnitsAlloc(allocator, .{}, "en", .long);
    defer allocator.free(zero);
    try testing.expectEqualStrings("0 seconds", zero);

    const calendar = try formatDurationUnitsAlloc(
        allocator,
        .{ .years = 1, .months = 2, .days = 3 },
        "en",
        .long,
    );
    defer allocator.free(calendar);
    try testing.expectEqualStrings("1 year, 2 months, 3 days", calendar);
}
