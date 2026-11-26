//! UTF-8 byte packing from scalar vectors.
const std = @import("std");

/// Interleave masks for packing sixteen BMP scalars into their UTF-8 bytes.
/// Negative lanes select from the second operand, as `@shuffle` defines.
pub fn pairLanes() @Vector(32, i32) {
    return pairLanesN(16);
}
fn pairLanesN(comptime n: usize) @Vector(n * 2, i32) {
    var mask: [n * 2]i32 = undefined;
    for (0..n) |index| {
        mask[index * 2] = @intCast(index);
        mask[index * 2 + 1] = -@as(i32, @intCast(index)) - 1;
    }
    return mask;
}

pub fn tripleLanes() @Vector(48, i32) {
    return tripleLanesN(16);
}
fn tripleLanesN(comptime n: usize) @Vector(n * 3, i32) {
    var mask: [n * 3]i32 = undefined;
    for (0..n) |index| {
        mask[index * 3] = @intCast(index * 2);
        mask[index * 3 + 1] = @intCast(index * 2 + 1);
        mask[index * 3 + 2] = -@as(i32, @intCast(index)) - 1;
    }
    return mask;
}

/// True when every lane is a BMP scalar that encodes to three UTF-8 bytes.
pub inline fn bmpThreeByteLanes(
    comptime Lane: type,
    units: @Vector(16, Lane),
) bool {
    const Wide = @Vector(16, Lane);
    return @reduce(.And, (units >= @as(Wide, @splat(0x800))) &
        (units <= @as(Wide, @splat(0xFFFF))) &
        ((units < @as(Wide, @splat(0xD800))) |
            (units > @as(Wide, @splat(0xDFFF)))));
}

/// Store sixteen three-byte sequences at `written` and return the new length.
pub inline fn storeThreeByteScalars(
    comptime Lane: type,
    spare: []u8,
    written: usize,
    units: @Vector(16, Lane),
) usize {
    return encode3(Lane, 16, spare, written, units);
}
pub inline fn encode3(comptime Lane: type, comptime n: usize, spare: []u8, written: usize, units: @Vector(n, Lane)) usize {
    const Wide = @Vector(n, Lane);
    const Shift = @Vector(n, std.math.Log2Int(Lane));
    const first: @Vector(n, u8) = @intCast(
        (units >> @as(Shift, @splat(12))) | @as(Wide, @splat(0xE0)),
    );
    const second: @Vector(n, u8) = @intCast(
        ((units >> @as(Shift, @splat(6))) & @as(Wide, @splat(0x3F))) |
            @as(Wide, @splat(0x80)),
    );
    const third: @Vector(n, u8) = @intCast(
        (units & @as(Wide, @splat(0x3F))) | @as(Wide, @splat(0x80)),
    );
    const pairs: @Vector(n * 2, u8) = @shuffle(u8, first, second, pairLanesN(n));
    const triples: @Vector(n * 3, u8) = @shuffle(u8, pairs, third, tripleLanesN(n));
    spare[written..][0 .. n * 3].* = @bitCast(triples);
    return written + n * 3;
}

pub inline fn encode2(comptime n: usize, output: []u8, written: usize, units: @Vector(n, u16)) usize {
    const W = @Vector(n, u16);
    var words = (units >> @splat(6)) | @as(W, @splat(0xc0)) |
        (((units & @as(W, @splat(0x3f))) | @as(W, @splat(0x80))) << @splat(8));
    if (@import("builtin").cpu.arch.endian() == .big) words = @byteSwap(words);
    output[written..][0 .. n * 2].* = @bitCast(words);
    return written + n * 2;
}

pub inline fn encode4(comptime checked: bool, comptime n: usize, output: []u8, written: usize, units: @Vector(n * 2, u16)) ?usize {
    const H = @Vector(n, u16);
    comptime var high_mask: [n]i32 = undefined;
    comptime var low_mask: [n]i32 = undefined;
    inline for (0..n) |i| {
        high_mask[i] = i * 2;
        low_mask[i] = i * 2 + 1;
    }
    const high = @shuffle(u16, units, undefined, high_mask);
    const low = @shuffle(u16, units, undefined, low_mask);
    if (!@reduce(.And, (high & @as(H, @splat(0xfc00))) == @as(H, @splat(0xd800)))) return null;
    if (checked and !@reduce(.And, (low & @as(H, @splat(0xfc00))) == @as(H, @splat(0xdc00)))) return null;
    var words = surrogateWords(n, high, low);
    if (@import("builtin").cpu.arch.endian() == .big) words = @byteSwap(words);
    output[written..][0 .. n * 4].* = @bitCast(words);
    return written + n * 4;
}

inline fn surrogateWords(comptime n: usize, high: @Vector(n, u16), low: @Vector(n, u16)) @Vector(n, u32) {
    const U = @Vector(n, u16);
    const W = @Vector(n, u32);
    const adjusted = high - @as(U, @splat(0xd7c0));
    const tail = low & @as(U, @splat(0x3ff));
    const first = @as(U, @splat(0x80f0)) | (adjusted >> @splat(8)) | ((adjusted & @as(U, @splat(0xfc))) << @splat(6));
    const second = @as(U, @splat(0x8080)) | ((adjusted & @as(U, @splat(3))) << @splat(4)) |
        (tail >> @splat(6)) | ((tail & @as(U, @splat(0x3f))) << @splat(8));
    return @as(W, @intCast(first)) | (@as(W, @intCast(second)) << @splat(16));
}

pub inline fn writeSurrogatePair(output: []u8, written: usize, high: u16, low: u16) usize {
    const h: @Vector(1, u16) = @splat(high);
    const l: @Vector(1, u16) = @splat(low);
    const values: [1]u32 = surrogateWords(1, h, l);
    std.mem.writeInt(u32, output[written..][0..4], values[0], .little);
    return written + 4;
}

/// Write one valid scalar as UTF-8 at `written` and return the new length.
pub inline fn writeScalar(spare: []u8, written: usize, codepoint: u21) usize {
    if (codepoint < 0x80) {
        spare[written] = @intCast(codepoint);
        return written + 1;
    }
    if (codepoint < 0x800) {
        spare[written] = @intCast(0xC0 | (codepoint >> 6));
        spare[written + 1] = @intCast(0x80 | (codepoint & 0x3F));
        return written + 2;
    }
    if (codepoint < 0x10000) {
        spare[written] = @intCast(0xE0 | (codepoint >> 12));
        spare[written + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        spare[written + 2] = @intCast(0x80 | (codepoint & 0x3F));
        return written + 3;
    }
    spare[written] = @intCast(0xF0 | (codepoint >> 18));
    spare[written + 1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    spare[written + 2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    spare[written + 3] = @intCast(0x80 | (codepoint & 0x3F));
    return written + 4;
}
