//! BOCU-1 (UTS #4) decoder and encoder.
//!
//! BOCU-1 encodes code point differences with a 1..4 byte variable-length
//! scheme. C0 controls and space are encoded directly; everything else is
//! a difference from the previous code point, with special "prev" anchors
//! for Hiragana, Unihan, and Hangul runs.

const std = @import("std");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

const ascii_prev: i32 = 0x40;
const min: i32 = 0x21;
const middle: i32 = 0x90;
const reset: i32 = 0xFF;
const trail_controls_count: i32 = 20;
const trail_byte_offset: i32 = 0x0D;
const trail_count: i32 = 243;
const reach_pos_1: i32 = 63;
const reach_neg_1: i32 = -64;
const lead_2: i32 = 43;
const lead_3: i32 = 3;
const reach_pos_2: i32 = reach_pos_1 + lead_2 * trail_count;
const reach_neg_2: i32 = reach_neg_1 - lead_2 * trail_count;
const reach_pos_3: i32 = reach_pos_2 + lead_3 * trail_count * trail_count;
const reach_neg_3: i32 = reach_neg_2 - lead_3 * trail_count * trail_count;
const start_pos_2: i32 = middle + reach_pos_1 + 1;
const start_pos_3: i32 = start_pos_2 + lead_2;
const start_pos_4: i32 = start_pos_3 + lead_3;
const start_neg_2: i32 = middle + reach_neg_1;
const start_neg_3: i32 = start_neg_2 - lead_2;
const start_neg_4: i32 = start_neg_3 - lead_3;

const byte_to_trail = [_]i8{
    -1,   0x00, 0x01, 0x02, 0x03, 0x04, 0x05, -1,
    -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
    0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
    0x0E, 0x0F, -1,   -1,   0x10, 0x11, 0x12, 0x13,
    -1,
};

const trail_to_byte = [_]u8{
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x10, 0x11,
    0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
    0x1C, 0x1D, 0x1E, 0x1F,
};

pub const State = struct {
    prev: i32 = ascii_prev,
};

fn trailToByte(trail: i32) u8 {
    if (trail >= trail_controls_count) {
        return @intCast(trail + trail_byte_offset);
    }
    return trail_to_byte[@intCast(trail)];
}

fn byteToTrail(byte: i32) i32 {
    if (byte <= 0x20) return byte_to_trail[@intCast(byte)];
    return byte - trail_byte_offset;
}

fn prevFor(codepoint: i32) i32 {
    if (codepoint >= 0x3040 and codepoint <= 0x309F) return 0x3070;
    if (codepoint >= 0x4E00 and codepoint <= 0x9FA5) {
        return 0x4E00 - reach_neg_2;
    }
    if (codepoint >= 0xAC00 and codepoint <= 0xD7A3) {
        return (0xD7A3 + 0xAC00) / 2;
    }
    return (codepoint & -0x80) + ascii_prev;
}

fn negDivMod(value: *i32, divisor: i32) i32 {
    var remainder = @rem(value.*, divisor);
    value.* = @divTrunc(value.*, divisor);
    if (remainder < 0) {
        value.* -= 1;
        remainder += divisor;
    }
    return remainder;
}

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    while (true) {
        if (index.* >= input.len) return .end;
        const lead: i32 = input[index.*];
        if (lead <= 0x20) {
            index.* += 1;
            if (lead != 0x20) state.prev = ascii_prev;
            return .{ .codepoint = @intCast(lead) };
        }
        if (lead == reset) {
            index.* += 1;
            state.prev = ascii_prev;
            continue;
        }
        var length: usize = undefined;
        if (lead >= start_neg_2 and lead < start_pos_2) {
            length = 1;
        } else if (lead >= start_neg_3 and lead < start_pos_3) {
            length = 2;
        } else if (lead >= start_neg_4 and lead < start_pos_4) {
            length = 3;
        } else {
            length = 4;
        }
        if (index.* + length > input.len) return .incomplete;

        var diff: i32 = undefined;
        if (length == 1) {
            diff = lead - middle;
        } else if (length == 2) {
            if (lead >= start_pos_2) {
                diff = (lead - start_pos_2) * trail_count + reach_pos_1 + 1;
            } else {
                diff = (lead - start_neg_2) * trail_count + reach_neg_1;
            }
        } else if (length == 3) {
            if (lead >= start_pos_3) {
                diff = (lead - start_pos_3) * trail_count * trail_count +
                    reach_pos_2 + 1;
            } else {
                diff = (lead - start_neg_3) * trail_count * trail_count +
                    reach_neg_2;
            }
        } else {
            if (lead >= start_pos_4) {
                diff = reach_pos_3 + 1;
            } else {
                diff = -trail_count * trail_count * trail_count + reach_neg_3;
            }
        }

        var offset = index.* + 1;
        var remaining = length - 1;
        var multiplier: i32 = 1;
        var power: usize = 1;
        while (power < remaining) : (power += 1) {
            multiplier *= trail_count;
        }
        while (remaining > 0) : (remaining -= 1) {
            const trail = byteToTrail(input[offset]);
            if (trail < 0) {
                index.* += 1;
                return .{ .malformed = 1 };
            }
            diff += trail * multiplier;
            offset += 1;
            multiplier = @divTrunc(multiplier, trail_count);
        }

        const codepoint = state.prev + diff;
        index.* += length;
        if (codepoint < 0 or codepoint > 0x10FFFF or
            (codepoint >= 0xD800 and codepoint <= 0xDFFF))
        {
            return .{ .malformed = @intCast(length) };
        }
        state.prev = prevFor(codepoint);
        return .{ .codepoint = @intCast(codepoint) };
    }
}

pub fn encode(state: *State, codepoint: u21, out: []u8) EncodeResult {
    const value: i32 = codepoint;
    if (value <= 0x20) {
        out[0] = @intCast(value);
        if (value != 0x20) state.prev = ascii_prev;
        return .{ .written = 1 };
    }

    var diff = value - state.prev;
    if (diff >= reach_neg_1 and diff <= reach_pos_1) {
        out[0] = @intCast(middle + diff);
        state.prev = prevFor(value);
        return .{ .written = 1 };
    }

    var written: u8 = 0;
    if (diff > 0) {
        if (diff <= reach_pos_2) {
            diff -= reach_pos_1 + 1;
            const low = @rem(diff, trail_count);
            diff = @divTrunc(diff, trail_count);
            out[0] = @intCast(start_pos_2 + diff);
            out[1] = trailToByte(low);
            written = 2;
        } else if (diff <= reach_pos_3) {
            diff -= reach_pos_2 + 1;
            const low = @rem(diff, trail_count);
            diff = @divTrunc(diff, trail_count);
            const middle_trail = @rem(diff, trail_count);
            diff = @divTrunc(diff, trail_count);
            out[0] = @intCast(start_pos_3 + diff);
            out[1] = trailToByte(middle_trail);
            out[2] = trailToByte(low);
            written = 3;
        } else {
            diff -= reach_pos_3 + 1;
            const low = @rem(diff, trail_count);
            diff = @divTrunc(diff, trail_count);
            const middle_trail = @rem(diff, trail_count);
            diff = @divTrunc(diff, trail_count);
            const high = @rem(diff, trail_count);
            out[0] = @intCast(start_pos_4);
            out[1] = trailToByte(high);
            out[2] = trailToByte(middle_trail);
            out[3] = trailToByte(low);
            written = 4;
        }
    } else {
        if (diff >= reach_neg_2) {
            diff -= reach_neg_1;
            const low = negDivMod(&diff, trail_count);
            out[0] = @intCast(start_neg_2 + diff);
            out[1] = trailToByte(low);
            written = 2;
        } else if (diff >= reach_neg_3) {
            diff -= reach_neg_2;
            const low = negDivMod(&diff, trail_count);
            const middle_trail = negDivMod(&diff, trail_count);
            out[0] = @intCast(start_neg_3 + diff);
            out[1] = trailToByte(middle_trail);
            out[2] = trailToByte(low);
            written = 3;
        } else {
            diff -= reach_neg_3;
            const low = negDivMod(&diff, trail_count);
            const middle_trail = negDivMod(&diff, trail_count);
            const high = diff + trail_count;
            out[0] = @intCast(min);
            out[1] = trailToByte(high);
            out[2] = trailToByte(middle_trail);
            out[3] = trailToByte(low);
            written = 4;
        }
    }
    state.prev = prevFor(value);
    return .{ .written = written };
}

pub fn flush(_: *State, _: []u8) u8 {
    return 0;
}

test "BOCU-1 matches ICU encodings" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "Hello", .encoded = "\x98\xB5\xBC\xBC\xBF" },
        .{
            .text = "Hello, World!",
            .encoded = "\x98\xB5\xBC\xBC\xBF\x7C\x20\xA7\xBF\xC2\xBC\xB4\x71",
        },
        .{
            .text = "Привет",
            .encoded = "\xD3\xD3\x90\x88\x82\x85\x92",
        },
        .{
            .text = "日本語テスト",
            .encoded = "\xFB\x4C\xD4\x3F\x8B\xE4\x5E\x24\xE1\x40\x89\x98",
        },
        .{
            .text = "😀😁😂",
            .encoded = "\xFC\xFF\x5D\x51\x52",
        },
        .{
            .text = "€£¥",
            .encoded = "\xF1\xE6\x2E\x76\x75",
        },
        .{ .text = "\x00\t\n\r", .encoded = "\x00\x09\x0A\x0D" },
        .{
            .text = "→←↑↓",
            .encoded = "\xF2\xD9\x60\x61\x63",
        },
        .{
            .text = "𝕳𝖊𝖑𝖑𝖔",
            .encoded = "\xFC\xDD\x13\xD0\x14\x61\x61\x64",
        },
        .{
            .text = "a\u{0301}b",
            .encoded = "\xB1\xD2\xA8\x4D\x48",
        },
        .{
            .text = "café naïve",
            .encoded = "\xB3\xB1\xB6\xD0\x76\x20\x4F\xEE\xB1\xD0\x7C\x4F\xF6\xB5",
        },
        .{ .text = "", .encoded = "" },
    };

    for (cases) |case| {
        var encoder = State{};
        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(allocator);
        var index: usize = 0;
        while (index < case.text.len) {
            const length = std.unicode.utf8ByteSequenceLength(
                case.text[index],
            ) catch return error.TestUnexpectedResult;
            const codepoint = try std.unicode.utf8Decode(
                case.text[index..][0..length],
            );
            index += length;
            var buffer: [8]u8 = undefined;
            const written = switch (encode(&encoder, codepoint, &buffer)) {
                .written => |value| value,
                .unmappable => return error.TestUnexpectedResult,
            };
            try encoded.appendSlice(allocator, buffer[0..written]);
        }
        try testing.expectEqualStrings(case.encoded, encoded.items);

        var decoder = State{};
        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(allocator);
        var cursor: usize = 0;
        while (true) {
            switch (next(&decoder, case.encoded, &cursor)) {
                .end => break,
                .codepoint => |codepoint| {
                    var buffer: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
                        return error.TestUnexpectedResult;
                    try decoded.appendSlice(allocator, buffer[0..length]);
                },
                .malformed, .incomplete => return error.TestUnexpectedResult,
            }
        }
        try testing.expectEqualStrings(case.text, decoded.items);
    }
}
