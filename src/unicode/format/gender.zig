//! CLDR list-gender rules, mirroring ICU's `GenderInfo`.
//!
//! `listGender` classifies a list of people by the locale's rule: neutral
//! locales always return other, mixed-neutral locales preserve a uniform
//! male or female list, and male-tainting locales return female only when
//! every entry is female.

const std = @import("std");

const data = @import("gender_data.zig");

pub const Gender = enum { male, female, other };
pub const Rule = data.Rule;

fn normalizeLocale(locale: []const u8, buffer: *[64]u8) []const u8 {
    const length = @min(locale.len, buffer.len);
    for (locale[0..length], 0..) |byte, index| {
        buffer[index] = if (byte == '-') '_' else byte;
    }
    return buffer[0..length];
}

fn findRule(id: []const u8) ?Rule {
    var low: usize = 0;
    var high = data.locales.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.locales[middle];
        switch (std.mem.order(u8, entry.id, id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return entry.rule,
        }
    }
    return null;
}

fn ruleFor(locale: []const u8) Rule {
    var buffer: [64]u8 = undefined;
    const id = normalizeLocale(locale, &buffer);
    if (findRule(id)) |rule| return rule;
    if (std.mem.indexOfScalar(u8, id, '_')) |position| {
        if (findRule(id[0..position])) |rule| return rule;
    }
    return .neutral;
}

/// Gender of a list of people under the locale's CLDR rule.
pub fn listGender(locale: []const u8, genders: []const Gender) Gender {
    if (genders.len == 0) return .other;
    return switch (ruleFor(locale)) {
        .neutral => .other,
        .mixed_neutral => blk: {
            var all_male = true;
            var all_female = true;
            for (genders) |gender| {
                if (gender != .male) all_male = false;
                if (gender != .female) all_female = false;
            }
            if (all_male) break :blk .male;
            if (all_female) break :blk .female;
            break :blk .other;
        },
        .male_taints => blk: {
            for (genders) |gender| {
                if (gender != .female) break :blk .male;
            }
            break :blk .female;
        },
    };
}

test "CLDR list gender rules" {
    const testing = @import("std").testing;

    try testing.expectEqual(
        Gender.other,
        listGender("en", &.{ .male, .female }),
    );
    try testing.expectEqual(
        Gender.other,
        listGender("en", &.{ .male, .male }),
    );
    try testing.expectEqual(
        Gender.male,
        listGender("el", &.{ .male, .male }),
    );
    try testing.expectEqual(
        Gender.female,
        listGender("el", &.{ .female, .female }),
    );
    try testing.expectEqual(
        Gender.other,
        listGender("el", &.{ .male, .female }),
    );
    try testing.expectEqual(
        Gender.female,
        listGender("ar", &.{ .female, .female }),
    );
    try testing.expectEqual(
        Gender.male,
        listGender("ar", &.{ .female, .male }),
    );
    try testing.expectEqual(
        Gender.male,
        listGender("ar", &.{ .other }),
    );
    try testing.expectEqual(Gender.other, listGender("ar", &.{}));
    try testing.expectEqual(
        Gender.other,
        listGender("zz", &.{ .male, .male }),
    );
}
