//! HZ (RFC 1843) decoder and encoder.
//!
//! ASCII passes through directly; GB2312 characters are written between
//! `~{` and `~}`. `~~` represents a literal `~`, and `~\n` is a line
//! continuation.

const std = @import("std");
const cjk = @import("cjk.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

pub const State = struct {
    gb: bool = false,
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

pub fn next(state: *State, input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    while (true) {
        if (index.* >= input.len) return .end;
        const byte = input[index.*];
        if (byte == '~') {
            if (index.* + 1 >= input.len) return incomplete(index, start);
            const kind = input[index.* + 1];
            switch (kind) {
                '~' => {
                    index.* += 2;
                    return .{ .codepoint = '~' };
                },
                '\n' => {
                    index.* += 2;
                    continue;
                },
                '{' => {
                    index.* += 2;
                    state.gb = true;
                    continue;
                },
                '}' => {
                    index.* += 2;
                    state.gb = false;
                    continue;
                },
                else => return malformed(index, start),
            }
        }
        if (!state.gb) {
            if (byte > 0x7F) return malformed(index, start);
            index.* += 1;
            return .{ .codepoint = byte };
        }
        if (byte < 0x21 or byte > 0x7E) return malformed(index, start);
        if (index.* + 1 >= input.len) return incomplete(index, start);
        const second = input[index.* + 1];
        if (second < 0x21 or second > 0x7E) return malformed(index, start);
        const codepoint = gbPair(byte, second) orelse
            return malformed(index, start);
        index.* += 2;
        return .{ .codepoint = codepoint };
    }
}

pub fn encode(state: *State, codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        var written: u8 = 0;
        if (state.gb) {
            out[written] = '~';
            out[written + 1] = '}';
            written += 2;
            state.gb = false;
        }
        if (codepoint == '~') {
            out[written] = '~';
            out[written + 1] = '~';
            return .{ .written = written + 2 };
        }
        out[written] = @intCast(codepoint);
        return .{ .written = written + 1 };
    }

    var buffer: [4]u8 = undefined;
    const length = switch (cjk.gbkEncode(codepoint, &buffer)) {
        .written => |value| value,
        .unmappable => return .unmappable,
    };
    if (length != 2) return .unmappable;
    const first = buffer[0];
    const second = buffer[1];
    if (first < 0xA1 or first > 0xFE or second < 0xA1 or second > 0xFE) {
        return .unmappable;
    }

    var written: u8 = 0;
    if (!state.gb) {
        out[written] = '~';
        out[written + 1] = '{';
        written += 2;
        state.gb = true;
    }
    out[written] = first - 0x80;
    out[written + 1] = second - 0x80;
    return .{ .written = written + 2 };
}

pub fn flush(state: *State, out: []u8) u8 {
    if (!state.gb) return 0;
    out[0] = '~';
    out[1] = '}';
    state.gb = false;
    return 2;
}

test "HZ round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "Hello", .encoded = "Hello" },
        .{ .text = "中国", .encoded = "~{VP9z~}" },
        .{ .text = "a~b", .encoded = "a~~b" },
        .{ .text = "中国abc", .encoded = "~{VP9z~}abc" },
        .{ .text = "中文~test", .encoded = "~{VPND~}~~test" },
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
