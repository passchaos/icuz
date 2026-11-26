//! Bounded eight/sixteen-scalar ASCII/two-byte UTF-8 decoding.
const std = @import("std");
const builtin = @import("builtin");
pub const supported = builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);
const B = @Vector(16, u8);
const W = @Vector(8, u16);
const Control = struct { shuffle: B align(64), bits: B, weights: B };
const controls = makeControls();
const shifts = makeShifts();
const wide_supported = supported and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
pub const Block = struct { units: W, consumed: usize };
const Block16 = struct { units: @Vector(16, u16), consumed: usize };

fn makeControls() [256]Control {
    @setEvalBranchQuota(10000);
    var result: [256]Control = undefined;
    for (0..256) |code| {
        var mask: [16]u8 = undefined;
        var bits: [16]u8 = undefined;
        var weights: [16]u8 = undefined;
        var position: u8 = 0;
        for (0..8) |i| {
            const wide = (code >> i) & 1 != 0;
            mask[i * 2] = position;
            mask[i * 2 + 1] = if (wide) position + 1 else 0x80;
            bits[i * 2] = if (wide) 0x1f else 0x7f;
            bits[i * 2 + 1] = 0x3f;
            weights[i * 2] = if (wide) 64 else 1;
            weights[i * 2 + 1] = 1;
            position += if (wide) @as(u8, 2) else 1;
        }
        result[code] = .{ .shuffle = mask, .bits = bits, .weights = weights };
    }
    return result;
}

fn makeShifts() [16]B {
    var result: [16]B = undefined;
    for (0..16) |shift| {
        var mask: [16]u8 = undefined;
        for (0..16) |i| mask[i] = if (i + shift < 16) @intCast(i + shift) else 0x80;
        result[shift] = mask;
    }
    return result;
}

inline fn highMask(comptime n: usize, bytes: @Vector(n, u8)) u32 {
    return asm ("vpmovmskb %[bytes], %[result]"
        : [result] "=r" (-> u32),
        : [bytes] "x" (bytes),
    );
}

pub inline fn decodeBytes(comptime checked: bool, bytes: B) ?Block {
    if (comptime !supported) return null;
    var invalid = (bytes & @as(B, @splat(0xe0))) == @as(B, @splat(0xe0));
    if (checked) invalid |= (bytes & @as(B, @splat(0xfe))) == @as(B, @splat(0xc0));
    if (@reduce(.Or, invalid)) return null;
    const high: u16 = @truncate(highMask(16, bytes));
    const cont: u16 = @bitCast((bytes & @as(B, @splat(0xc0))) == @as(B, @splat(0x80)));
    const lead = high ^ cont;
    if (checked and cont != @as(u16, @truncate(@as(u32, lead) << 1))) return null;
    return decodeMask(bytes, lead, cont);
}

inline fn decodeMask(bytes: B, lead: u16, cont: u16) Block {
    const starts: u32 = @as(u16, ~cont);
    const flags = asm ("pext %[mask], %[value], %[result]"
        : [result] "=r" (-> u32),
        : [mask] "r" (starts),
          [value] "r" (@as(u32, lead)),
    );
    const code: u8 = @truncate(flags);
    const control = controls[code];
    const pairs: B = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> B),
        : [mask] "x" (control.shuffle),
          [bytes] "x" (bytes),
    );
    // Unsigned masked bytes times signed [64, 1] or [1, 1] weights.
    // Every result is at most 0x7ff, so the signed saturation is inactive.
    const units = asm ("vpmaddubsw %[weights], %[pairs], %[result]"
        : [result] "=x" (-> W),
        : [weights] "x" (control.weights),
          [pairs] "x" (pairs & control.bits),
    );
    return .{ .units = units, .consumed = 8 + @as(usize, @popCount(code)) };
}

inline fn join(a: B, b: B) @Vector(32, u8) {
    return @shuffle(u8, a, b, blk: {
        var mask: [32]i32 = undefined;
        for (0..16) |i| {
            mask[i] = @intCast(i);
            mask[16 + i] = ~@as(i32, @intCast(i));
        }
        break :blk mask;
    });
}

inline fn decode16(text: []const u8, index: usize, lead: u32, cont: u32) Block16 {
    const flags = asm ("pext %[mask], %[value], %[result]"
        : [result] "=r" (-> u32),
        : [mask] "r" (~cont),
          [value] "r" (lead),
    );
    const code: u16 = @truncate(flags);
    const low_code: u8 = @truncate(code);
    const low = controls[low_code];
    const high = controls[@as(u8, @truncate(code >> 8))];
    const low_count = 8 + @as(usize, @popCount(low_code));
    const first = @as(*align(1) const B, @ptrCast(text.ptr + index)).*;
    const second = @as(*align(1) const B, @ptrCast(text.ptr + index + low_count)).*;
    const V = @Vector(32, u8);
    const pairs = asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> V),
        : [mask] "x" (join(low.shuffle, high.shuffle)),
          [bytes] "x" (join(first, second)),
    );
    const units = asm ("vpmaddubsw %[weights], %[pairs], %[result]"
        : [result] "=x" (-> @Vector(16, u16)),
        : [weights] "x" (join(low.weights, high.weights)),
          [pairs] "x" (pairs & join(low.bits, high.bits)),
    );
    return .{ .units = units, .consumed = 16 + @as(usize, @popCount(code)) };
}

pub const Run = struct { consumed: usize, written: usize };

const Masks = struct { high: u64, cont: u64 };

inline fn classify64(comptime checked: bool, a: @Vector(32, u8), b: @Vector(32, u8)) ?Masks {
    const V = @Vector(32, u8);
    const high = @as(u64, highMask(32, a)) | (@as(u64, highMask(32, b)) << 32);
    if (high == 0) return .{ .high = 0, .cont = 0 };
    var bad = ((a & @as(V, @splat(0xe0))) == @as(V, @splat(0xe0))) |
        ((b & @as(V, @splat(0xe0))) == @as(V, @splat(0xe0)));
    if (checked) bad |= ((a & @as(V, @splat(0xfe))) == @as(V, @splat(0xc0))) |
        ((b & @as(V, @splat(0xfe))) == @as(V, @splat(0xc0)));
    if (@reduce(.Or, bad)) return null;
    const first: u32 = @bitCast((a & @as(V, @splat(0xc0))) == @as(V, @splat(0x80)));
    const second: u32 = @bitCast((b & @as(V, @splat(0xc0))) == @as(V, @splat(0x80)));
    const cont = @as(u64, first) | (@as(u64, second) << 32);
    const lead = high ^ cont;
    if (checked and cont != lead << 1) return null;
    return .{ .high = high, .cont = cont };
}

inline fn consume64(text: []const u8, output: []u16, masks: Masks) Run {
    var index: usize = 0;
    var written: usize = 0;
    while (index + 32 <= 64) {
        const shift: u6 = @intCast(index);
        const high: u32 = @truncate(masks.high >> shift);
        if (high == 0) {
            const bytes = @as(*align(1) const @Vector(32, u8), @ptrCast(text.ptr + index)).*;
            const units: @Vector(32, u16) = @intCast(bytes);
            output[written..][0..32].* = units;
            index += 32;
            written += 32;
        } else {
            const cont: u32 = @truncate(masks.cont >> shift);
            const block = decode16(text, index, high ^ cont, cont);
            output[written..][0..16].* = block.units;
            index += block.consumed;
            written += 16;
        }
    }
    while (index + 8 <= 64) {
        const shift: u6 = @intCast(index);
        const bytes = if (index <= 48)
            @as(*align(1) const B, @ptrCast(text.ptr + index)).*
        else blk: {
            const last = @as(*align(1) const B, @ptrCast(text.ptr + 48)).*;
            break :blk asm ("vpshufb %[mask], %[bytes], %[result]"
                : [result] "=x" (-> B),
                : [mask] "x" (shifts[index - 48]),
                  [bytes] "x" (last),
            );
        };
        const high: u16 = @truncate(masks.high >> shift);
        if (index + 16 <= 64 and high == 0) {
            const units: @Vector(16, u16) = @intCast(bytes);
            output[written..][0..16].* = units;
            index += 16;
            written += 16;
        } else {
            const cont: u16 = @truncate(masks.cont >> shift);
            const block = decodeMask(bytes, high ^ cont, cont);
            // Shifted windows are zero-padded; only complete real scalars
            // may commit. A lead in byte 63 is deferred to the next window.
            if (index + block.consumed > 64) break;
            output[written..][0..8].* = block.units;
            index += block.consumed;
            written += 8;
        }
    }
    return .{ .consumed = index, .written = written };
}

// Keep the table and width-decode state local across a complete one/two-byte run.
pub noinline fn run(comptime checked: bool, text: []const u8, output: []u16) ?Run {
    var index: usize = 0;
    var written: usize = 0;
    while (index + 16 <= text.len) {
        if (comptime wide_supported) {
            if (index + 64 <= text.len) {
                const V = @Vector(32, u8);
                const a = @as(*align(1) const V, @ptrCast(text.ptr + index)).*;
                const b = @as(*align(1) const V, @ptrCast(text.ptr + index + 32)).*;
                if (classify64(checked, a, b)) |masks| {
                    const result = consume64(text[index..], output[written..], masks);
                    index += result.consumed;
                    written += result.written;
                    continue;
                }
            }
        }
        const bytes = @as(*align(1) const B, @ptrCast(text.ptr + index)).*;
        if (highMask(16, bytes) == 0) {
            const units: @Vector(16, u16) = @intCast(bytes);
            output[written..][0..16].* = units;
            index += 16;
            written += 16;
            continue;
        }
        const block = decodeBytes(checked, bytes) orelse break;
        output[written..][0..8].* = block.units;
        index += block.consumed;
        written += 8;
    }
    if (written == 0) return null;
    return .{ .consumed = index, .written = written };
}
