//! Fixed-width UTF-8 decoding blocks.
const std = @import("std");

/// Lane masks for deinterleaving a 48-byte block of sixteen three-byte
/// sequences into its lead and continuation byte vectors.
pub fn threeByteLane(comptime offset: usize) @Vector(16, i32) {
    var mask: [16]i32 = undefined;
    for (&mask, 0..) |*lane, index| lane.* = @intCast(index * 3 + offset);
    return mask;
}

/// Decode sixteen consecutive three-byte BMP sequences at `index`. Returns
/// null when the block holds anything else, so the scalar path can take over.
pub inline fn decodeThreeByteBlock(
    input: []const u8,
    index: usize,
) ?@Vector(16, u16) {
    return decode3(true, 16, input, index);
}

fn lanes(comptime n: usize, comptime stride: usize, comptime offset: usize) [n]i32 {
    var result: [n]i32 = undefined;
    for (0..n) |i| result[i] = @intCast(i * stride + offset);
    return result;
}

pub inline fn decode3(comptime checked: bool, comptime n: usize, input: []const u8, index: usize) ?@Vector(n, u16) {
    const Lane = @Vector(n, u8);
    const chunk: @Vector(n * 3, u8) = if (@import("builtin").zig_backend == .stage2_llvm)
        @as(*align(1) const @Vector(n * 3, u8), @ptrCast(input.ptr + index)).*
    else
        input[index..][0 .. n * 3].*;
    const lead = @shuffle(u8, chunk, undefined, lanes(n, 3, 0));
    const second = @shuffle(u8, chunk, undefined, lanes(n, 3, 1));
    const third = @shuffle(u8, chunk, undefined, lanes(n, 3, 2));
    if (!@reduce(.And, (lead >= @as(Lane, @splat(0xe0))) &
        (lead <= @as(Lane, @splat(0xef)))))
    {
        return null;
    }
    if (checked and !@reduce(.And, (second >= @as(Lane, @splat(0x80))) &
        (second <= @as(Lane, @splat(0xbf)))))
    {
        return null;
    }
    if (checked and !@reduce(.And, (third >= @as(Lane, @splat(0x80))) &
        (third <= @as(Lane, @splat(0xbf)))))
    {
        return null;
    }
    const Wide = @Vector(n, u16);
    const lead_wide: Wide = @intCast(lead & @as(Lane, @splat(0x0f)));
    const second_wide: Wide = @intCast(second & @as(Lane, @splat(0x3f)));
    const third_wide: Wide = @intCast(third & @as(Lane, @splat(0x3f)));
    // Multiplying by powers of two keeps the shift counts out of vector
    // operands, whose element type would be Log2Int(u16).
    const value: Wide = (lead_wide * @as(Wide, @splat(1 << 12))) |
        (second_wide * @as(Wide, @splat(1 << 6))) |
        third_wide;
    // Overlong forms and U+D800..U+DFFF must not reach the output.
    if (checked and @reduce(.Or, value < @as(Wide, @splat(0x800)))) return null;
    if (checked and @reduce(.Or, (value >= @as(Wide, @splat(0xd800))) &
        (value <= @as(Wide, @splat(0xdfff)))))
    {
        return null;
    }
    return value;
}

pub inline fn decode2(comptime checked: bool, comptime n: usize, input: []const u8, index: usize) ?@Vector(n, u16) {
    const B = @Vector(n, u8);
    const W = @Vector(n, u16);
    const data: @Vector(n * 2, u8) = if (@import("builtin").zig_backend == .stage2_llvm)
        @as(*align(1) const @Vector(n * 2, u8), @ptrCast(input.ptr + index)).*
    else
        input[index..][0 .. n * 2].*;
    const first = @shuffle(u8, data, undefined, lanes(n, 2, 0));
    const second = @shuffle(u8, data, undefined, lanes(n, 2, 1));
    if (!@reduce(.And, (first >= @as(B, @splat(0xc2))) & (first <= @as(B, @splat(0xdf))))) return null;
    if (checked and !@reduce(.And, (second & @as(B, @splat(0xc0))) == @as(B, @splat(0x80)))) return null;
    return (@as(W, @intCast(first & @as(B, @splat(0x1f)))) * @as(W, @splat(64))) |
        @as(W, @intCast(second & @as(B, @splat(0x3f))));
}

pub inline fn decode4(comptime checked: bool, comptime n: usize, input: []const u8, index: usize) ?@Vector(n * 2, u16) {
    const B = @Vector(n, u8);
    const W = @Vector(n, u32);
    const data: @Vector(n * 4, u8) = if (@import("builtin").zig_backend == .stage2_llvm)
        @as(*align(1) const @Vector(n * 4, u8), @ptrCast(input.ptr + index)).*
    else
        input[index..][0 .. n * 4].*;
    const a = @shuffle(u8, data, undefined, lanes(n, 4, 0));
    const b = @shuffle(u8, data, undefined, lanes(n, 4, 1));
    const c = @shuffle(u8, data, undefined, lanes(n, 4, 2));
    const d = @shuffle(u8, data, undefined, lanes(n, 4, 3));
    if (!@reduce(.And, (a >= @as(B, @splat(0xf0))) & (a <= @as(B, @splat(0xf4))))) return null;
    if (checked and !@reduce(.And, ((b & @as(B, @splat(0xc0))) == @as(B, @splat(0x80))) &
        ((c & @as(B, @splat(0xc0))) == @as(B, @splat(0x80))) &
        ((d & @as(B, @splat(0xc0))) == @as(B, @splat(0x80))))) return null;
    const cp = @as(W, @intCast(a & @as(B, @splat(7)))) * @as(W, @splat(1 << 18)) |
        @as(W, @intCast(b & @as(B, @splat(0x3f)))) * @as(W, @splat(1 << 12)) |
        @as(W, @intCast(c & @as(B, @splat(0x3f)))) * @as(W, @splat(1 << 6)) |
        @as(W, @intCast(d & @as(B, @splat(0x3f))));
    if (checked and !@reduce(.And, (cp >= @as(W, @splat(0x10000))) & (cp <= @as(W, @splat(0x10ffff))))) return null;
    const value = cp - @as(W, @splat(0x10000));
    const high: @Vector(n, u16) = @intCast((value >> @splat(10)) | @as(W, @splat(0xd800)));
    const low: @Vector(n, u16) = @intCast((value & @as(W, @splat(0x3ff))) | @as(W, @splat(0xdc00)));
    comptime var mask: [n * 2]i32 = undefined;
    inline for (0..n) |i| {
        mask[i * 2] = i;
        mask[i * 2 + 1] = ~@as(i32, @intCast(i));
    }
    return @shuffle(u16, high, low, mask);
}
