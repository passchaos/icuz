//! Unicode 17.0 default word-boundary iterator (UAX #29, WB1–WB999).
//!
//! The iterator reports every boundary segment. `is_word` is an orthogonal
//! editor-facing classification: punctuation and whitespace remain observable
//! to conformance callers, while compatibility collectors can retain only
//! segments that contain a selectable letter, number, connector, Katakana, or
//! ideographic scalar.

const std = @import("std");
const rules = @import("rules.zig");
const scalar = @import("../scalar/root.zig");
const dictionary = @import("dictionary.zig");
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
        const first_packed = scalar.decodeValidPacked(self.text, start);
        const first_codepoint = scalar.packedCodepoint(first_packed);
        var end = start + scalar.packedLength(first_packed);
        const first_properties = properties(first_codepoint);
        var previous_codepoint = first_codepoint;
        var previous_start = start;
        var previous_properties = first_properties;
        var is_word = first_properties.word_anchor;
        var regional_indicator_count: usize =
            if (first_properties.class == .regional_indicator) 1 else 0;
        while (end < self.text.len) {
            if (asciiBreaksAt(self.text, end)) |should_break| {
                if (should_break) break;
                if (asciiIsWordAnchor(self.text[end])) is_word = true;
                regional_indicator_count = 0;
                previous_codepoint = self.text[end];
                previous_start = end;
                previous_properties = properties(self.text[end]);
                end += 1;
                continue;
            }
            const current_packed = scalar.decodeValidPacked(self.text, end);
            const current_codepoint = scalar.packedCodepoint(current_packed);
            const current_next = end + scalar.packedLength(current_packed);
            const current_properties = properties(current_codepoint);
            if (breaksAt(
                self.text,
                end,
                previous_codepoint,
                previous_start,
                previous_properties,
                current_next,
                current_properties,
                regional_indicator_count,
            )) break;
            is_word = is_word or current_properties.word_anchor;
            if (current_properties.class == .regional_indicator) {
                regional_indicator_count += 1;
            } else if (!isIgnored(current_properties.class)) {
                regional_indicator_count = 0;
            }
            previous_codepoint = current_codepoint;
            previous_start = end;
            previous_properties = current_properties;
            end = current_next;
        }
        self.cursor = end;
        return .{
            .byte_start = start,
            .byte_len = end - start,
            .is_word = is_word,
        };
    }
};

/// Word iterator that applies ICU-style dictionary segmentation to Thai, Lao,
/// Khmer, Burmese, and CJK runs. Other text uses the UAX #29 default rules.
pub const DictionaryIterator = struct {
    text: []const u8,
    cursor: usize = 0,
    cached_breaks: [dictionary.max_run_codepoints + 1]usize = undefined,
    cached_count: usize = 0,
    cached_index: usize = 0,

    pub fn next(self: *DictionaryIterator) ?Segment {
        if (self.cursor >= self.text.len) return null;
        if (self.cached_index < self.cached_count and
            self.cursor < self.cached_breaks[self.cached_index])
        {
            const end = self.cached_breaks[self.cached_index];
            self.cached_index += 1;
            return self.makeSegment(self.cursor, end);
        }

        const first = decode(self.text, self.cursor) orelse return null;
        const language = dictionary.languageForCodepoint(first.codepoint) orelse {
            var fallback = Iterator{ .text = self.text[self.cursor..] };
            const segment = fallback.next() orelse return null;
            const start = self.cursor;
            self.cursor = start + segment.byte_len;
            return .{
                .byte_start = start,
                .byte_len = segment.byte_len,
                .is_word = segment.is_word,
            };
        };

        var run_end = first.next;
        var codepoint_count: usize = 1;
        while (run_end < self.text.len and
            codepoint_count < dictionary.max_run_codepoints)
        {
            const decoded = decode(self.text, run_end) orelse break;
            if (!dictionary.isRunCodepoint(language, decoded.codepoint)) break;
            run_end = decoded.next;
            codepoint_count += 1;
        }

        const count = if (language == .cjk)
            dictionary.segmentCjk(
                self.text,
                self.cursor,
                run_end,
                &self.cached_breaks,
            )
        else
            dictionary.segmentSoutheastAsian(
                language,
                self.text,
                self.cursor,
                run_end,
                &self.cached_breaks,
            );
        self.cached_count = count;
        self.cached_index = 0;
        if (count == 0 or self.cached_breaks[count - 1] < run_end) {
            if (count < self.cached_breaks.len) {
                self.cached_breaks[count] = run_end;
                self.cached_count += 1;
            }
        }
        if (self.cached_count == 0) {
            const start = self.cursor;
            self.cursor = run_end;
            return self.makeSegment(start, run_end);
        }
        const end = self.cached_breaks[0];
        self.cached_index = 1;
        return self.makeSegment(self.cursor, end);
    }

    fn makeSegment(self: *DictionaryIterator, start: usize, end: usize) Segment {
        var is_word = false;
        var cursor = start;
        while (cursor < end) {
            const decoded = decode(self.text, cursor) orelse break;
            if (properties(decoded.codepoint).word_anchor) {
                is_word = true;
                break;
            }
            cursor = decoded.next;
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

const ascii_word_anchors = blk: {
    var table = [_]bool{false} ** 128;
    for ('0'..'9' + 1) |byte| table[byte] = true;
    for ('A'..'Z' + 1) |byte| table[byte] = true;
    for ('a'..'z' + 1) |byte| table[byte] = true;
    table['_'] = true;
    break :blk table;
};

fn asciiIsWordAnchor(byte: u8) bool {
    return ascii_word_anchors[byte];
}

const ascii_classes = blk: {
    var table = [_]Class{.other} ** 128;
    table['\r'] = .cr;
    table['\n'] = .lf;
    table[0x0b] = .newline;
    table[0x0c] = .newline;
    table[' '] = .wseg_space;
    table['"'] = .double_quote;
    table['\''] = .single_quote;
    table[','] = .mid_num;
    table[';'] = .mid_num;
    table['.'] = .mid_num_let;
    table[':'] = .mid_letter;
    for ('0'..'9' + 1) |byte| table[byte] = .numeric;
    for ('A'..'Z' + 1) |byte| table[byte] = .a_letter;
    for ('a'..'z' + 1) |byte| table[byte] = .a_letter;
    table['_'] = .extend_num_let;
    break :blk table;
};

fn asciiClass(byte: u8) Class {
    return ascii_classes[byte];
}

pub fn segments(text: []const u8) Error!Iterator {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return assumeValid(text);
}

pub fn assumeValid(text: []const u8) Iterator {
    scalar.assertValidUtf8(text);
    return .{ .text = text };
}

pub fn segmentsWithDictionaries(text: []const u8) Error!DictionaryIterator {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return assumeValidWithDictionaries(text);
}

pub fn assumeValidWithDictionaries(text: []const u8) DictionaryIterator {
    scalar.assertValidUtf8(text);
    return .{ .text = text };
}

fn breaksAt(
    text: []const u8,
    offset: usize,
    previous_actual_codepoint: u21,
    previous_actual_start: usize,
    previous_actual_properties: rules.Properties,
    current_next: usize,
    current_properties: rules.Properties,
    regional_indicator_count: usize,
) bool {
    if (rules.adjacentBreak(previous_actual_properties, current_properties)) |decision|
        return decision;

    // The previous scalar is usually not ignored, so the caller's decode and
    // property lookup can be reused for the significant-neighbour scan.
    const previous = if (isIgnored(previous_actual_properties.class))
        previousSignificant(text, offset) orelse return true
    else
        Decoded{
            .codepoint = previous_actual_codepoint,
            .start = previous_actual_start,
            .next = offset,
        };
    const previous_properties = if (previous.start == previous_actual_start)
        previous_actual_properties
    else
        properties(previous.codepoint);
    const previous_class = previous_properties.class;
    if (isNewline(previous_class)) return true;
    const current_class = current_properties.class;
    // Only the mid-letter and Hebrew double-quote rules look at the scalars
    // beyond the pair; ordinary letters, numbers, and spaces decide without
    // the two extra decodes and property lookups.
    const previous_previous_class = if (isLetterMid(previous_class) or
        isNumericMid(previous_class) or previous_class == .double_quote)
    previous: {
        const decoded = previousSignificant(text, previous.start) orelse
            break :previous Class.other;
        break :previous properties(decoded.codepoint).class;
    } else Class.other;
    const next_class = if (rules.needsLookahead(previous_class, current_class)) next: {
        const decoded = nextSignificant(text, current_next) orelse
            break :next Class.other;
        break :next properties(decoded.codepoint).class;
    } else Class.other;

    return rules.significantBreak(
        previous_class,
        previous_previous_class,
        current_class,
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
    // The iterator's contract is valid UTF-8 (`segments` validates up front),
    // so the fast non-validating decoder is used.
    const decoded = scalar.decodeValid(text, offset) orelse return null;
    return .{ .codepoint = decoded.codepoint, .start = offset, .next = decoded.next };
}

fn decodeBefore(text: []const u8, offset: usize) ?Decoded {
    if (offset == 0 or offset > text.len) return null;
    var start = offset - 1;
    while (start != 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    const decoded = decode(text, start) orelse return null;
    if (decoded.next != offset) return null;
    return decoded;
}

test "dictionary word segmentation iterator" {
    const testing = @import("std").testing;
    const cases = [_]struct {
        text: []const u8,
        expected: []const []const u8,
    }{
        .{ .text = "ภาษาไทย", .expected = &.{ "ภาษา", "ไทย" } },
        .{ .text = "ພາສາລາວ", .expected = &.{ "ພາສາ", "ລາວ" } },
        .{ .text = "ភាសាខ្មែរ", .expected = &.{"ភាសាខ្មែរ"} },
        .{ .text = "မြန်မာဘာသာ", .expected = &.{"မြန်မာဘာသာ"} },
        .{
            .text = "中华人民共和国",
            .expected = &.{ "中华", "人民", "共和国" },
        },
        .{
            .text = "中华人民共和国日本語東京都",
            .expected = &.{ "中华", "人民", "共和国", "日本語", "東京", "都" },
        },
        .{
            .text = "ภาษาไทยประเทศไทย",
            .expected = &.{ "ภาษา", "ไทย", "ประเทศไทย" },
        },
        .{ .text = "東京都", .expected = &.{ "東京", "都" } },
        .{
            .text = "Hello ภาษาไทย world",
            .expected = &.{ "Hello", " ", "ภาษา", "ไทย", " ", "world" },
        },
        .{ .text = "กรุงเทพฯ", .expected = &.{"กรุงเทพฯ"} },
        .{ .text = "จริงๆ", .expected = &.{"จริงๆ"} },
        .{ .text = "ดีๆ", .expected = &.{"ดีๆ"} },
        .{ .text = "アイウエオ", .expected = &.{"アイウエオ"} },
        .{ .text = "テストデータ", .expected = &.{ "テスト", "データ" } },
    };
    for (cases) |case| {
        var iterator = assumeValidWithDictionaries(case.text);
        var start: usize = 0;
        for (case.expected) |expected| {
            const segment = iterator.next() orelse
                return error.TestUnexpectedResult;
            try testing.expectEqual(start, segment.byte_start);
            const actual = case.text[segment.byte_start..][0..segment.byte_len];
            try testing.expectEqualStrings(expected, actual);
            if (!std.mem.eql(u8, expected, " ")) {
                try testing.expect(segment.is_word);
            }
            start = segment.byte_start + segment.byte_len;
        }
        try testing.expect(iterator.next() == null);
        try testing.expectEqual(case.text.len, start);
    }
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

test "dictionary segmentation conformance" {
    const fixture = @embedFile("dictionary_conformance.bin");
    if (fixture.len < 12 or !std.mem.eql(u8, fixture[0..4], "CJDW") or
        fixture[4] != 1 or fixture[5] != 0 or fixture[6] != 0 or
        fixture[7] != 0)
    {
        return error.InvalidFixture;
    }
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var offset: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |case_index| {
        if (offset + 4 > fixture.len) return error.InvalidFixture;
        const source_len = std.mem.readInt(
            u16,
            fixture[offset..][0..2],
            .little,
        );
        const segment_count = std.mem.readInt(
            u16,
            fixture[offset + 2 ..][0..2],
            .little,
        );
        offset += 4;
        if (offset + source_len + @as(usize, segment_count) * 2 >
            fixture.len)
        {
            return error.InvalidFixture;
        }
        const source = fixture[offset..][0..source_len];
        offset += source_len;
        const lengths_offset = offset;
        offset += @as(usize, segment_count) * 2;

        var iterator = assumeValidWithDictionaries(source);
        var expected_start: usize = 0;
        var segment_index: usize = 0;
        while (iterator.next()) |segment| {
            if (segment_index >= segment_count) {
                failures += 1;
                break;
            }
            const expected_len = std.mem.readInt(
                u16,
                fixture[lengths_offset + segment_index * 2 ..][0..2],
                .little,
            );
            const expected_end = expected_start + expected_len;
            const actual = source[segment.byte_start..][0..segment.byte_len];
            if (expected_end > source.len or
                !std.mem.eql(
                    u8,
                    source[expected_start..expected_end],
                    actual,
                ))
            {
                failures += 1;
                if (failures <= 20) {
                    std.debug.print(
                        "dictionary case {d} segment {d}: expected {s}, got {s}\n",
                        .{
                            case_index,
                            segment_index,
                            source[expected_start..@min(expected_end, source.len)],
                            actual,
                        },
                    );
                }
            }
            expected_start = expected_end;
            segment_index += 1;
        }
        if (segment_index != segment_count or expected_start != source.len) {
            failures += 1;
        }
    }
    if (offset != fixture.len) return error.InvalidFixture;
    if (failures != 0) return error.TestUnexpectedResult;
}
