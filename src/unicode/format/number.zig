//! CLDR 48 decimal, percent, and currency number formatting.

const std = @import("std");
const data = @import("numbers_data.zig");
const currencies = @import("currencies.zig");
const plural = @import("plurals.zig");
const misc = @import("misc.zig");
const numbering_systems = @import("numbering_systems.zig");
const properties = @import("../properties.zig");

pub const cldr_version = "48";

pub const Style = enum { decimal, percent, currency, scientific, compact };

pub const CompactStyle = enum { short, long };

pub const CurrencyDisplay = enum { symbol, code, name };

pub const Options = struct {
    style: Style = .decimal,
    currency: ?[]const u8 = null,
    currency_display: CurrencyDisplay = .symbol,
    accounting: bool = false,
    min_fraction_digits: ?u8 = null,
    max_fraction_digits: ?u8 = null,
    use_grouping: bool = true,
    compact_style: CompactStyle = .short,
    numbering_system: ?[]const u8 = null,
};

pub const Error = error{
    InvalidPattern,
    MissingCurrency,
    OutOfMemory,
};

/// Format a floating-point value for one locale.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    return switch (options.style) {
        .scientific => formatScientificAlloc(allocator, value, locale_name, options),
        .compact => formatCompactAlloc(allocator, value, locale_name, options),
        .decimal, .percent, .currency => formatStandardAlloc(
            allocator,
            value,
            locale_name,
            options,
        ),
    };
}

fn resolveLocale(locale_name: []const u8, options: Options) data.Locale {
    const split = misc.splitNumberingSystem(locale_name);
    var locale = findLocale(split.locale) orelse findLocale("en").?;
    const name = options.numbering_system orelse split.system orelse return locale;
    const system = numbering_systems.find(name) orelse return locale;
    locale.digits = system.digits;
    if (std.mem.eql(u8, name, locale.numbering_system)) return locale;
    const latn = numbering_systems.find("latn") orelse return locale;
    var request_decimal: []const u8 = "";
    var request_group: []const u8 = "";
    var request_minus: []const u8 = "";
    var request_plus: []const u8 = "";
    if (numbering_systems.findOverride(split.locale, name)) |entry| {
        request_decimal = entry.decimal;
        request_group = entry.group;
        request_minus = entry.minus;
        request_plus = entry.plus;
    }
    var default_decimal: []const u8 = "";
    var default_group: []const u8 = "";
    var default_minus: []const u8 = "";
    var default_plus: []const u8 = "";
    if (numbering_systems.findOverride(split.locale, locale.numbering_system)) |entry| {
        default_decimal = entry.decimal;
        default_group = entry.group;
        default_minus = entry.minus;
        default_plus = entry.plus;
    }
    locale.decimal = pickSymbol(
        &.{ request_decimal, system.decimal, default_decimal, latn.decimal },
        ".",
    );
    locale.group = pickSymbol(
        &.{ request_group, system.group, default_group, latn.group },
        ",",
    );
    locale.minus = pickSymbol(
        &.{ request_minus, system.minus, default_minus, locale.minus },
        "-",
    );
    locale.plus = pickSymbol(
        &.{ request_plus, system.plus, default_plus, locale.plus },
        "+",
    );
    return locale;
}

fn pickSymbol(values: []const []const u8, fallback: []const u8) []const u8 {
    for (values) |value| {
        if (value.len != 0) return value;
    }
    return fallback;
}

fn formatStandardAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    const locale = resolveLocale(locale_name, options);
    var currency_display_text: []const u8 = "";
    if (options.style == .currency) {
        const code = options.currency orelse return error.MissingCurrency;
        if (options.currency_display == .name) {
            return formatCurrencyNameAlloc(
                allocator,
                value,
                locale_name,
                options,
                locale,
                code,
            );
        }
        currency_display_text = currencyDisplayText(
            locale,
            code,
            options.currency_display,
        );
    }
    const pattern_text = switch (options.style) {
        .decimal => locale.decimal_pattern,
        .percent => locale.percent_pattern,
        .currency => currencyPatternText(locale, options, currency_display_text),
        .scientific, .compact => unreachable,
    };
    const pattern = parsePattern(pattern_text) orelse
        return error.InvalidPattern;

    if (std.math.isNan(value)) {
        return allocator.dupe(u8, locale.nan);
    }
    if (std.math.isInf(value)) {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        if (value < 0) try output.appendSlice(allocator, locale.minus);
        try output.appendSlice(allocator, locale.infinity);
        return output.toOwnedSlice(allocator);
    }

    var min_fraction = options.min_fraction_digits orelse
        pattern.fraction_min;
    var max_fraction = options.max_fraction_digits orelse
        pattern.fraction_max;
    if (options.style == .currency) {
        const code = options.currency orelse return error.MissingCurrency;
        const digits = currencyDigits(code);
        if (options.min_fraction_digits == null) min_fraction = digits;
        if (options.max_fraction_digits == null) max_fraction = digits;
    }
    if (min_fraction > max_fraction) max_fraction = min_fraction;
    if (max_fraction > 6) max_fraction = 6;
    if (min_fraction > max_fraction) min_fraction = max_fraction;

    const negative = value < 0;
    const magnitude = @abs(value) *
        @as(f64, @floatFromInt(pattern.multiplier));

    var number_buffer: [64]u8 = undefined;
    const formatted = formatFloat(
        &number_buffer,
        roundHalfEven(magnitude, max_fraction),
        max_fraction,
    );

    var integer_part = formatted;
    var fraction_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, formatted, '.')) |dot| {
        integer_part = formatted[0..dot];
        fraction_part = formatted[dot + 1 ..];
    }

    return formatParts(
        allocator,
        integer_part,
        fraction_part,
        min_fraction,
        negative,
        pattern,
        locale,
        currency_display_text,
        options.use_grouping,
    );
}

/// Format an integer value for one locale.
pub fn formatIntegerAlloc(
    allocator: std.mem.Allocator,
    value: i64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    if (options.style == .scientific or options.style == .compact or
        (options.style == .currency and options.currency_display == .name))
    {
        return formatAlloc(allocator, @floatFromInt(value), locale_name, options);
    }
    const locale = resolveLocale(locale_name, options);
    var currency_display_text: []const u8 = "";
    if (options.style == .currency) {
        const code = options.currency orelse return error.MissingCurrency;
        currency_display_text = currencyDisplayText(
            locale,
            code,
            options.currency_display,
        );
    }
    const pattern_text = switch (options.style) {
        .decimal => locale.decimal_pattern,
        .percent => locale.percent_pattern,
        .currency => currencyPatternText(locale, options, currency_display_text),
        .scientific, .compact => unreachable,
    };
    const pattern = parsePattern(pattern_text) orelse
        return error.InvalidPattern;

    var min_fraction = options.min_fraction_digits orelse
        pattern.fraction_min;
    var max_fraction = options.max_fraction_digits orelse
        pattern.fraction_max;
    if (options.style == .currency) {
        const code = options.currency orelse return error.MissingCurrency;
        const digits = currencyDigits(code);
        if (options.min_fraction_digits == null) min_fraction = digits;
        if (options.max_fraction_digits == null) max_fraction = digits;
    }
    if (min_fraction > max_fraction) min_fraction = max_fraction;

    var magnitude: u128 = @abs(value);
    magnitude *= pattern.multiplier;

    var digits_buffer: [48]u8 = undefined;
    const integer_digits = std.fmt.bufPrint(
        &digits_buffer,
        "{d}",
        .{magnitude},
    ) catch return error.OutOfMemory;

    var fraction_buffer: [8]u8 = undefined;
    const fraction_len = @min(@as(usize, min_fraction), fraction_buffer.len);
    @memset(fraction_buffer[0..fraction_len], '0');

    return formatParts(
        allocator,
        integer_digits,
        fraction_buffer[0..fraction_len],
        min_fraction,
        value < 0,
        pattern,
        locale,
        currency_display_text,
        options.use_grouping,
    );
}

/// Format a value using a compact ICU-style number skeleton.
pub fn formatSkeletonAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    skeleton: []const u8,
) Error![]u8 {
    const options = try parseSkeleton(skeleton);
    return formatAlloc(allocator, value, locale_name, options);
}

/// Format an integer using a compact ICU-style number skeleton.
pub fn formatSkeletonIntegerAlloc(
    allocator: std.mem.Allocator,
    value: i64,
    locale_name: []const u8,
    skeleton: []const u8,
) Error![]u8 {
    const options = try parseSkeleton(skeleton);
    return formatIntegerAlloc(allocator, value, locale_name, options);
}

fn parseSkeleton(skeleton: []const u8) Error!Options {
    var options = Options{};
    var tokens = std.mem.tokenizeAny(u8, skeleton, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "percent")) {
            options.style = .percent;
        } else if (std.mem.eql(u8, token, "decimal")) {
            options.style = .decimal;
        } else if (std.mem.eql(u8, token, "scientific")) {
            options.style = .scientific;
        } else if (std.mem.eql(u8, token, "integer")) {
            options.style = .decimal;
            options.min_fraction_digits = 0;
            options.max_fraction_digits = 0;
        } else if (std.mem.eql(u8, token, "compact-short")) {
            options.style = .compact;
            options.compact_style = .short;
        } else if (std.mem.eql(u8, token, "compact-long")) {
            options.style = .compact;
            options.compact_style = .long;
        } else if (std.mem.eql(u8, token, "group-off")) {
            options.use_grouping = false;
        } else if (std.mem.eql(u8, token, "group-on") or
            std.mem.eql(u8, token, "group-auto"))
        {
            options.use_grouping = true;
        } else if (std.mem.eql(u8, token, "precision-integer")) {
            options.min_fraction_digits = 0;
            options.max_fraction_digits = 0;
        } else if (std.mem.eql(u8, token, "precision-currency-standard")) {
            options.min_fraction_digits = null;
            options.max_fraction_digits = null;
        } else if (std.mem.startsWith(u8, token, "currency/")) {
            const code = token["currency/".len..];
            if (code.len == 0) return error.InvalidPattern;
            options.style = .currency;
            options.currency = code;
        } else if (token.len >= 2 and token[0] == '.') {
            var minimum: u8 = 0;
            var maximum: u8 = 0;
            for (token[1..]) |byte| {
                if (byte == '0') {
                    minimum += 1;
                    maximum += 1;
                } else if (byte == '#') {
                    maximum += 1;
                } else {
                    return error.InvalidPattern;
                }
            }
            if (maximum == 0) return error.InvalidPattern;
            options.min_fraction_digits = minimum;
            options.max_fraction_digits = maximum;
        } else if (std.mem.startsWith(u8, token, "unit-width-") or
            std.mem.startsWith(u8, token, "rounding-mode-") or
            std.mem.startsWith(u8, token, "sign-"))
        {
            // Accepted for compatibility but not applied.
        } else {
            return error.InvalidPattern;
        }
    }
    return options;
}

fn formatScientificAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    const locale = resolveLocale(locale_name, options);
    if (std.math.isNan(value)) return allocator.dupe(u8, locale.nan);
    if (std.math.isInf(value)) {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        if (value < 0) try output.appendSlice(allocator, locale.minus);
        try output.appendSlice(allocator, locale.infinity);
        return output.toOwnedSlice(allocator);
    }

    var exponent: i32 = 0;
    if (value != 0) {
        exponent = @intFromFloat(@floor(@log10(@abs(value))));
        const scaled = @abs(value) / std.math.pow(
            f64,
            10.0,
            @floatFromInt(exponent),
        );
        if (scaled >= 10.0) exponent += 1;
        if (scaled < 1.0) exponent -= 1;
    }
    const power = std.math.pow(f64, 10.0, @floatFromInt(exponent));
    if (power == 0) return decimalFallback(allocator, value, locale_name, options);
    var mantissa = if (value == 0) 0.0 else value / power;
    const max_fraction = options.max_fraction_digits orelse 6;
    if (roundHalfEven(@abs(mantissa), max_fraction) >= 10.0) {
        exponent += 1;
        mantissa /= 10.0;
    }

    const mantissa_text = try formatStandardAlloc(
        allocator,
        mantissa,
        locale_name,
        .{
            .style = .decimal,
            .min_fraction_digits = options.min_fraction_digits orelse 0,
            .max_fraction_digits = max_fraction,
            .use_grouping = false,
        },
    );
    defer allocator.free(mantissa_text);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, mantissa_text);
    try output.appendSlice(allocator, locale.exponential);
    if (exponent < 0) {
        try output.appendSlice(allocator, locale.minus);
        exponent = -exponent;
    }
    var buffer: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{exponent}) catch
        unreachable;
    for (digits) |digit| {
        try appendCodepoint(allocator, &output, locale.digits[digit - '0']);
    }
    return output.toOwnedSlice(allocator);
}

const compact_magnitudes = [_]u64{
    1000,
    10000,
    100000,
    1000000,
    10000000,
    100000000,
    1000000000,
    10000000000,
    100000000000,
    1000000000000,
    10000000000000,
    100000000000000,
};

const CompactFormat = struct {
    int_digits: u8,
    fraction_digits: u8,
    start: usize,
    end: usize,
};

fn parseCompactFormat(pattern: []const u8) ?CompactFormat {
    var start: ?usize = null;
    var end: usize = 0;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const character = pattern[index];
        if (character == '0' or character == '#' or
            character == '.' or character == ',')
        {
            if (start == null) start = index;
            end = index + 1;
        } else if (start != null) {
            break;
        }
    }
    const numeric_start = start orelse return null;
    var int_digits: u8 = 0;
    var fraction_digits: u8 = 0;
    var seen_dot = false;
    for (pattern[numeric_start..end]) |character| {
        if (character == '.') {
            seen_dot = true;
        } else if (character == '0') {
            if (seen_dot) {
                fraction_digits += 1;
            } else {
                int_digits += 1;
            }
        }
    }
    if (int_digits == 0) int_digits = 1;
    return .{
        .int_digits = int_digits,
        .fraction_digits = fraction_digits,
        .start = numeric_start,
        .end = end,
    };
}

fn compactUsable(entry: data.Compact) bool {
    if (entry.exact_one.len != 0) return true;
    for (entry.patterns) |pattern| {
        if (pattern.len != 0) return true;
    }
    return false;
}

fn compactCategory(
    locale_name: []const u8,
    value: f64,
    fraction_digits: u8,
) plural.Category {
    const magnitude = @abs(value);
    const scale = std.math.pow(f64, 10.0, @floatFromInt(fraction_digits));
    const rounded = roundHalfEven(magnitude, fraction_digits);
    if (fraction_digits == 0) {
        return plural.categoryForInteger(locale_name, @intFromFloat(rounded));
    }
    const integer_part: u64 = @intFromFloat(@floor(rounded));
    const fraction_value: u64 = @intFromFloat(
        @round((rounded - @floor(rounded)) * scale),
    );
    var trimmed = fraction_value;
    var trimmed_digits: u32 = fraction_digits;
    while (trimmed_digits > 0 and trimmed % 10 == 0) {
        trimmed /= 10;
        trimmed_digits -= 1;
    }
    return plural.category(locale_name, .{
        .n = rounded,
        .i = integer_part,
        .v = fraction_digits,
        .w = trimmed_digits,
        .f = fraction_value,
        .t = trimmed,
        .e = 0,
    });
}

fn formatCompactAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    const magnitude = @abs(value);
    if (!std.math.isFinite(value) or magnitude < 1000) {
        return compactFallback(allocator, value, locale_name, options);
    }
    const locale = resolveLocale(locale_name, options);
    const table = switch (options.compact_style) {
        .short => locale.compact_short,
        .long => locale.compact_long,
    };

    var chosen: ?usize = null;
    var index: usize = 0;
    while (index < compact_magnitudes.len and
        @as(f64, @floatFromInt(compact_magnitudes[index])) <= magnitude) : (index += 1)
    {
        if (compactUsable(table[index])) chosen = index;
    }
    const chosen_index = chosen orelse
        return compactFallback(allocator, value, locale_name, options);
    const entry = table[chosen_index];

    var reference: []const u8 = entry.patterns[@intFromEnum(plural.Category.other)];
    if (reference.len == 0) {
        for (entry.patterns) |pattern| {
            if (pattern.len != 0) {
                reference = pattern;
                break;
            }
        }
    }
    const format_info = parseCompactFormat(reference) orelse {
        if (entry.exact_one.len != 0 and
            magnitude == @as(f64, @floatFromInt(compact_magnitudes[chosen_index])))
        {
            return allocator.dupe(u8, entry.exact_one);
        }
        return compactFallback(allocator, value, locale_name, options);
    };

    var divisor = compact_magnitudes[chosen_index];
    var digits: u8 = 1;
    while (digits < format_info.int_digits) : (digits += 1) divisor /= 10;
    const scaled = value / @as(f64, @floatFromInt(divisor));
    if (scaled == 1 and entry.exact_one.len != 0) {
        return allocator.dupe(u8, entry.exact_one);
    }

    const category = compactCategory(
        locale_name,
        scaled,
        format_info.fraction_digits,
    );
    var pattern = entry.patterns[@intFromEnum(category)];
    if (pattern.len == 0) pattern = entry.patterns[@intFromEnum(plural.Category.other)];
    const info = parseCompactFormat(pattern) orelse {
        if (pattern.len != 0) return allocator.dupe(u8, pattern);
        return compactFallback(allocator, value, locale_name, options);
    };
    if (info.end == pattern.len) {
        // The locale writes this magnitude in full.
        return compactFallback(allocator, value, locale_name, options);
    }

    const scaled_text = try formatStandardAlloc(
        allocator,
        scaled,
        locale_name,
        .{
            .style = .decimal,
            .min_fraction_digits = info.fraction_digits,
            .max_fraction_digits = info.fraction_digits,
            .use_grouping = false,
        },
    );
    defer allocator.free(scaled_text);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, pattern[0..info.start]);
    try output.appendSlice(allocator, scaled_text);
    try output.appendSlice(allocator, pattern[info.end..]);
    return output.toOwnedSlice(allocator);
}

fn compactFallback(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    return formatStandardAlloc(allocator, value, locale_name, .{
        .style = .decimal,
        .min_fraction_digits = options.min_fraction_digits,
        .max_fraction_digits = options.max_fraction_digits,
        .use_grouping = false,
    });
}

fn decimalFallback(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
) Error![]u8 {
    return formatStandardAlloc(allocator, value, locale_name, .{
        .style = .decimal,
        .min_fraction_digits = options.min_fraction_digits,
        .max_fraction_digits = options.max_fraction_digits,
        .use_grouping = options.use_grouping,
    });
}

fn appendCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u21,
) Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        return error.InvalidPattern;
    try output.appendSlice(allocator, buffer[0..length]);
}

fn currencyDigits(code: []const u8) u8 {
    return currencies.fractionDigits(code);
}

fn currencyEntry(locale: data.Locale, code: []const u8) ?currencies.Entry {
    return currencies.find(locale.id, code);
}

fn currencyDisplayText(
    locale: data.Locale,
    code: []const u8,
    display: CurrencyDisplay,
) []const u8 {
    if (display == .code) return code;
    if (currencyEntry(locale, code)) |entry| {
        if (entry.symbol.len != 0) return entry.symbol;
        // The locale resolves the currency but defines no standard symbol,
        // so ICU falls back to the ISO code instead of borrowing another
        // locale's symbol.
        return code;
    }
    const fallback = currencySymbol(code);
    return if (fallback.len != 0) fallback else code;
}

fn currencyPatternText(
    locale: data.Locale,
    options: Options,
    display_text: []const u8,
) []const u8 {
    const base = if (options.accounting)
        locale.currency_accounting_pattern
    else
        locale.currency_pattern;
    const alpha = if (options.accounting)
        locale.currency_accounting_alpha_pattern
    else
        locale.currency_alpha_pattern;
    if (alpha.len != 0 and isAlphaNextToNumber(base, display_text)) {
        return alpha;
    }
    return base;
}

/// True when the currency symbol adjacent to the number in `pattern` is a
/// Unicode letter, which selects CLDR's alphaNextToNumber variant.
fn isAlphaNextToNumber(pattern: []const u8, symbol: []const u8) bool {
    if (symbol.len == 0) return false;
    const symbol_start = std.mem.indexOf(u8, pattern, "\xc2\xa4");
    const number_start = std.mem.indexOfScalar(u8, pattern, '0');
    const prefix = symbol_start != null and
        (number_start == null or symbol_start.? < number_start.?);
    const codepoint = if (prefix)
        lastCodepoint(symbol)
    else
        firstCodepoint(symbol);
    return if (codepoint) |cp| properties.isLetter(cp) else false;
}

fn firstCodepoint(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (length > text.len) return null;
    return std.unicode.utf8Decode(text[0..length]) catch null;
}

fn lastCodepoint(text: []const u8) ?u21 {
    var index = text.len;
    while (index > 0) {
        index -= 1;
        if (text[index] & 0xc0 != 0x80) {
            return std.unicode.utf8Decode(text[index..]) catch null;
        }
    }
    return null;
}

fn formatCurrencyNameAlloc(
    allocator: std.mem.Allocator,
    value: f64,
    locale_name: []const u8,
    options: Options,
    locale: data.Locale,
    code: []const u8,
) Error![]u8 {
    const fraction_digits = options.max_fraction_digits orelse
        currencyDigits(code);
    const min_fraction = options.min_fraction_digits orelse fraction_digits;
    const magnitude = @abs(value);
    const formatted = try formatStandardAlloc(
        allocator,
        magnitude,
        locale_name,
        .{
            .style = .decimal,
            .min_fraction_digits = min_fraction,
            .max_fraction_digits = fraction_digits,
            .use_grouping = options.use_grouping,
        },
    );
    defer allocator.free(formatted);

    const category = compactCategory(locale_name, magnitude, fraction_digits);
    var name: []const u8 = code;
    if (currencyEntry(locale, code)) |entry| {
        name = entry.names[@intFromEnum(category)];
        if (name.len == 0) {
            name = entry.names[@intFromEnum(plural.Category.other)];
        }
        if (name.len == 0) name = code;
    }

    var unit_pattern = locale.currency_unit_patterns[@intFromEnum(category)];
    if (unit_pattern.len == 0) {
        unit_pattern = locale.currency_unit_patterns[@intFromEnum(plural.Category.other)];
    }
    if (unit_pattern.len == 0) unit_pattern = "{0} {1}";

    const combined = try replaceTwoPlaceholdersAlloc(
        allocator,
        unit_pattern,
        formatted,
        name,
    );
    if (value >= 0) return combined;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    if (options.accounting) {
        try output.append(allocator, '(');
        try output.appendSlice(allocator, combined);
        try output.append(allocator, ')');
    } else {
        try output.appendSlice(allocator, locale.minus);
        try output.appendSlice(allocator, combined);
    }
    allocator.free(combined);
    return output.toOwnedSlice(allocator);
}

fn replaceTwoPlaceholdersAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    first: []const u8,
    second: []const u8,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '{' and index + 2 < pattern.len and
            pattern[index + 2] == '}')
        {
            switch (pattern[index + 1]) {
                '0' => {
                    try output.appendSlice(allocator, first);
                    index += 3;
                    continue;
                },
                '1' => {
                    try output.appendSlice(allocator, second);
                    index += 3;
                    continue;
                },
                else => {},
            }
        }
        try output.append(allocator, pattern[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn formatParts(
    allocator: std.mem.Allocator,
    integer_digits: []const u8,
    fraction_digits: []const u8,
    min_fraction: u8,
    negative: bool,
    pattern: Pattern,
    locale: data.Locale,
    currency_display: []const u8,
    use_grouping: bool,
) Error![]u8 {
    var fraction_len = fraction_digits.len;
    while (fraction_len > min_fraction and
        fraction_digits[fraction_len - 1] == '0')
    {
        fraction_len -= 1;
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const negative_pattern = negative and pattern.has_negative;
    if (negative_pattern) {
        try appendAffix(
            allocator,
            &output,
            pattern.negative_prefix,
            locale,
            currency_display,
        );
    } else {
        if (negative) try output.appendSlice(allocator, locale.minus);
        try appendAffix(
            allocator,
            &output,
            pattern.positive_prefix,
            locale,
            currency_display,
        );
    }

    try appendGroupedDigits(
        allocator,
        &output,
        integer_digits,
        pattern,
        locale,
        use_grouping,
    );

    if (fraction_len > 0) {
        try output.appendSlice(allocator, locale.decimal);
        for (fraction_digits[0..fraction_len]) |byte| {
            try appendDigit(allocator, &output, byte - '0', locale);
        }
    }

    if (negative_pattern) {
        try appendAffix(
            allocator,
            &output,
            pattern.negative_suffix,
            locale,
            currency_display,
        );
    } else {
        try appendAffix(
            allocator,
            &output,
            pattern.positive_suffix,
            locale,
            currency_display,
        );
    }
    return output.toOwnedSlice(allocator);
}

const Pattern = struct {
    positive_prefix: []const u8,
    positive_suffix: []const u8,
    negative_prefix: []const u8,
    negative_suffix: []const u8,
    has_negative: bool,
    integer_min: u8,
    fraction_min: u8,
    fraction_max: u8,
    group_primary: u8,
    group_secondary: u8,
    multiplier: u16,
};

const Subpattern = struct {
    prefix: []const u8,
    suffix: []const u8,
    integer_min: u8,
    fraction_min: u8,
    fraction_max: u8,
    group_primary: u8,
    group_secondary: u8,
};

fn parsePattern(text: []const u8) ?Pattern {
    var positive = text;
    var negative: ?[]const u8 = null;
    var in_quote = false;
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
        if (!in_quote and byte == ';') {
            positive = text[0..index];
            negative = text[index + 1 ..];
            break;
        }
    }

    const positive_part = parseSubpattern(positive) orelse return null;
    const negative_part = if (negative) |value| parseSubpattern(value) else null;

    return .{
        .positive_prefix = positive_part.prefix,
        .positive_suffix = positive_part.suffix,
        .negative_prefix = if (negative_part) |part| part.prefix else "",
        .negative_suffix = if (negative_part) |part| part.suffix else "",
        .has_negative = negative_part != null,
        .integer_min = positive_part.integer_min,
        .fraction_min = positive_part.fraction_min,
        .fraction_max = positive_part.fraction_max,
        .group_primary = positive_part.group_primary,
        .group_secondary = positive_part.group_secondary,
        .multiplier = scanMultiplier(text),
    };
}

fn parseSubpattern(text: []const u8) ?Subpattern {
    var start: ?usize = null;
    var end: ?usize = null;
    for (text, 0..) |byte, index| {
        if (byte == '#' or byte == '0') {
            if (start == null) start = index;
            end = index;
        }
    }
    const first = start orelse return null;
    const last = end.?;
    const prefix = text[0..first];
    const suffix = text[last + 1 ..];
    const numeric = text[first .. last + 1];

    var dot: ?usize = null;
    for (numeric, 0..) |byte, index| {
        if (byte == '.') {
            dot = index;
            break;
        }
    }
    const integer_part = if (dot) |position| numeric[0..position] else numeric;
    const fraction_part = if (dot) |position| numeric[position + 1 ..] else "";

    var integer_min: u8 = 0;
    var digit_count: u8 = 0;
    var commas: [8]u8 = undefined;
    var comma_count: usize = 0;
    for (integer_part) |byte| {
        if (byte == '0') integer_min += 1;
        if (byte == '#') {}
        if (byte == ',') {
            if (comma_count < commas.len) {
                commas[comma_count] = digit_count;
                comma_count += 1;
            }
            continue;
        }
        if (byte == '#' or byte == '0') digit_count += 1;
    }

    var group_primary: u8 = 0;
    var group_secondary: u8 = 0;
    if (comma_count > 0) {
        group_primary = digit_count - commas[comma_count - 1];
        group_secondary = if (comma_count > 1)
            commas[comma_count - 1] - commas[comma_count - 2]
        else
            group_primary;
    }

    var fraction_min: u8 = 0;
    var fraction_max: u8 = 0;
    for (fraction_part) |byte| {
        if (byte == '0') {
            fraction_min += 1;
            fraction_max += 1;
        } else if (byte == '#') {
            fraction_max += 1;
        }
    }

    return .{
        .prefix = prefix,
        .suffix = suffix,
        .integer_min = @max(integer_min, 1),
        .fraction_min = fraction_min,
        .fraction_max = fraction_max,
        .group_primary = group_primary,
        .group_secondary = group_secondary,
    };
}

fn scanMultiplier(text: []const u8) u16 {
    var in_quote = false;
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
        if (byte == '%') return 100;
        if (byte == 0xe2 and index + 2 < text.len and
            text[index + 1] == 0x80 and text[index + 2] == 0xb0)
        {
            return 1000;
        }
    }
    return 1;
}

/// Round `value` at `digits` fraction digits with ties going to the even
/// digit, matching the HALF_EVEN mode ICU's DecimalFormat applies by default.
fn roundHalfEven(value: f64, digits: u8) f64 {
    const scale = std.math.pow(f64, 10.0, @floatFromInt(digits));
    const scaled = value * scale;
    if (!std.math.isFinite(scaled)) return value;
    const lower = @floor(scaled);
    const fraction = scaled - lower;
    var rounded = lower;
    if (fraction > 0.5) {
        rounded = lower + 1.0;
    } else if (fraction == 0.5) {
        if (@mod(lower, 2.0) != 0.0) rounded = lower + 1.0;
    }
    return rounded / scale;
}

fn formatFloat(buffer: []u8, value: f64, digits: u8) []const u8 {
    return switch (digits) {
        0 => std.fmt.bufPrint(buffer, "{d:.0}", .{value}) catch unreachable,
        1 => std.fmt.bufPrint(buffer, "{d:.1}", .{value}) catch unreachable,
        2 => std.fmt.bufPrint(buffer, "{d:.2}", .{value}) catch unreachable,
        3 => std.fmt.bufPrint(buffer, "{d:.3}", .{value}) catch unreachable,
        4 => std.fmt.bufPrint(buffer, "{d:.4}", .{value}) catch unreachable,
        5 => std.fmt.bufPrint(buffer, "{d:.5}", .{value}) catch unreachable,
        else => std.fmt.bufPrint(buffer, "{d:.6}", .{value}) catch unreachable,
    };
}

fn appendGroupedDigits(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    digits: []const u8,
    pattern: Pattern,
    locale: data.Locale,
    use_grouping: bool,
) Error!void {
    const length = digits.len;
    const primary = @as(usize, pattern.group_primary);
    const secondary = @as(usize, pattern.group_secondary);
    // ICU's default number format groups as soon as the integer part exceeds
    // the primary grouping size; CLDR's minimumGroupingDigits is opt-in via
    // the API and is not applied by default.
    if (!use_grouping or primary == 0 or length <= primary) {
        for (digits) |byte| {
            try appendDigit(allocator, output, byte - '0', locale);
        }
        return;
    }

    // Build the group sizes from the right: the last group holds `primary`
    // digits and every preceding group holds `secondary` (or `primary` when
    // the pattern has a single group size, as in Indian "#,##,##0").
    var sizes: [32]usize = undefined;
    var count: usize = 0;
    var remaining = length;
    sizes[count] = @min(primary, remaining);
    count += 1;
    remaining -= sizes[0];
    const step = if (secondary > 0) secondary else primary;
    while (remaining > 0 and count < sizes.len) {
        const take = @min(step, remaining);
        sizes[count] = take;
        count += 1;
        remaining -= take;
    }
    if (remaining > 0) {
        // Extremely long digit strings fall back to one group.
        for (digits) |byte| {
            try appendDigit(allocator, output, byte - '0', locale);
        }
        return;
    }

    var index: usize = 0;
    var group_index = count;
    while (group_index > 0) {
        group_index -= 1;
        if (index > 0) try output.appendSlice(allocator, locale.group);
        const end = index + sizes[group_index];
        for (digits[index..end]) |byte| {
            try appendDigit(allocator, output, byte - '0', locale);
        }
        index = end;
    }
}

fn appendDigit(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    digit: u8,
    locale: data.Locale,
) Error!void {
    const codepoint = locale.digits[@as(usize, digit)];
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        unreachable;
    try output.appendSlice(allocator, buffer[0..length]);
}

fn appendAffix(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    affix: []const u8,
    locale: data.Locale,
    currency_display: []const u8,
) Error!void {
    var in_quote = false;
    var index: usize = 0;
    while (index < affix.len) : (index += 1) {
        const byte = affix[index];
        if (byte == '\'') {
            if (index + 1 < affix.len and affix[index + 1] == '\'') {
                try output.append(allocator, '\'');
                index += 1;
            } else {
                in_quote = !in_quote;
            }
            continue;
        }
        if (!in_quote and byte == 0xc2 and index + 1 < affix.len and
            affix[index + 1] == 0xa4)
        {
            try output.appendSlice(allocator, currency_display);
            if (index + 3 < affix.len and affix[index + 2] == 0xc2 and
                affix[index + 3] == 0xa4)
            {
                index += 3;
            } else {
                index += 1;
            }
            continue;
        }
        // ICU substitutes the localized symbols for pattern characters in
        // affixes; the localized minus sign carries RTL bidi marks.
        if (!in_quote and byte == '-') {
            try output.appendSlice(allocator, locale.minus);
            continue;
        }
        if (!in_quote and byte == '%') {
            try output.appendSlice(allocator, locale.percent);
            continue;
        }
        try output.append(allocator, byte);
    }
}

const CurrencySymbol = struct {
    code: []const u8,
    symbol: []const u8,
};

const currency_symbols = [_]CurrencySymbol{
    .{ .code = "USD", .symbol = "$" },
    .{ .code = "EUR", .symbol = "\u{20ac}" },
    .{ .code = "GBP", .symbol = "\u{00a3}" },
    .{ .code = "JPY", .symbol = "\u{00a5}" },
    .{ .code = "CNY", .symbol = "CN\u{00a5}" },
    .{ .code = "KRW", .symbol = "\u{20a9}" },
    .{ .code = "INR", .symbol = "\u{20b9}" },
    .{ .code = "RUB", .symbol = "\u{20bd}" },
    .{ .code = "BRL", .symbol = "R$" },
    .{ .code = "CAD", .symbol = "CA$" },
    .{ .code = "AUD", .symbol = "A$" },
    .{ .code = "CHF", .symbol = "CHF" },
    .{ .code = "SEK", .symbol = "kr" },
    .{ .code = "NOK", .symbol = "kr" },
    .{ .code = "DKK", .symbol = "kr" },
    .{ .code = "PLN", .symbol = "z\u{0142}" },
    .{ .code = "TRY", .symbol = "\u{20ba}" },
    .{ .code = "ILS", .symbol = "\u{20aa}" },
    .{ .code = "AED", .symbol = "AED" },
    .{ .code = "SAR", .symbol = "SAR" },
    .{ .code = "HKD", .symbol = "HK$" },
    .{ .code = "SGD", .symbol = "S$" },
    .{ .code = "NZD", .symbol = "NZ$" },
    .{ .code = "ZAR", .symbol = "R" },
    .{ .code = "MXN", .symbol = "MX$" },
};

fn currencySymbol(code: []const u8) []const u8 {
    for (currency_symbols) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry.symbol;
    }
    return code;
}

fn findLocale(locale: []const u8) ?data.Locale {
    if (lookup(locale)) |result| return result;

    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    for (locale) |byte| {
        if (len == buffer.len) break;
        buffer[len] = if (byte == '-') '_' else byte;
        len += 1;
    }
    if (lookup(buffer[0..len])) |result| return result;
    if (std.mem.indexOfAny(u8, locale, "-_")) |position| {
        if (lookup(locale[0..position])) |result| return result;
    }
    return null;
}

fn lookup(locale: []const u8) ?data.Locale {
    var low: usize = 0;
    var high = data.locales.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = data.locales[mid];
        switch (std.mem.order(u8, entry.id, locale)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return entry,
        }
    }
    return null;
}

test "decimal number formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const en = try formatAlloc(allocator, 1234.5, "en", .{});
    defer allocator.free(en);
    try testing.expectEqualStrings("1,234.5", en);

    const grouped = try formatAlloc(allocator, 1234567, "en", .{});
    defer allocator.free(grouped);
    try testing.expectEqualStrings("1,234,567", grouped);

    const de = try formatAlloc(allocator, 1234.5, "de", .{});
    defer allocator.free(de);
    try testing.expectEqualStrings("1.234,5", de);

    const fr = try formatAlloc(allocator, 1234.5, "fr", .{});
    defer allocator.free(fr);
    try testing.expectEqualStrings("1\u{202f}234,5", fr);

    const ru = try formatAlloc(allocator, 1234.5, "ru", .{});
    defer allocator.free(ru);
    try testing.expectEqualStrings("1\u{00a0}234,5", ru);

    const hi = try formatAlloc(allocator, 1234567, "hi", .{});
    defer allocator.free(hi);
    try testing.expectEqualStrings("12,34,567", hi);
}

test "percent and currency formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const percent = try formatAlloc(allocator, 0.25, "en", .{
        .style = .percent,
    });
    defer allocator.free(percent);
    try testing.expectEqualStrings("25%", percent);

    const de_percent = try formatAlloc(allocator, 0.25, "de", .{
        .style = .percent,
    });
    defer allocator.free(de_percent);
    try testing.expectEqualStrings("25\u{00a0}%", de_percent);

    const currency = try formatAlloc(allocator, 1234.5, "en", .{
        .style = .currency,
        .currency = "USD",
    });
    defer allocator.free(currency);
    try testing.expectEqualStrings("$1,234.50", currency);

    const euro = try formatAlloc(allocator, 1234.5, "de", .{
        .style = .currency,
        .currency = "EUR",
    });
    defer allocator.free(euro);
    try testing.expectEqualStrings("1.234,50\u{00a0}\u{20ac}", euro);
}

test "scientific and compact formatting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const scientific = try formatAlloc(allocator, 1234, "en", .{
        .style = .scientific,
    });
    defer allocator.free(scientific);
    try testing.expectEqualStrings("1.234E3", scientific);

    const small = try formatAlloc(allocator, 0.0012, "en", .{
        .style = .scientific,
    });
    defer allocator.free(small);
    try testing.expectEqualStrings("1.2E-3", small);

    const negative = try formatAlloc(allocator, -1234, "en", .{
        .style = .scientific,
    });
    defer allocator.free(negative);
    try testing.expectEqualStrings("-1.234E3", negative);

    const rounded = try formatAlloc(allocator, 9.9999999, "en", .{
        .style = .scientific,
    });
    defer allocator.free(rounded);
    try testing.expectEqualStrings("1E1", rounded);

    const compact = try formatAlloc(allocator, 1234, "en", .{
        .style = .compact,
    });
    defer allocator.free(compact);
    try testing.expectEqualStrings("1K", compact);

    const compact_12k = try formatAlloc(allocator, 12345, "en", .{
        .style = .compact,
    });
    defer allocator.free(compact_12k);
    try testing.expectEqualStrings("12K", compact_12k);

    const compact_123k = try formatAlloc(allocator, 123456, "en", .{
        .style = .compact,
    });
    defer allocator.free(compact_123k);
    try testing.expectEqualStrings("123K", compact_123k);

    const compact_m = try formatAlloc(allocator, 1234567, "en", .{
        .style = .compact,
    });
    defer allocator.free(compact_m);
    try testing.expectEqualStrings("1M", compact_m);

    const compact_long = try formatAlloc(allocator, 1234, "en", .{
        .style = .compact,
        .compact_style = .long,
    });
    defer allocator.free(compact_long);
    try testing.expectEqualStrings("1 thousand", compact_long);

    const small_plain = try formatAlloc(allocator, 999, "en", .{
        .style = .compact,
    });
    defer allocator.free(small_plain);
    try testing.expectEqualStrings("999", small_plain);

    const japanese_plain = try formatAlloc(allocator, 1234, "ja", .{
        .style = .compact,
    });
    defer allocator.free(japanese_plain);
    try testing.expectEqualStrings("1234", japanese_plain);

    const japanese_man = try formatAlloc(allocator, 12345, "ja", .{
        .style = .compact,
    });
    defer allocator.free(japanese_man);
    try testing.expectEqualStrings("1万", japanese_man);

    const french_mille = try formatAlloc(allocator, 1000, "fr", .{
        .style = .compact,
        .compact_style = .long,
    });
    defer allocator.free(french_mille);
    try testing.expectEqualStrings("mille", french_mille);

    const russian_few = try formatAlloc(allocator, 2000, "ru", .{
        .style = .compact,
        .compact_style = .long,
    });
    defer allocator.free(russian_few);
    try testing.expectEqualStrings("2 тысячи", russian_few);

    const russian_many = try formatAlloc(allocator, 5000, "ru", .{
        .style = .compact,
        .compact_style = .long,
    });
    defer allocator.free(russian_many);
    try testing.expectEqualStrings("5 тысяч", russian_many);
}

test "currency display and accounting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const code = try formatAlloc(allocator, 1234.5, "en", .{
        .style = .currency,
        .currency = "USD",
        .currency_display = .code,
    });
    defer allocator.free(code);
    try testing.expectEqualStrings("USD\u{00a0}1,234.50", code);

    const name = try formatAlloc(allocator, 1234.5, "en", .{
        .style = .currency,
        .currency = "USD",
        .currency_display = .name,
    });
    defer allocator.free(name);
    try testing.expectEqualStrings("1,234.50 US dollars", name);

    const accounting = try formatAlloc(allocator, -1234.5, "en", .{
        .style = .currency,
        .currency = "USD",
        .accounting = true,
    });
    defer allocator.free(accounting);
    try testing.expectEqualStrings("($1,234.50)", accounting);

    const accounting_name = try formatAlloc(allocator, -1234.5, "en", .{
        .style = .currency,
        .currency = "USD",
        .currency_display = .name,
        .accounting = true,
    });
    defer allocator.free(accounting_name);
    try testing.expectEqualStrings("(1,234.50 US dollars)", accounting_name);

    const german_code = try formatAlloc(allocator, 1234.5, "de", .{
        .style = .currency,
        .currency = "USD",
        .currency_display = .code,
    });
    defer allocator.free(german_code);
    try testing.expectEqualStrings("1.234,50\u{00a0}USD", german_code);

    const french_name = try formatAlloc(allocator, 1234.5, "fr", .{
        .style = .currency,
        .currency = "USD",
        .currency_display = .name,
    });
    defer allocator.free(french_name);
    try testing.expectEqualStrings(
        "1\u{202f}234,50 dollars des \u{00c9}tats-Unis",
        french_name,
    );

    const japanese_symbol = try formatAlloc(allocator, 1234.5, "ja", .{
        .style = .currency,
        .currency = "JPY",
    });
    defer allocator.free(japanese_symbol);
    try testing.expectEqualStrings("\u{ffe5}1,234", japanese_symbol);

    const japanese_name = try formatAlloc(allocator, 1234.5, "ja", .{
        .style = .currency,
        .currency = "JPY",
        .currency_display = .name,
    });
    defer allocator.free(japanese_name);
    try testing.expectEqualStrings("1,234\u{5186}", japanese_name);

    const chinese_name = try formatAlloc(allocator, 1234.5, "zh", .{
        .style = .currency,
        .currency = "CNY",
        .currency_display = .name,
    });
    defer allocator.free(chinese_name);
    try testing.expectEqualStrings(
        "1,234.50\u{4eba}\u{6c11}\u{5e01}",
        chinese_name,
    );

    const fallback = try formatAlloc(allocator, 1234.5, "en", .{
        .style = .currency,
        .currency = "XYZ",
        .currency_display = .code,
    });
    defer allocator.free(fallback);
    try testing.expectEqualStrings("XYZ\u{00a0}1,234.50", fallback);

    const yen = try formatAlloc(allocator, 1234.5, "en", .{
        .style = .currency,
        .currency = "JPY",
    });
    defer allocator.free(yen);
    try testing.expectEqualStrings("\u{00a5}1,234", yen);

    const won = try formatAlloc(allocator, 1234.5, "en", .{
        .style = .currency,
        .currency = "KRW",
    });
    defer allocator.free(won);
    try testing.expectEqualStrings("\u{20a9}1,234", won);
}

test "number formatting covers additional locales" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        value: f64,
        locale: []const u8,
        expected: []const u8,
    }{
        .{ .value = 1234.5, .locale = "de", .expected = "1.234,5" },
        .{ .value = 12345678.5, .locale = "es", .expected = "12.345.678,5" },
        .{ .value = 12345678.5, .locale = "it", .expected = "12.345.678,5" },
        .{ .value = 12345678.5, .locale = "pl", .expected = "12\u{00a0}345\u{00a0}678,5" },
        .{ .value = 1234.5, .locale = "tr", .expected = "1.234,5" },
        .{ .value = 1234.5, .locale = "ko", .expected = "1,234.5" },
        .{ .value = 1234.5, .locale = "hi", .expected = "1,234.5" },
        .{ .value = 12345678.5, .locale = "hi", .expected = "1,23,45,678.5" },
        .{ .value = 12345678.5, .locale = "en-IN", .expected = "1,23,45,678.5" },
        .{ .value = 1234.5, .locale = "fr-CA", .expected = "1\u{00a0}234,5" },
        .{ .value = 1234.5, .locale = "ru", .expected = "1\u{00a0}234,5" },
        .{ .value = 12345678.5, .locale = "pt-PT", .expected = "12\u{00a0}345\u{00a0}678,5" },
        .{ .value = 1234.5, .locale = "nl-BE", .expected = "1.234,5" },
        .{ .value = 1234.5, .locale = "cs", .expected = "1\u{00a0}234,5" },
        .{ .value = 1234.5, .locale = "da", .expected = "1.234,5" },
        .{ .value = 1234.5, .locale = "vi", .expected = "1.234,5" },
        .{ .value = 12345678.5, .locale = "ja", .expected = "12,345,678.5" },
        .{ .value = 12345678.5, .locale = "zh-Hant", .expected = "12,345,678.5" },
    };
    for (cases) |case| {
        const result = try formatAlloc(allocator, case.value, case.locale, .{});
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "number skeletons" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        skeleton: []const u8,
        value: f64,
        expected: []const u8,
    }{
        .{ .skeleton = "percent", .value = 0.25, .expected = "25%" },
        .{ .skeleton = "currency/USD", .value = 1234.5, .expected = "$1,234.50" },
        .{ .skeleton = "currency/JPY", .value = 1234.5, .expected = "\u{00a5}1,234" },
        .{ .skeleton = "compact-short", .value = 1234567, .expected = "1M" },
        .{ .skeleton = "compact-long", .value = 1234, .expected = "1 thousand" },
        .{ .skeleton = "scientific", .value = 1234, .expected = "1.234E3" },
        .{ .skeleton = "precision-integer", .value = 1.6, .expected = "2" },
        .{ .skeleton = ".00", .value = 1.2, .expected = "1.20" },
        .{ .skeleton = "group-off", .value = 1234, .expected = "1234" },
        .{
            .skeleton = "currency/USD group-off .00",
            .value = -1234.5,
            .expected = "-$1234.50",
        },
    };
    for (cases) |case| {
        const result = try formatSkeletonAlloc(
            allocator,
            case.value,
            "en",
            case.skeleton,
        );
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }

    try testing.expectError(
        error.InvalidPattern,
        formatSkeletonAlloc(allocator, 1, "en", "bogus"),
    );
}

test "integer and fraction options" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const integer = try formatIntegerAlloc(allocator, 1234, "en", .{});
    defer allocator.free(integer);
    try testing.expectEqualStrings("1,234", integer);

    const fixed = try formatAlloc(allocator, 1.2, "en", .{
        .min_fraction_digits = 2,
        .max_fraction_digits = 2,
    });
    defer allocator.free(fixed);
    try testing.expectEqualStrings("1.20", fixed);

    const negative = try formatAlloc(allocator, -1234.5, "en", .{});
    defer allocator.free(negative);
    try testing.expectEqualStrings("-1,234.5", negative);

    const polish_small = try formatAlloc(allocator, 1234, "pl", .{});
    defer allocator.free(polish_small);
    try testing.expectEqualStrings("1\u{00a0}234", polish_small);

    const polish_large = try formatAlloc(allocator, 12345, "pl", .{});
    defer allocator.free(polish_large);
    try testing.expectEqualStrings("12\u{00a0}345", polish_large);
}

test "currency conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("currency_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJR1", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const locale_length = fixture[cursor];
        const code_length = fixture[cursor + 1];
        const value: f64 = @bitCast(std.mem.readInt(u64, fixture[cursor + 4 ..][0..8], .little));
        const expected_length = std.mem.readInt(u16, fixture[cursor + 12 ..][0..2], .little);
        cursor += 16;
        const locale_name = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const code = fixture[cursor .. cursor + code_length];
        cursor += code_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        total += 1;
        const actual = formatAlloc(allocator, value, locale_name, .{
            .style = .currency,
            .currency = code,
        }) catch |err| {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print("currency mismatch {s} {s}: {s}\n", .{ locale_name, code, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "currency mismatch {s} {s} {d}: got '{s}' expected '{s}'\n",
                    .{ locale_name, code, value, actual, expected },
                );
            }
        }
    }
    std.debug.print("currency conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}
