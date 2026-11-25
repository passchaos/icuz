//! Unicode 17.0 default sentence-boundary iterator (UAX #29, SB1–SB998).
//!
//! The iterator owns no allocation and returns every segment, including
//! segments containing only separators or formatting controls. Higher-level
//! collectors may filter blank segments, but they must not alter the boundary
//! state machine.

const std = @import("std");
const rules = @import("rules.zig");
const scalar = @import("../scalar/root.zig");
const test_data = @embedFile("conformance.bin");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{InvalidUtf8};

pub const Segment = struct {
    byte_start: usize,
    byte_len: usize,
};

const Class = rules.Class;
const BoundaryState = rules.BoundaryState;
const classForCodepoint = rules.classForCodepoint;
const isParagraphSeparator = rules.isParagraphSeparator;
const isLetter = rules.isLetter;

pub const Iterator = struct {
    text: []const u8,
    cursor: usize = 0,
    /// SB8 can inspect beyond the next candidate boundary. Candidate offsets
    /// only move forward, so one cached decision interval makes all such
    /// lookahead linear even for adversarial repeated-terminator input.
    lower_scan_end: usize = 0,
    lower_scan_result: bool = false,

    pub fn next(self: *Iterator) ?Segment {
        if (self.cursor >= self.text.len) return null;
        const start = self.cursor;
        const first = scalar.decodeValidPacked(self.text, start);
        var state = BoundaryState{};
        state.consume(classForCodepoint(scalar.packedCodepoint(first)));

        var end = start + scalar.packedLength(first);
        while (end < self.text.len) {
            // ASCII prose dominates sentence scanning; classify the byte
            // directly and keep the decoded-struct path for other scripts.
            if (self.text[end] < 0x80) {
                const current_class = classForCodepoint(self.text[end]);
                if (!isParagraphSeparator(state.previous_actual)) {
                    // SB4 has been ruled out, so no letter or space can
                    // start a boundary. Consume whole ASCII runs instead of
                    // re-running the rule chain for every byte.
                    if (state.terminator == null and isLetter(current_class)) {
                        // A terminator-free state makes every letter
                        // boundary-free: SB6/SB7 need a terminator and
                        // SB8-SB11 return early without one.
                        var last = current_class;
                        var previous = state.last_significant;
                        end += 1;
                        while (end < self.text.len and self.text[end] < 0x80) {
                            const next_class = classForCodepoint(
                                self.text[end],
                            );
                            if (!isLetter(next_class)) break;
                            previous = last;
                            last = next_class;
                            end += 1;
                        }
                        state.previous_actual = last;
                        state.previous_significant = previous;
                        state.last_significant = last;
                        continue;
                    }
                    if (current_class == .space) {
                        // SB10 never breaks before a space, and a space run
                        // only sets `saw_space` when a terminator is pending.
                        // Every space still shifts the significant classes,
                        // exactly like a single `consume` call.
                        var spaces: usize = 1;
                        end += 1;
                        while (end < self.text.len and
                            self.text[end] == ' ') : (end += 1)
                        {
                            spaces += 1;
                        }
                        state.previous_actual = .space;
                        if (state.terminator) |*terminator| {
                            terminator.saw_space = true;
                        }
                        if (spaces > 1) {
                            state.previous_significant = .space;
                        } else {
                            state.previous_significant = state.last_significant;
                        }
                        state.last_significant = .space;
                        continue;
                    }
                }
                if (state.terminator == null and
                    !isParagraphSeparator(state.previous_actual))
                {
                    // SB998: without a pending terminator and with no
                    // separator on the left there is no break here.
                    state.consume(current_class);
                    end += 1;
                    continue;
                }
                if (self.breaksAt(end, current_class, &state)) break;
                state.consume(current_class);
                end += 1;
                continue;
            }
            const value = decode(self.text, end) orelse unreachable;
            const current_class = classForCodepoint(scalar.packedCodepoint(value));
            // Without a pending terminator and with no separator on the
            // left, SB998 makes every boundary here a non-break. Letters are
            // consumed as a run; any other class just updates the state.
            if (state.terminator == null and
                !isParagraphSeparator(state.previous_actual))
            {
                if (isLetter(current_class)) {
                    var last = current_class;
                    var previous = state.last_significant;
                    end += scalar.packedLength(value);
                    while (end < self.text.len) {
                        const next_value = decode(self.text, end) orelse break;
                        const next_class = classForCodepoint(
                            scalar.packedCodepoint(next_value),
                        );
                        if (!isLetter(next_class)) break;
                        previous = last;
                        last = next_class;
                        end += scalar.packedLength(next_value);
                    }
                    state.previous_actual = last;
                    state.previous_significant = previous;
                    state.last_significant = last;
                    continue;
                }
                state.consume(current_class);
                end += scalar.packedLength(value);
                continue;
            }
            if (self.breaksAt(end, current_class, &state)) break;
            state.consume(current_class);
            end += scalar.packedLength(value);
        }
        self.cursor = end;
        return .{ .byte_start = start, .byte_len = end - start };
    }

    fn breaksAt(
        self: *Iterator,
        offset: usize,
        current: Class,
        state: *const BoundaryState,
    ) bool {
        if (rules.immediateBreak(current, state)) |decision| return decision;
        const lower_follows = if (state.terminator) |terminator|
            terminator.class == .a_term and self.lowerFollows(offset)
        else
            false;
        return rules.contextualBreak(current, state, lower_follows);
    }

    fn lowerFollows(self: *Iterator, offset: usize) bool {
        if (offset <= self.lower_scan_end) return self.lower_scan_result;

        var cursor = offset;
        while (decode(self.text, cursor)) |value| {
            const class = classForCodepoint(scalar.packedCodepoint(value));
            if (class == .lower) {
                self.lower_scan_end = cursor;
                self.lower_scan_result = true;
                return true;
            }
            if (class == .other_letter or class == .upper or
                isParagraphSeparator(class))
            {
                self.lower_scan_end = cursor;
                self.lower_scan_result = false;
                return false;
            }
            cursor += scalar.packedLength(value);
        }
        self.lower_scan_end = self.text.len;
        self.lower_scan_result = false;
        return false;
    }
};

pub fn segments(text: []const u8) Error!Iterator {
    if (!scalar.validate.isValid(text)) return error.InvalidUtf8;
    return assumeValid(text);
}

pub fn assumeValid(text: []const u8) Iterator {
    scalar.assertValidUtf8(text);
    return .{ .text = text };
}

/// Packed decode for the iterator's hot loops. The packed form keeps the
/// codepoint and length in one register, so the loop avoids spilling a
/// three-field struct. The iterator's contract guarantees valid UTF-8.
fn decode(text: []const u8, offset: usize) ?u32 {
    // Two-byte sequences dominate the non-ASCII scalars of sentence text
    // (accented Latin, Hebrew, Arabic, Greek, Cyrillic); skip the general
    // length ladder for them.
    if (offset + 2 <= text.len) {
        const first = text[offset];
        if (first >= 0xc2 and first <= 0xdf) {
            const codepoint = (@as(u32, first & 0x1f) << 6) |
                (text[offset + 1] & 0x3f);
            return ((codepoint + 1) << 3) | 1;
        }
    }
    const value = scalar.decodeValidPacked(text, offset);
    if (value == scalar.packed_invalid) return null;
    return value;
}

test "Unicode 17 sentence-boundary conformance" {
    if (test_data.len < 12 or !std.mem.eql(u8, test_data[0..4], "CJST") or
        test_data[4] != 1 or test_data[5] != unicode_version[0] or
        test_data[6] != unicode_version[1] or test_data[7] != unicode_version[2])
    {
        return error.InvalidFixture;
    }
    const case_count = std.mem.readInt(u32, test_data[8..12], .little);
    try std.testing.expectEqual(@as(u32, 512), case_count);

    var offset: usize = 12;
    for (0..case_count) |case_index| {
        const count = test_data[offset];
        offset += 1;
        const expected = test_data[offset..][0 .. @as(usize, count) + 1];
        offset += @as(usize, count) + 1;
        const codepoint_bytes = test_data[offset..][0 .. @as(usize, count) * 4];
        offset += @as(usize, count) * 4;

        var utf8: [256]u8 = undefined;
        var utf8_len: usize = 0;
        var expected_offsets: [64]usize = undefined;
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
                    "sentence case={d} boundary={d} expected={d} actual={d}\n",
                    .{
                        case_index,
                        actual_count,
                        if (actual_count < expected_count)
                            expected_offsets[actual_count]
                        else
                            std.math.maxInt(usize),
                        actual_end,
                    },
                );
                return error.SentenceBreakConformanceMismatch;
            }
            actual_count += 1;
        }
        try std.testing.expectEqual(expected_count, actual_count);
    }
    try std.testing.expectEqual(test_data.len, offset);
}
