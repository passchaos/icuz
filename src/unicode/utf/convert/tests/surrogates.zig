//! Every supplementary scalar through the scalar and SIMD surrogate encoders.
const std = @import("std");
const blocks = @import("../../blocks.zig");
const big_endian = @import("builtin").cpu.arch.endian() == .big;

test "UTF surrogate blocks match every supplementary scalar in exact buffers" {
    var units = [_]u16{ 0xd83d, 0xde00 } ** 8;
    var expected: [32]u8 = ("😀" ** 8).*;
    var pair: [2]u16 = undefined;
    var storage: [54]u8 = undefined;
    for (0x10000..0x110000) |value| {
        _ = try std.unicode.utf8Encode(@intCast(value), expected[0..4]);
        _ = try std.unicode.utf8ToUtf16Le(&pair, expected[0..4]);
        units[0] = if (big_endian) @byteSwap(pair[0]) else pair[0];
        units[1] = if (big_endian) @byteSwap(pair[1]) else pair[1];
        @memcpy(storage[0..6], "prefix");
        const scalar_written = blocks.writeSurrogatePair(storage[0..10], 6, units[0], units[1]);
        try std.testing.expectEqual(10, scalar_written);
        try std.testing.expectEqualStrings("prefix", storage[0..6]);
        try std.testing.expectEqualSlices(u8, expected[0..4], storage[6..scalar_written]);
        inline for (.{ 2, 8 }) |count| {
            const bytes = count * 4;
            inline for (.{ true, false }) |checked| {
                @memcpy(storage[0..6], "prefix");
                const vector: @Vector(count * 2, u16) = units[0 .. count * 2].*;
                const written = blocks.encode4(checked, count, storage[6..][0..bytes], 0, vector) orelse return error.InvalidUtf16;
                try std.testing.expectEqual(bytes, written);
                try std.testing.expectEqualStrings("prefix", storage[0..6]);
                try std.testing.expectEqualSlices(u8, expected[0..bytes], storage[6..][0..written]);
            }
        }
    }
}
