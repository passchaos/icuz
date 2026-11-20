//! EUC-TW decoder and encoder.

const std = @import("std");
const tables = @import("tables.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

fn malformed(index: *usize, consumed: usize) DecodeResult {
    index.* += consumed;
    return .{ .malformed = @intCast(consumed) };
}

pub fn next(_: void, input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    if (start >= input.len) return .end;
    const first = input[start];
    if (first < 0x80) {
        index.* = start + 1;
        return .{ .codepoint = first };
    }
    if (first == 0x8E) {
        if (start + 3 >= input.len) return .incomplete;
        const plane_byte = input[start + 1];
        const row = input[start + 2];
        const cell = input[start + 3];
        if (plane_byte < 0xA1 or plane_byte > 0xB0 or
            row < 0xA1 or row > 0xFE or cell < 0xA1 or cell > 0xFE)
        {
            return malformed(index, 4);
        }
        const codepoint = tables.euctwForward(
            plane_byte - 0xA1,
            row - 0xA1,
            cell - 0xA1,
        ) orelse return malformed(index, 4);
        index.* = start + 4;
        return .{ .codepoint = codepoint };
    }
    if (first < 0xA1 or first > 0xFE) return malformed(index, 1);
    if (start + 1 >= input.len) return .incomplete;
    const second = input[start + 1];
    if (second < 0xA1 or second > 0xFE) return malformed(index, 2);
    const codepoint = tables.euctwForward(0, first - 0xA1, second - 0xA1) orelse
        return malformed(index, 2);
    index.* = start + 2;
    return .{ .codepoint = codepoint };
}

pub fn encode(_: void, codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    const key = tables.euctwReverse(codepoint) orelse return .unmappable;
    const plane: u8 = @intCast(key >> 14);
    const row: u8 = @intCast((key >> 7) & 0x7F);
    const cell: u8 = @intCast(key & 0x7F);
    if (plane == 0) {
        out[0] = 0xA1 + row;
        out[1] = 0xA1 + cell;
        return .{ .written = 2 };
    }
    out[0] = 0x8E;
    out[1] = 0xA1 + plane;
    out[2] = 0xA1 + row;
    out[3] = 0xA1 + cell;
    return .{ .written = 4 };
}

test "EUC-TW round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "中文測試", .encoded = "\xC4\xE3\xC5\xC6\xE0\xC1\xE6\xDC" },
        .{ .text = "香港", .encoded = "\xD3\xFC\xE0\xAB" },
        .{ .text = "€", .encoded = "\xC2\xC2" },
        .{
            .text = "Hello 中文",
            .encoded = "Hello \xC4\xE3\xC5\xC6",
        },
        .{ .text = "𠀋", .encoded = "\x8E\xA3\xA1\xC4" },
        .{ .text = "㐀", .encoded = "\x8E\xA6\xA2\xAC" },
    };

    for (cases) |case| {
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
            const written = switch (encode({}, codepoint, &buffer)) {
                .written => |value| value,
                .unmappable => return error.TestUnexpectedResult,
            };
            try encoded.appendSlice(allocator, buffer[0..written]);
        }
        try testing.expectEqualStrings(case.encoded, encoded.items);

        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(allocator);
        var cursor: usize = 0;
        while (true) {
            switch (next({}, case.encoded, &cursor)) {
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
