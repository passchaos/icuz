//! ICU `DecimalFormat` pattern support.
//!
//! Patterns use ICU's decimal syntax: `#`/`0` digit placeholders, `.` and `,`
//! for decimal and grouping, `%`/`‰` multipliers, `¤` currency symbols,
//! quoted literals, and an optional `positive;negative` pair.

const std = @import("std");
const number = @import("number.zig");

pub const Error = error{
    InvalidPattern,
    MissingCurrency,
    OutOfMemory,
};

const Subpattern = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

const PatternSplit = struct {
    positive: []const u8,
    negative: ?[]const u8,
};

const Match = struct {
    value: f64,
    end: usize,
};

pub const DecimalFormat = struct {
    allocator: std.mem.Allocator,
    pattern: []u8 = &.{},
    positive: Subpattern = .{},
    negative: ?Subpattern = null,
    integer_min: u8 = 1,
    has_currency: bool = false,
    has_permille: bool = false,
    multiplier: u16 = 1,

    pub fn init(allocator: std.mem.Allocator) DecimalFormat {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DecimalFormat) void {
        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn applyPattern(
        self: *DecimalFormat,
        pattern: []const u8,
    ) Error!void {
        if (!number.validatePattern(pattern)) return error.InvalidPattern;
        const owned = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned);

        const split = splitPattern(owned);
        const positive = extractSubpattern(split.positive) orelse
            return error.InvalidPattern;
        const negative = if (split.negative) |text|
            extractSubpattern(text) orelse return error.InvalidPattern
        else
            null;
        const integer_min = number.patternIntegerMinDigits(owned) orelse
            return error.InvalidPattern;

        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        self.pattern = owned;
        self.positive = positive;
        self.negative = negative;
        self.integer_min = integer_min;
        self.has_currency = scanFor(owned, "\u{00a4}");
        self.has_permille = scanFor(owned, "\u{2030}");
        self.multiplier = if (self.has_permille)
            1000
        else if (scanFor(owned, "%"))
            100
        else
            1;
    }

    pub fn toPattern(self: *const DecimalFormat) []const u8 {
        return self.pattern;
    }

    pub fn formatAlloc(
        self: *const DecimalFormat,
        allocator: std.mem.Allocator,
        value: f64,
        locale_name: []const u8,
        currency: ?[]const u8,
    ) Error![]u8 {
        var options = number.Options{};
        options.integer_min_digits = self.integer_min;
        if (self.has_currency) {
            const code = currency orelse return error.MissingCurrency;
            options.style = .currency;
            options.currency = code;
        }
        if (self.has_permille) options.permille = true;
        return number.formatPatternAlloc(
            allocator,
            value,
            locale_name,
            self.pattern,
            options,
        );
    }

    /// Parses a prefix of `text` using this pattern's affixes.
    pub fn parse(
        self: *const DecimalFormat,
        text: []const u8,
        locale_name: []const u8,
        currency: ?[]const u8,
        index: *usize,
    ) ?f64 {
        const start = index.*;
        if (start > text.len) return null;
        const symbols = number.symbolsFor(locale_name, .{});
        var currency_symbol: ?[]const u8 = null;
        if (self.has_currency) {
            const code = currency orelse return null;
            currency_symbol = number.currencySymbolFor(locale_name, code);
        }

        var best: ?Match = null;
        if (matchSubpattern(
            text,
            start,
            self.positive,
            locale_name,
            symbols,
            currency_symbol,
            false,
            self.multiplier,
        )) |result| {
            best = result;
        }
        if (self.negative) |negative| {
            if (matchSubpattern(
                text,
                start,
                negative,
                locale_name,
                symbols,
                currency_symbol,
                true,
                self.multiplier,
            )) |result| {
                if (best == null or result.end > best.?.end) best = result;
            }
        }
        const result = best orelse return null;
        index.* = result.end;
        return result.value;
    }
};

fn splitPattern(pattern: []const u8) PatternSplit {
    var in_quote = false;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                index += 1;
                continue;
            }
            in_quote = !in_quote;
            continue;
        }
        if (!in_quote and byte == ';') {
            return .{
                .positive = pattern[0..index],
                .negative = pattern[index + 1 ..],
            };
        }
    }
    return .{ .positive = pattern, .negative = null };
}

fn extractSubpattern(text: []const u8) ?Subpattern {
    var in_quote = false;
    var first: ?usize = null;
    var last: ?usize = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\'') {
            if (index + 1 < text.len and text[index + 1] == '\'') {
                index += 1;
                continue;
            }
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        if (byte == '#' or byte == '0') {
            if (first == null) first = index;
            last = index;
        }
    }
    const start = first orelse return null;
    const end = last.?;
    return .{
        .prefix = text[0..start],
        .suffix = text[end + 1 ..],
    };
}

fn scanFor(pattern: []const u8, needle: []const u8) bool {
    var in_quote = false;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                index += 1;
                continue;
            }
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        if (std.mem.startsWith(u8, pattern[index..], needle)) return true;
    }
    return false;
}

fn appendTo(buffer: []u8, length: *usize, text: []const u8) bool {
    if (text.len > buffer.len - length.*) return false;
    @memcpy(buffer[length.*..][0..text.len], text);
    length.* += text.len;
    return true;
}

fn buildAffix(
    raw: []const u8,
    buffer: []u8,
    symbols: number.Symbols,
    currency_symbol: ?[]const u8,
) ?[]const u8 {
    var length: usize = 0;
    var in_quote = false;
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == '\'') {
            if (index + 1 < raw.len and raw[index + 1] == '\'') {
                if (!appendTo(buffer, &length, "'")) return null;
                index += 2;
                continue;
            }
            in_quote = !in_quote;
            index += 1;
            continue;
        }
        if (!in_quote) {
            if (byte == '-') {
                if (!appendTo(buffer, &length, symbols.minus)) return null;
                index += 1;
                continue;
            }
            if (byte == '%') {
                if (!appendTo(buffer, &length, symbols.percent)) return null;
                index += 1;
                continue;
            }
            if (std.mem.startsWith(u8, raw[index..], "\u{00a4}")) {
                const symbol = currency_symbol orelse return null;
                if (!appendTo(buffer, &length, symbol)) return null;
                index += 2;
                continue;
            }
            if (std.mem.startsWith(u8, raw[index..], "\u{2030}")) {
                if (!appendTo(buffer, &length, "\u{2030}")) return null;
                index += 3;
                continue;
            }
        }
        if (!appendTo(buffer, &length, raw[index..][0..1])) return null;
        index += 1;
    }
    return buffer[0..length];
}

fn matchSubpattern(
    text: []const u8,
    start: usize,
    subpattern: Subpattern,
    locale_name: []const u8,
    symbols: number.Symbols,
    currency_symbol: ?[]const u8,
    negate: bool,
    multiplier: u16,
) ?Match {
    var prefix_buffer: [256]u8 = undefined;
    const prefix = buildAffix(
        subpattern.prefix,
        &prefix_buffer,
        symbols,
        currency_symbol,
    ) orelse return null;
    var sign: f64 = 1;
    var prefix_start = start;
    const prefix_has_sign =
        std.mem.startsWith(u8, prefix, symbols.minus) or
        std.mem.startsWith(u8, prefix, symbols.plus);
    if (!prefix_has_sign) {
        if (std.mem.startsWith(u8, text[start..], symbols.minus)) {
            sign = -1;
            prefix_start += symbols.minus.len;
        } else if (std.mem.startsWith(u8, text[start..], "-")) {
            sign = -1;
            prefix_start += 1;
        } else if (std.mem.startsWith(u8, text[start..], symbols.plus)) {
            prefix_start += symbols.plus.len;
        } else if (std.mem.startsWith(u8, text[start..], "+")) {
            prefix_start += 1;
        }
    }
    if (!std.mem.startsWith(u8, text[prefix_start..], prefix)) return null;

    const number_start = prefix_start + prefix.len;
    const parsed = number.parseFloatPrefix(
        text[number_start..],
        locale_name,
        .{},
    ) orelse return null;
    const number_end = number_start + parsed.end;

    var suffix_buffer: [256]u8 = undefined;
    const suffix = buildAffix(
        subpattern.suffix,
        &suffix_buffer,
        symbols,
        currency_symbol,
    ) orelse return null;
    if (!std.mem.startsWith(u8, text[number_end..], suffix)) return null;

    var value = parsed.value * sign;
    if (multiplier != 1) value /= @floatFromInt(multiplier);
    if (negate) value = -value;
    return .{ .value = value, .end = number_end + suffix.len };
}

test "DecimalFormat patterns format like ICU" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var format = DecimalFormat.init(allocator);
    defer format.deinit();
    try format.applyPattern("#,##0.00");
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = 0, .expected = "0.00" },
        .{ .value = 1, .expected = "1.00" },
        .{ .value = 1.5, .expected = "1.50" },
        .{ .value = -1.5, .expected = "-1.50" },
        .{ .value = 1234567.891, .expected = "1,234,567.89" },
        .{ .value = 0.0051, .expected = "0.01" },
    };
    for (cases) |case| {
        const text = try format.formatAlloc(
            allocator,
            case.value,
            "en",
            null,
        );
        defer allocator.free(text);
        try testing.expectEqualStrings(case.expected, text);
    }

    try format.applyPattern("#,##0.00;(#,##0.00)");
    const negative = try format.formatAlloc(allocator, -1234.5, "en", null);
    defer allocator.free(negative);
    try testing.expectEqualStrings("(1,234.50)", negative);
    const positive = try format.formatAlloc(allocator, 1234.5, "en", null);
    defer allocator.free(positive);
    try testing.expectEqualStrings("1,234.50", positive);

    try format.applyPattern("0000");
    const padded = try format.formatAlloc(allocator, 42, "en", null);
    defer allocator.free(padded);
    try testing.expectEqualStrings("0042", padded);

    try format.applyPattern("#,##0.###");
    const trimmed = try format.formatAlloc(allocator, 1.5, "en", null);
    defer allocator.free(trimmed);
    try testing.expectEqualStrings("1.5", trimmed);

    try format.applyPattern("#,##0%");
    const percent = try format.formatAlloc(allocator, 0.25, "en", null);
    defer allocator.free(percent);
    try testing.expectEqualStrings("25%", percent);

    try format.applyPattern("\u{00a4}#,##0.00");
    const currency = try format.formatAlloc(allocator, 12.5, "en", "USD");
    defer allocator.free(currency);
    try testing.expectEqualStrings("$12.50", currency);
    try testing.expectError(
        error.MissingCurrency,
        format.formatAlloc(allocator, 12.5, "en", null),
    );

    try format.applyPattern("#,##0.00 '\u{20ac}'");
    const quoted = try format.formatAlloc(allocator, 12.5, "en", null);
    defer allocator.free(quoted);
    try testing.expectEqualStrings("12.50 \u{20ac}", quoted);

    try testing.expectError(
        error.InvalidPattern,
        format.applyPattern("0.###E0"),
    );
}

test "DecimalFormat parses affixes and multipliers" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var format = DecimalFormat.init(allocator);
    defer format.deinit();
    try format.applyPattern("#,##0.00;(#,##0.00)");

    var index: usize = 0;
    try testing.expectEqual(
        @as(?f64, 1234.5),
        format.parse("1,234.50", "en", null, &index),
    );
    try testing.expectEqual(@as(usize, 8), index);

    index = 0;
    try testing.expectEqual(
        @as(?f64, -1234.5),
        format.parse("(1,234.50)", "en", null, &index),
    );
    try testing.expectEqual(@as(usize, 10), index);

    index = 0;
    try testing.expectEqual(
        @as(?f64, null),
        format.parse("abc", "en", null, &index),
    );
    try testing.expectEqual(@as(usize, 0), index);

    try format.applyPattern("#,##0%");
    index = 0;
    try testing.expectEqual(
        @as(?f64, 0.25),
        format.parse("25%", "en", null, &index),
    );
    try testing.expectEqual(@as(usize, 3), index);

    try format.applyPattern("\u{00a4}#,##0.00");
    index = 0;
    try testing.expectEqual(
        @as(?f64, 12.5),
        format.parse("$12.50", "en", "USD", &index),
    );
    try testing.expectEqual(@as(usize, 6), index);
}

test "ICU DecimalFormat conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("decimal_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGO", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const patterns = [_]struct { text: []const u8, currency: bool }{
        .{ .text = "#,##0.00", .currency = false },
        .{ .text = "#,##0.00;(#,##0.00)", .currency = false },
        .{ .text = "0.###", .currency = false },
        .{ .text = "0000", .currency = false },
        .{ .text = "#,##0%", .currency = false },
        .{ .text = "\u{00a4}#,##0.00", .currency = true },
        .{ .text = "#,##0.00 'kg'", .currency = false },
        .{ .text = "#,##0.0", .currency = false },
        .{ .text = "#,##0", .currency = false },
        .{ .text = "0.00\u{2030}", .currency = false },
    };
    const locales = [_][]const u8{ "en", "de", "fr" };

    var cursor: usize = 12;
    var failures: usize = 0;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const locale_index = fixture[cursor];
        cursor += 1;
        const pattern_index = fixture[cursor];
        cursor += 1;
        const kind = fixture[cursor];
        cursor += 1;
        if (locale_index >= locales.len or pattern_index >= patterns.len) {
            return error.InvalidFixture;
        }
        const locale = locales[locale_index];
        const pattern = patterns[pattern_index];
        const currency: ?[]const u8 = if (pattern.currency) "USD" else null;

        var format = DecimalFormat.init(allocator);
        defer format.deinit();
        format.applyPattern(pattern.text) catch {
            failures += 1;
            continue;
        };

        switch (kind) {
            0 => {
                const value_bits = std.mem.readInt(
                    u64,
                    fixture[cursor..][0..8],
                    .little,
                );
                cursor += 8;
                const value: f64 = @bitCast(value_bits);
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const expected = try utf16FixtureToUtf8(
                    allocator,
                    fixture,
                    cursor,
                    length,
                );
                defer allocator.free(expected);
                cursor += @as(usize, length) * 2;

                const actual = format.formatAlloc(
                    allocator,
                    value,
                    locale,
                    currency,
                ) catch {
                    failures += 1;
                    continue;
                };
                defer allocator.free(actual);
                if (!std.mem.eql(u8, actual, expected)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "decimal format mismatch: locale [{s}] pattern [{s}] value {d} got [{s}] want [{s}]\n",
                            .{ locale, pattern.text, value, actual, expected },
                        );
                    }
                }
            },
            1 => {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const input = try utf16FixtureToUtf8(
                    allocator,
                    fixture,
                    cursor,
                    length,
                );
                defer allocator.free(input);
                cursor += @as(usize, length) * 2;
                const matched = fixture[cursor] != 0;
                cursor += 1;
                const value_bits = std.mem.readInt(
                    u64,
                    fixture[cursor..][0..8],
                    .little,
                );
                cursor += 8;
                const expected_value: f64 = @bitCast(value_bits);
                const expected_index = std.mem.readInt(
                    u32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;

                var index: usize = 0;
                const actual = format.parse(
                    input,
                    locale,
                    currency,
                    &index,
                );
                if ((actual != null) != matched) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "decimal parse match mismatch: locale [{s}] pattern [{s}] input [{s}]\n",
                            .{ locale, pattern.text, input },
                        );
                    }
                } else if (actual) |value| {
                    const same = std.math.approxEqRel(
                        f64,
                        value,
                        expected_value,
                        1e-15,
                    ) or (std.math.isNan(value) and
                        std.math.isNan(expected_value));
                    if (!same or index != @as(usize, expected_index)) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "decimal parse mismatch: locale [{s}] pattern [{s}] input [{s}] got {d}@{d} want {d}@{d}\n",
                                .{
                                    locale,
                                    pattern.text,
                                    input,
                                    value,
                                    index,
                                    expected_value,
                                    expected_index,
                                },
                            );
                        }
                    }
                }
            },
            else => return error.InvalidFixture,
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "DecimalFormat conformance: {d} records passed\n",
        .{record_count},
    );
}

fn utf16FixtureToUtf8(
    allocator: std.mem.Allocator,
    fixture: []const u8,
    offset: usize,
    length: u16,
) ![]u8 {
    const units = try allocator.alloc(u16, length);
    defer allocator.free(units);
    for (units, 0..) |*unit, index| {
        unit.* = std.mem.readInt(
            u16,
            fixture[offset + index * 2 ..][0..2],
            .little,
        );
    }
    return std.unicode.utf16LeToUtf8Alloc(allocator, units);
}
