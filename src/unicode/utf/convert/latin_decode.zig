//! Decode eight variable-width ASCII/two-byte UTF-8 scalars with one shuffle.
const std = @import("std");
const builtin = @import("builtin");
pub const supported = builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);
const B = @Vector(16, u8);
const W = @Vector(8, u16);
const controls = makeControls();
pub const Block = struct { units: W, consumed: usize };

fn makeControls() [256]B {
    @setEvalBranchQuota(10000);
    var result: [256]B = undefined;
    for (0..256) |code| {
        var mask: [16]u8 = undefined;
        var position: u8 = 0;
        for (0..8) |i| {
            const wide = (code >> i) & 1 != 0;
            mask[i * 2] = position;
            mask[i * 2 + 1] = if (wide) position + 1 else 0x80;
            position += if (wide) @as(u8, 2) else 1;
        }
        result[code] = mask;
    }
    return result;
}

inline fn highMask(bytes: B) u16 {
    return @truncate(asm ("vpmovmskb %[bytes], %[result]"
        : [result] "=r" (-> u32),
        : [bytes] "x" (bytes),
    ));
}

pub inline fn decode(comptime checked: bool, text: []const u8, index: usize) ?Block {
    if (comptime !supported) return null;
    const bytes = @as(*align(1) const B, @ptrCast(text.ptr + index)).*;
    return decodeBytes(checked, bytes);
}

pub inline fn decodeBytes(comptime checked: bool, bytes: B) ?Block {
    if (comptime !supported) return null;
    var invalid = (bytes & @as(B, @splat(0xe0))) == @as(B, @splat(0xe0));
    if (checked) invalid |= (bytes & @as(B, @splat(0xfe))) == @as(B, @splat(0xc0));
    if (@reduce(.Or, invalid)) return null;
    const high = highMask(bytes);
    const cont: u16 = @bitCast((bytes & @as(B, @splat(0xc0))) == @as(B, @splat(0x80)));
    const lead = high ^ cont;
    if (checked and cont != @as(u16, @truncate(@as(u32, lead) << 1))) return null;
    const starts: u32 = @as(u16, ~cont);
    const flags = asm ("pext %[mask], %[value], %[result]"
        : [result] "=r" (-> u32),
        : [mask] "r" (starts),
          [value] "r" (@as(u32, lead)),
    );
    const code: u8 = @truncate(flags);
    const mask = controls[code];
    const pairs: W = @bitCast(asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> B),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    ));
    const two = ((pairs & @as(W, @splat(0x1f))) << @splat(6)) |
        ((pairs >> @splat(8)) & @as(W, @splat(0x3f)));
    return .{ .units = @select(u16, (pairs & @as(W, @splat(0x80))) == @as(W, @splat(0)), pairs, two), .consumed = 8 + @as(usize, @popCount(code)) };
}

pub const Run = struct { consumed: usize, written: usize };

// Keep the table and width-decode state local across a complete one/two-byte run.
pub noinline fn run(comptime checked: bool, text: []const u8, output: []u16) ?Run {
    const first = decode(checked, text, 0) orelse return null;
    output[0..8].* = first.units;
    var index = first.consumed;
    var written: usize = 8;
    while (index + 16 <= text.len) {
        const bytes = @as(*align(1) const B, @ptrCast(text.ptr + index)).*;
        if (highMask(bytes) == 0) {
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
    return .{ .consumed = index, .written = written };
}
