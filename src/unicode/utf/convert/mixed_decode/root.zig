//! General bounded UTF-8 windows, including mixed BMP and supplementary scalars.
const validation = @import("../../../scalar/validation/avx2.zig");
const tables = @import("tables.zig");
const B = tables.B;
const V = @Vector(32, u8);
const W = @Vector(4, u32);
pub const supported = validation.supported;
pub const Run = struct { consumed: usize, written: usize };

pub inline fn candidate(bytes: B) bool {
    if (!@reduce(.Or, bytes >= @as(B, @splat(0xe0)))) return false;
    const cont: u16 = @bitCast((bytes & @as(B, @splat(0xc0))) == @as(B, @splat(0x80)));
    const starts = ~cont;
    const values: [16]u8 = bytes;
    return !((starts == 0x9249 and values[0] >= 0xe0 and values[0] < 0xf0) or
        (starts == 0x1111 and values[0] >= 0xf0));
}

/// Classify a bounded 64-byte window after an ASCII run.
pub inline fn denseCandidate(text: []const u8) bool {
    const a = @as(*align(1) const V, @ptrCast(text.ptr)).*;
    const b = @as(*align(1) const V, @ptrCast(text.ptr + 32)).*;
    const high_a: u32 = @bitCast(a >= @as(V, @splat(0x80)));
    const high_b: u32 = @bitCast(b >= @as(V, @splat(0x80)));
    const first: [32]u8 = a;
    return @as(usize, @popCount(high_a)) + @popCount(high_b) > 32 and candidate(first[0..16].*);
}

inline fn shuffle(bytes: B, mask: B) B {
    return asm ("vpshufb %[mask], %[bytes], %[result]"
        : [result] "=x" (-> B),
        : [mask] "x" (mask),
          [bytes] "x" (bytes),
    );
}

inline fn decode(bytes: B, entry: tables.Entry, output: []u16, written: usize) usize {
    const code = entry.control;
    const control = tables.controls[code];
    const perm = shuffle(bytes, control.shuffle);
    if (code >= 320) {
        const U = @Vector(8, u16);
        const pairs: U = @bitCast(perm);
        const cp = (pairs & @as(U, @splat(0x7f))) | ((pairs & @as(U, @splat(0x1f00))) >> @splat(2));
        const units: [8]u16 = cp;
        output[written..][0..6].* = units[0..6].*;
        return written + 6;
    }
    {
        const words: W = @bitCast(perm & control.bits);
        const cp = (words & @as(W, @splat(0xff))) |
            ((words & @as(W, @splat(0xff00))) >> @splat(2)) |
            ((words & @as(W, @splat(0xff0000))) >> @splat(4)) |
            ((words & @as(W, @splat(0xff000000))) >> @splat(6));
        const high = ((cp -% @as(W, @splat(0x10000))) >> @splat(10)) & @as(W, @splat(0x3ff));
        const low = cp & @as(W, @splat(0x3ff));
        const pairs = (high | @as(W, @splat(0xd800))) | ((low | @as(W, @splat(0xdc00))) << @splat(16));
        const encoded = @select(u32, cp >= @as(W, @splat(0x10000)), pairs, cp);
        const units: [8]u16 = @bitCast(shuffle(@bitCast(encoded), control.units_shuffle));
        // The loop retains at least sixteen input bytes at this point.
        // Valid UTF-8 needs at least six UTF-16 units for those bytes;
        // later groups replace padding without crossing the output slice.
        output[written..][0..6].* = units[0..6].*;
    }
    return written + entry.units;
}

pub noinline fn run(comptime checked: bool, text: []const u8, output: []u16) error{InvalidUtf8}!Run {
    var index: usize = 0;
    var written: usize = 0;
    while (index + 64 <= text.len) {
        const a = @as(*align(1) const V, @ptrCast(text.ptr + index)).*;
        const b = @as(*align(1) const V, @ptrCast(text.ptr + index + 32)).*;
        if (checked and !validation.validPrefix64(a, b)) return error.InvalidUtf8;
        const cont_a: u32 = @bitCast((a & @as(V, @splat(0xc0))) == @as(V, @splat(0x80)));
        const cont_b: u32 = @bitCast((b & @as(V, @splat(0xc0))) == @as(V, @splat(0x80)));
        var ends = ~(@as(u64, cont_a) | (@as(u64, cont_b) << 32)) >> 1;
        var consumed: usize = 0;
        while (consumed + 16 <= 64) {
            const bytes = @as(*align(1) const B, @ptrCast(text.ptr + index + consumed)).*;
            if (@as(u16, @truncate(ends)) == 0xffff) {
                const units: @Vector(16, u16) = @intCast(bytes);
                output[written..][0..16].* = units;
                written += 16;
                consumed += 16;
                ends >>= 16;
                continue;
            }
            const key: u12 = @truncate(ends);
            if (key == 0xfff) {
                const units: [16]u16 = @as(@Vector(16, u16), @intCast(bytes));
                output[written..][0..12].* = units[0..12].*;
                written += 12;
                consumed += 12;
                ends >>= 12;
                continue;
            }
            const entry = tables.index[key];
            if (entry.control == 511) return error.InvalidUtf8;
            written = decode(bytes, entry, output, written);
            consumed += entry.consumed;
            const amount: u6 = @intCast(entry.consumed);
            ends >>= amount;
        }
        index += consumed;
    }
    return .{ .consumed = index, .written = written };
}
