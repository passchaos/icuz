//! ICU `uloc` metadata helpers: character/line orientation and ISO alpha-3
//! language/country codes.

const std = @import("std");
const locale_mod = @import("../locale.zig");
const iso3 = @import("iso3_data.zig");

pub const Orientation = enum(u8) {
    ltr = 0,
    rtl = 1,
    ttb = 2,
    btt = 3,
};

pub fn characterOrientation(locale: []const u8) Orientation {
    const parsed = locale_mod.Locale.parse(locale) catch return .ltr;
    return if (parsed.isRightToLeft()) .rtl else .ltr;
}

/// Horizontal text lays out in top-to-bottom lines, matching ICU's default.
pub fn lineOrientation(locale: []const u8) Orientation {
    _ = locale;
    return .ttb;
}

pub fn iso3Language(locale: []const u8) []const u8 {
    const parsed = locale_mod.Locale.parse(locale) catch return "";
    var buffer: [16]u8 = undefined;
    if (parsed.language.len == 0 or parsed.language.len > buffer.len) return "";
    for (parsed.language, 0..) |byte, index| {
        buffer[index] = std.ascii.toLower(byte);
    }
    const language = buffer[0..parsed.language.len];
    if (std.mem.eql(u8, language, "und") or
        std.mem.eql(u8, language, "root"))
    {
        return "";
    }
    return lookup(&iso3.languages, language);
}

pub fn iso3Country(locale: []const u8) []const u8 {
    const parsed = locale_mod.Locale.parse(locale) catch return "";
    var buffer: [16]u8 = undefined;
    if (parsed.region.len == 0 or parsed.region.len > buffer.len) return "";
    for (parsed.region, 0..) |byte, index| {
        buffer[index] = std.ascii.toUpper(byte);
    }
    return lookup(&iso3.countries, buffer[0..parsed.region.len]);
}

fn lookup(table: []const iso3.Entry, code: []const u8) []const u8 {
    var low: usize = 0;
    var high = table.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const order = std.mem.order(u8, table[middle].code, code);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return table[middle].alpha3,
        }
    }
    return "";
}

test "locale metadata orientation and ISO3 codes" {
    const testing = std.testing;
    try testing.expectEqual(Orientation.ltr, characterOrientation("en"));
    try testing.expectEqual(Orientation.rtl, characterOrientation("ar"));
    try testing.expectEqual(Orientation.rtl, characterOrientation("pa-PK"));
    try testing.expectEqual(Orientation.ltr, characterOrientation("zh-Hant"));
    try testing.expectEqual(Orientation.ttb, lineOrientation("en"));

    try testing.expectEqualStrings("eng", iso3Language("en"));
    try testing.expectEqualStrings("ara", iso3Language("ar"));
    try testing.expectEqualStrings("srp", iso3Language("sr-Latn"));
    try testing.expectEqualStrings("", iso3Language("zz"));

    try testing.expectEqualStrings("USA", iso3Country("en-US"));
    try testing.expectEqualStrings("GBR", iso3Country("en-GB"));
    try testing.expectEqualStrings("", iso3Country("en"));
    try testing.expectEqualStrings("", iso3Country("zz-ZZ"));
}

const Fixture = struct {
    data: []const u8,
    index: usize = 0,

    fn readU8(self: *Fixture) !u8 {
        if (self.index >= self.data.len) return error.Truncated;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    fn readU16(self: *Fixture) !u16 {
        if (self.index + 2 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u16, self.data[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn string(self: *Fixture) ![]const u8 {
        const length = try self.readU16();
        if (self.index + length > self.data.len) return error.Truncated;
        const value = self.data[self.index..][0..length];
        self.index += length;
        return value;
    }
};

test "locale metadata ICU conformance fixture" {
    const fixture_data = @embedFile("metadata_conformance.bin");
    try std.testing.expectEqualSlices(u8, "CJL4", fixture_data[0..4]);
    var fixture = Fixture{ .data = fixture_data, .index = 8 };
    const case_count = std.mem.readInt(u32, fixture.data[fixture.index..][0..4], .little);
    fixture.index += 4;

    var passed: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const locale = try fixture.string();
        const expected_character: Orientation = @enumFromInt(try fixture.readU8());
        const expected_line: Orientation = @enumFromInt(try fixture.readU8());
        const expected_language = try fixture.string();
        const expected_country = try fixture.string();

        try std.testing.expectEqual(expected_character, characterOrientation(locale));
        try std.testing.expectEqual(expected_line, lineOrientation(locale));
        try std.testing.expectEqualStrings(expected_language, iso3Language(locale));
        try std.testing.expectEqualStrings(expected_country, iso3Country(locale));
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), fixture_data.len - fixture.index);
    std.debug.print("locale metadata conformance: {}/{} passed\n", .{ passed, case_count });
}
