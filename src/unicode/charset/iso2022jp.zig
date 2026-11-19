//! ISO-2022-JP stateful decoder and encoder.
//!
//! Decoding follows the WHATWG state machine closely; the encoder emits
//! JIS X 0208 for everything outside ASCII, Roman, and half-width katakana
//! (mapping half-width katakana to full-width per the WHATWG index).

const std = @import("std");
const tables = @import("tables.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

pub const Mode = enum { ascii, roman, katakana, jis0208 };

pub const State = struct {
    mode: Mode = .ascii,
};

fn malformed(index: *usize, start: usize) DecodeResult {
    index.* = start + 1;
    return .{ .malformed = 1 };
}

fn incomplete(index: *usize, start: usize) DecodeResult {
    index.* = start;
    return .incomplete;
}

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    while (true) {
        if (index.* >= input.len) return .end;
        const byte = input[index.*];
        index.* += 1;

        if (byte == 0x1B) {
            if (index.* >= input.len) return incomplete(index, start);
            const kind = input[index.*];
            index.* += 1;
            if (kind == 0x28) {
                if (index.* >= input.len) return incomplete(index, start);
                const final = input[index.*];
                index.* += 1;
                state.mode = switch (final) {
                    0x42 => .ascii,
                    0x4A => .roman,
                    0x49 => .katakana,
                    else => return malformed(index, start),
                };
            } else if (kind == 0x24) {
                if (index.* >= input.len) return incomplete(index, start);
                const final = input[index.*];
                index.* += 1;
                if (final != 0x40 and final != 0x42) {
                    return malformed(index, start);
                }
                state.mode = .jis0208;
            } else {
                return malformed(index, start);
            }
            continue;
        }

        if (byte == 0x0E or byte == 0x0F) return malformed(index, start);

        switch (state.mode) {
            .ascii => {
                if (byte > 0x7F) return malformed(index, start);
                return .{ .codepoint = byte };
            },
            .roman => {
                if (byte > 0x7F) return malformed(index, start);
                const codepoint: u21 = switch (byte) {
                    0x5C => 0x00A5,
                    0x7E => 0x203E,
                    else => byte,
                };
                return .{ .codepoint = codepoint };
            },
            .katakana => {
                if (byte < 0x21 or byte > 0x5F) return malformed(index, start);
                return .{ .codepoint = @as(u21, 0xFF61) + byte - 0x21 };
            },
            .jis0208 => {
                if (byte < 0x21 or byte > 0x7E) return malformed(index, start);
                if (index.* >= input.len) return incomplete(index, start);
                const second = input[index.*];
                index.* += 1;
                if (second < 0x21 or second > 0x7E) {
                    return malformed(index, start);
                }
                const pointer = (@as(u32, byte) - 0x21) * 94 +
                    (@as(u32, second) - 0x21);
                const codepoint = tables.forwardLookup(
                    tables.jis0208_forward,
                    pointer,
                ) orelse return malformed(index, start);
                return .{ .codepoint = codepoint };
            },
        }
    }
}

pub fn encode(state: *State, codepoint: u21, out: []u8) EncodeResult {
    if (codepoint == 0x0E or codepoint == 0x0F or codepoint == 0x1B) {
        return .unmappable;
    }

    if (codepoint < 0x80) {
        if (state.mode == .ascii) {
            out[0] = @intCast(codepoint);
            return .{ .written = 1 };
        }
        out[0] = 0x1B;
        out[1] = 0x28;
        out[2] = 0x42;
        state.mode = .ascii;
        out[3] = @intCast(codepoint);
        return .{ .written = 4 };
    }

    if (codepoint == 0x00A5 or codepoint == 0x203E) {
        const byte: u8 = if (codepoint == 0x00A5) 0x5C else 0x7E;
        if (state.mode == .roman) {
            out[0] = byte;
            return .{ .written = 1 };
        }
        out[0] = 0x1B;
        out[1] = 0x28;
        out[2] = 0x4A;
        state.mode = .roman;
        out[3] = byte;
        return .{ .written = 4 };
    }

    var target = codepoint;
    if (target == 0x2212) target = 0xFF0D;
    if (target >= 0xFF61 and target <= 0xFF9F) {
        target = tables.forwardLookup(
            tables.iso2022jp_katakana_forward,
            target - 0xFF61,
        ) orelse return .unmappable;
    }

    const pointer = tables.reverseLookupPaged(
        tables.jis0208_reverse,
        &tables.jis0208_reverse_pages,
        target,
    ) orelse
        return .unmappable;
    const lead: u8 = @intCast(pointer / 94 + 0x21);
    const trail: u8 = @intCast(pointer % 94 + 0x21);
    if (state.mode == .jis0208) {
        out[0] = lead;
        out[1] = trail;
        return .{ .written = 2 };
    }
    out[0] = 0x1B;
    out[1] = 0x24;
    out[2] = 0x42;
    state.mode = .jis0208;
    out[3] = lead;
    out[4] = trail;
    return .{ .written = 5 };
}

/// Emit the trailing ASCII escape when the encoder is not in ASCII mode.
pub fn flush(state: *State, out: []u8) u8 {
    if (state.mode == .ascii) return 0;
    state.mode = .ascii;
    out[0] = 0x1B;
    out[1] = 0x28;
    out[2] = 0x42;
    return 3;
}

test "ISO-2022-JP round trip" {
    const testing = @import("std").testing;

    const text = "\xE3\x81\x93\xE3\x82\x93\xE3\x81\xAB\xE3\x81\xA1\xE3\x81\xAF";
    var encoded: [64]u8 = undefined;
    var encoder_state: State = .{};
    var length: usize = 0;
    var utf8_index: usize = 0;
    while (utf8_index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(
            text[utf8_index],
        ) catch unreachable;
        const codepoint = std.unicode.utf8Decode(
            text[utf8_index..][0..sequence_length],
        ) catch unreachable;
        utf8_index += sequence_length;
        const result = encode(&encoder_state, codepoint, encoded[length..]);
        switch (result) {
            .written => |count| length += count,
            .unmappable => return error.TestUnexpectedResult,
        }
    }
    length += flush(&encoder_state, encoded[length..]);
    try testing.expectEqualSlices(
        u8,
        &.{
            0x1B, 0x24, 0x42, 0x24, 0x33, 0x24, 0x73, 0x24,
            0x4B, 0x24, 0x41, 0x24, 0x4F, 0x1B, 0x28, 0x42,
        },
        encoded[0..length],
    );

    var decoder_state: State = .{};
    var decoded: [64]u8 = undefined;
    var decoded_length: usize = 0;
    var index: usize = 0;
    while (true) {
        switch (next(&decoder_state, encoded[0..length], &index)) {
            .codepoint => |codepoint| {
                var buffer: [4]u8 = undefined;
                const count = std.unicode.utf8Encode(codepoint, &buffer) catch
                    return error.TestUnexpectedResult;
                @memcpy(decoded[decoded_length..][0..count], buffer[0..count]);
                decoded_length += count;
            },
            .end => break,
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqualStrings(text, decoded[0..decoded_length]);
}
