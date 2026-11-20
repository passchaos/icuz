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

pub const Style = enum { long, short, narrow };

pub const Options = struct {
    numeric: Numeric = .auto,
    style: Style = .long,
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
    const unit_index = @intFromEnum(unit);
    // Relative-type text ("yesterday") always comes from the long field, as
    // in ICU's RelativeDateTimeFormatter; only the numeric patterns follow
    // the requested width.
    const text_field = locale_data.fields[unit_index];
    const field = switch (options.style) {
        .long => locale_data.fields[unit_index],
        .short => locale_data.short_fields[unit_index] orelse
            locale_data.fields[unit_index],
        .narrow => locale_data.narrow_fields[unit_index] orelse
            locale_data.short_fields[unit_index] orelse
            locale_data.fields[unit_index],
    };

    if (options.numeric == .auto and isSmallInteger(value)) {
        const integer: i64 = @intFromFloat(value);
        if (integer == -1 and text_field.past_relative.len != 0) {
            return allocator.dupe(u8, text_field.past_relative);
        }
        if (integer == 0 and text_field.now_relative.len != 0) {
            return allocator.dupe(u8, text_field.now_relative);
        }
        if (integer == 1 and text_field.future_relative.len != 0) {
            return allocator.dupe(u8, text_field.future_relative);
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

test "relative time covers additional locales" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        value: f64,
        unit: Unit,
        locale: []const u8,
        expected: []const u8,
    }{
        .{ .value = 3, .unit = .day, .locale = "de", .expected = "in 3 Tagen" },
        .{ .value = -5, .unit = .day, .locale = "de", .expected = "vor 5 Tagen" },
        .{ .value = -1, .unit = .day, .locale = "de", .expected = "gestern" },
        .{ .value = 3, .unit = .day, .locale = "es", .expected = "dentro de 3 d\u{00ED}as" },
        .{ .value = -5, .unit = .day, .locale = "es", .expected = "hace 5 d\u{00ED}as" },
        .{ .value = 3, .unit = .day, .locale = "pl", .expected = "za 3 dni" },
        .{ .value = -5, .unit = .day, .locale = "pl", .expected = "5 dni temu" },
        .{ .value = 3, .unit = .day, .locale = "tr", .expected = "3 g\u{00FC}n sonra" },
        .{ .value = -5, .unit = .day, .locale = "tr", .expected = "5 g\u{00FC}n \u{00F6}nce" },
        .{ .value = 3, .unit = .day, .locale = "ko", .expected = "3\u{C77C} \u{D6C4}" },
        .{ .value = -5, .unit = .day, .locale = "ko", .expected = "5\u{C77C} \u{C804}" },
        .{ .value = 3, .unit = .day, .locale = "it", .expected = "tra 3 giorni" },
        .{ .value = 3, .unit = .day, .locale = "nl", .expected = "over 3 dagen" },
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
}


test "relative time styles" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const french_short = try formatAlloc(
        allocator,
        2,
        .day,
        "fr",
        .{ .numeric = .always, .style = .short },
    );
    defer allocator.free(french_short);
    try testing.expectEqualStrings("dans 2\u{00a0}j", french_short);

    const french_long = try formatAlloc(
        allocator,
        2,
        .day,
        "fr",
        .{ .numeric = .always, .style = .long },
    );
    defer allocator.free(french_long);
    try testing.expectEqualStrings("dans 2 jours", french_long);

    const french_narrow = try formatAlloc(
        allocator,
        2,
        .day,
        "fr",
        .{ .numeric = .always, .style = .narrow },
    );
    defer allocator.free(french_narrow);
    try testing.expectEqualStrings("+2 j", french_narrow);

    // Relative-type text stays long regardless of the requested width.
    const french_yesterday = try formatAlloc(
        allocator,
        -1,
        .day,
        "fr",
        .{ .style = .narrow },
    );
    defer allocator.free(french_yesterday);
    try testing.expectEqualStrings("hier", french_yesterday);

    const english_narrow = try formatAlloc(
        allocator,
        2,
        .day,
        "en",
        .{ .numeric = .always, .style = .narrow },
    );
    defer allocator.free(english_narrow);
    try testing.expectEqualStrings("in 2d", english_narrow);

    // German has no explicit short field; it falls back to the long one.
    const german_short = try formatAlloc(
        allocator,
        2,
        .day,
        "de",
        .{ .numeric = .always, .style = .short },
    );
    defer allocator.free(german_short);
    try testing.expectEqualStrings("in 2 Tagen", german_short);
}
