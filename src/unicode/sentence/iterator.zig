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
        const first = decode(self.text, start) orelse unreachable;
        var state = BoundaryState{};
        state.consume(classForCodepoint(first.codepoint));

        var end = first.next;
        while (end < self.text.len) {
            const current = if (self.text[end] < 0x80)
                Decoded{
                    .codepoint = self.text[end],
                    .start = end,
                    .next = end + 1,
                }
            else
                decode(self.text, end) orelse unreachable;
            const current_class = classForCodepoint(current.codepoint);
            if (self.breaksAt(end, current_class, state)) break;
            state.consume(current_class);
            end = current.next;
        }
        self.cursor = end;
        return .{ .byte_start = start, .byte_len = end - start };
    }

    fn breaksAt(
        self: *Iterator,
        offset: usize,
        current: Class,
        state: BoundaryState,
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
        while (decode(self.text, cursor)) |decoded| {
            const class = classForCodepoint(decoded.codepoint);
            if (class == .lower) {
                self.lower_scan_end = decoded.start;
                self.lower_scan_result = true;
                return true;
            }
            if (class == .other_letter or class == .upper or
                isParagraphSeparator(class))
            {
                self.lower_scan_end = decoded.start;
                self.lower_scan_result = false;
                return false;
            }
            cursor = decoded.next;
        }
        self.lower_scan_end = self.text.len;
        self.lower_scan_result = false;
        return false;
    }
};

pub fn segments(text: []const u8) Error!Iterator {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return assumeValid(text);
}

pub fn assumeValid(text: []const u8) Iterator {
    scalar.assertValidUtf8(text);
    return .{ .text = text };
}

const Decoded = struct {
    codepoint: u21,
    start: usize,
    next: usize,
};

fn decode(text: []const u8, offset: usize) ?Decoded {
    const decoded = scalar.decodeValid(text, offset) orelse return null;
    return .{
        .codepoint = decoded.codepoint,
        .start = offset,
        .next = decoded.next,
    };
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
