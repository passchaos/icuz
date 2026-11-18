//! CLDR 48 unit formatting.

const std = @import("std");
const data = @import("units_data.zig");
const misc = @import("misc.zig");
const number = @import("number.zig");
const plural = @import("plurals.zig");

pub const Unit = enum {
    meter,
    kilometer,
    centimeter,
    millimeter,
    mile,
    yard,
    foot,
    inch,
    kilogram,
    gram,
    milligram,
    pound,
    ounce,
    celsius,
    fahrenheit,
    kelvin,
    kilometer_per_hour,
    mile_per_hour,
    meter_per_second,
    square_meter,
    square_kilometer,
    hectare,
    acre,
    square_foot,
    liter,
    milliliter,
    gallon,
    quart,
    pint,
    cup,
    second,
    minute,
    hour,
    day,
    week,
    month,
    year,
    bit,
    byte,
    kilobyte,
    megabyte,
    gigabyte,
    terabyte,
    joule,
    kilojoule,
    calorie,
    kilocalorie,
    watt,
    kilowatt,
    horsepower,
    hectopascal,
    millibar,
    atmosphere,
    hertz,
    kilohertz,
    megahertz,
    degree,
    radian,
    percent,
    permille,
};

pub const Style = enum { long, short };

pub const Options = struct {
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
    const entry = locale_data.units[@intFromEnum(unit)];
    const formatted = try number.formatAlloc(allocator, value, locale, .{});
    defer allocator.free(formatted);

    const category = misc.pluralCategory(locale, value);
    const patterns = switch (options.style) {
        .long => entry.long,
        .short => entry.short,
    };
    var pattern = patterns[@intFromEnum(category)];
    if (pattern.len == 0) pattern = patterns[@intFromEnum(plural.Category.other)];
    return misc.replacePlaceholderAlloc(allocator, pattern, formatted);
}

test "unit formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        value: f64,
        unit: Unit,
        locale: []const u8,
        style: Style,
        expected: []const u8,
    }{
        .{ .value = 1, .unit = .meter, .locale = "en", .style = .long, .expected = "1 meter" },
        .{ .value = 5, .unit = .meter, .locale = "en", .style = .long, .expected = "5 meters" },
        .{ .value = 3.5, .unit = .kilogram, .locale = "en", .style = .long, .expected = "3.5 kilograms" },
        .{ .value = 2, .unit = .hour, .locale = "en", .style = .long, .expected = "2 hours" },
        .{ .value = 0, .unit = .celsius, .locale = "en", .style = .long, .expected = "0 degrees Celsius" },
        .{ .value = 50, .unit = .percent, .locale = "en", .style = .long, .expected = "50 percent" },
        .{ .value = 5, .unit = .meter, .locale = "en", .style = .short, .expected = "5 m" },
        .{ .value = -3, .unit = .celsius, .locale = "en", .style = .short, .expected = "-3°C" },
        .{ .value = 2, .unit = .hour, .locale = "ru", .style = .long, .expected = "2 часа" },
        .{ .value = 5, .unit = .hour, .locale = "ru", .style = .long, .expected = "5 часов" },
        .{ .value = 1, .unit = .hour, .locale = "ru", .style = .long, .expected = "1 час" },
        .{ .value = 2, .unit = .hour, .locale = "fr", .style = .long, .expected = "2\u{00A0}heures" },
        .{ .value = 5, .unit = .meter, .locale = "zh", .style = .long, .expected = "5米" },
        .{ .value = 2, .unit = .hour, .locale = "zh", .style = .long, .expected = "2小时" },
        .{ .value = 5, .unit = .meter, .locale = "en-GB", .style = .long, .expected = "5 meters" },
        .{ .value = 5, .unit = .meter, .locale = "zz", .style = .long, .expected = "5 meters" },
    };

    for (cases) |case| {
        const result = try formatAlloc(
            allocator,
            case.value,
            case.unit,
            case.locale,
            .{ .style = case.style },
        );
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }
}
