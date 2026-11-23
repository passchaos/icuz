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
    return categoryIn(
        data.rules[0..],
        &compiled_cardinal,
        locale,
        operands,
    );
}

/// Return the ordinal plural category for one set of CLDR operands.
pub fn ordinalCategory(locale: []const u8, operands: Operands) Category {
    return categoryIn(
        ordinal_data.rules[0..],
        &compiled_ordinal,
        locale,
        operands,
    );
}

fn categoryIn(
    rules: anytype,
    set: anytype,
    locale: []const u8,
    operands: Operands,
) Category {
    const index = findRuleIndex(rules, locale) orelse return .other;
    const categories = [_]Category{ .zero, .one, .two, .few, .many };
    for (categories, 0..) |candidate, category_index| {
        const expr_index = index * 5 + category_index;
        if (set.exprs[expr_index].group_count != 0 and
            evaluateCompiled(set, expr_index, operands))
        {
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

const rule_cache_len = 8;
const rule_cache_name_len = 24;

const RuleCacheEntry = struct {
    rules_ptr: usize = 0,
    locale: [rule_cache_name_len]u8 = [_]u8{0} ** rule_cache_name_len,
    len: u8 = 0,
    found: bool = false,
    index: usize = 0,
};

/// Plural formatting repeats the same locale, so the fallback chain of
/// binary searches runs once per thread and rule set.
threadlocal var rule_cache: [rule_cache_len]RuleCacheEntry =
    [_]RuleCacheEntry{.{}} ** rule_cache_len;

fn findRuleIndex(rules: anytype, locale: []const u8) ?usize {
    const rules_ptr = @intFromPtr(rules.ptr);
    if (locale.len <= rule_cache_name_len) {
        var hash: usize = rules_ptr ^ locale.len;
        for (locale) |byte| hash = hash *% 31 +% byte;
        const slot = &rule_cache[hash & (rule_cache_len - 1)];
        if (slot.rules_ptr == rules_ptr and slot.len == locale.len and
            std.mem.eql(u8, slot.locale[0..slot.len], locale))
        {
            return if (slot.found) slot.index else null;
        }
        const result = findRuleIndexUncached(rules, locale);
        slot.rules_ptr = rules_ptr;
        slot.len = @intCast(locale.len);
        @memcpy(slot.locale[0..locale.len], locale);
        slot.found = result != null;
        if (result) |index| slot.index = index;
        return result;
    }
    return findRuleIndexUncached(rules, locale);
}

fn findRuleIndexUncached(rules: anytype, locale: []const u8) ?usize {
    if (lookupIndex(rules, locale)) |index| return index;

    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    for (locale) |byte| {
        if (len == buffer.len) break;
        buffer[len] = if (byte == '-') '_' else byte;
        len += 1;
    }
    const normalized = buffer[0..len];
    if (lookupIndex(rules, normalized)) |index| return index;

    if (std.mem.indexOfAny(u8, locale, "-_")) |position| {
        if (lookupIndex(rules, locale[0..position])) |index| return index;
    }
    return lookupIndex(rules, "root");
}

fn lookupIndex(rules: anytype, locale: []const u8) ?usize {
    var low: usize = 0;
    var high = rules.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, rules[mid].locale, locale)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return mid,
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

const CompiledOperand = enum(u3) { n, i, v, w, f, t, e };

const CompiledRange = struct {
    first: u32,
    last: u32,
};

const CompiledRelation = struct {
    operand: CompiledOperand,
    modulus: u32,
    negate: bool,
    range_start: u16,
    range_count: u8,
};

const CompiledGroup = struct {
    relation_start: u16,
    relation_count: u8,
};

const CompiledExpr = struct {
    group_start: u16,
    group_count: u8,
};

fn CompiledSet(comptime count: usize) type {
    return struct {
        exprs: [count]CompiledExpr,
        groups: [count]CompiledGroup,
        relations: [count]CompiledRelation,
        ranges: [count]CompiledRange,
    };
}

/// Compile-time parser for one CLDR plural expression.
const Compiler = struct {
    text: []const u8,
    index: usize = 0,
    ranges: []CompiledRange,
    range_len: usize = 0,

    fn skipSpaces(self: *Compiler) void {
        while (self.index < self.text.len and
            (self.text[self.index] == ' ' or self.text[self.index] == '\t'))
        {
            self.index += 1;
        }
    }

    fn consume(self: *Compiler, token: []const u8) bool {
        if (std.mem.startsWith(u8, self.text[self.index..], token)) {
            self.index += token.len;
            return true;
        }
        return false;
    }

    fn consumeWord(self: *Compiler, word: []const u8) bool {
        self.skipSpaces();
        if (!std.mem.startsWith(u8, self.text[self.index..], word)) return false;
        const end = self.index + word.len;
        if (end < self.text.len and self.text[end] != ' ' and
            self.text[end] != '\t')
        {
            return false;
        }
        self.index = end;
        return true;
    }

    fn parseInteger(self: *Compiler) ?u64 {
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

    fn parseRelation(self: *Compiler) ?CompiledRelation {
        self.skipSpaces();
        if (self.index >= self.text.len) return null;
        const name = self.text[self.index];
        self.index += 1;
        const operand: CompiledOperand = switch (name) {
            'n' => .n,
            'i' => .i,
            'v' => .v,
            'w' => .w,
            'f' => .f,
            't' => .t,
            'e', 'c' => .e,
            else => return null,
        };
        self.skipSpaces();
        var modulus: u32 = 0;
        if (self.consume("%")) {
            self.skipSpaces();
            const value = self.parseInteger() orelse return null;
            if (value == 0) return null;
            modulus = @intCast(value);
        }
        self.skipSpaces();
        const negate = self.consume("!=");
        if (!negate and !self.consume("=")) return null;
        const range_start = self.range_len;
        var count: usize = 0;
        while (true) {
            self.skipSpaces();
            const first = self.parseInteger() orelse break;
            var last = first;
            self.skipSpaces();
            if (self.consume("..")) {
                self.skipSpaces();
                last = self.parseInteger() orelse break;
            }
            if (self.range_len == self.ranges.len) return null;
            self.ranges[self.range_len] = .{
                .first = @intCast(first),
                .last = @intCast(last),
            };
            self.range_len += 1;
            count += 1;
            self.skipSpaces();
            if (!self.consume(",")) break;
        }
        if (count == 0) return null;
        return .{
            .operand = operand,
            .modulus = modulus,
            .negate = negate,
            .range_start = @intCast(range_start),
            .range_count = @intCast(count),
        };
    }
};

fn compileSet(comptime rules: anytype) CompiledSet(rules.len * 5) {
    @setEvalBranchQuota(50_000_000);
    const expr_count = rules.len * 5;
    const pool_count = expr_count;
    var exprs: [expr_count]CompiledExpr = undefined;
    var groups: [pool_count]CompiledGroup = undefined;
    var relations: [pool_count]CompiledRelation = undefined;
    var ranges: [pool_count]CompiledRange = undefined;
    var group_len: usize = 0;
    var relation_len: usize = 0;
    var range_len: usize = 0;

    for (rules, 0..) |rule, rule_index| {
        const texts = [5][]const u8{
            rule.zero,
            rule.one,
            rule.two,
            rule.few,
            rule.many,
        };
        for (texts, 0..) |text, category_index| {
            const expr_index = rule_index * 5 + category_index;
            if (text.len == 0) {
                exprs[expr_index] = .{ .group_start = 0, .group_count = 0 };
                continue;
            }
            var compiler = Compiler{
                .text = text,
                .ranges = &ranges,
                .range_len = range_len,
            };
            const group_start = group_len;
            while (true) {
                const relation_start = relation_len;
                while (true) {
                    const relation = compiler.parseRelation() orelse
                        @compileError("unsupported plural rule: " ++ text);
                    if (relation_len == pool_count) {
                        @compileError("plural relation pool overflow");
                    }
                    relations[relation_len] = relation;
                    relation_len += 1;
                    if (!compiler.consumeWord("and")) break;
                }
                if (group_len == pool_count) {
                    @compileError("plural group pool overflow");
                }
                groups[group_len] = .{
                    .relation_start = @intCast(relation_start),
                    .relation_count = @intCast(relation_len - relation_start),
                };
                group_len += 1;
                if (!compiler.consumeWord("or")) break;
            }
            range_len = compiler.range_len;
            exprs[expr_index] = .{
                .group_start = @intCast(group_start),
                .group_count = @intCast(group_len - group_start),
            };
        }
    }
    return .{
        .exprs = exprs,
        .groups = groups,
        .relations = relations,
        .ranges = ranges,
    };
}

fn evaluateCompiled(
    set: anytype,
    expr_index: usize,
    operands: Operands,
) bool {
    const expr = set.exprs[expr_index];
    var group_index: usize = 0;
    while (group_index < expr.group_count) : (group_index += 1) {
        const group = set.groups[@as(usize, expr.group_start) + group_index];
        var all = true;
        var relation_index: usize = 0;
        while (relation_index < group.relation_count) : (relation_index += 1) {
            const relation = set.relations[
                @as(usize, group.relation_start) + relation_index
            ];
            var value: f64 = switch (relation.operand) {
                .n => operands.n,
                .i => @floatFromInt(operands.i),
                .v => @floatFromInt(operands.v),
                .w => @floatFromInt(operands.w),
                .f => @floatFromInt(operands.f),
                .t => @floatFromInt(operands.t),
                .e => @floatFromInt(operands.e),
            };
            if (relation.modulus != 0) {
                value = @mod(value, @as(f64, @floatFromInt(relation.modulus)));
            }
            var matched = false;
            if (value == @floor(value)) {
                var range_index: usize = 0;
                while (range_index < relation.range_count) : (range_index += 1) {
                    const range = set.ranges[
                        @as(usize, relation.range_start) + range_index
                    ];
                    if (value >= @as(f64, @floatFromInt(range.first)) and
                        value <= @as(f64, @floatFromInt(range.last)))
                    {
                        matched = true;
                        break;
                    }
                }
            }
            if (relation.negate) matched = !matched;
            if (!matched) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

const compiled_cardinal = compileSet(data.rules[0..]);
const compiled_ordinal = compileSet(ordinal_data.rules[0..]);

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

test "compiled plural rules match the parser" {
    const testing = @import("std").testing;
    inline for (.{
        .{ data.rules[0..], &compiled_cardinal },
        .{ ordinal_data.rules[0..], &compiled_ordinal },
    }) |entry| {
        const rules = entry[0];
        const set = entry[1];
        var integer: u32 = 0;
        while (integer <= 120) : (integer += 1) {
            const n: f64 = @floatFromInt(integer);
            const variants = [_]Operands{
                .{ .n = n, .i = integer, .v = 0, .w = 0, .f = 0, .t = 0, .e = 0 },
                .{ .n = n, .i = integer, .v = 1, .w = 1, .f = integer, .t = integer, .e = 0 },
                .{ .n = n, .i = integer, .v = 0, .w = 0, .f = 0, .t = 0, .e = 1 },
            };
            for (rules, 0..) |rule, rule_index| {
                const texts = [5][]const u8{
                    rule.zero,
                    rule.one,
                    rule.two,
                    rule.few,
                    rule.many,
                };
                for (texts, 0..) |text, category_index| {
                    if (text.len == 0) continue;
                    for (variants) |operands| {
                        try testing.expectEqual(
                            evaluate(text, operands),
                            evaluateCompiled(
                                set,
                                rule_index * 5 + category_index,
                                operands,
                            ),
                        );
                    }
                }
            }
        }
        var fractional: u32 = 1;
        while (fractional <= 20) : (fractional += 1) {
            const n = @as(f64, @floatFromInt(fractional)) + 0.5;
            const operands = Operands{
                .n = n,
                .i = fractional,
                .v = 1,
                .w = 1,
                .f = 5,
                .t = 5,
                .e = 0,
            };
            for (rules, 0..) |rule, rule_index| {
                const texts = [5][]const u8{
                    rule.zero,
                    rule.one,
                    rule.two,
                    rule.few,
                    rule.many,
                };
                for (texts, 0..) |text, category_index| {
                    if (text.len == 0) continue;
                    try testing.expectEqual(
                        evaluate(text, operands),
                        evaluateCompiled(
                            set,
                            rule_index * 5 + category_index,
                            operands,
                        ),
                    );
                }
            }
        }
    }
}

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
