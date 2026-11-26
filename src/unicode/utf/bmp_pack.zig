//! Mixed-width BMP and Latin-1 packing, with bounded tail stores.
const std = @import("std");
const builtin = @import("builtin");
pub const supported = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3) and builtin.zig_backend == .stage2_llvm;
const V = @Vector(16, u8);
const Control = struct { shuffle: V, count: u8 };
const controls = makeControls();
const latin_controls = makeLatinControls();
pub const wide_supported = supported and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

pub const Run = struct { consumed: usize, written: usize };

/// Consume a complete Latin-1 run in a loop whose vector constants stay local.
pub noinline fn latinRun(units: []const u16, output: []u8, start: usize) Run {
    var index: usize = 0;
    var written = start;
    while (index + 16 <= units.len) {
        const U = @Vector(16, u16);
        const v = @as(*align(2) const U, @ptrCast(units.ptr + index)).*;
        if (!@reduce(.And, v < @as(U, @splat(0x100)))) break;
        written = latin16(output, written, v);
        index += 16;
    }
    while (index + 8 <= units.len) {
        const U = @Vector(8, u16);
        const v = @as(*align(2) const U, @ptrCast(units.ptr + index)).*;
        if (!@reduce(.And, v < @as(U, @splat(0x100)))) break;
        written = latin8(output, written, v);
        index += 8;
    }
    while (index < units.len and units[index] < 0x100) : (index += 1) {
        const unit = units[index];
        if (unit < 0x80) {
            output[written] = @intCast(unit);
            written += 1;
        } else {
            output[written] = @intCast(0xc0 | (unit >> 6));
            output[written + 1] = @intCast(0x80 | (unit & 0x3f));
            written += 2;
        }
    }
    return .{ .consumed = index, .written = written };
}

/// Encode sixteen already classified Latin-1 units in two eight-unit lanes.
pub inline fn latin16(output: []u8, written: usize, units: @Vector(16, u16)) usize {
    const U = @Vector(16, u16);
    const B = @Vector(32, u8);
    const narrow: @Vector(16, u8) = @truncate(units);
    const non_ascii: u16 = @bitCast(narrow >= @as(@Vector(16, u8), @splat(0x80)));
    if (non_ascii == 0) {
        output[written..][0..16].* = narrow;
        return written + 16;
    }
    const first = @select(u16, units < @as(U, @splat(0x80)), units, (units >> @splat(6)) | @as(U, @splat(0xc0)));
    const second = (units & @as(U, @splat(0x3f))) | @as(U, @splat(0x80));
    const bytes: B = @bitCast(first | (second << @splat(8)));
    const a = latin_controls[@as(u8, @truncate(non_ascii))];
    const b = latin_controls[@as(u8, @truncate(non_ascii >> 8))];
    const mask: B = @shuffle(u8, a, b, blk: {
        var indices: [32]i32 = undefined;
        for (0..16) |i| {
            indices[i] = @intCast(i);
            indices[16 + i] = ~@as(i32, @intCast(i));
        }
        break :blk indices;
    });
    const encoded = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> B),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    );
    const low_count: usize = 8 + @as(usize, @popCount(@as(u8, @truncate(non_ascii))));
    const high_count: usize = 8 + @as(usize, @popCount(@as(u8, @truncate(non_ascii >> 8))));
    return storeLanes(output, written, encoded, low_count, high_count);
}

inline fn storeLanes(output: []u8, written: usize, encoded: @Vector(32, u8), low_count: usize, high_count: usize) usize {
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
    return store(output, store(output, written, low, low_count), high, high_count);
}

inline fn store(output: []u8, written: usize, bytes: V, count: usize) usize {
    if (output.len - written >= 16) output[written..][0..16].* = bytes else {
        const tail: [16]u8 = bytes;
        @memcpy(output[written..][0..count], tail[0..count]);
    }
    return written + count;
}

/// Encode eight BMP scalars after the caller has excluded surrogates.
pub inline fn encode8Valid(output: []u8, written: usize, units: @Vector(8, u16)) usize {
    const U = @Vector(8, u16);
    const W = @Vector(8, u32);
    const B = @Vector(32, u8);
    if (@reduce(.And, units < @as(U, @splat(0x100)))) return latin8(output, written, units);
    const value: W = @intCast(units);
    const code = widthCode(8, units);
    const first = @select(u32, value < @as(W, @splat(0x80)), value, @select(u32, value < @as(W, @splat(0x800)), (value >> @splat(6)) | @as(W, @splat(0xc0)), (value >> @splat(12)) | @as(W, @splat(0xe0))));
    const second = @select(u32, value < @as(W, @splat(0x800)), value & @as(W, @splat(0x3f)), (value >> @splat(6)) & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const third = (value & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const words = first | (second << @splat(8)) | (third << @splat(16));
    const low_control = controls[@as(u8, @truncate(code))];
    const high_control = controls[@as(u8, @truncate(code >> 8))];
    const low_mask = low_control.shuffle;
    const high_mask = high_control.shuffle;
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
    return storeLanes(output, written, encoded, low_control.count, high_control.count);
}

fn makeControls() [256]Control {
    @setEvalBranchQuota(20000);
    var result: [256]Control = undefined;
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
        result[code] = .{ .shuffle = mask, .count = @intCast(written) };
    }
    return result;
}

inline fn widthCode(comptime n: usize, units: @Vector(n, u16)) std.meta.Int(.unsigned, n * 2) {
    const U = @Vector(n, u16);
    // Each UTF-16 lane contributes two adjacent movemask bits: 00, 01, 10.
    const flags = @select(u16, units >= @as(U, @splat(0x800)), @as(U, @splat(0x8000)), @select(u16, units >= @as(U, @splat(0x80)), @as(U, @splat(0x80)), @as(U, @splat(0))));
    const bytes: @Vector(n * 2, i8) = @bitCast(flags);
    return @bitCast(bytes < @as(@Vector(n * 2, i8), @splat(0)));
}

pub inline fn encode(output: []u8, written: usize, units: @Vector(4, u16)) ?usize {
    if (comptime !supported) return null;
    const U = @Vector(4, u16);
    const W = @Vector(4, u32);
    const value: W = @intCast(units);
    if (@reduce(.And, units < @as(U, @splat(0x80)))) {
        const bytes: @Vector(4, u8) = @truncate(units);
        output[written..][0..4].* = bytes;
        return written + 4;
    }
    if (@reduce(.Or, (units & @as(U, @splat(0xf800))) == @as(U, @splat(0xd800)))) return null;
    const code = widthCode(4, units);
    const first = @select(u32, value < @as(W, @splat(0x80)), value, @select(u32, value < @as(W, @splat(0x800)), (value >> @splat(6)) | @as(W, @splat(0xc0)), (value >> @splat(12)) | @as(W, @splat(0xe0))));
    const second = @select(u32, value < @as(W, @splat(0x800)), value & @as(W, @splat(0x3f)), (value >> @splat(6)) & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const third = (value & @as(W, @splat(0x3f))) | @as(W, @splat(0x80));
    const words = first | (second << @splat(8)) | (third << @splat(16));
    const bytes: V = @bitCast(words);
    const control = controls[code];
    const mask = control.shuffle;
    const encoded = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> V),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    );
    return store(output, written, encoded, control.count);
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
