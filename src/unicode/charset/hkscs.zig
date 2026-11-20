//! Big5-HKSCS decoder and encoder.

const std = @import("std");
const tables = @import("tables.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

pub fn next(_: void, input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    if (start >= input.len) return .end;
    const first = input[start];
    if (first < 0x80) {
        index.* = start + 1;
        return .{ .codepoint = first };
    }
    if (first < 0x81 or first > 0xFE) {
        index.* = start + 1;
        return .{ .malformed = 1 };
    }
    if (start + 1 >= input.len) return .incomplete;
    const second = input[start + 1];
    const codepoint = tables.hkscsForward(first, second) orelse {
        index.* = start + 2;
        return .{ .malformed = 2 };
    };
    index.* = start + 2;
    return .{ .codepoint = codepoint };
}

pub fn encode(_: void, codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    const pair = tables.hkscsReverse(codepoint) orelse return .unmappable;
    out[0] = pair[0];
    out[1] = pair[1];
    return .{ .written = 2 };
}

test "Big5-HKSCS round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "香港", .encoded = "\xAD\xBB\xB4\xE4" },
        .{ .text = "€", .encoded = "\xA3\xE1" },
        .{ .text = "\u{27267}", .encoded = "\x87\x45" },
        .{ .text = "Hello 香港", .encoded = "Hello \xAD\xBB\xB4\xE4" },
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
            var buffer: [4]u8 = undefined;
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
