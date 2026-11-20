//! SCSU (UTS #6) decoder and encoder.
//!
//! The decoder implements the full command set, dynamic and extended
//! windows, Unicode mode, and quoted UTF-16 units. The encoder emits a
//! valid but simple stream using static-window quotes and `SQU` for
//! everything else.

const std = @import("std");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

const static_offsets = [_]u32{
    0x0000,
    0x0080,
    0x0100,
    0x0300,
    0x2000,
    0x2080,
    0x2100,
    0x3000,
};

const initial_dynamic_offsets = [_]u32{
    0x0080,
    0x00C0,
    0x0400,
    0x0600,
    0x0900,
    0x3040,
    0x30A0,
    0xFF00,
};

const fixed_offsets = [_]u32{
    0x00C0,
    0x0250,
    0x0370,
    0x0530,
    0x3040,
    0x30A0,
    0xFF60,
};

const gap_offset: u32 = 0xAC00;

pub const State = struct {
    single_byte: bool = true,
    dynamic: [8]u32 = initial_dynamic_offsets,
    selected: u8 = 0,
};

fn dynamicOffsetFromByte(byte: u8) ?u32 {
    if (byte == 0) return null;
    if (byte < 0x68) return @as(u32, byte) << 7;
    if (byte < 0xA8) return (@as(u32, byte) << 7) + gap_offset;
    if (byte < 0xF9) return null;
    return fixed_offsets[byte - 0xF9];
}

fn resultFromCodepoint(codepoint: u32) DecodeResult {
    if (codepoint > 0x10FFFF or
        (codepoint >= 0xD800 and codepoint <= 0xDFFF))
    {
        return .{ .malformed = 1 };
    }
    return .{ .codepoint = @intCast(codepoint) };
}

fn readUnit(input: []const u8, offset: usize) ?u16 {
    if (offset > input.len or input.len - offset < 2) return null;
    return (@as(u16, input[offset]) << 8) | input[offset + 1];
}

fn quotedCommand(state: *const State) u8 {
    return if (state.single_byte) 0x0E else 0xF0;
}

fn combineSurrogates(high: u16, low: u16) ?u21 {
    if (high < 0xD800 or high > 0xDBFF or low < 0xDC00 or low > 0xDFFF) {
        return null;
    }
    return 0x10000 +
        (@as(u21, high - 0xD800) << 10) +
        (low - 0xDC00);
}

fn emitQuoted(
    state: *const State,
    input: []const u8,
    index: *usize,
    unit: u16,
) DecodeResult {
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        const command = quotedCommand(state);
        const next_unit = readUnit(input, index.* + 1);
        if (next_unit == null or input[index.*] != command) {
            return .{ .malformed = 1 };
        }
        const low = next_unit.?;
        const codepoint = combineSurrogates(unit, low) orelse
            return .{ .malformed = 1 };
        index.* += 3;
        return .{ .codepoint = codepoint };
    }
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        return .{ .malformed = 1 };
    }
    return .{ .codepoint = unit };
}

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    while (true) {
        if (index.* >= input.len) return .end;
        if (state.single_byte) {
            const byte = input[index.*];
            if (byte == 0x00 or byte == 0x09 or byte == 0x0A or byte == 0x0D) {
                index.* += 1;
                return .{ .codepoint = byte };
            }
            if (byte >= 0x01 and byte <= 0x08) {
                if (index.* + 1 >= input.len) return .incomplete;
                const window: usize = byte - 0x01;
                const next_byte = input[index.* + 1];
                const codepoint = if (next_byte < 0x80)
                    static_offsets[window] + next_byte
                else
                    state.dynamic[window] + (next_byte & 0x7F);
                index.* += 2;
                return resultFromCodepoint(codepoint);
            }
            if (byte == 0x0B) {
                if (index.* + 2 >= input.len) return .incomplete;
                const first = input[index.* + 1];
                const second = input[index.* + 2];
                const window: usize = (first >> 5) & 7;
                state.dynamic[window] = 0x10000 +
                    ((@as(u32, first & 0x1F) << 15) |
                        (@as(u32, second) << 7));
                state.selected = @intCast(window);
                index.* += 3;
                continue;
            }
            if (byte == 0x0C) {
                index.* += 1;
                return .{ .malformed = 1 };
            }
            if (byte == 0x0E) {
                if (index.* + 2 >= input.len) return .incomplete;
                const unit = readUnit(input, index.* + 1).?;
                index.* += 3;
                return emitQuoted(state, input, index, unit);
            }
            if (byte == 0x0F) {
                state.single_byte = false;
                index.* += 1;
                continue;
            }
            if (byte >= 0x10 and byte <= 0x17) {
                state.selected = byte - 0x10;
                index.* += 1;
                continue;
            }
            if (byte >= 0x18 and byte <= 0x1F) {
                if (index.* + 1 >= input.len) return .incomplete;
                const offset = dynamicOffsetFromByte(input[index.* + 1]) orelse {
                    index.* += 2;
                    return .{ .malformed = 2 };
                };
                const window: usize = byte - 0x18;
                state.dynamic[window] = offset;
                state.selected = @intCast(window);
                index.* += 2;
                continue;
            }
            if (byte >= 0x20 and byte <= 0x7F) {
                index.* += 1;
                return .{ .codepoint = byte };
            }
            const codepoint = state.dynamic[state.selected] + (byte & 0x7F);
            index.* += 1;
            return resultFromCodepoint(codepoint);
        }

        const byte = input[index.*];
        if (byte >= 0xE0 and byte <= 0xE7) {
            state.selected = byte - 0xE0;
            state.single_byte = true;
            index.* += 1;
            continue;
        }
        if (byte >= 0xE8 and byte <= 0xEF) {
            if (index.* + 1 >= input.len) return .incomplete;
            const offset = dynamicOffsetFromByte(input[index.* + 1]) orelse {
                index.* += 2;
                return .{ .malformed = 2 };
            };
            const window: usize = byte - 0xE8;
            state.dynamic[window] = offset;
            state.selected = @intCast(window);
            state.single_byte = true;
            index.* += 2;
            continue;
        }
        if (byte == 0xF0) {
            if (index.* + 2 >= input.len) return .incomplete;
            const unit = readUnit(input, index.* + 1).?;
            index.* += 3;
            return emitQuoted(state, input, index, unit);
        }
        if (byte == 0xF1) {
            if (index.* + 2 >= input.len) return .incomplete;
            const first = input[index.* + 1];
            const second = input[index.* + 2];
            const window: usize = (first >> 5) & 7;
            state.dynamic[window] = 0x10000 +
                ((@as(u32, first & 0x1F) << 15) |
                    (@as(u32, second) << 7));
            state.selected = @intCast(window);
            state.single_byte = true;
            index.* += 3;
            continue;
        }
        if (byte == 0xF2) {
            index.* += 1;
            return .{ .malformed = 1 };
        }
        if (index.* + 1 >= input.len) return .incomplete;
        const unit = readUnit(input, index.*).?;
        index.* += 2;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (index.* + 1 >= input.len) {
                return .{ .malformed = 2 };
            }
            const low = readUnit(input, index.*).?;
            const codepoint = combineSurrogates(unit, low) orelse
                return .{ .malformed = 2 };
            index.* += 2;
            return .{ .codepoint = codepoint };
        }
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return .{ .malformed = 2 };
        }
        return .{ .codepoint = unit };
    }
}

fn writeQuoted(codepoint: u21, out: []u8) u8 {
    if (codepoint <= 0xFFFF) {
        out[0] = 0x0E;
        out[1] = @intCast(codepoint >> 8);
        out[2] = @intCast(codepoint & 0xFF);
        return 3;
    }
    const value = codepoint - 0x10000;
    const high: u16 = @intCast(0xD800 + (value >> 10));
    const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
    out[0] = 0x0E;
    out[1] = @intCast(high >> 8);
    out[2] = @intCast(high & 0xFF);
    out[3] = 0x0E;
    out[4] = @intCast(low >> 8);
    out[5] = @intCast(low & 0xFF);
    return 6;
}

pub fn encode(_: *State, codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        if (codepoint >= 0x20 or codepoint == 0x00 or codepoint == 0x09 or
            codepoint == 0x0A or codepoint == 0x0D)
        {
            out[0] = @intCast(codepoint);
            return .{ .written = 1 };
        }
        return .{ .written = writeQuoted(codepoint, out) };
    }
    var index: usize = 0;
    while (index < static_offsets.len) : (index += 1) {
        const base = static_offsets[index];
        if (codepoint >= base and codepoint <= base + 0x7F) {
            out[0] = @intCast(0x01 + index);
            out[1] = @intCast(codepoint - base);
            return .{ .written = 2 };
        }
    }
    return .{ .written = writeQuoted(codepoint, out) };
}

pub fn flush(_: *State, _: []u8) u8 {
    return 0;
}

test "SCSU round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_][]const u8{
        "Hello, World!",
        "Привет",
        "日本語テスト",
        "😀😁😂",
        "€£¥",
        "\x00\t\n\r",
        "→←↑↓",
        "𝕳𝖊𝖑𝖑𝖔",
        "a\u{0301}b",
        "ééêë",
    };

    for (cases) |text| {
        var encoder = State{};
        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(allocator);
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
                return error.TestUnexpectedResult;
            const codepoint = try std.unicode.utf8Decode(
                text[index..][0..length],
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

        var decoder = State{};
        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(allocator);
        var cursor: usize = 0;
        while (true) {
            switch (next(&decoder, encoded.items, &cursor)) {
                .end => break,
                .codepoint => |codepoint| {
                    var buffer: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
                        return error.TestUnexpectedResult;
                    try decoded.appendSlice(allocator, buffer[0..length]);
                },
                .malformed, .incomplete => {
                    std.debug.print(
                        "scsu decode failed: text [{s}] encoded {any} cursor {d}\n",
                        .{ text, encoded.items, cursor },
                    );
                    return error.TestUnexpectedResult;
                },
            }
        }
        try testing.expectEqualStrings(text, decoded.items);
    }
}
