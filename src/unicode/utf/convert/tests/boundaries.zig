//! Prefix and classification-window boundaries against independent std conversion.
const std = @import("std");
const conversion = @import("../../transcode.zig");
const big_endian = @import("builtin").cpu.arch.endian() == .big;

test "UTF conversion matches std across dense and sparse phases" {
    const pattern = [_]u16{ 0x80, 0x800, 'x', 0xd83d, 0xde00 };
    var units: [784]u16 = undefined;
    var little: [784]u16 = undefined;
    var expected: [2352]u8 = undefined;
    var storage: [2358]u8 = undefined;
    var wide_storage: [2353]u16 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    // The third phase stays globally sparse so exact owned output selects
    // adaptive BMP packing before its long ASCII suffix.
    for (0..3) |phase| {
        const dense_first = phase != 1;
        @memset(&units, 'x');
        const begin: usize = if (dense_first) 0 else 464;
        for (0..160) |i| units[begin + i] = pattern[i % pattern.len];
        if (phase == 0) {
            for (0..160) |i| units[624 + i] = pattern[i % pattern.len];
        } else if (phase == 1) units[0] = 0x800;
        const positions = [_]usize{ 0, 1, 7, 8, 15, 16, 31, 32, 127, 128, 159, 160, 255, 256, 463, 464, 511, 512, 623, 624, 767, 783 };
        for (positions) |position| {
            const saved = units[position];
            for ([_]u16{ saved, 0xd800, 0xdbff, 0xdc00, 0xdfff }) |replacement| {
                units[position] = replacement;
                for (units, 0..) |unit, i| little[i] = if (big_endian) @byteSwap(unit) else unit;
                const count = std.unicode.utf16LeToUtf8(&expected, &little) catch {
                    @memcpy(storage[0..6], "prefix");
                    var output = std.ArrayList(u8){ .items = storage[0..6], .capacity = storage.len };
                    try std.testing.expectError(error.InvalidUtf16, conversion.utf16ToUtf8Into(failed.allocator(), &units, &output));
                    try std.testing.expectEqualStrings("prefix", output.items);
                    continue;
                };
                const owned_wide = try conversion.utf8ToUtf16Alloc(std.testing.allocator, expected[0..count]);
                defer std.testing.allocator.free(owned_wide);
                try std.testing.expectEqualSlices(u16, &units, owned_wide);
                const owned_narrow = try conversion.utf16ToUtf8Alloc(std.testing.allocator, &units);
                defer std.testing.allocator.free(owned_narrow);
                try std.testing.expectEqualSlices(u8, expected[0..count], owned_narrow);
                for ([_]usize{ 1 + units.len, wide_storage.len }) |capacity| {
                    wide_storage[0] = 'A';
                    var wide = std.ArrayList(u16){ .items = wide_storage[0..1], .capacity = capacity };
                    try conversion.utf8ToUtf16Into(failed.allocator(), expected[0..count], &wide);
                    try std.testing.expectEqual(@as(u16, 'A'), wide.items[0]);
                    try std.testing.expectEqualSlices(u16, &units, wide.items[1..]);
                }
                for ([_]usize{ 6 + count, storage.len }) |capacity| {
                    @memcpy(storage[0..6], "prefix");
                    var output = std.ArrayList(u8){ .items = storage[0..6], .capacity = capacity };
                    try conversion.utf16ToUtf8Into(failed.allocator(), &units, &output);
                    try std.testing.expectEqualStrings("prefix", output.items[0..6]);
                    try std.testing.expectEqualSlices(u8, expected[0..count], output.items[6..]);
                }
            }
            units[position] = saved;
        }
    }
}

test "UTF conversion rejects malformed neighbors after a long ASCII prefix" {
    var text = [_]u8{'x'} ** 512;
    var storage: [513]u16 = undefined;
    var expected: [512]u16 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const dense = "aé世😀" ** 16;
    const sequences = [_][]const u8{ "\x80", "\xc0\x80", "\xc2A", "\xe0\x80\x80", "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xff" };
    for (sequences) |sequence| {
        for ([_]usize{ 0, 1, 15, 16, 31, 32, 47, 48, 63, 64, 127, 159 }) |offset| {
            @memset(&text, 'x');
            @memcpy(text[256..][0..dense.len], dense);
            @memcpy(text[256 + offset ..][0..sequence.len], sequence);
            const count = std.unicode.utf8ToUtf16Le(&expected, &text) catch {
                for ([_]usize{ 257, storage.len }) |capacity| {
                    storage[0] = 'A';
                    var output = std.ArrayList(u16){ .items = storage[0..1], .capacity = capacity };
                    try std.testing.expectError(error.InvalidUtf8, conversion.utf8ToUtf16Into(failed.allocator(), &text, &output));
                    try std.testing.expectEqualSlices(u16, &.{'A'}, output.items);
                }
                continue;
            };
            if (comptime big_endian) for (expected[0..count]) |*unit| {
                unit.* = @byteSwap(unit.*);
            };
            for ([_]usize{ 1 + count, storage.len }) |capacity| {
                storage[0] = 'A';
                var output = std.ArrayList(u16){ .items = storage[0..1], .capacity = capacity };
                try conversion.utf8ToUtf16Into(failed.allocator(), &text, &output);
                try std.testing.expectEqual(@as(u16, 'A'), output.items[0]);
                try std.testing.expectEqualSlices(u16, expected[0..count], output.items[1..]);
            }
        }
    }
}

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
