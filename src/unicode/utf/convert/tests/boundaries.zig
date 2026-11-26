//! Prefix and classification-window boundaries against independent std conversion.
const std = @import("std");
const conversion = @import("../../transcode.zig");
const big_endian = @import("builtin").cpu.arch.endian() == .big;

test "UTF conversion preserves prefixes across long ASCII transitions" {
    var units = [_]u16{'x'} ** 513;
    var little: [513]u16 = undefined;
    var expected: [1539]u8 = undefined;
    var storage: [1545]u8 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for ([_]u16{ 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff }) |value| {
        for (0..units.len) |position| {
            units[position] = value;
            for (units, 0..) |unit, i| little[i] = if (big_endian) @byteSwap(unit) else unit;
            const count = try std.unicode.utf16LeToUtf8(&expected, &little);
            for ([_]usize{ 6 + count, storage.len }) |capacity| {
                @memcpy(storage[0..6], "prefix");
                var output = std.ArrayList(u8){ .items = storage[0..6], .capacity = capacity };
                try conversion.utf16ToUtf8Into(failed.allocator(), &units, &output);
                try std.testing.expectEqualStrings("prefix", output.items[0..6]);
                try std.testing.expectEqualSlices(u8, expected[0..count], output.items[6..]);
            }
            units[position] = 'x';
        }
    }
    for ([_]u16{ 0xd800, 0xdbff, 0xdc00, 0xdfff }) |bad| {
        for ([_]usize{ 0, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 511, 512 }) |position| {
            units[position] = bad;
            @memcpy(storage[0..6], "prefix");
            var output = std.ArrayList(u8){ .items = storage[0..6], .capacity = storage.len };
            try std.testing.expectError(error.InvalidUtf16, conversion.utf16ToUtf8Into(failed.allocator(), &units, &output));
            try std.testing.expectEqualStrings("prefix", output.items);
            units[position] = 'x';
        }
    }
}

test "UTF conversion validates Latin input across batched boundaries" {
    var text = [_]u8{'x'} ** 192;
    var storage: [193]u16 = undefined;
    var expected: [192]u16 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const bad = [_][]const u8{ "\x80", "\xc0\x80", "\xc1\xbf", "\xc2A", "\xdf\x7f", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80" };
    for (bad) |sequence| {
        for ([_]usize{ 0, 1, 15, 16, 31, 32, 47, 48, 63, 64, 79, 80, 95, 96, 127, 128, 191 }) |position| {
            @memset(&text, 'x');
            text[0] = 0xc3;
            text[1] = 0xa9;
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
