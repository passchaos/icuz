//! Local BMP, ASCII, and surrogate runs for native UTF-16 conversion.
const blocks = @import("../blocks.zig");
const bmp = @import("../bmp_pack.zig");
const ascii = @import("ascii_encode.zig");
const Error = error{InvalidUtf16};
const std = @import("std");

pub const Run = struct { consumed: usize, written: usize };

pub inline fn run(comptime checked: bool, units: []const u16, output: []u8, start: usize) Error!Run {
    if (checked and units.len < 256) return ShortPairs.convert(checked, units, output, start);
    // Select once for long buffers so dense loops carry no ASCII-run checks.
    if (units.len >= 256) {
        const U = @Vector(32, u16);
        const v = @as(*align(2) const U, @ptrCast(units.ptr)).*;
        const ascii_mask: u32 = @bitCast(v < @as(U, @splat(0x80)));
        if (@popCount(ascii_mask) >= 24) return mixedRun(checked, true, units, output, start);
        if (checked or units.len < 8192) {
            // Keep scalar-first dispatch for checked or smaller pair-dense buffers.
            const surrogate_mask: u32 = @bitCast((v & @as(U, @splat(0xf800))) == @as(U, @splat(0xd800)));
            if (@popCount(surrogate_mask) >= 16) {
                if (checked and units.len >= 8192) return LongPairs.convert(checked, units, output, start);
                return ShortPairs.convert(checked, units, output, start);
            }
        }
    }
    return mixedRun(checked, false, units, output, start);
}

// Keep mixed-width packing local across BMP and surrogate boundaries.
noinline fn mixedRun(comptime checked: bool, comptime ascii_runs: bool, units: []const u16, output: []u8, start: usize) align(64) Error!Run {
    var index: usize = 0;
    var written = start;
    while (index + 8 <= units.len) {
        const unit = units[index];
        if (unit & 0xf800 != 0xd800) {
            const U = @Vector(8, u16);
            const v = @as(*align(2) const U, @ptrCast(units.ptr + index)).*;
            if (ascii_runs and unit < 0x80 and @reduce(.And, v < @as(U, @splat(0x80))) and index + 32 <= units.len) {
                const A = @Vector(32, u16);
                const ascii_units = @as(*align(2) const A, @ptrCast(units.ptr + index)).*;
                if (@reduce(.And, ascii_units < @as(A, @splat(0x80)))) {
                    const bytes: @Vector(32, u8) = @truncate(ascii_units);
                    output[written..][0..32].* = bytes;
                    const count = @call(.never_inline, ascii.after32, .{ units[index..], output[written..] });
                    index += count;
                    written += count;
                    continue;
                }
            }
            const surrogates: u8 = @bitCast((v & @as(U, @splat(0xf800))) == @as(U, @splat(0xd800)));
            if (surrogates == 0) {
                written = bmp.encode8Valid(output, written, v);
                index += 8;
                continue;
            }
            const prefix = @ctz(surrogates);
            const end = index + prefix;
            if (prefix >= 4) {
                const first: @Vector(4, u16) = units[index..][0..4].*;
                written = bmp.encode4Valid(output, written, first);
                index += 4;
            }
            while (index < end) : (index += 1) written = blocks.writeScalar(output, written, units[index]);
        }
        const high = units[index];
        if (high >= 0xdc00 or index + 1 == units.len or (checked and units[index + 1] & 0xfc00 != 0xdc00)) return error.InvalidUtf16;
        if (index + 4 <= units.len) {
            const pairs: @Vector(4, u16) = units[index..][0..4].*;
            if (blocks.encode4(checked, 2, output, written, pairs)) |next| {
                written = next;
                index += 4;
                continue;
            }
        }
        written = blocks.writeSurrogatePair(output, written, high, units[index + 1]);
        index += 2;
    }
    while (index < units.len and units[index] & 0xf800 != 0xd800) : (index += 1) written = blocks.writeScalar(output, written, units[index]);
    return .{ .consumed = index, .written = written };
}

fn PairKernel(comptime alignment: usize) type {
    return struct {
        noinline fn convert(comptime checked: bool, units: []const u16, output: []u8, start: usize) align(alignment) Error!Run {
            var index: usize = 0;
            var written = start;
            while (index + 8 <= units.len) {
                const unit = units[index];
                if (unit & 0xf800 == 0xd800) {
                    if (unit >= 0xdc00 or index + 1 == units.len or (checked and units[index + 1] & 0xfc00 != 0xdc00)) return error.InvalidUtf16;
                    const pairs: @Vector(4, u16) = units[index..][0..4].*;
                    if (blocks.encode4(checked, 2, output, written, pairs)) |next| {
                        written = next;
                        index += 4;
                        continue;
                    }
                    written = blocks.writeSurrogatePair(output, written, unit, units[index + 1]);
                    index += 2;
                    continue;
                }
                const U = @Vector(8, u16);
                const v = @as(*align(2) const U, @ptrCast(units.ptr + index)).*;
                const surrogates: u8 = @bitCast((v & @as(U, @splat(0xf800))) == @as(U, @splat(0xd800)));
                if (surrogates != 0) {
                    const prefix = @ctz(surrogates);
                    if (prefix >= 4) {
                        const first: @Vector(4, u16) = units[index..][0..4].*;
                        written = bmp.encode4Valid(output, written, first);
                        index += 4;
                        continue;
                    }
                    const end = index + prefix;
                    while (index < end) : (index += 1) written = blocks.writeScalar(output, written, units[index]);
                    continue;
                }
                written = bmp.encode8Valid(output, written, v);
                index += 8;
            }
            while (index < units.len and units[index] & 0xf800 != 0xd800) : (index += 1) written = blocks.writeScalar(output, written, units[index]);
            return .{ .consumed = index, .written = written };
        }
    };
}

const ShortPairs = PairKernel(64);
const LongPairs = PairKernel(16);

test "UTF dense surrogate runs match std and preserve prefixes on malformed neighbors" {
    if (comptime !bmp.wide_supported) return error.SkipZigTest;
    var units = ([_]u16{ 0x800, 'x', 0xd800, 0xdc00, 0xdbff, 0xdfff, 0xd83d, 0xde00 } ** 64) ++ ([_]u16{'x'} ** 8);
    var expected: [1560]u8 = undefined;
    var storage: [1566]u8 = undefined;
    for (0..512) |position| {
        const saved = units[position];
        for ([_]u16{ 0xd800, 0xdbff, 0xdc00, 0xdfff }) |replacement| {
            units[position] = replacement;
            const count = std.unicode.utf16LeToUtf8(&expected, &units) catch {
                @memcpy(storage[0..6], "prefix");
                try std.testing.expectError(error.InvalidUtf16, run(true, &units, storage[6..], 0));
                try std.testing.expectEqualStrings("prefix", storage[0..6]);
                continue;
            };
            for ([_]usize{ 6 + count, storage.len }) |capacity| {
                @memcpy(storage[0..6], "prefix");
                inline for (.{ true, false }) |checked| {
                    const result: Run = try run(checked, &units, storage[6..capacity], 0);
                    try std.testing.expectEqual(units.len, result.consumed);
                    try std.testing.expectEqual(count, result.written);
                    try std.testing.expectEqualStrings("prefix", storage[0..6]);
                    try std.testing.expectEqualSlices(u8, expected[0..count], storage[6..][0..result.written]);
                }
            }
        }
        units[position] = saved;
    }
}
test "UTF long surrogate runs match std at eight-pair and malformed boundaries" {
    if (comptime !bmp.wide_supported) return error.SkipZigTest;
    const group = [_]u16{ 0x800, 'x' } ++ ([_]u16{ 0xd83d, 0xde00 } ** 8);
    var units = (group ** 512) ++ ([_]u16{'x'} ** 8);
    var expected: [27672]u8 = undefined;
    var storage: [27678]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 3, 14, 15, 16, 17, 18, 19, 31, 32, 63, 64, 127, 128, 255, 256, 511, 512, 1023, 1024, 4095, 4096, 8191, 8192, 9214, 9215 }) |position| {
        const saved = units[position];
        for ([_]u16{ 0xd800, 0xdbff, 0xdc00, 0xdfff }) |replacement| {
            units[position] = replacement;
            const count = std.unicode.utf16LeToUtf8(&expected, &units) catch {
                @memcpy(storage[0..6], "prefix");
                try std.testing.expectError(error.InvalidUtf16, run(true, &units, storage[6..], 0));
                try std.testing.expectEqualStrings("prefix", storage[0..6]);
                continue;
            };
            for ([_]usize{ 6 + count, storage.len }) |capacity| {
                @memcpy(storage[0..6], "prefix");
                inline for (.{ true, false }) |checked| {
                    const result: Run = try run(checked, &units, storage[6..capacity], 0);
                    try std.testing.expectEqual(units.len, result.consumed);
                    try std.testing.expectEqual(count, result.written);
                    try std.testing.expectEqualStrings("prefix", storage[0..6]);
                    try std.testing.expectEqualSlices(u8, expected[0..count], storage[6..][0..result.written]);
                }
            }
        }
        units[position] = saved;
    }
}
