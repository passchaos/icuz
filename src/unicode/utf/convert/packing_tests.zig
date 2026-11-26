//! Width-pattern differentials against independent std conversion.
const std = @import("std");
const conversion = @import("../transcode.zig");
const big_endian = @import("builtin").cpu.arch.endian() == .big;

test "UTF conversion handles every sixteen-unit Latin width mask" {
    var units: [16]u16 = undefined;
    var expected: [32]u8 = undefined;
    var storage: [64]u8 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..0x10000) |mask| {
        for (&units, 0..) |*unit, i| unit.* = if ((mask >> @intCast(i)) & 1 != 0) @intCast(0x80 + ((mask + i * 17) & 0x7f)) else @intCast(i * 7);
        var little = units;
        if (comptime big_endian) for (&little) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        const count = try std.unicode.utf16LeToUtf8(&expected, &little);
        for ([_]usize{ count, storage.len }) |capacity| {
            var output = std.ArrayList(u8){ .items = storage[0..0], .capacity = capacity };
            try conversion.utf16ToUtf8Into(failed.allocator(), &units, &output);
            try std.testing.expectEqualSlices(u8, expected[0..count], output.items);
        }
    }
}

test "UTF conversion covers all two-byte scalars inside variable-width windows" {
    const a = std.testing.allocator;
    var output = std.ArrayList(u16).empty;
    defer output.deinit(a);
    try output.ensureTotalCapacity(a, 64);
    var text = [_]u8{'x'} ** 32;
    var expected: [32]u16 = undefined;
    for (0x80..0x800) |value| {
        _ = try std.unicode.utf8Encode(@intCast(value), text[0..4]);
        const count = try std.unicode.utf8ToUtf16Le(&expected, &text);
        if (comptime big_endian) for (expected[0..count]) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        output.clearRetainingCapacity();
        try conversion.utf8ToUtf16Into(a, &text, &output);
        try std.testing.expectEqualSlices(u16, expected[0..count], output.items);
    }
}

test "UTF conversion decodes every variable-width two-byte pattern" {
    const a = std.testing.allocator;
    var wide = std.ArrayList(u16).empty;
    defer wide.deinit(a);
    try wide.ensureTotalCapacity(a, 64);
    var text: [64]u8 = undefined;
    var expected: [40]u16 = undefined;
    for (0..256) |mask| {
        var written: usize = 0;
        for (0..8) |i| {
            const cp: u21 = if ((mask >> @intCast(i)) & 1 != 0) @intCast(0x80 + (mask * 17 + i * 193) % 0x780) else @intCast('A' + i);
            expected[i] = @intCast(cp);
            written += try std.unicode.utf8Encode(cp, text[written..][0..4]);
        }
        // A following non-ASCII scalar also exercises the all-ASCII first
        // eight-lane pattern inside the variable-width decoder.
        expected[8] = 0xe9;
        @memset(expected[9..], 'x');
        written += try std.unicode.utf8Encode(0xe9, text[written..][0..4]);
        @memset(text[written..][0..31], 'x');
        written += 31;
        wide.clearRetainingCapacity();
        try conversion.utf8ToUtf16Into(a, text[0..written], &wide);
        try std.testing.expectEqualSlices(u16, &expected, wide.items);
        const owned = try conversion.utf8ToUtf16Alloc(a, text[0..written]);
        defer a.free(owned);
        try std.testing.expectEqualSlices(u16, &expected, owned);
    }
    const bad = [_][]const u8{ "\x80", "\xc0\x80", "\xc1\xbf", "\xc2A", "\xdf\x7f" };
    for (bad) |sequence| {
        for (2..16) |position| {
            @memset(&text, 'x');
            text[0] = 0xc3;
            text[1] = 0xa9;
            @memcpy(text[position..][0..sequence.len], sequence);
            wide.clearRetainingCapacity();
            try wide.append(a, 0x41);
            try std.testing.expectError(error.InvalidUtf8, conversion.utf8ToUtf16Into(a, &text, &wide));
            try std.testing.expectEqualSlices(u16, &.{0x41}, wide.items);
        }
    }
}

test "UTF conversion packs every eight-unit BMP width pattern" {
    const values = [_]u16{ 0x7f, 0x7ff, 0xffff };
    var units: [8]u16 = undefined;
    var expected: [24]u8 = undefined;
    var storage: [48]u8 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..6561) |pattern| {
        var code = pattern;
        for (&units) |*unit| {
            unit.* = values[code % 3];
            code /= 3;
        }
        var little = units;
        if (comptime big_endian) for (&little) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        const count = try std.unicode.utf16LeToUtf8(&expected, &little);
        for ([_]usize{ count, storage.len }) |capacity| {
            var output = std.ArrayList(u8){ .items = storage[0..0], .capacity = capacity };
            try conversion.utf16ToUtf8Into(failed.allocator(), &units, &output);
            try std.testing.expectEqualSlices(u8, expected[0..count], output.items);
        }
    }
}

test "UTF conversion packs every BMP width combination into exact buffers" {
    const values = [_]u16{ 0x00, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff };
    var output_storage: [32]u8 = undefined;
    var expected: [12]u8 = undefined;
    var units: [4]u16 = undefined;
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..4096) |number| {
        var value = number;
        for (&units) |*unit| {
            unit.* = values[value % values.len];
            value /= values.len;
        }
        var little_units = units;
        if (comptime big_endian) for (&little_units) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        const count = try std.unicode.utf16LeToUtf8(&expected, &little_units);
        for ([_]usize{ count, output_storage.len }) |capacity| {
            var output = std.ArrayList(u8){ .items = output_storage[0..0], .capacity = capacity };
            try conversion.utf16ToUtf8Into(failed.allocator(), &units, &output);
            try std.testing.expectEqualSlices(u8, expected[0..count], output.items);
        }
    }
    for (0..256) |mask| {
        var latin: [8]u16 = undefined;
        for (&latin, 0..) |*unit, i| unit.* = if ((mask >> @intCast(i)) & 1 != 0) @intCast(0x80 + (i * 17)) else @intCast(i * 13);
        var reference_bytes: [16]u8 = undefined;
        var little_latin = latin;
        if (comptime big_endian) for (&little_latin) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        const count = try std.unicode.utf16LeToUtf8(&reference_bytes, &little_latin);
        for ([_]usize{ count, output_storage.len }) |capacity| {
            var output = std.ArrayList(u8){ .items = output_storage[0..0], .capacity = capacity };
            try conversion.utf16ToUtf8Into(failed.allocator(), &latin, &output);
            try std.testing.expectEqualSlices(u8, reference_bytes[0..count], output.items);
        }
    }
}
