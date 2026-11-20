//! ISO-2022-CN decoder and encoder.
//!
//! Supports GB 2312 as G1, CNS 11643 plane 1 as G1, and CNS 11643 plane 2
//! as G2. G1 uses SO/SI shifts; G2 uses the single-shift `ESC N`.

const std = @import("std");
const cjk = @import("cjk.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

const escape = 0x1B;
const shift_out = 0x0E;
const shift_in = 0x0F;

pub const G1 = enum { none, gb, cns1 };
pub const G2 = enum { none, cns2 };

pub const State = struct {
    g1: G1 = .none,
    g2: G2 = .none,
    shifted: bool = false,
};

fn malformed(index: *usize, start: usize) DecodeResult {
    index.* = start + 1;
    return .{ .malformed = 1 };
}

fn incomplete(index: *usize, start: usize) DecodeResult {
    index.* = start;
    return .incomplete;
}

fn gbPair(first: u8, second: u8) ?u21 {
    const buffer = [2]u8{ first + 0x80, second + 0x80 };
    var index: usize = 0;
    return switch (cjk.gbkNext(&buffer, &index)) {
        .codepoint => |codepoint| codepoint,
        else => null,
    };
}

fn cnsPair(plane: u8, first: u8, second: u8) ?u21 {
    return tables.euctwForward(plane, first - 0x21, second - 0x21);
}

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    while (true) {
        if (index.* >= input.len) return .end;
        const byte = input[index.*];
        if (byte == escape) {
            if (index.* + 1 >= input.len) return incomplete(index, start);
            const kind = input[index.* + 1];
            if (kind == 0x4E) {
                // Single shift to G2 for one character.
                if (state.g2 != .cns2) return malformed(index, start);
                if (index.* + 3 >= input.len) return incomplete(index, start);
                const first = input[index.* + 2];
                const second = input[index.* + 3];
                if (first < 0x21 or first > 0x7E or second < 0x21 or
                    second > 0x7E)
                {
                    return malformed(index, start);
                }
                const codepoint = cnsPair(1, first, second) orelse
                    return malformed(index, start);
                index.* += 4;
                return .{ .codepoint = codepoint };
            }
            if (kind != '$') return malformed(index, start);
            if (index.* + 3 >= input.len) return incomplete(index, start);
            const third = input[index.* + 2];
            const fourth = input[index.* + 3];
            if (third == ')') {
                state.g1 = switch (fourth) {
                    'A' => .gb,
                    'G' => .cns1,
                    else => return malformed(index, start),
                };
            } else if (third == '*') {
                state.g2 = switch (fourth) {
                    'H' => .cns2,
                    else => return malformed(index, start),
                };
            } else {
                return malformed(index, start);
            }
            index.* += 4;
            continue;
        }
        if (byte == shift_out) {
            if (state.g1 == .none) return malformed(index, start);
            state.shifted = true;
            index.* += 1;
            continue;
        }
        if (byte == shift_in) {
            state.shifted = false;
            index.* += 1;
            continue;
        }
        if (state.shifted) {
            if (index.* + 1 >= input.len) return incomplete(index, start);
            const second = input[index.* + 1];
            if (byte < 0x21 or byte > 0x7E or second < 0x21 or
                second > 0x7E)
            {
                return malformed(index, start);
            }
            const codepoint = switch (state.g1) {
                .gb => gbPair(byte, second),
                .cns1 => cnsPair(0, byte, second),
                .none => null,
            } orelse return malformed(index, start);
            index.* += 2;
            return .{ .codepoint = codepoint };
        }
        if (byte > 0x7F) return malformed(index, start);
        index.* += 1;
        return .{ .codepoint = byte };
    }
}

const Encoded = struct {
    set: G1,
    first: u8,
    second: u8,
};

fn encodeGb(codepoint: u21) ?[2]u8 {
    var buffer: [4]u8 = undefined;
    const length = switch (cjk.gbkEncode(codepoint, &buffer)) {
        .written => |value| value,
        .unmappable => return null,
    };
    if (length != 2) return null;
    if (buffer[0] < 0xA1 or buffer[0] > 0xFE or
        buffer[1] < 0xA1 or buffer[1] > 0xFE)
    {
        return null;
    }
    return .{ buffer[0] - 0x80, buffer[1] - 0x80 };
}

fn encodeCns(codepoint: u21, plane: u8) ?[2]u8 {
    const key = tables.euctwReverse(codepoint) orelse return null;
    if (key >> 14 != plane) return null;
    const row: u8 = @intCast((key >> 7) & 0x7F);
    const cell: u8 = @intCast(key & 0x7F);
    return .{ 0x21 + row, 0x21 + cell };
}

fn findG1(codepoint: u21, current: G1) ?Encoded {
    if (current == .gb) {
        if (encodeGb(codepoint)) |pair| {
            return .{ .set = .gb, .first = pair[0], .second = pair[1] };
        }
    }
    if (current == .cns1) {
        if (encodeCns(codepoint, 0)) |pair| {
            return .{ .set = .cns1, .first = pair[0], .second = pair[1] };
        }
    }
    if (encodeGb(codepoint)) |pair| {
        return .{ .set = .gb, .first = pair[0], .second = pair[1] };
    }
    if (encodeCns(codepoint, 0)) |pair| {
        return .{ .set = .cns1, .first = pair[0], .second = pair[1] };
    }
    return null;
}

pub fn encode(state: *State, codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        if (codepoint == escape or codepoint == shift_out or
            codepoint == shift_in)
        {
            return .unmappable;
        }
        var written: u8 = 0;
        if (state.shifted) {
            out[0] = shift_in;
            written = 1;
            state.shifted = false;
        }
        out[written] = @intCast(codepoint);
        return .{ .written = written + 1 };
    }

    if (findG1(codepoint, state.g1)) |encoded| {
        var written: u8 = 0;
        if (encoded.set != state.g1) {
            out[0] = escape;
            out[1] = '$';
            out[2] = ')';
            out[3] = if (encoded.set == .gb) 'A' else 'G';
            written = 4;
            state.g1 = encoded.set;
        }
        if (!state.shifted) {
            out[written] = shift_out;
            written += 1;
            state.shifted = true;
        }
        out[written] = encoded.first;
        out[written + 1] = encoded.second;
        return .{ .written = written + 2 };
    }

    if (encodeCns(codepoint, 1)) |pair| {
        var written: u8 = 0;
        if (state.shifted) {
            out[written] = shift_in;
            written += 1;
            state.shifted = false;
        }
        if (state.g2 != .cns2) {
            out[written] = escape;
            out[written + 1] = '$';
            out[written + 2] = '*';
            out[written + 3] = 'H';
            written += 4;
            state.g2 = .cns2;
        }
        out[written] = escape;
        out[written + 1] = 'N';
        out[written + 2] = pair[0];
        out[written + 3] = pair[1];
        return .{ .written = written + 4 };
    }

    return .unmappable;
}

pub fn flush(state: *State, out: []u8) u8 {
    if (!state.shifted) return 0;
    out[0] = shift_in;
    state.shifted = false;
    return 1;
}

test "ISO-2022-CN round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{
            .text = "中文",
            .encoded = "\x1B\x24\x29\x41\x0E\x56\x50\x4E\x44\x0F",
        },
        .{
            .text = "測試",
            .encoded = "\x1B\x24\x29\x47\x0E\x60\x41\x66\x5C\x0F",
        },
        .{
            .text = "香港",
            .encoded = "\x1B\x24\x29\x41\x0E\x4F\x63\x38\x5B\x0F",
        },
        .{
            .text = "中文測試",
            .encoded = "\x1B\x24\x29\x41\x0E\x56\x50\x4E\x44" ++
                "\x1B\x24\x29\x47\x60\x41\x66\x5C\x0F",
        },
        .{
            .text = "Hello 中文",
            .encoded = "Hello \x1B\x24\x29\x41\x0E\x56\x50\x4E\x44\x0F",
        },
        .{
            .text = "繁體中文",
            .encoded = "\x1B\x24\x29\x41\x0E\x37\x31" ++
                "\x1B\x24\x29\x47\x7C\x55\x44\x63\x45\x46\x0F",
        },
        .{
            .text = "简体中文",
            .encoded = "\x1B\x24\x29\x41\x0E\x3C\x72\x4C\x65" ++
                "\x56\x50\x4E\x44\x0F",
        },
        .{ .text = "ABC", .encoded = "ABC" },
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
            var buffer: [16]u8 = undefined;
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
