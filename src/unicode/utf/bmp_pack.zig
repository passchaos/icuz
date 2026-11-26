//! Mixed-width BMP encoding in four-unit blocks, with bounded tail stores.
const std = @import("std");
const builtin = @import("builtin");
pub const supported = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3) and builtin.zig_backend == .stage2_llvm;
const V = @Vector(16, u8);
const controls = makeControls();
const latin_controls = makeLatinControls();
pub const wide_supported = supported and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

inline fn store(output: []u8, written: usize, bytes: V, count: usize) usize {
    if (output.len - written >= 16) output[written..][0..16].* = bytes else {
        const tail: [16]u8 = bytes;
        @memcpy(output[written..][0..count], tail[0..count]);
    }
    return written + count;
}

pub inline fn encode8(output: []u8, written: usize, units: @Vector(8, u16)) ?usize {
    if (comptime !wide_supported) return null;
    const U = @Vector(8, u16);
    const W = @Vector(8, u32);
    const B = @Vector(32, u8);
    if (@reduce(.And, units < @as(U, @splat(0x100)))) return latin8(output, written, units);
    const value: W = @intCast(units);
    const non_ascii: u8 = @bitCast(value >= @as(W, @splat(0x80)));
    if (non_ascii == 0) {
        const bytes: @Vector(8, u8) = @truncate(units);
        output[written..][0..8].* = bytes;
        return written + 8;
    }
    if (@reduce(.Or, (units & @as(U, @splat(0xf800))) == @as(U, @splat(0xd800)))) return null;
    const three: u8 = @bitCast(value >= @as(W, @splat(0x800)));
    const first = @select(u32, value < @as(W, @splat(0x80)), value, @select(u32, value < @as(W, @splat(0x800)), (value >> @splat(6)) | @as(W, @splat(0xc0)), (value >> @splat(12)) | @as(W, @splat(0xe0))));
    const second = @select(u32, value < @as(W, @splat(0x800)), value & @as(W, @splat(0x3f)), (value >> @splat(6)) & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const third = (value & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const words = first | (second << @splat(8)) | (third << @splat(16));
    const low_mask = controls[spread(@truncate(non_ascii)) + spread(@truncate(three))];
    const high_mask = controls[spread(@truncate(non_ascii >> 4)) + spread(@truncate(three >> 4))];
    const mask: B = @shuffle(u8, low_mask, high_mask, blk: {
        var indices: [32]i32 = undefined;
        for (0..16) |i| {
            indices[i] = @intCast(i);
            indices[16 + i] = ~@as(i32, @intCast(i));
        }
        break :blk indices;
    });
    const bytes: B = @bitCast(words);
    const encoded = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> B),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    );
    const low: V = @shuffle(u8, encoded, undefined, blk: {
        var indices: [16]i32 = undefined;
        for (0..16) |i| indices[i] = @intCast(i);
        break :blk indices;
    });
    const high: V = @shuffle(u8, encoded, undefined, blk: {
        var indices: [16]i32 = undefined;
        for (0..16) |i| indices[i] = @intCast(16 + i);
        break :blk indices;
    });
    const count_low: usize = 4 + @as(usize, @popCount(@as(u4, @truncate(non_ascii)))) + @popCount(@as(u4, @truncate(three)));
    const count_high: usize = 4 + @as(usize, @popCount(@as(u4, @truncate(non_ascii >> 4)))) + @popCount(@as(u4, @truncate(three >> 4)));
    return store(output, store(output, written, low, count_low), high, count_high);
}

fn makeControls() [256]V {
    @setEvalBranchQuota(20000);
    var result: [256]V = undefined;
    for (0..256) |code| {
        var mask = [_]u8{0x80} ** 16;
        var written: usize = 0;
        for (0..4) |lane| {
            const count = 1 + ((code >> (lane * 2)) & 3);
            for (0..count) |byte| {
                mask[written] = @intCast(lane * 4 + byte);
                written += 1;
            }
        }
        result[code] = mask;
    }
    return result;
}

inline fn spread(mask: u4) u8 {
    var value: u8 = mask;
    value = (value | (value << 2)) & 0x33;
    return (value | (value << 1)) & 0x55;
}

pub inline fn encode(output: []u8, written: usize, units: @Vector(4, u16)) ?usize {
    if (comptime !supported) return null;
    const U = @Vector(4, u16);
    const W = @Vector(4, u32);
    const value: W = @intCast(units);
    const non_ascii: u4 = @bitCast(value >= @as(W, @splat(0x80)));
    if (non_ascii == 0) {
        const bytes: @Vector(4, u8) = @truncate(units);
        output[written..][0..4].* = bytes;
        return written + 4;
    }
    if (@reduce(.Or, (units & @as(U, @splat(0xf800))) == @as(U, @splat(0xd800)))) return null;
    const three: u4 = @bitCast(value >= @as(W, @splat(0x800)));
    const first = @select(u32, value < @as(W, @splat(0x80)), value, @select(u32, value < @as(W, @splat(0x800)), (value >> @splat(6)) | @as(W, @splat(0xc0)), (value >> @splat(12)) | @as(W, @splat(0xe0))));
    const second = @select(u32, value < @as(W, @splat(0x800)), value & @as(W, @splat(0x3f)), (value >> @splat(6)) & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const third = (value & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const words = first | (second << @splat(8)) | (third << @splat(16));
    const bytes: V = @bitCast(words);
    const mask = controls[spread(non_ascii) + spread(three)];
    const encoded = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> V),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    );
    const count: usize = 4 + @as(usize, @popCount(non_ascii)) + @popCount(three);
    return store(output, written, encoded, count);
}

fn makeLatinControls() [256]V {
    @setEvalBranchQuota(20000);
    var result: [256]V = undefined;
    for (0..256) |code| {
        var mask = [_]u8{0x80} ** 16;
        var written: usize = 0;
        for (0..8) |lane| {
            mask[written] = @intCast(lane * 2);
            written += 1;
            if ((code >> lane) & 1 != 0) {
                mask[written] = @intCast(lane * 2 + 1);
                written += 1;
            }
        }
        result[code] = mask;
    }
    return result;
}

inline fn latin8(output: []u8, written: usize, units: @Vector(8, u16)) usize {
    const U = @Vector(8, u16);
    const narrow: @Vector(8, u8) = @truncate(units);
    const non_ascii: u8 = @bitCast(narrow >= @as(@Vector(8, u8), @splat(0x80)));
    if (non_ascii == 0) {
        output[written..][0..8].* = narrow;
        return written + 8;
    }
    const first = @select(u16, units < @as(U, @splat(0x80)), units, (units >> @splat(6)) | @as(U, @splat(0xc0)));
    const second = (units & @as(U, @splat(0x3f))) | @as(U, @splat(0x80));
    const words = first | (second << @splat(8));
    const bytes: V = @bitCast(words);
    const mask = latin_controls[non_ascii];
    const encoded = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> V),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    );
    return store(output, written, encoded, 8 + @as(usize, @popCount(non_ascii)));
}
