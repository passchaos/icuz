//! CLDR 48 relative-time formatting.

const std = @import("std");
const data = @import("relative_data.zig");
const misc = @import("misc.zig");
const number = @import("number.zig");
const plural = @import("plurals.zig");

pub const Unit = enum { year, month, week, day, hour, minute, second };

pub const Numeric = enum {
    /// Use "yesterday"/"today"/"tomorrow" style text for -1/0/1.
    auto,
    /// Always use a numeric pattern such as "in 1 day" or "1 day ago".
    always,
};

pub const Options = struct {
    numeric: Numeric = .auto,
};

pub const Error = error{ OutOfMemory, InvalidPattern, MissingCurrency };

pub fn formatAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    unit: Unit,
    locale: []const u8,
    options: Options,
) Error![]u8 {
    const locale_data = misc.findLocale(data.locales, locale) orelse
        misc.findLocale(data.locales, "en").?;
    const field = locale_data.fields[@intFromEnum(unit)];

    if (options.numeric == .auto and isSmallInteger(value)) {
        const integer: i64 = @intFromFloat(value);
        if (integer == -1 and field.past_relative.len != 0) {
            return allocator.dupe(u8, field.past_relative);
        }
        if (integer == 0 and field.now_relative.len != 0) {
            return allocator.dupe(u8, field.now_relative);
        }
        if (integer == 1 and field.future_relative.len != 0) {
            return allocator.dupe(u8, field.future_relative);
        }
    }

    const magnitude = @abs(value);
    const formatted = try number.formatAlloc(
        allocator,
        magnitude,
        locale,
        .{},
    );
    defer allocator.free(formatted);

    const category = misc.pluralCategory(locale, magnitude);
    const patterns = if (value >= 0) field.future else field.past;
    var pattern = patterns[@intFromEnum(category)];
    if (pattern.len == 0) pattern = patterns[@intFromEnum(plural.Category.other)];
    return misc.replacePlaceholderAlloc(allocator, pattern, formatted);
}

fn isSmallInteger(value: f64) bool {
    return value == @floor(value) and value >= -1 and value <= 1;
}

test "relative time formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        value: f64,
        unit: Unit,
        locale: []const u8,
        expected: []const u8,
    }{
        .{ .value = -1, .unit = .day, .locale = "en", .expected = "yesterday" },
        .{ .value = 0, .unit = .day, .locale = "en", .expected = "today" },
        .{ .value = 1, .unit = .day, .locale = "en", .expected = "tomorrow" },
        .{ .value = 3, .unit = .day, .locale = "en", .expected = "in 3 days" },
        .{ .value = -5, .unit = .day, .locale = "en", .expected = "5 days ago" },
        .{ .value = -1, .unit = .hour, .locale = "en", .expected = "1 hour ago" },
        .{ .value = 2, .unit = .month, .locale = "en", .expected = "in 2 months" },
        .{ .value = 1.5, .unit = .hour, .locale = "en", .expected = "in 1.5 hours" },
        .{ .value = -2, .unit = .day, .locale = "ru", .expected = "2 дня назад" },
        .{ .value = -5, .unit = .day, .locale = "ru", .expected = "5 дней назад" },
        .{ .value = -1, .unit = .day, .locale = "ru", .expected = "вчера" },
        .{ .value = -3, .unit = .day, .locale = "zh", .expected = "3天前" },
        .{ .value = 3, .unit = .day, .locale = "zh", .expected = "3天后" },
    };

    for (cases) |case| {
        const result = try formatAlloc(
            allocator,
            case.value,
            case.unit,
            case.locale,
            .{},
        );
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }

    const numeric = try formatAlloc(
        allocator,
        -1,
        .day,
        "en",
        .{ .numeric = .always },
    );
    defer allocator.free(numeric);
    try testing.expectEqualStrings("1 day ago", numeric);

    const russian_numeric = try formatAlloc(
        allocator,
        -1,
        .day,
        "ru",
        .{ .numeric = .always },
    );
    defer allocator.free(russian_numeric);
    try testing.expectEqualStrings("1 день назад", russian_numeric);

    const fallback = try formatAlloc(
        allocator,
        3,
        .day,
        "en-GB",
        .{},
    );
    defer allocator.free(fallback);
    try testing.expectEqualStrings("in 3 days", fallback);
}
