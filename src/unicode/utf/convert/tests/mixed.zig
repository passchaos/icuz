//! Independent mixed-width decoding/encoding and invalid-neighbor oracles.
const std = @import("std");
const conversion = @import("../../transcode.zig");
const decoder = @import("../mixed_decode/root.zig");
const big_endian = @import("builtin").cpu.arch.endian() == .big;

fn scalar(width: usize, salt: usize) u21 {
    return switch (width) {
        1 => if (salt & 1 == 0) 0 else 0x7f,
        2 => if (salt & 1 == 0) 0x80 else 0x7ff,
        3 => ([_]u21{ 0x800, 0xd7ff, 0xe000, 0xffff })[salt & 3],
        4 => if (salt & 1 == 0) 0x10000 else 0x10ffff,
        else => unreachable,
    };
}

test "UTF mixed decoding matches every four-scalar width tuple and offset" {
    var text: [256]u8 = undefined;
    var expected: [256]u16 = undefined;
    var storage: [257]u16 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..256) |pattern| {
        for (0..8) |offset| {
            @memset(text[0..offset], 'x');
            var written = offset;
            for (0..4) |repeat| {
                for (0..4) |lane| {
                    const width = 1 + ((pattern >> @intCast(lane * 2)) & 3);
                    written += try std.unicode.utf8Encode(scalar(width, repeat + lane), text[written..][0..4]);
                }
            }
            @memset(text[written..][0..64], 'x');
            written += 64;
            const count = try std.unicode.utf8ToUtf16Le(&expected, text[0..written]);
            if (comptime big_endian) for (expected[0..count]) |*unit| {
                unit.* = @byteSwap(unit.*);
            };
            for ([_]usize{ 1 + count, storage.len }) |capacity| {
                storage[0] = 0x41;
                var output = std.ArrayList(u16){ .items = storage[0..1], .capacity = capacity };
                try conversion.utf8ToUtf16Into(failed.allocator(), text[0..written], &output);
                try std.testing.expectEqual(@as(u16, 0x41), output.items[0]);
                try std.testing.expectEqualSlices(u16, expected[0..count], output.items[1..]);
            }
            if (comptime decoder.supported) {
                inline for (.{ true, false }) |checked| {
                    const result = try decoder.run(checked, text[0..written], storage[0..]);
                    try std.testing.expect(result.consumed <= written);
                    const prefix = try std.unicode.utf8ToUtf16Le(&expected, text[0..result.consumed]);
                    if (comptime big_endian) for (expected[0..prefix]) |*unit| {
                        unit.* = @byteSwap(unit.*);
                    };
                    try std.testing.expectEqual(prefix, result.written);
                    try std.testing.expectEqualSlices(u16, expected[0..prefix], storage[0..result.written]);
                }
            }
        }
    }
}

test "UTF mixed encoding matches every eight-scalar width tuple" {
    var expected: [128]u8 = undefined;
    var units: [64]u16 = undefined;
    var storage: [256]u8 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..0x10000) |pattern| {
        expected[0] = 'x';
        var written: usize = 1;
        for (0..8) |lane| {
            const width = 1 + ((pattern >> @intCast(lane * 2)) & 3);
            written += try std.unicode.utf8Encode(scalar(width, pattern + lane), expected[written..][0..4]);
        }
        @memset(expected[written..][0..16], 'x');
        written += 16;
        const count = try std.unicode.utf8ToUtf16Le(&units, expected[0..written]);
        if (comptime big_endian) for (units[0..count]) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        for ([_]usize{ 6 + written, storage.len }) |capacity| {
            @memcpy(storage[0..6], "prefix");
            var output = std.ArrayList(u8){ .items = storage[0..6], .capacity = capacity };
            try conversion.utf16ToUtf8Into(failed.allocator(), units[0..count], &output);
            try std.testing.expectEqualStrings("prefix", output.items[0..6]);
            try std.testing.expectEqualSlices(u8, expected[0..written], output.items[6..]);
        }
    }
}

test "UTF mixed validation matches std at window boundaries" {
    var text = [_]u8{'x'} ** 192;
    var expected: [192]u16 = undefined;
    var storage: [193]u16 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const sequences = [_][]const u8{ "\x80", "\xc0\x80", "\xc1\xbf", "\xc2A", "\xe0\x80\x80", "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff" };
    for (sequences) |sequence| {
        for ([_]usize{ 0, 1, 15, 16, 31, 32, 47, 48, 63, 64, 95, 96, 127, 128, 191 }) |position| {
            @memset(&text, 'x');
            @memcpy(text[0..4], "a世");
            const length = @min(sequence.len, text.len - position);
            @memcpy(text[position..][0..length], sequence[0..length]);
            storage[0] = 0x41;
            var output = std.ArrayList(u16){ .items = storage[0..1], .capacity = storage.len };
            const count = std.unicode.utf8ToUtf16Le(&expected, &text) catch {
                try std.testing.expectError(error.InvalidUtf8, conversion.utf8ToUtf16Into(failed.allocator(), &text, &output));
                try std.testing.expectEqualSlices(u16, &.{0x41}, output.items);
                continue;
            };
            if (comptime big_endian) for (expected[0..count]) |*unit| {
                unit.* = @byteSwap(unit.*);
            };
            try conversion.utf8ToUtf16Into(failed.allocator(), &text, &output);
            try std.testing.expectEqual(@as(u16, 0x41), output.items[0]);
            try std.testing.expectEqualSlices(u16, expected[0..count], output.items[1..]);
        }
    }
}
