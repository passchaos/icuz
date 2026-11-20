//! CLDR plural range selection: the plural category for a range whose start
//! and end have their own categories, used by range formatting.

const std = @import("std");

const plural = @import("plurals.zig");
const data = @import("plural_ranges_data.zig");

/// Result category for a range from `start` to `end`.
///
/// Unknown locales fall back to the language subtag and then to `other`.
pub fn select(
    locale: []const u8,
    start: plural.Category,
    end: plural.Category,
) plural.Category {
    var buffer: [64]u8 = undefined;
    const normalized = normalize(locale, &buffer);
    if (lookup(normalized)) |record| {
        return categoryAt(record, start, end);
    }
    const language = languageOf(normalized);
    if (language.len != normalized.len) {
        if (lookup(language)) |record| return categoryAt(record, start, end);
    }
    return .other;
}

fn categoryAt(
    record: data.Locale,
    start: plural.Category,
    end: plural.Category,
) plural.Category {
    const index = @as(usize, @intFromEnum(start)) * 6 + @intFromEnum(end);
    return @enumFromInt(record.results[index]);
}

fn lookup(locale: []const u8) ?data.Locale {
    var low: usize = 0;
    var high: usize = data.locales.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, data.locales[middle].id, locale)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return data.locales[middle],
        }
    }
    return null;
}

fn normalize(locale: []const u8, buffer: *[64]u8) []const u8 {
    const end = std.mem.indexOfAny(u8, locale, "@") orelse locale.len;
    var length: usize = 0;
    for (locale[0..end]) |byte| {
        if (length == buffer.len) break;
        if (byte == '-' and length + 1 < end and locale[length + 1] == 'u') {
            break;
        }
        buffer[length] = if (byte == '-') '_' else byte;
        length += 1;
    }
    return buffer[0..length];
}

fn languageOf(locale: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, locale, "_") orelse locale.len;
    return locale[0..end];
}

test "plural ranges match CLDR" {
    const testing = @import("std").testing;

    try testing.expectEqual(
        plural.Category.other,
        select("en", .one, .other),
    );
    try testing.expectEqual(plural.Category.one, select("de", .other, .one));
    try testing.expectEqual(plural.Category.other, select("de", .one, .other));
    try testing.expectEqual(plural.Category.few, select("ru", .one, .few));
    try testing.expectEqual(plural.Category.one, select("ru", .few, .one));
    try testing.expectEqual(plural.Category.many, select("ru", .many, .many));
    try testing.expectEqual(plural.Category.other, select("ru", .one, .other));
    try testing.expectEqual(plural.Category.one, select("ka", .one, .other));
    try testing.expectEqual(plural.Category.other, select("ja", .other, .other));
    try testing.expectEqual(plural.Category.other, select("zz", .one, .one));
    // Region and extension fall back to the language.
    try testing.expectEqual(plural.Category.one, select("de-AT", .other, .one));
    try testing.expectEqual(
        plural.Category.one,
        select("de-AT-u-nu-latn", .other, .one),
    );
}
