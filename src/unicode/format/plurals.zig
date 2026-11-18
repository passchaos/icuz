//! CLDR 48 cardinal and ordinal plural rules.
//!
//! Rules are stored as the CLDR expression strings and evaluated with a small
//! recursive-descent parser. The conformance fixtures contain the CLDR sample
//! values for every locale/category.

const std = @import("std");
const data = @import("plurals_data.zig");
const ordinal_data = @import("ordinals_data.zig");

pub const cldr_version = "48";

pub const Category = enum(u3) {
    zero,
    one,
    two,
    few,
    many,
    other,
};

pub const Operands = struct {
    n: f64,
    i: u64,
    v: u32,
    w: u32,
    f: u64,
    t: u64,
    e: u32,
};

/// Return the cardinal plural category for one set of CLDR operands.
pub fn category(locale: []const u8, operands: Operands) Category {
    return categoryIn(data.rules[0..], locale, operands);
}

/// Return the ordinal plural category for one set of CLDR operands.
pub fn ordinalCategory(locale: []const u8, operands: Operands) Category {
    return categoryIn(ordinal_data.rules[0..], locale, operands);
}

fn categoryIn(rules: anytype, locale: []const u8, operands: Operands) Category {
    const rule = findRuleIn(rules, locale) orelse return .other;
    const categories = [_]Category{ .zero, .one, .two, .few, .many };
    for (categories) |candidate| {
        const expression = expressionFor(rule, candidate);
        if (expression.len != 0 and evaluate(expression, operands)) {
            return candidate;
        }
    }
    return .other;
}

/// Return the cardinal plural category for an integer value.
pub fn categoryForInteger(locale: []const u8, value: i64) Category {
    return category(locale, integerOperands(value));
}

/// Return the ordinal plural category for an integer value.
pub fn ordinalCategoryForInteger(locale: []const u8, value: i64) Category {
    return ordinalCategory(locale, integerOperands(value));
}

/// Return the cardinal plural category for a decimal string such as `1.00`.
pub fn categoryForDecimalString(
    locale: []const u8,
    text: []const u8,
) error{InvalidNumber}!Category {
    return category(locale, try parseDecimal(text));
}

/// Return the ordinal plural category for a decimal string such as `1.0`.
pub fn ordinalCategoryForDecimalString(
    locale: []const u8,
    text: []const u8,
) error{InvalidNumber}!Category {
    return ordinalCategory(locale, try parseDecimal(text));
}

fn integerOperands(value: i64) Operands {
    const magnitude: u64 = @abs(value);
    return .{
        .n = @floatFromInt(magnitude),
        .i = magnitude,
        .v = 0,
        .w = 0,
        .f = 0,
        .t = 0,
        .e = 0,
    };
}

fn expressionFor(rule: anytype, category_value: Category) []const u8 {
    return switch (category_value) {
        .zero => rule.zero,
        .one => rule.one,
        .two => rule.two,
        .few => rule.few,
        .many => rule.many,
        .other => "",
    };
}

fn findRuleIn(rules: anytype, locale: []const u8) ?@TypeOf(rules[0]) {
    if (lookupIn(rules, locale)) |rule| return rule;

    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    for (locale) |byte| {
        if (len == buffer.len) break;
        buffer[len] = if (byte == '-') '_' else byte;
        len += 1;
    }
    const normalized = buffer[0..len];
    if (lookupIn(rules, normalized)) |rule| return rule;

    if (std.mem.indexOfAny(u8, locale, "-_")) |position| {
        if (lookupIn(rules, locale[0..position])) |rule| return rule;
    }
    return lookupIn(rules, "root");
}

fn lookupIn(rules: anytype, locale: []const u8) ?@TypeOf(rules[0]) {
    var low: usize = 0;
    var high = rules.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const rule = rules[mid];
        switch (std.mem.order(u8, rule.locale, locale)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return rule,
        }
    }
    return null;
}

fn parseDecimal(text: []const u8) error{InvalidNumber}!Operands {
    var index: usize = 0;
    if (index < text.len and (text[index] == '-' or text[index] == '+')) {
        index += 1;
    }

    var integer_part: u64 = 0;
    var has_digit = false;
    while (index < text.len and text[index] >= '0' and text[index] <= '9') {
        integer_part = integer_part * 10 + (text[index] - '0');
        index += 1;
        has_digit = true;
    }

    var fraction_value: u64 = 0;
    var visible_digits: u32 = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and text[index] >= '0' and text[index] <= '9') {
            fraction_value = fraction_value * 10 + (text[index] - '0');
            visible_digits += 1;
            index += 1;
            has_digit = true;
        }
    }
    if (index != text.len or !has_digit) return error.InvalidNumber;

    var trimmed_value = fraction_value;
    var trimmed_digits = visible_digits;
    while (trimmed_digits > 0 and trimmed_value % 10 == 0) {
        trimmed_value /= 10;
        trimmed_digits -= 1;
    }

    const scale = std.math.pow(f64, 10.0, @floatFromInt(visible_digits));
    const magnitude = @as(f64, @floatFromInt(integer_part)) +
        @as(f64, @floatFromInt(fraction_value)) / scale;

    return .{
        .n = magnitude,
        .i = integer_part,
        .v = visible_digits,
        .w = trimmed_digits,
        .f = fraction_value,
        .t = trimmed_value,
        .e = 0,
    };
}

fn evaluate(expression: []const u8, operands: Operands) bool {
    var parser = Parser{
        .text = expression,
        .index = 0,
        .operands = operands,
    };
    return parser.parseOr();
}

const Parser = struct {
    text: []const u8,
    index: usize,
    operands: Operands,

    fn parseOr(self: *Parser) bool {
        var result = self.parseAnd();
        while (self.consumeWord("or")) {
            const right = self.parseAnd();
            result = result or right;
        }
        return result;
    }

    fn parseAnd(self: *Parser) bool {
        var result = self.parseRelation();
        while (self.consumeWord("and")) {
            const right = self.parseRelation();
            result = result and right;
        }
        return result;
    }

    fn parseRelation(self: *Parser) bool {
        const operand = self.parseOperand() orelse return false;
        self.skipSpaces();
        const negate = self.consume("!=");
        if (!negate and !self.consume("=")) return false;
        const matched = self.parseRangeList(operand);
        return if (negate) !matched else matched;
    }

    const Operand = struct {
        value: f64,
    };

    fn parseOperand(self: *Parser) ?Operand {
        self.skipSpaces();
        if (self.index >= self.text.len) return null;
        const name = self.text[self.index];
        self.index += 1;

        var value: f64 = switch (name) {
            'n' => self.operands.n,
            'i' => @floatFromInt(self.operands.i),
            'v' => @floatFromInt(self.operands.v),
            'w' => @floatFromInt(self.operands.w),
            'f' => @floatFromInt(self.operands.f),
            't' => @floatFromInt(self.operands.t),
            'e', 'c' => @floatFromInt(self.operands.e),
            else => return null,
        };

        self.skipSpaces();
        if (self.consume("%")) {
            self.skipSpaces();
            const modulus = self.parseInteger() orelse return null;
            if (modulus == 0) return null;
            value = @mod(value, @as(f64, @floatFromInt(modulus)));
        }
        return .{ .value = value };
    }

    fn parseRangeList(self: *Parser, operand: Operand) bool {
        var matched = false;
        while (true) {
            self.skipSpaces();
            const first = self.parseInteger() orelse return matched;
            var last = first;
            self.skipSpaces();
            if (self.consume("..")) {
                self.skipSpaces();
                last = self.parseInteger() orelse return matched;
            }

            const value = operand.value;
            if (value == @floor(value) and
                value >= @as(f64, @floatFromInt(first)) and
                value <= @as(f64, @floatFromInt(last)))
            {
                matched = true;
            }

            self.skipSpaces();
            if (!self.consume(",")) return matched;
        }
    }

    fn parseInteger(self: *Parser) ?u64 {
        self.skipSpaces();
        var value: u64 = 0;
        var digits: usize = 0;
        while (self.index < self.text.len and
            self.text[self.index] >= '0' and self.text[self.index] <= '9')
        {
            value = value * 10 + (self.text[self.index] - '0');
            self.index += 1;
            digits += 1;
        }
        return if (digits == 0) null else value;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.index < self.text.len and
            (self.text[self.index] == ' ' or self.text[self.index] == '\t'))
        {
            self.index += 1;
        }
    }

    fn consume(self: *Parser, token: []const u8) bool {
        if (std.mem.startsWith(u8, self.text[self.index..], token)) {
            self.index += token.len;
            return true;
        }
        return false;
    }

    fn consumeWord(self: *Parser, word: []const u8) bool {
        self.skipSpaces();
        if (!std.mem.startsWith(u8, self.text[self.index..], word)) return false;
        const end = self.index + word.len;
        if (end < self.text.len and
            self.text[end] != ' ' and self.text[end] != '\t') return false;
        self.index = end;
        return true;
    }
};

test "cardinal plural categories" {
    const testing = @import("std").testing;

    try testing.expectEqual(Category.one, categoryForInteger("en", 1));
    try testing.expectEqual(Category.other, categoryForInteger("en", 2));
    try testing.expectEqual(Category.one, categoryForInteger("ru", 1));
    try testing.expectEqual(Category.few, categoryForInteger("ru", 2));
    try testing.expectEqual(Category.many, categoryForInteger("ru", 5));
    try testing.expectEqual(Category.many, categoryForInteger("ru", 11));
    try testing.expectEqual(Category.one, categoryForInteger("ru", 21));
    try testing.expectEqual(Category.zero, categoryForInteger("ar", 0));
    try testing.expectEqual(Category.two, categoryForInteger("ar", 2));
    try testing.expectEqual(Category.few, categoryForInteger("ar", 3));
    try testing.expectEqual(Category.many, categoryForInteger("ar", 11));
    try testing.expectEqual(Category.other, categoryForInteger("ar", 100));
    try testing.expectEqual(Category.other, categoryForInteger("ja", 5));
    try testing.expectEqual(
        Category.other,
        try categoryForDecimalString("en", "1.0"),
    );
    try testing.expectEqual(
        Category.one,
        try categoryForDecimalString("fr", "1.5"),
    );
    try testing.expectEqual(
        Category.other,
        try categoryForDecimalString("ru", "1.5"),
    );
}

test "ordinal plural categories" {
    const testing = @import("std").testing;

    try testing.expectEqual(Category.one, ordinalCategoryForInteger("en", 1));
    try testing.expectEqual(Category.two, ordinalCategoryForInteger("en", 2));
    try testing.expectEqual(Category.few, ordinalCategoryForInteger("en", 3));
    try testing.expectEqual(Category.other, ordinalCategoryForInteger("en", 4));
    try testing.expectEqual(Category.other, ordinalCategoryForInteger("en", 11));
    try testing.expectEqual(Category.other, ordinalCategoryForInteger("en", 12));
    try testing.expectEqual(Category.other, ordinalCategoryForInteger("en", 13));
    try testing.expectEqual(Category.one, ordinalCategoryForInteger("en", 21));
    try testing.expectEqual(Category.two, ordinalCategoryForInteger("en", 22));
    try testing.expectEqual(Category.few, ordinalCategoryForInteger("en", 103));
    try testing.expectEqual(Category.one, ordinalCategoryForInteger("fr", 1));
    try testing.expectEqual(Category.other, ordinalCategoryForInteger("fr", 2));
    try testing.expectEqual(Category.other, ordinalCategoryForInteger("ja", 1));
    try testing.expectEqual(
        Category.one,
        try ordinalCategoryForDecimalString("en", "1.0"),
    );
    try testing.expectEqual(
        Category.two,
        try ordinalCategoryForDecimalString("en", "2.0"),
    );
}

const conformance = @embedFile("plurals_conformance.bin");
const ordinal_conformance = @embedFile("ordinals_conformance.bin");

test "CLDR 48 plural conformance" {
    try checkConformance(conformance, false);
}

test "CLDR 48 ordinal conformance" {
    try checkConformance(ordinal_conformance, true);
}

fn checkConformance(fixture: []const u8, comptime ordinal: bool) !void {
    if (fixture.len < 12 or
        !std.mem.eql(u8, fixture[0..4], "CJPL") or
        fixture[4] != 1 or fixture[5] != 48 or
        fixture[6] != 0 or fixture[7] != 0)
    {
        return error.InvalidFixture;
    }

    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var offset: usize = 12;
    for (0..case_count) |case_index| {
        if (offset + 5 > fixture.len) return error.InvalidFixture;
        const locale_len = fixture[offset];
        const expected = fixture[offset + 1];
        const kind = fixture[offset + 2];
        const text_len = std.mem.readInt(
            u16,
            fixture[offset + 3 ..][0..2],
            .little,
        );
        offset += 5;
        if (offset + locale_len + text_len > fixture.len) {
            return error.InvalidFixture;
        }
        const locale = fixture[offset..][0..locale_len];
        offset += locale_len;
        const text = fixture[offset..][0..text_len];
        offset += text_len;

        const actual = if (kind == 0)
            if (ordinal)
                ordinalCategoryForInteger(
                    locale,
                    std.fmt.parseInt(i64, text, 10) catch
                        return error.InvalidFixture,
                )
            else
                categoryForInteger(
                    locale,
                    std.fmt.parseInt(i64, text, 10) catch
                        return error.InvalidFixture,
                )
        else if (ordinal)
            ordinalCategoryForDecimalString(locale, text) catch
                return error.InvalidFixture
        else
            categoryForDecimalString(locale, text) catch
                return error.InvalidFixture;

        if (@intFromEnum(actual) != expected) {
            std.debug.print(
                "plural conformance case {d}: {s} {s} expected {d}, got {d}\n",
                .{ case_index, locale, text, expected, @intFromEnum(actual) },
            );
            return error.TestUnexpectedResult;
        }
    }
    if (offset != fixture.len) return error.InvalidFixture;
}
