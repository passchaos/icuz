//! UTF-7 (RFC 2152) decoder and encoder.
//!
//! Direct ASCII passes through unchanged; everything else uses modified
//! base64 runs introduced by `+` and terminated by `-`. `+` itself is
//! written as `+-`.

const std = @import("std");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

pub const State = struct {
    shifted: bool = false,
    bits: u64 = 0,
    bit_count: u8 = 0,
};

fn isDirect(codepoint: u21) bool {
    if (codepoint > 0x7F) return false;
    return switch (codepoint) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '\'', '(', ')', ',', '-', '.', '/', ':', '?', ' ', '\t', '\r', '\n' => true,
        '!', '"', '#', '$', '%', '&', '*', ';', '<', '=', '>', '@', '[', ']', '^', '_', '`', '{', '|', '}' => true,
        else => false,
    };
}

fn base64Value(byte: u8) ?u6 {
    return switch (byte) {
        'A'...'Z' => @intCast(byte - 'A'),
        'a'...'z' => @intCast(byte - 'a' + 26),
        '0'...'9' => @intCast(byte - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

fn base64Char(value: u6) u8 {
    return switch (value) {
        0...25 => 'A' + @as(u8, value),
        26...51 => 'a' + @as(u8, value - 26),
        52...61 => '0' + @as(u8, value - 52),
        62 => '+',
        63 => '/',
    };
}

fn peekUnit(state: *const State) u16 {
    const shift: u6 = @intCast(state.bit_count - 16);
    return @intCast((state.bits >> shift) & 0xffff);
}

fn dropBits(state: *State, count: u8) void {
    state.bit_count -= count;
    if (state.bit_count == 0) {
        state.bits = 0;
    } else {
        state.bits &= (@as(u64, 1) << @as(u6, @intCast(state.bit_count))) - 1;
    }
}

fn emitUnit(state: *State) DecodeResult {
    const unit = peekUnit(state);
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        if (state.bit_count < 32) return .incomplete;
        const shift: u6 = @intCast(state.bit_count - 32);
        const low: u16 = @intCast((state.bits >> shift) & 0xffff);
        if (low < 0xDC00 or low > 0xDFFF) {
            dropBits(state, 16);
            return .{ .malformed = 1 };
        }
        dropBits(state, 32);
        const codepoint: u21 = 0x10000 +
            (@as(u21, unit - 0xD800) << 10) +
            (low - 0xDC00);
        return .{ .codepoint = codepoint };
    }
    dropBits(state, 16);
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        return .{ .malformed = 1 };
    }
    return .{ .codepoint = unit };
}

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    while (true) {
        if (state.bit_count >= 16) {
            const unit = peekUnit(state);
            if (unit >= 0xD800 and unit <= 0xDBFF and state.bit_count < 32) {
                return .incomplete;
            }
            return emitUnit(state);
        }
        if (state.shifted) {
            const start = index.*;
            var cursor = start;
            while (cursor < input.len) {
                const digit = base64Value(input[cursor]) orelse break;
                state.bits = (state.bits << 6) | digit;
                state.bit_count += 6;
                cursor += 1;
                if (state.bit_count >= 16) {
                    const unit = peekUnit(state);
                    if (unit < 0xD800 or unit > 0xDBFF or
                        state.bit_count >= 32)
                    {
                        break;
                    }
                }
            }
            if (cursor == input.len) {
                // Keep the partial run; the caller can append more input.
                return .incomplete;
            }
            const terminator = input[cursor];
            if (state.bit_count >= 16) {
                const unit = peekUnit(state);
                if (unit >= 0xD800 and unit <= 0xDBFF and
                    state.bit_count < 32)
                {
                    index.* = if (terminator == '-') cursor + 1 else cursor;
                    state.bits = 0;
                    state.bit_count = 0;
                    state.shifted = false;
                    return .{ .malformed = 1 };
                }
                index.* = cursor;
                return emitUnit(state);
            }
            if (terminator == '-') {
                if (state.bits != 0) {
                    index.* = cursor + 1;
                    state.bits = 0;
                    state.bit_count = 0;
                    state.shifted = false;
                    return .{ .malformed = 1 };
                }
                index.* = cursor + 1;
                state.shifted = false;
                continue;
            }
            if (state.bits != 0) {
                index.* = cursor;
                state.bits = 0;
                state.bit_count = 0;
                state.shifted = false;
                return .{ .malformed = 1 };
            }
            index.* = cursor;
            state.shifted = false;
            continue;
        }
        if (index.* >= input.len) return .end;
        const start = index.*;
        const byte = input[start];
        if (byte == '+') {
            if (start + 1 >= input.len) return .incomplete;
            if (input[start + 1] == '-') {
                index.* = start + 2;
                return .{ .codepoint = '+' };
            }
            state.shifted = true;
            state.bits = 0;
            state.bit_count = 0;
            index.* = start + 1;
            continue;
        }
        index.* = start + 1;
        if (byte < 0x80) return .{ .codepoint = byte };
        return .{ .malformed = 1 };
    }
}

fn flushShift(state: *State, out: []u8, terminate: bool) u8 {
    var written: u8 = 0;
    if (state.bit_count > 0) {
        const shift: u6 = @intCast(6 - state.bit_count);
        out[written] = base64Char(@intCast((state.bits << shift) & 0x3f));
        written += 1;
    }
    if (terminate) {
        out[written] = '-';
        written += 1;
    }
    state.shifted = false;
    state.bits = 0;
    state.bit_count = 0;
    return written;
}

pub fn encode(state: *State, codepoint: u21, out: []u8) EncodeResult {
    if (isDirect(codepoint)) {
        var written: u8 = 0;
        if (state.shifted) {
            const ambiguous = codepoint == '-' or
                (codepoint < 0x80 and base64Value(@intCast(codepoint)) != null);
            written += flushShift(state, out, ambiguous);
        }
        out[written] = @intCast(codepoint);
        return .{ .written = written + 1 };
    }
    if (codepoint == '+') {
        var written: u8 = 0;
        if (state.shifted) written += flushShift(state, out, true);
        out[written] = '+';
        out[written + 1] = '-';
        return .{ .written = written + 2 };
    }

    var units: [2]u16 = undefined;
    var unit_count: usize = 1;
    if (codepoint <= 0xFFFF) {
        units[0] = @intCast(codepoint);
    } else {
        const value = codepoint - 0x10000;
        units[0] = @intCast(0xD800 + (value >> 10));
        units[1] = @intCast(0xDC00 + (value & 0x3FF));
        unit_count = 2;
    }

    var written: u8 = 0;
    if (!state.shifted) {
        out[written] = '+';
        written += 1;
        state.shifted = true;
        state.bits = 0;
        state.bit_count = 0;
    }
    for (units[0..unit_count]) |unit| {
        state.bits = (state.bits << 16) | unit;
        state.bit_count += 16;
        while (state.bit_count >= 6) {
            const shift: u6 = @intCast(state.bit_count - 6);
            out[written] = base64Char(@intCast((state.bits >> shift) & 0x3f));
            written += 1;
            dropBits(state, 6);
        }
    }
    return .{ .written = written };
}

pub fn flush(state: *State, out: []u8) u8 {
    if (!state.shifted) return 0;
    return flushShift(state, out, true);
}

test "UTF-7 round trip and RFC examples" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "Hello, World!", .encoded = "Hello, World!" },
        .{ .text = "Hi Mom -☺-!", .encoded = "Hi Mom -+Jjo--!" },
        .{ .text = "+", .encoded = "+-" },
        .{ .text = "€", .encoded = "+IKw-" },
        .{ .text = "😀", .encoded = "+2D3eAA-" },
        .{ .text = "a€b", .encoded = "a+IKw-b" },
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
}
