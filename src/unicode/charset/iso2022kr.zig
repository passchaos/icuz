//! ISO-2022-KR decoder and encoder.
//!
//! The stream starts with the `ESC $ ) C` designator. ASCII passes through;
//! Korean text is wrapped in SO (0x0E) and SI (0x0F) and uses KS X 1001
//! 7-bit pairs, which are the EUC-KR bytes minus 0x80.

const std = @import("std");
const cjk = @import("cjk.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

const escape = 0x1B;
const shift_out = 0x0E;
const shift_in = 0x0F;

pub const State = struct {
    designated: bool = false,
    korean: bool = false,
};

fn malformed(index: *usize, start: usize) DecodeResult {
    index.* = start + 1;
    return .{ .malformed = 1 };
}

fn incomplete(index: *usize, start: usize) DecodeResult {
    index.* = start;
    return .incomplete;
}

fn koreanPair(first: u8, second: u8) ?u21 {
    if (first < 0x21 or first > 0x7E or second < 0x21 or second > 0x7E) {
        return null;
    }
    const buffer = [2]u8{ first + 0x80, second + 0x80 };
    var index: usize = 0;
    return switch (cjk.eucKrNext(&buffer, &index)) {
        .codepoint => |codepoint| codepoint,
        else => null,
    };
}

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    while (true) {
        if (index.* >= input.len) return .end;
        const byte = input[index.*];
        if (byte == escape) {
            if (index.* + 3 >= input.len) return incomplete(index, start);
            if (input[index.* + 1] != '$' or
                input[index.* + 2] != ')' or
                input[index.* + 3] != 'C')
            {
                return malformed(index, start);
            }
            state.designated = true;
            state.korean = false;
            index.* += 4;
            continue;
        }
        if (byte == shift_out) {
            if (!state.designated) return malformed(index, start);
            state.korean = true;
            index.* += 1;
            continue;
        }
        if (byte == shift_in) {
            state.korean = false;
            index.* += 1;
            continue;
        }
        if (state.korean) {
            if (index.* + 1 >= input.len) return incomplete(index, start);
            const second = input[index.* + 1];
            const codepoint = koreanPair(byte, second) orelse
                return malformed(index, start);
            index.* += 2;
            return .{ .codepoint = codepoint };
        }
        if (byte > 0x7F) return malformed(index, start);
        index.* += 1;
        return .{ .codepoint = byte };
    }
}

pub fn encode(state: *State, codepoint: u21, out: []u8) EncodeResult {
    var written: u8 = 0;
    if (!state.designated) {
        out[0] = escape;
        out[1] = '$';
        out[2] = ')';
        out[3] = 'C';
        written = 4;
        state.designated = true;
    }

    if (codepoint < 0x80) {
        if (codepoint == escape or codepoint == shift_out or
            codepoint == shift_in)
        {
            return .unmappable;
        }
        if (state.korean) {
            out[written] = shift_in;
            written += 1;
            state.korean = false;
        }
        out[written] = @intCast(codepoint);
        return .{ .written = written + 1 };
    }

    var buffer: [4]u8 = undefined;
    const length = switch (cjk.eucKrEncode(codepoint, &buffer)) {
        .written => |value| value,
        .unmappable => return .unmappable,
    };
    if (length != 2) return .unmappable;
    const first = buffer[0];
    const second = buffer[1];
    if (first < 0xA1 or first > 0xFE or second < 0xA1 or second > 0xFE) {
        return .unmappable;
    }
    if (!state.korean) {
        out[written] = shift_out;
        written += 1;
        state.korean = true;
    }
    out[written] = first - 0x80;
    out[written + 1] = second - 0x80;
    return .{ .written = written + 2 };
}

pub fn flush(state: *State, out: []u8) u8 {
    if (!state.korean) return 0;
    out[0] = shift_in;
    state.korean = false;
    return 1;
}

test "ISO-2022-KR round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "Hello", .encoded = "\x1B$)CHello" },
        .{ .text = "한국어", .encoded = "\x1B$)C\x0EGQ19>n\x0F" },
        .{
            .text = "Hello 한국",
            .encoded = "\x1B$)CHello \x0EGQ19\x0F",
        },
        .{ .text = "A", .encoded = "\x1B$)CA" },
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
        var flush_buffer: [8]u8 = undefined;
        const flushed = flush(&encoder, &flush_buffer);
        try encoded.appendSlice(allocator, flush_buffer[0..flushed]);
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

    var decoder = State{};
    var cursor: usize = 0;
    const ascii = "Hello";
    var decoded = std.ArrayList(u8).empty;
    defer decoded.deinit(allocator);
    while (true) {
        switch (next(&decoder, ascii, &cursor)) {
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
    try testing.expectEqualStrings(ascii, decoded.items);
}
