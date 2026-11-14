//! Unicode 17.0 default word-boundary iterator (UAX #29, WB1–WB999).
//!
//! The iterator reports every boundary segment. `is_word` is an orthogonal
//! editor-facing classification: punctuation and whitespace remain observable
//! to conformance callers, while compatibility collectors can retain only
//! segments that contain a selectable letter, number, connector, Katakana, or
//! ideographic scalar.

const std = @import("std");
const rules = @import("rules.zig");
const test_data = @embedFile("conformance.bin");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{InvalidUtf8};

pub const Segment = struct {
    byte_start: usize,
    byte_len: usize,
    is_word: bool,
};

const Class = rules.Class;
const properties = rules.properties;
const isNewline = rules.isNewline;
const isIgnored = rules.isIgnored;
const isAhLetter = rules.isAhLetter;
const isLetterMid = rules.isLetterMid;
const isNumericMid = rules.isNumericMid;
const isExtendNumLetLeft = rules.isExtendNumLetLeft;
const isExtendNumLetRight = rules.isExtendNumLetRight;

pub const Iterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn next(self: *Iterator) ?Segment {
        if (self.cursor >= self.text.len) return null;

        const start = self.cursor;
        const first = decode(self.text, start) orelse unreachable;
        var end = first.next;
        const first_properties = properties(first.codepoint);
        var is_word = first_properties.word_anchor;
        var regional_indicator_count: usize =
            if (first_properties.class == .regional_indicator) 1 else 0;
        while (end < self.text.len) {
            const should_break = asciiBreaksAt(self.text, end) orelse breaksAt(
                self.text,
                end,
                regional_indicator_count,
            );
            if (should_break) break;
            const current = decode(self.text, end) orelse unreachable;
            const current_properties = properties(current.codepoint);
            is_word = is_word or current_properties.word_anchor;
            if (current_properties.class == .regional_indicator) {
                regional_indicator_count += 1;
            } else if (!isIgnored(current_properties.class)) {
                regional_indicator_count = 0;
            }
            end = current.next;
        }
        self.cursor = end;
        return .{
            .byte_start = start,
            .byte_len = end - start,
            .is_word = is_word,
        };
    }
};

fn asciiBreaksAt(text: []const u8, offset: usize) ?bool {
    const current_byte = text[offset];
    const previous_byte = text[offset - 1];
    if (current_byte >= 0x80 or previous_byte >= 0x80) return null;

    const previous = asciiClass(previous_byte);
    const current = asciiClass(current_byte);
    // WB3–WB3d. No ASCII scalar has WB=Extend/Format/ZWJ, so WB4 needs no
    // special handling in this path.
    if (previous == .cr and current == .lf) return false;
    if (isNewline(previous) or isNewline(current)) return true;
    if (previous == .wseg_space and current == .wseg_space) return false;
    // WB5.
    if (isAhLetter(previous) and isAhLetter(current)) return false;

    const next = if (offset + 1 < text.len) next: {
        if (text[offset + 1] >= 0x80) {
            if (isLetterMid(current) or isNumericMid(current)) return null;
            break :next Class.other;
        }
        break :next asciiClass(text[offset + 1]);
    } else Class.other;
    const previous_previous = if (offset >= 2) previous: {
        if (text[offset - 2] >= 0x80) {
            if (isLetterMid(previous) or isNumericMid(previous)) return null;
            break :previous Class.other;
        }
        break :previous asciiClass(text[offset - 2]);
    } else Class.other;

    // WB6 / WB7.
    if (isAhLetter(previous) and isLetterMid(current) and
        isAhLetter(next)) return false;
    if (isAhLetter(previous_previous) and isLetterMid(previous) and
        isAhLetter(current)) return false;
    // WB8–WB12.
    if (previous == .numeric and current == .numeric) return false;
    if (isAhLetter(previous) and current == .numeric) return false;
    if (previous == .numeric and isAhLetter(current)) return false;
    if (previous_previous == .numeric and isNumericMid(previous) and
        current == .numeric) return false;
    if (previous == .numeric and isNumericMid(current) and
        next == .numeric) return false;
    // WB13a / WB13b.
    if (isExtendNumLetLeft(previous) and current == .extend_num_let) return false;
    if (previous == .extend_num_let and isExtendNumLetRight(current)) return false;
    return true;
}

fn asciiClass(byte: u8) Class {
    return switch (byte) {
        '\r' => .cr,
        '\n' => .lf,
        0x0b, 0x0c => .newline,
        ' ' => .wseg_space,
        '"' => .double_quote,
        '\'' => .single_quote,
        ',', ';' => .mid_num,
        '.' => .mid_num_let,
        ':' => .mid_letter,
        '0'...'9' => .numeric,
        'A'...'Z', 'a'...'z' => .a_letter,
        '_' => .extend_num_let,
        else => .other,
    };
}

pub fn segments(text: []const u8) Error!Iterator {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return assumeValid(text);
}

pub fn assumeValid(text: []const u8) Iterator {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    return .{ .text = text };
}

fn breaksAt(
    text: []const u8,
    offset: usize,
    regional_indicator_count: usize,
) bool {
    const previous_actual = decodeBefore(text, offset) orelse unreachable;
    const current = decode(text, offset) orelse unreachable;
    const previous_actual_properties = properties(previous_actual.codepoint);
    const current_properties = properties(current.codepoint);

    if (rules.adjacentBreak(previous_actual_properties, current_properties)) |decision|
        return decision;

    const previous = previousSignificant(text, offset) orelse return true;
    const previous_properties = properties(previous.codepoint);
    if (isNewline(previous_properties.class)) return true;
    const previous_previous = previousSignificant(text, previous.start);
    const previous_previous_class = if (previous_previous) |decoded|
        properties(decoded.codepoint).class
    else
        Class.other;
    const next = nextSignificant(text, current.next);
    const next_class = if (next) |decoded|
        properties(decoded.codepoint).class
    else
        Class.other;

    return rules.significantBreak(
        previous_properties.class,
        previous_previous_class,
        current_properties.class,
        next_class,
        regional_indicator_count % 2 == 1,
    );
}

const Decoded = struct {
    codepoint: u21,
    start: usize,
    next: usize,
};

fn previousSignificant(text: []const u8, offset: usize) ?Decoded {
    var cursor = offset;
    while (decodeBefore(text, cursor)) |decoded| {
        if (!isIgnored(properties(decoded.codepoint).class)) return decoded;
        cursor = decoded.start;
    }
    return null;
}

fn nextSignificant(text: []const u8, offset: usize) ?Decoded {
    var cursor = offset;
    while (decode(text, cursor)) |decoded| {
        if (!isIgnored(properties(decoded.codepoint).class)) return decoded;
        cursor = decoded.next;
    }
    return null;
}

fn decode(text: []const u8, offset: usize) ?Decoded {
    if (offset >= text.len) return null;
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return null;
    if (offset + sequence_len > text.len) return null;
    const codepoint = std.unicode.utf8Decode(text[offset .. offset + sequence_len]) catch
        return null;
    return .{ .codepoint = codepoint, .start = offset, .next = offset + sequence_len };
}

fn decodeBefore(text: []const u8, offset: usize) ?Decoded {
    if (offset == 0 or offset > text.len) return null;
    var start = offset - 1;
    while (start != 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    const decoded = decode(text, start) orelse return null;
    if (decoded.next != offset) return null;
    return decoded;
}

test "Unicode 17 word-boundary conformance" {
    if (test_data.len < 12 or !std.mem.eql(u8, test_data[0..4], "CJWT") or
        test_data[4] != 1 or test_data[5] != unicode_version[0] or
        test_data[6] != unicode_version[1] or test_data[7] != unicode_version[2])
    {
        return error.InvalidFixture;
    }

    const case_count = std.mem.readInt(u32, test_data[8..12], .little);
    try std.testing.expectEqual(@as(u32, 1944), case_count);
    var offset: usize = 12;
    for (0..case_count) |case_index| {
        const count = test_data[offset];
        offset += 1;
        const expected = test_data[offset..][0 .. @as(usize, count) + 1];
        offset += @as(usize, count) + 1;
        const codepoint_bytes = test_data[offset..][0 .. @as(usize, count) * 4];
        offset += @as(usize, count) * 4;

        var utf8: [128]u8 = undefined;
        var utf8_len: usize = 0;
        var expected_offsets: [32]usize = undefined;
        var expected_count: usize = 0;
        if (expected[0] != 0) {
            expected_offsets[expected_count] = 0;
            expected_count += 1;
        }
        for (0..count) |index| {
            const codepoint: u21 = @intCast(std.mem.readInt(
                u32,
                codepoint_bytes[index * 4 ..][0..4],
                .little,
            ));
            utf8_len += try std.unicode.utf8Encode(codepoint, utf8[utf8_len..]);
            if (expected[index + 1] != 0) {
                expected_offsets[expected_count] = utf8_len;
                expected_count += 1;
            }
        }

        var iterator = assumeValid(utf8[0..utf8_len]);
        var actual_count: usize = 1;
        while (iterator.next()) |segment| {
            const actual_end = segment.byte_start + segment.byte_len;
            if (actual_count >= expected_count or
                expected_offsets[actual_count] != actual_end)
            {
                std.debug.print(
                    "word case={d} boundary={d} expected={d} actual={d}\n",
                    .{
                        case_index,
                        actual_count,
                        expected_offsets[actual_count],
                        actual_end,
                    },
                );
                return error.WordBreakConformanceMismatch;
            }
            actual_count += 1;
        }
        try std.testing.expectEqual(expected_count, actual_count);
    }
    try std.testing.expectEqual(test_data.len, offset);
}
