//! CLDR RBNF (rule-based number format) engine.
//!
//! The tables are generated from the CLDR `common/rbnf/<locale>.xml` rule
//! sets by tools/unicode/format/generate_rbnf.py. Formatting recursively
//! substitutes numerators, denominators, and named rule sets following ICU's
//! RBNF semantics:
//!
//!   * a rule's optional section is used when the remainder is non-zero
//!     (`[before|after]` selects the second branch when it is zero);
//!   * a negative number without a negative rule keeps its sign for pattern
//!     and value substitutions while rules are selected by its magnitude;
//!   * `>>` in a decimal rule spells each fraction digit separated by a
//!     space, `>>>` spells them without spaces;
//!   * plural substitutions select on the rule's divisor;
//!   * rule sets referenced from a decimal rule are fraction rule sets that
//!     pick a denominator and format its numerator.

const std = @import("std");
const number_data = @import("numbers_data.zig");
const number_mod = @import("number.zig");
const plurals = @import("plurals.zig");
const misc = @import("misc.zig");

pub const cldr_version = "48";

pub const Error = error{
    InvalidPattern,
    MissingCurrency,
    OutOfMemory,
    UnknownLocale,
    Unsupported,
};

pub const Tag = enum {
    spellout,
    ordinal,
    duration,
    numbering_system,
};

const blob = @embedFile("rbnf_data.bin");

const header_len = 26;
const locale_count = readU16(8);
const ruleset_count = readU32(10);
const rule_count = readU32(14);
const token_count = readU32(18);
const string_len = readU32(22);

const locale_offset = header_len;
const refs_offset = locale_offset + @as(usize, locale_count) * 12;
const ruleset_offset = refs_offset + totalRefCount() * 10;
const rule_offset = ruleset_offset + @as(usize, ruleset_count) * 16;
const token_offset = rule_offset + @as(usize, rule_count) * 24;
const strings_offset = token_offset + @as(usize, token_count) * 8;

const rule_normal = 0;
const rule_negative = 1;
const rule_decimal = 2;
const rule_infinity = 3;
const rule_nan = 4;
const rule_proper = 5;

const token_literal = 0;
const token_numerator = 1;
const token_denominator = 2;
const token_digits = 3;
const token_hyphen_denominator = 4;
const token_numerator_set = 5;
const token_denominator_set = 6;
const token_value_set = 7;
const token_pattern = 8;
const token_optional_start = 9;
const token_optional_end = 10;
const token_plural = 11;
const token_numerator_pattern = 12;
const token_denominator_pattern = 13;
const token_optional_else = 14;
const token_hyphen_denominator_set = 15;
const token_hyphen_denominator_pattern = 16;

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn readU64(offset: usize) u64 {
    return std.mem.readInt(u64, blob[offset..][0..8], .little);
}

fn totalRefCount() usize {
    @setEvalBranchQuota(100_000);
    var total: usize = 0;
    for (0..locale_count) |index| {
        total += blob[locale_offset + index * 12 + 5];
    }
    return total;
}

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJRB") or
        blob[4] != 1)
    {
        @compileError("invalid RBNF data");
    }
    if (strings_offset + @as(usize, string_len) != blob.len) {
        @compileError("invalid RBNF data lengths");
    }
}

const LocaleRecord = struct {
    id: []const u8,
    ref_start: u32,
    ref_count: u8,
};

fn localeAt(index: usize) LocaleRecord {
    const base = locale_offset + index * 12;
    const id_offset = readU32(base);
    const id_len = blob[base + 4];
    return .{
        .id = stringAt(id_offset, id_len),
        .ref_start = readU32(base + 6),
        .ref_count = blob[base + 5],
    };
}

const RefRecord = struct {
    name: []const u8,
    ruleset: u32,
};

fn refAt(index: usize) RefRecord {
    const base = refs_offset + index * 10;
    const name_offset = readU32(base);
    const name_len = blob[base + 4];
    return .{
        .name = stringAt(name_offset, name_len),
        .ruleset = readU32(base + 5),
    };
}

const RuleSetRecord = struct {
    name: []const u8,
    first_rule: u32,
    rule_count: u16,
    fraction: bool,
};

fn ruleSetAt(index: usize) RuleSetRecord {
    const base = ruleset_offset + index * 16;
    const name_offset = readU32(base);
    const name_len = blob[base + 4];
    return .{
        .name = stringAt(name_offset, name_len),
        .rule_count = readU16(base + 6),
        .first_rule = readU32(base + 8),
        .fraction = (blob[base + 12] & 1) != 0,
    };
}

const RuleRecord = struct {
    base: u64,
    radix: u64,
    first_token: u32,
    token_count: u16,
    kind: u8,
};

fn ruleAt(index: usize) RuleRecord {
    const base = rule_offset + index * 24;
    return .{
        .base = readU64(base),
        .radix = readU64(base + 8),
        .first_token = readU32(base + 16),
        .token_count = readU16(base + 20),
        .kind = blob[base + 22],
    };
}

const TokenRecord = struct {
    kind: u8,
    len: u16,
    value: u32,
};

fn tokenAt(index: usize) TokenRecord {
    const base = token_offset + index * 8;
    return .{
        .kind = blob[base],
        .len = readU16(base + 2),
        .value = readU32(base + 4),
    };
}

fn stringAt(offset: u32, len: u16) []const u8 {
    return blob[strings_offset + @as(usize, offset) ..][0..len];
}

fn findLocale(name: []const u8) ?usize {
    if (lookupLocale(name)) |index| return index;
    var buffer: [64]u8 = undefined;
    var length: usize = 0;
    for (name) |byte| {
        if (length == buffer.len) break;
        buffer[length] = if (byte == '-') '_' else byte;
        length += 1;
    }
    if (lookupLocale(buffer[0..length])) |index| return index;
    if (std.mem.indexOfAny(u8, name, "-_")) |position| {
        if (lookupLocale(name[0..position])) |index| return index;
    }
    return lookupLocale("root") orelse lookupLocale("en");
}

fn lookupLocale(name: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = locale_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = localeAt(middle);
        switch (std.mem.order(u8, record.id, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn findRuleSet(locale_index: usize, name: []const u8) ?u32 {
    const locale = localeAt(locale_index);
    var low: usize = locale.ref_start;
    var high: usize = locale.ref_start + locale.ref_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = refAt(middle);
        switch (std.mem.order(u8, record.name, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return record.ruleset,
        }
    }
    return null;
}

fn tagRulesetName(tag: Tag) []const u8 {
    return switch (tag) {
        .spellout => "spellout-numbering",
        .ordinal => "digits-ordinal",
        .duration => "duration",
        .numbering_system => "digits-ordinal",
    };
}

fn tagFallbackName(tag: Tag) []const u8 {
    return switch (tag) {
        .spellout => "spellout-cardinal",
        .ordinal => "spellout-numbering",
        .duration => "spellout-numbering",
        .numbering_system => "digits-ordinal",
    };
}

/// Format `value` using the locale's RBNF rule set for `tag`.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale: []const u8,
    tag: Tag,
) Error![]u8 {
    if (tag == .numbering_system) {
        return number_mod.formatAlloc(allocator, value, locale, .{});
    }
    const locale_index = findLocale(locale) orelse return error.UnknownLocale;
    const ruleset = findRuleSet(locale_index, tagRulesetName(tag)) orelse
        findRuleSet(locale_index, tagFallbackName(tag)) orelse
        return error.UnknownLocale;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try formatValue(allocator, &output, locale_index, ruleset, ruleset, value, 0);
    return output.toOwnedSlice(allocator);
}

const Context = struct {
    /// Value being formatted by the rule, sign included.
    value: f64,
    /// Magnitude divided by the rule divisor (integer part for decimals).
    quotient: u64,
    /// Magnitude modulo the rule divisor.
    remainder: u64,
    /// Fraction digits of the magnitude for decimal rules.
    digits: []const u8,
    decimal: bool,
    negative: bool,
    /// Rule set of the outermost format call (used by fraction numerators).
    default_ruleset: u32,
    /// Fraction value when emitting a fraction rule set rule.
    fraction: ?f64,
    /// Whether an optional section is emitted (remainder non-zero for
    /// normal rules, integer part non-zero for decimal rules).
    optional: bool,
};

fn roundHalfUp(value: f64) f64 {
    return @floor(value + 0.5);
}

fn roundHalfEven(value: f64) f64 {
    const base = @floor(value);
    const diff = value - base;
    if (diff < 0.5) return base;
    if (diff > 0.5) return base + 1;
    return if (@mod(base, 2) == 0) base else base + 1;
}

fn decimalDigits(value: f64, buffer: *[64]u8) []const u8 {
    const text = std.fmt.bufPrint(buffer, "{d}", .{value}) catch return "";
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return "";
    return text[dot + 1 ..];
}

fn formatValue(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    default_ruleset: u32,
    ruleset: u32,
    value: f64,
    depth: u8,
) Error!void {
    if (depth > 40) return error.Unsupported;
    if (std.math.isNan(value)) {
        if (findSpecial(ruleset, rule_nan)) |rule| {
            return emitRule(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                rule,
                .{
                    .value = value,
                    .quotient = 0,
                    .remainder = 0,
                    .digits = "",
                    .decimal = false,
                    .negative = false,
                    .default_ruleset = default_ruleset,
                    .fraction = null,
                    .optional = false,
                },
                depth,
            );
        }
        return output.appendSlice(allocator, "NaN");
    }
    if (value < 0) {
        if (findSpecial(ruleset, rule_negative)) |rule| {
            return emitRule(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                rule,
                .{
                    .value = value,
                    .quotient = 0,
                    .remainder = 0,
                    .digits = "",
                    .decimal = false,
                    .negative = true,
                    .default_ruleset = default_ruleset,
                    .fraction = null,
                    .optional = false,
                },
                depth,
            );
        }
    }
    if (std.math.isInf(value)) {
        if (findSpecial(ruleset, rule_infinity)) |rule| {
            return emitRule(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                rule,
                .{
                    .value = value,
                    .quotient = 0,
                    .remainder = 0,
                    .digits = "",
                    .decimal = false,
                    .negative = false,
                    .default_ruleset = default_ruleset,
                    .fraction = null,
                    .optional = false,
                },
                depth,
            );
        }
        return output.appendSlice(allocator, "Infinity");
    }
    const magnitude = @abs(value);
    if (magnitude != @floor(magnitude)) {
        var digit_storage: [64]u8 = undefined;
        const digits = decimalDigits(magnitude, &digit_storage);
        const integer_part: u64 = if (@floor(magnitude) < 9.2e18)
            @intFromFloat(@floor(magnitude))
        else
            std.math.maxInt(u64);
        if (magnitude < 1) {
            if (findSpecial(ruleset, rule_proper)) |rule| {
                return emitRule(
                    allocator,
                    output,
                    locale_index,
                    default_ruleset,
                    ruleset,
                    rule,
                    .{
                        .value = value,
                        .quotient = integer_part,
                        .remainder = 0,
                        .digits = digits,
                        .decimal = true,
                        .negative = false,
                        .default_ruleset = default_ruleset,
                        .fraction = null,
                        .optional = true,
                    },
                    depth,
                );
            }
        }
        if (findSpecial(ruleset, rule_decimal)) |rule| {
            return emitRule(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                rule,
                .{
                    .value = value,
                    .quotient = integer_part,
                    .remainder = 0,
                    .digits = digits,
                    .decimal = true,
                    .negative = false,
                    .default_ruleset = default_ruleset,
                    .fraction = null,
                    .optional = integer_part != 0,
                },
                depth,
            );
        }
        // No explicit fraction rule: ICU rounds half-up for rule selection
        // while substitutions still receive the original value.
        const rounded = roundHalfUp(magnitude);
        const integer: u64 = if (rounded < 9.2e18)
            @intFromFloat(rounded)
        else
            std.math.maxInt(u64);
        const rule = findRule(ruleset, integer) orelse return error.Unsupported;
        var quotient: u64 = 0;
        var remainder: u64 = 0;
        if (rule.base != 0) {
            const radix = @max(rule.radix, 1);
            quotient = integer / radix;
            remainder = integer % radix;
        } else {
            quotient = integer;
        }
        return emitRule(
            allocator,
            output,
            locale_index,
            default_ruleset,
            ruleset,
            rule,
            .{
                .value = value,
                .quotient = quotient,
                .remainder = remainder,
                .digits = "",
                .decimal = false,
                .negative = false,
                .default_ruleset = default_ruleset,
                .fraction = null,
                .optional = remainder != 0,
            },
            depth,
        );
    }
    const integer: u64 = if (magnitude < 9.2e18)
        @intFromFloat(magnitude)
    else
        std.math.maxInt(u64);
    const rule = findRule(ruleset, integer) orelse return error.Unsupported;
    var quotient: u64 = 0;
    var remainder: u64 = 0;
    if (rule.base != 0) {
        const radix = @max(rule.radix, 1);
        quotient = integer / radix;
        remainder = integer % radix;
    } else {
        quotient = integer;
    }
    try emitRule(
        allocator,
        output,
        locale_index,
        default_ruleset,
        ruleset,
        rule,
        .{
            .value = value,
            .quotient = quotient,
            .remainder = remainder,
            .digits = "",
            .decimal = false,
            .negative = false,
            .default_ruleset = default_ruleset,
            .fraction = null,
            .optional = remainder != 0,
        },
        depth,
    );
}

fn findSpecial(ruleset: u32, kind: u8) ?RuleRecord {
    const set = ruleSetAt(ruleset);
    var index: usize = 0;
    while (index < set.rule_count) : (index += 1) {
        const rule = ruleAt(set.first_rule + index);
        if (rule.kind == rule_normal) break;
        if (rule.kind == kind) return rule;
    }
    return null;
}

fn findRule(ruleset: u32, value: u64) ?RuleRecord {
    const set = ruleSetAt(ruleset);
    var best: ?RuleRecord = null;
    var index: usize = 0;
    while (index < set.rule_count) : (index += 1) {
        const rule = ruleAt(set.first_rule + index);
        if (rule.kind != rule_normal) continue;
        if (rule.base > value) break;
        best = rule;
    }
    return best;
}

fn ruleDivisor(rule: RuleRecord) u64 {
    if (rule.base == 0) return 1;
    return @max(rule.radix, 1);
}

fn emitRule(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    default_ruleset: u32,
    ruleset: u32,
    rule: RuleRecord,
    context: Context,
    depth: u8,
) Error!void {
    // Optional section state: 0 = outside, 1 = emit first branch,
    // 2 = skip first branch, 3 = emit second branch, 4 = skip second branch.
    var optional_state: u8 = 0;
    var index: usize = 0;
    while (index < rule.token_count) : (index += 1) {
        const token = tokenAt(rule.first_token + index);
        switch (token.kind) {
            token_optional_start => {
                if (optional_state == 0) {
                    optional_state = if (context.optional) 1 else 2;
                }
                continue;
            },
            token_optional_else => {
                if (optional_state == 1) {
                    optional_state = 4;
                } else if (optional_state == 2) {
                    optional_state = 3;
                }
                continue;
            },
            token_optional_end => {
                optional_state = 0;
                continue;
            },
            else => {},
        }
        if (optional_state == 2 or optional_state == 4) continue;
        switch (token.kind) {
            token_literal => try output.appendSlice(
                allocator,
                stringAt(token.value, token.len),
            ),
            token_numerator => {
                if (context.fraction) |fraction| {
                    const denominator: f64 = @floatFromInt(rule.base);
                    try formatValue(
                        allocator,
                        output,
                        locale_index,
                        default_ruleset,
                        context.default_ruleset,
                        roundHalfUp(fraction * denominator),
                        depth + 1,
                    );
                } else {
                    try formatValue(
                        allocator,
                        output,
                        locale_index,
                        default_ruleset,
                        ruleset,
                        @floatFromInt(context.quotient),
                        depth + 1,
                    );
                }
            },
            token_denominator => try emitDenominator(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                context,
                true,
                depth,
            ),
            token_digits => try emitDenominator(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                context,
                false,
                depth,
            ),
            token_hyphen_denominator => {
                try output.append(allocator, '-');
                try emitDenominator(
                    allocator,
                    output,
                    locale_index,
                    default_ruleset,
                    ruleset,
                    context,
                    true,
                    depth,
                );
            },
            token_hyphen_denominator_set => {
                try output.append(allocator, '-');
                try emitDenominatorSet(
                    allocator,
                    output,
                    locale_index,
                    default_ruleset,
                    ruleset,
                    stringAt(token.value, token.len),
                    context,
                    depth,
                );
            },
            token_hyphen_denominator_pattern => {
                try output.append(allocator, '-');
                try emitDenominatorPattern(
                    allocator,
                    output,
                    locale_index,
                    stringAt(token.value, token.len),
                    context,
                );
            },
            token_numerator_set => {
                const name = stringAt(token.value, token.len);
                const target = findRuleSet(locale_index, name) orelse continue;
                const numerator = if (context.fraction) |fraction|
                    roundHalfUp(fraction * @as(f64, @floatFromInt(rule.base)))
                else
                    @as(f64, @floatFromInt(context.quotient));
                try formatValue(
                    allocator,
                    output,
                    locale_index,
                    default_ruleset,
                    target,
                    numerator,
                    depth + 1,
                );
            },
            token_denominator_set => try emitDenominatorSet(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                stringAt(token.value, token.len),
                context,
                depth,
            ),
            token_value_set => {
                const name = stringAt(token.value, token.len);
                const target = findRuleSet(locale_index, name) orelse continue;
                try formatValue(
                    allocator,
                    output,
                    locale_index,
                    default_ruleset,
                    target,
                    context.value,
                    depth + 1,
                );
            },
            token_pattern => try formatPattern(
                allocator,
                output,
                stringAt(token.value, token.len),
                context.value,
                locale_index,
            ),
            token_numerator_pattern => try formatPattern(
                allocator,
                output,
                stringAt(token.value, token.len),
                @floatFromInt(context.quotient),
                locale_index,
            ),
            token_denominator_pattern => try emitDenominatorPattern(
                allocator,
                output,
                locale_index,
                stringAt(token.value, token.len),
                context,
            ),
            token_plural => try emitPlural(
                allocator,
                output,
                stringAt(token.value, token.len),
                context.value,
                ruleDivisor(rule),
                locale_index,
            ),
            else => {},
        }
    }
}

fn emitDenominator(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    default_ruleset: u32,
    ruleset: u32,
    context: Context,
    spaces: bool,
    depth: u8,
) Error!void {
    if (context.negative) {
        return formatValue(
            allocator,
            output,
            locale_index,
            default_ruleset,
            ruleset,
            @abs(context.value),
            depth + 1,
        );
    }
    if (context.decimal) {
        return emitFractionDigits(
            allocator,
            output,
            locale_index,
            default_ruleset,
            ruleset,
            context.digits,
            spaces,
            depth,
        );
    }
    try formatValue(
        allocator,
        output,
        locale_index,
        default_ruleset,
        ruleset,
        @floatFromInt(context.remainder),
        depth + 1,
    );
}

fn emitDenominatorSet(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    default_ruleset: u32,
    ruleset: u32,
    name: []const u8,
    context: Context,
    depth: u8,
) Error!void {
    const target = findRuleSet(locale_index, name) orelse return;
    if (context.negative) {
        return formatValue(
            allocator,
            output,
            locale_index,
            default_ruleset,
            target,
            @abs(context.value),
            depth + 1,
        );
    }
    if (context.decimal) {
        const fraction = @abs(context.value) - @floor(@abs(context.value));
        if (target == ruleset) {
            return emitFractionDigits(
                allocator,
                output,
                locale_index,
                default_ruleset,
                ruleset,
                context.digits,
                true,
                depth,
            );
        }
        if (ruleSetAt(target).fraction) {
            return emitFractionRule(
                allocator,
                output,
                locale_index,
                default_ruleset,
                target,
                fraction,
                depth,
            );
        }
        return formatValue(
            allocator,
            output,
            locale_index,
            default_ruleset,
            target,
            fraction,
            depth + 1,
        );
    }
    try formatValue(
        allocator,
        output,
        locale_index,
        default_ruleset,
        target,
        @floatFromInt(context.remainder),
        depth + 1,
    );
}

fn emitDenominatorPattern(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    pattern: []const u8,
    context: Context,
) Error!void {
    const value = if (context.negative)
        @abs(context.value)
    else if (context.decimal)
        @abs(context.value) - @floor(@abs(context.value))
    else
        @as(f64, @floatFromInt(context.remainder));
    try formatPattern(allocator, output, pattern, value, locale_index);
}

fn emitFractionDigits(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    default_ruleset: u32,
    ruleset: u32,
    digits: []const u8,
    spaces: bool,
    depth: u8,
) Error!void {
    var first = true;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') continue;
        if (!first and spaces) try output.append(allocator, ' ');
        first = false;
        try formatValue(
            allocator,
            output,
            locale_index,
            default_ruleset,
            ruleset,
            @floatFromInt(digit - '0'),
            depth + 1,
        );
    }
    if (first) {
        try formatValue(
            allocator,
            output,
            locale_index,
            default_ruleset,
            ruleset,
            0,
            depth + 1,
        );
    }
}

fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const temp = x % y;
        x = y;
        y = temp;
    }
    return x;
}

fn lcm(a: u64, b: u64) u64 {
    if (a == 0 or b == 0) return 0;
    const divisor = gcd(a, b);
    return std.math.mul(u64, a / divisor, b) catch std.math.maxInt(u64);
}

fn emitFractionRule(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    locale_index: usize,
    default_ruleset: u32,
    target: u32,
    fraction: f64,
    depth: u8,
) Error!void {
    const set = ruleSetAt(target);
    var multiple: u64 = 0;
    var index: usize = 0;
    while (index < set.rule_count) : (index += 1) {
        const rule = ruleAt(set.first_rule + index);
        if (rule.kind != rule_normal or rule.base == 0) continue;
        multiple = if (multiple == 0) rule.base else lcm(multiple, rule.base);
    }
    if (multiple == 0) return;
    const scaled = fraction * @as(f64, @floatFromInt(multiple));
    const numerator: u64 = if (scaled < 9.2e18)
        @intFromFloat(roundHalfUp(scaled))
    else
        std.math.maxInt(u64);

    var winner_rule: usize = 0;
    var winner_base: u64 = 0;
    var found = false;
    var difference: u64 = std.math.maxInt(u64);
    index = 0;
    while (index < set.rule_count) : (index += 1) {
        const rule = ruleAt(set.first_rule + index);
        if (rule.kind != rule_normal or rule.base == 0) continue;
        var temp: u64 = @intCast(
            (@as(u128, numerator) * rule.base) % multiple,
        );
        if (multiple - temp < temp) temp = multiple - temp;
        if (temp < difference) {
            difference = temp;
            winner_rule = set.first_rule + index;
            winner_base = rule.base;
            found = true;
            if (difference == 0) break;
        }
    }
    if (!found) return;
    // Two successive rules with the same denominator: the second one is used
    // unless the fraction is close to one part or more than two parts.
    var next_index = winner_rule + 1;
    while (next_index < set.first_rule + set.rule_count) : (next_index += 1) {
        const candidate = ruleAt(next_index);
        if (candidate.kind != rule_normal) continue;
        if (candidate.base == winner_base) {
            const parts = @as(f64, @floatFromInt(winner_base)) * fraction;
            if (parts < 0.5 or parts >= 2) winner_rule = next_index;
        }
        break;
    }
    const rule = ruleAt(winner_rule);
    try emitRule(
        allocator,
        output,
        locale_index,
        default_ruleset,
        target,
        rule,
        .{
            .value = fraction,
            .quotient = 0,
            .remainder = 0,
            .digits = "",
            .decimal = false,
            .negative = false,
            .default_ruleset = default_ruleset,
            .fraction = fraction,
            .optional = false,
        },
        depth,
    );
}

fn numberLocale(locale_index: usize) number_data.Locale {
    const id = localeAt(locale_index).id;
    return misc.findLocale(number_data.locales, id) orelse
        misc.findLocale(number_data.locales, "en").?;
}

fn countPatternDigits(pattern: []const u8) usize {
    var count: usize = 0;
    for (pattern) |character| {
        if (character == '#' or character == '0') count += 1;
    }
    return count;
}

fn formatPattern(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    pattern: []const u8,
    value: f64,
    locale_index: usize,
) Error!void {
    const locale = numberLocale(locale_index);
    const dot = std.mem.indexOfScalar(u8, pattern, '.');
    const integer_pattern = if (dot) |position| pattern[0..position] else pattern;
    const fraction_pattern = if (dot) |position| pattern[position + 1 ..] else "";
    const commas = std.mem.count(u8, integer_pattern, ",");
    var primary: usize = 0;
    var secondary: usize = 0;
    if (commas > 0) {
        const last_comma = std.mem.lastIndexOfScalar(u8, integer_pattern, ',').?;
        primary = countPatternDigits(integer_pattern[last_comma + 1 ..]);
        secondary = primary;
        if (commas >= 2) {
            const previous = std.mem.lastIndexOfScalar(
                u8,
                integer_pattern[0..last_comma],
                ',',
            ).?;
            secondary = countPatternDigits(integer_pattern[previous + 1 .. last_comma]);
        }
        if (primary == 0) primary = 3;
        if (secondary == 0) secondary = primary;
    }
    var minimum_integer: usize = 0;
    for (integer_pattern) |character| {
        if (character == '0') minimum_integer += 1;
    }
    var required_fraction: usize = 0;
    var optional_fraction: usize = 0;
    for (fraction_pattern) |character| {
        if (character == '0') {
            required_fraction += 1;
        } else if (character == '#') {
            optional_fraction += 1;
        }
    }
    const total_fraction = required_fraction + optional_fraction;

    var number = value;
    const negative = number < 0;
    number = @abs(number);
    if (!std.math.isFinite(number)) return error.Unsupported;

    var scale: f64 = 1;
    for (0..total_fraction) |_| scale *= 10;
    const rounded = roundHalfEven(number * scale);
    const integer_part = @floor(rounded / scale);
    var fraction_value: u64 = 0;
    if (total_fraction > 0) {
        const remainder = rounded - integer_part * scale;
        if (remainder >= 0 and remainder < 1.9e19) {
            fraction_value = @intFromFloat(remainder);
        }
    }
    if (negative) try output.appendSlice(allocator, locale.minus);

    var integer_buffer: [32]u8 = undefined;
    const integer_value: u64 = if (integer_part < 9.2e18)
        @intFromFloat(integer_part)
    else
        std.math.maxInt(u64);
    const integer_text = std.fmt.bufPrint(&integer_buffer, "{d}", .{integer_value}) catch
        return error.Unsupported;
    const padding = if (integer_text.len < minimum_integer)
        minimum_integer - integer_text.len
    else
        0;
    const total_integer = integer_text.len + padding;
    var position: usize = 0;
    while (position < total_integer) : (position += 1) {
        const remaining = total_integer - position;
        if (commas > 0 and position > 0 and remaining > 0 and
            (remaining == primary or
                (remaining > primary and (remaining - primary) % secondary == 0)))
        {
            try output.appendSlice(allocator, locale.group);
        }
        const digit: u8 = if (position < padding)
            '0'
        else
            integer_text[position - padding];
        try appendDigit(allocator, output, digit - '0', locale);
    }

    if (total_fraction == 0) return;
    if (fraction_value == 0 and required_fraction == 0) return;
    try output.appendSlice(allocator, locale.decimal);
    var fraction_buffer: [24]u8 = undefined;
    const fraction_text = std.fmt.bufPrint(&fraction_buffer, "{d}", .{fraction_value}) catch "";
    var digit_buffer: [24]u8 = undefined;
    const padding_zeros = if (fraction_text.len < total_fraction)
        total_fraction - fraction_text.len
    else
        0;
    var length: usize = 0;
    while (length < padding_zeros) : (length += 1) digit_buffer[length] = '0';
    for (fraction_text) |character| {
        if (length == digit_buffer.len) break;
        digit_buffer[length] = character;
        length += 1;
    }
    var count = length;
    while (count > required_fraction and digit_buffer[count - 1] == '0') count -= 1;
    for (digit_buffer[0..count]) |digit| {
        try appendDigit(allocator, output, digit - '0', locale);
    }
}

fn categoryName(category: plurals.Category) []const u8 {
    return switch (category) {
        .zero => "zero",
        .one => "one",
        .two => "two",
        .few => "few",
        .many => "many",
        .other => "other",
    };
}

fn emitPlural(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    payload: []const u8,
    value: f64,
    divisor: u64,
    locale_index: usize,
) Error!void {
    if (payload.len == 0) return;
    const ordinal = payload[0] == 'o';
    const locale_id = localeAt(locale_index).id;
    const divisor_value: f64 = @floatFromInt(@max(divisor, 1));
    var plural_value: i64 = 0;
    if (value >= 0 and value < 1) {
        const scaled = roundHalfUp(value * divisor_value);
        plural_value = if (scaled < 9.2e18) @intFromFloat(scaled) else 0;
    } else {
        const divided = @trunc(value / divisor_value);
        plural_value = if (@abs(divided) < 9.2e18) @intFromFloat(divided) else 0;
    }
    const category = if (ordinal)
        plurals.ordinalCategoryForInteger(locale_id, plural_value)
    else
        misc.pluralCategory(locale_id, @floatFromInt(plural_value));
    var other: []const u8 = "";
    var rest = payload[1..];
    if (rest.len > 0 and rest[0] == 0x1f) rest = rest[1..];
    var parts = std.mem.splitScalar(u8, rest, 0x1f);
    while (parts.next()) |key| {
        const text = parts.next() orelse break;
        if (std.mem.eql(u8, key, "other")) other = text;
        if (std.mem.eql(u8, key, categoryName(category))) {
            return output.appendSlice(allocator, text);
        }
    }
    if (other.len != 0) try output.appendSlice(allocator, other);
}

fn appendDigit(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    digit: u8,
    locale: number_data.Locale,
) Error!void {
    const codepoint = locale.digits[@as(usize, @min(digit, 9))];
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
    try output.appendSlice(allocator, buffer[0..length]);
}

test "RBNF conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("rbnf_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJRN", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var offset: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const locale_len = fixture[offset];
        const tag_id = fixture[offset + 1];
        const expected_len = std.mem.readInt(u16, fixture[offset + 2 ..][0..2], .little);
        const bits = std.mem.readInt(u64, fixture[offset + 4 ..][0..8], .little);
        offset += 12;
        const locale = fixture[offset .. offset + locale_len];
        offset += locale_len;
        const expected = fixture[offset .. offset + expected_len];
        offset += expected_len;
        const value: f64 = @bitCast(bits);
        const tag: Tag = if (tag_id == 0) .spellout else .ordinal;
        total += 1;
        const result = formatAlloc(allocator, value, locale, tag) catch |err| {
            failures += 1;
            if (printed < 100) {
                printed += 1;
                std.debug.print("RBNF mismatch {s} tag={d} value={d}: error {s} expected '{s}'\n", .{ locale, tag_id, value, @errorName(err), expected });
            }
            continue;
        };
        defer allocator.free(result);
        if (!std.mem.eql(u8, result, expected)) {
            failures += 1;
            if (printed < 100) {
                printed += 1;
                std.debug.print("RBNF mismatch {s} tag={d} value={d}: got '{s}' expected '{s}'\n", .{ locale, tag_id, value, result, expected });
            }
        }
    }
    std.debug.print("RBNF conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}

test "RBNF spellout and ordinal" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        value: f64,
        locale: []const u8,
        tag: Tag,
        expected: []const u8,
    }{
        .{ .value = 0, .locale = "en", .tag = .spellout, .expected = "zero" },
        .{ .value = 21, .locale = "en", .tag = .spellout, .expected = "twenty-one" },
        .{ .value = 123, .locale = "en", .tag = .spellout, .expected = "one hundred twenty-three" },
        .{ .value = 1001, .locale = "en", .tag = .spellout, .expected = "one thousand one" },
        .{ .value = -5, .locale = "en", .tag = .spellout, .expected = "minus five" },
        .{ .value = 1.5, .locale = "en", .tag = .spellout, .expected = "one point five" },
        .{ .value = 3, .locale = "en", .tag = .ordinal, .expected = "3rd" },
        .{ .value = 3, .locale = "en", .tag = .numbering_system, .expected = "3" },
    };
    for (cases) |case| {
        const result = try formatAlloc(allocator, case.value, case.locale, case.tag);
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }
}
