//! ICU `ChoiceFormat`-compatible numeric range selection.
//!
//! A pattern is a `|`-separated list of `limit selector message` triples,
//! where the selector is `<`, `#`, or `≤`. Formatting picks the message
//! whose interval contains the number; parsing matches message literals and
//! returns the corresponding limit.

const std = @import("std");

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
};

const Element = struct {
    limit: f64,
    /// True for `<`: the boundary belongs to the previous interval.
    closure: bool,
    message: []const u8,
};

const infinity_text = "\u{221e}";
const less_equal_text = "\u{2264}";

const Parser = struct {
    pattern: []const u8,
    index: usize = 0,

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.pattern.len and isSpace(self.pattern[self.index])) {
            self.index += 1;
        }
    }

    fn parseNumber(self: *Parser) Error!f64 {
        const start = self.index;
        while (self.index < self.pattern.len) {
            const byte = self.pattern[self.index];
            if ((byte >= '0' and byte <= '9') or
                byte == '+' or byte == '-' or byte == '.' or
                byte == 'e' or byte == 'E')
            {
                self.index += 1;
            } else if (std.mem.startsWith(
                u8,
                self.pattern[self.index..],
                infinity_text,
            )) {
                self.index += infinity_text.len;
            } else {
                break;
            }
        }
        const token = self.pattern[start..self.index];
        if (token.len == 0) return error.InvalidPattern;
        if (std.mem.eql(u8, token, infinity_text)) return std.math.inf(f64);
        if (std.mem.eql(u8, token, "-" ++ infinity_text)) {
            return -std.math.inf(f64);
        }
        if (std.mem.eql(u8, token, "+" ++ infinity_text)) {
            return std.math.inf(f64);
        }
        const number_text = if (token[0] == '+') token[1..] else token;
        if (number_text.len == 0) return error.InvalidPattern;
        return std.fmt.parseFloat(f64, number_text) catch
            error.InvalidPattern;
    }

    fn findMessageEnd(self: *const Parser) usize {
        var index = self.index;
        var depth: usize = 0;
        var in_quote = false;
        while (index < self.pattern.len) {
            const byte = self.pattern[index];
            if (in_quote) {
                if (byte == '\'') {
                    if (index + 1 < self.pattern.len and
                        self.pattern[index + 1] == '\'')
                    {
                        index += 2;
                        continue;
                    }
                    in_quote = false;
                    index += 1;
                    continue;
                }
                index += 1;
                continue;
            }
            if (byte == '\'') {
                if (index + 1 < self.pattern.len and
                    self.pattern[index + 1] == '\'')
                {
                    index += 2;
                    continue;
                }
                const next_byte = if (index + 1 < self.pattern.len)
                    self.pattern[index + 1]
                else
                    0;
                if (next_byte == '{' or next_byte == '}' or next_byte == '|') {
                    in_quote = true;
                }
                index += 1;
                continue;
            }
            if (byte == '{') {
                depth += 1;
            } else if (byte == '}') {
                if (depth > 0) depth -= 1;
            } else if (byte == '|' and depth == 0) {
                break;
            }
            index += 1;
        }
        return index;
    }

    fn next(self: *Parser) Error!?Element {
        self.skipWhitespace();
        if (self.index >= self.pattern.len) return null;
        const limit = try self.parseNumber();
        self.skipWhitespace();
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        var closure: bool = undefined;
        if (self.pattern[self.index] == '<') {
            closure = true;
            self.index += 1;
        } else if (self.pattern[self.index] == '#') {
            closure = false;
            self.index += 1;
        } else if (std.mem.startsWith(
            u8,
            self.pattern[self.index..],
            less_equal_text,
        )) {
            closure = false;
            self.index += less_equal_text.len;
        } else {
            return error.InvalidPattern;
        }
        const message_start = self.index;
        const message_end = self.findMessageEnd();
        const message = self.pattern[message_start..message_end];
        self.index = message_end;
        if (self.index < self.pattern.len and self.pattern[self.index] == '|') {
            self.index += 1;
        }
        return .{
            .limit = limit,
            .closure = closure,
            .message = message,
        };
    }
};

/// ICU `ChoiceFormat.findSubMessage` for an unparsed pattern.
pub fn selectMessage(pattern: []const u8, value: f64) ?[]const u8 {
    var parser = Parser{ .pattern = pattern };
    const current = parser.next() catch return null;
    if (current == null) return null;
    var current_element = current.?;
    while (true) {
        const maybe_next = parser.next() catch return null;
        if (maybe_next == null) return current_element.message;
        const next_element = maybe_next.?;
        const stop = if (next_element.closure)
            !(value > next_element.limit)
        else
            !(value >= next_element.limit);
        if (stop) return current_element.message;
        current_element = next_element;
    }
}

/// Formats a number by selecting the matching message from `pattern`.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    value: f64,
) Error![]u8 {
    const message = selectMessage(pattern, value) orelse
        return error.InvalidPattern;
    return allocator.dupe(u8, message);
}

fn matchMessage(message: []const u8, text: []const u8) ?usize {
    var message_index: usize = 0;
    var text_index: usize = 0;
    var in_quote = false;
    while (message_index < message.len) {
        const byte = message[message_index];
        if (in_quote) {
            if (byte == '\'') {
                if (message_index + 1 < message.len and
                    message[message_index + 1] == '\'')
                {
                    if (text_index >= text.len or text[text_index] != '\'') {
                        return null;
                    }
                    text_index += 1;
                    message_index += 2;
                    continue;
                }
                in_quote = false;
                message_index += 1;
                continue;
            }
            if (text_index >= text.len or text[text_index] != byte) return null;
            text_index += 1;
            message_index += 1;
            continue;
        }
        if (byte == '\'') {
            if (message_index + 1 < message.len and
                message[message_index + 1] == '\'')
            {
                if (text_index >= text.len or text[text_index] != '\'') {
                    return null;
                }
                text_index += 1;
                message_index += 2;
                continue;
            }
            const next_byte = if (message_index + 1 < message.len)
                message[message_index + 1]
            else
                0;
            if (next_byte == '{' or next_byte == '}' or next_byte == '|') {
                in_quote = true;
                message_index += 1;
                continue;
            }
            if (text_index >= text.len or text[text_index] != '\'') return null;
            text_index += 1;
            message_index += 1;
            continue;
        }
        if (text_index >= text.len or text[text_index] != byte) return null;
        text_index += 1;
        message_index += 1;
    }
    return text_index;
}

fn appendLimit(
    allocator: std.mem.Allocator,
    pattern: *std.ArrayList(u8),
    limit: f64,
) Error!void {
    if (std.math.isPositiveInf(limit)) {
        try pattern.appendSlice(allocator, infinity_text);
        return;
    }
    if (std.math.isNegativeInf(limit)) {
        try pattern.append(allocator, '-');
        try pattern.appendSlice(allocator, infinity_text);
        return;
    }
    var buffer: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const text = std.fmt.float.render(&buffer, limit, .{ .mode = .decimal }) catch
        return error.InvalidPattern;
    try pattern.appendSlice(allocator, text);
}

/// ICU `ChoiceFormat` with an owned, pre-parsed pattern.
pub const ChoiceFormat = struct {
    allocator: std.mem.Allocator,
    pattern: []u8 = &.{},
    elements: std.ArrayList(Element) = .empty,

    pub fn init(allocator: std.mem.Allocator) ChoiceFormat {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ChoiceFormat) void {
        self.elements.deinit(self.allocator);
        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn applyPattern(self: *ChoiceFormat, pattern: []const u8) Error!void {
        const owned = try self.allocator.dupe(u8, pattern);
        var elements = std.ArrayList(Element).empty;
        errdefer {
            elements.deinit(self.allocator);
            self.allocator.free(owned);
        }
        var parser = Parser{ .pattern = owned };
        while (true) {
            const maybe_element = try parser.next();
            if (maybe_element == null) break;
            try elements.append(self.allocator, maybe_element.?);
        }
        if (elements.items.len == 0) return error.InvalidPattern;

        self.elements.deinit(self.allocator);
        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        self.elements = elements;
        self.pattern = owned;
    }

    /// ICU `ChoiceFormat.setChoices`. `closures[i] == true` selects `<`.
    pub fn setChoices(
        self: *ChoiceFormat,
        limits: []const f64,
        closures: ?[]const bool,
        messages: []const []const u8,
    ) Error!void {
        if (limits.len != messages.len) return error.InvalidPattern;
        var pattern = std.ArrayList(u8).empty;
        defer pattern.deinit(self.allocator);
        for (limits, 0..) |limit, index| {
            if (index != 0) try pattern.append(self.allocator, '|');
            try appendLimit(self.allocator, &pattern, limit);
            const closure = if (closures) |values|
                (index < values.len and values[index])
            else
                false;
            try pattern.append(self.allocator, if (closure) '<' else '#');
            try pattern.appendSlice(self.allocator, messages[index]);
        }
        try self.applyPattern(pattern.items);
    }

    /// ICU `ChoiceFormat.format(double)`.
    pub fn select(self: *const ChoiceFormat, value: f64) ?[]const u8 {
        const items = self.elements.items;
        if (items.len == 0) return null;
        var current = items[0];
        for (items[1..]) |element| {
            const stop = if (element.closure)
                !(value > element.limit)
            else
                !(value >= element.limit);
            if (stop) return current.message;
            current = element;
        }
        return current.message;
    }

    pub fn formatAlloc(
        self: *const ChoiceFormat,
        allocator: std.mem.Allocator,
        value: f64,
    ) Error![]u8 {
        const message = self.select(value) orelse return error.InvalidPattern;
        return allocator.dupe(u8, message);
    }

    /// ICU `ChoiceFormat.parse`: consumes the longest matching message.
    pub fn parse(
        self: *const ChoiceFormat,
        text: []const u8,
        index: *usize,
    ) ?f64 {
        const start = index.*;
        if (start > text.len) return null;
        var best_length: usize = 0;
        var best_limit: f64 = std.math.nan(f64);
        var matched = false;
        for (self.elements.items) |element| {
            const length = matchMessage(element.message, text[start..]) orelse
                continue;
            if (length == 0) continue;
            if (!matched or length > best_length) {
                matched = true;
                best_length = length;
                best_limit = element.limit;
            }
        }
        if (!matched) return null;
        index.* = start + best_length;
        return best_limit;
    }

    pub fn toPattern(self: *const ChoiceFormat) []const u8 {
        return self.pattern;
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

test "ChoiceFormat formatting matches ICU intervals" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var format = ChoiceFormat.init(allocator);
    defer format.deinit();
    try format.applyPattern("0#no files|1#one file|1<many files");

    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = -1, .expected = "no files" },
        .{ .value = 0, .expected = "no files" },
        .{ .value = 0.5, .expected = "no files" },
        .{ .value = 1, .expected = "one file" },
        .{ .value = 1.5, .expected = "many files" },
        .{ .value = 2, .expected = "many files" },
        .{ .value = std.math.nan(f64), .expected = "no files" },
    };
    for (cases) |case| {
        const text = try format.formatAlloc(allocator, case.value);
        defer allocator.free(text);
        try testing.expectEqualStrings(case.expected, text);
    }

    var parsed_index: usize = 0;
    try testing.expectEqual(
        @as(?f64, 0),
        format.parse("no files", &parsed_index),
    );
    try testing.expectEqual(@as(usize, 8), parsed_index);
    parsed_index = 0;
    try testing.expectEqual(
        @as(?f64, 1),
        format.parse("one file", &parsed_index),
    );
    try testing.expectEqual(@as(usize, 8), parsed_index);
    parsed_index = 0;
    try testing.expectEqual(
        @as(?f64, 1),
        format.parse("many files!", &parsed_index),
    );
    try testing.expectEqual(@as(usize, 10), parsed_index);
    parsed_index = 0;
    try testing.expectEqual(@as(?f64, null), format.parse("xyz", &parsed_index));
    try testing.expectEqual(@as(usize, 0), parsed_index);
    try testing.expectEqualStrings(
        "0#no files|1#one file|1<many files",
        format.toPattern(),
    );
}

test "ChoiceFormat setChoices, infinity, and quotes" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var format = ChoiceFormat.init(allocator);
    defer format.deinit();
    try format.setChoices(
        &.{ -std.math.inf(f64), 0, std.math.inf(f64) },
        &.{ false, false, false },
        &.{ "neg", "zero", "inf" },
    );
    try testing.expectEqualStrings("-∞#neg|0#zero|∞#inf", format.toPattern());
    const negative = try format.formatAlloc(allocator, -1e300);
    defer allocator.free(negative);
    try testing.expectEqualStrings("neg", negative);
    const zero = try format.formatAlloc(allocator, 0);
    defer allocator.free(zero);
    try testing.expectEqualStrings("zero", zero);
    const large = try format.formatAlloc(allocator, 1e300);
    defer allocator.free(large);
    try testing.expectEqualStrings("zero", large);
    const negative_infinity = try format.formatAlloc(
        allocator,
        -std.math.inf(f64),
    );
    defer allocator.free(negative_infinity);
    try testing.expectEqualStrings("neg", negative_infinity);
    const positive_infinity = try format.formatAlloc(
        allocator,
        std.math.inf(f64),
    );
    defer allocator.free(positive_infinity);
    try testing.expectEqualStrings("inf", positive_infinity);
    const not_a_number = try format.formatAlloc(allocator, std.math.nan(f64));
    defer allocator.free(not_a_number);
    try testing.expectEqualStrings("neg", not_a_number);

    var quoted = ChoiceFormat.init(allocator);
    defer quoted.deinit();
    try quoted.applyPattern("0#'abc'|1#c");
    const quoted_text = try quoted.formatAlloc(allocator, 0);
    defer allocator.free(quoted_text);
    try testing.expectEqualStrings("'abc'|1#c", quoted_text);
    var quoted_index: usize = 0;
    try testing.expectEqual(
        @as(?f64, null),
        quoted.parse("abc", &quoted_index),
    );
    try testing.expectEqual(@as(usize, 0), quoted_index);

    var escaped = ChoiceFormat.init(allocator);
    defer escaped.deinit();
    try escaped.applyPattern("0#a''b|1#c");
    const escaped_text = try escaped.formatAlloc(allocator, 0);
    defer allocator.free(escaped_text);
    try testing.expectEqualStrings("a''b", escaped_text);
    var escaped_index: usize = 0;
    try testing.expectEqual(
        @as(?f64, 0),
        escaped.parse("a'b", &escaped_index),
    );
    try testing.expectEqual(@as(usize, 3), escaped_index);

    try testing.expectError(
        error.InvalidPattern,
        escaped.applyPattern("0#a|b|1#c"),
    );
    try testing.expectError(
        error.InvalidPattern,
        escaped.applyPattern("a#b"),
    );
}

test "ICU ChoiceFormat conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("choice_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGH", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const valid = fixture[cursor] != 0;
        cursor += 1;
        const pattern_length = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        const pattern = fixture[cursor..][0..pattern_length];
        cursor += pattern_length;

        var format = ChoiceFormat.init(allocator);
        defer format.deinit();
        if (!valid) {
            if (format.applyPattern(pattern)) |_| {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "choice pattern should be invalid: case {d}\n",
                        .{case_index},
                    );
                }
            } else |_| {}
            continue;
        }
        format.applyPattern(pattern) catch {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "choice pattern rejected: case {d}\n",
                    .{case_index},
                );
            }
            continue;
        };
        if (!std.mem.eql(u8, format.toPattern(), pattern)) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "choice pattern mismatch: case {d}\n",
                    .{case_index},
                );
            }
        }

        const format_count = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        var format_index: usize = 0;
        while (format_index < format_count) : (format_index += 1) {
            const value_bits = std.mem.readInt(
                u64,
                fixture[cursor..][0..8],
                .little,
            );
            cursor += 8;
            const value: f64 = @bitCast(value_bits);
            const text_length = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
            const expected = fixture[cursor..][0..text_length];
            cursor += text_length;

            const actual = format.formatAlloc(allocator, value) catch {
                failures += 1;
                continue;
            };
            defer allocator.free(actual);
            if (!std.mem.eql(u8, actual, expected)) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "choice format mismatch: case {d} value {d} got [{s}] want [{s}]\n",
                        .{ case_index, value, actual, expected },
                    );
                }
            }
        }

        const parse_count = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        var parse_index: usize = 0;
        while (parse_index < parse_count) : (parse_index += 1) {
            const text_length = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
            const text = fixture[cursor..][0..text_length];
            cursor += text_length;
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
            const actual = format.parse(text, &index);
            if ((actual != null) != matched) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "choice parse match mismatch: case {d} text [{s}]\n",
                        .{ case_index, text },
                    );
                }
            } else if (actual) |value| {
                const same_bits =
                    @as(u64, @bitCast(value)) ==
                    @as(u64, @bitCast(expected_value));
                if (!same_bits or index != @as(usize, expected_index)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "choice parse mismatch: case {d} text [{s}] got {d}@{d} want {d}@{d}\n",
                            .{
                                case_index,
                                text,
                                value,
                                index,
                                expected_value,
                                expected_index,
                            },
                        );
                    }
                }
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "ChoiceFormat conformance: {}/{} cases passed\n",
        .{ case_count, case_count },
    );
}
