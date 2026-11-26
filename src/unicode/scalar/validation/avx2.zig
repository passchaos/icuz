//! AVX2 UTF-8 lookup validation, adapted from simdutf's lookup4 algorithm.
//! The nibble tables are covered by licenses/simdutf-MIT.txt.
//!
//! Overlapping vector loads provide the three preceding bytes directly;
//! pairs of windows share one error check and one ASCII check. All reads
//! remain inside the input, including the overlapping final window.

const std = @import("std");
const builtin = @import("builtin");
const scalar = @import("scalar.zig");
const V = @Vector(32, u8);

pub const supported = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2) and
    builtin.zig_backend == .stage2_llvm;

// Independent error bits for pairs of adjacent bytes. The top bit denotes
// two continuations; it is cancelled when a lead two or three bytes back
// actually requires that second continuation.
const short = 1;
const long = 2;
const overlong3 = 4;
const large = 8;
const surrogate = 16;
const overlong2 = 32;
const large_1000_or_overlong4 = 64;
const two_continuations = 128;
const carry = short | long | two_continuations;

fn table(comptime values: [16]u8) V {
    return values ++ values;
}

const previous_high = table(.{
    long,              long,              long,              long,              long,              long,  long,                          long,
    two_continuations, two_continuations, two_continuations, two_continuations, short | overlong2, short, short | overlong3 | surrogate, short | large | large_1000_or_overlong4,
});
const previous_low = table(.{
    carry | overlong3 | overlong2 | large_1000_or_overlong4,
    carry | overlong2,
    carry,
    carry,
    carry | large,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4 | surrogate,
    carry | large | large_1000_or_overlong4,
    carry | large | large_1000_or_overlong4,
});
const current_high = table(.{
    short,                                                                      short,                                                    short,                                                    short,                                                    short, short, short, short,
    long | overlong2 | two_continuations | overlong3 | large_1000_or_overlong4, long | overlong2 | two_continuations | overlong3 | large, long | overlong2 | two_continuations | surrogate | large, long | overlong2 | two_continuations | surrogate | large, short, short, short, short,
});

inline fn lookup(values: V, indices: V) V {
    return asm ("vpshufb %[indices], %[values], %[result]"
        : [result] "=x" (-> V),
        : [values] "x" (values),
          [indices] "x" (indices),
    );
}

inline fn load(text: []const u8, offset: usize) V {
    return @as(*align(1) const V, @ptrCast(text.ptr + offset)).*;
}

inline fn errors(text: []const u8, offset: usize, bytes: V) V {
    const prev1 = load(text, offset - 1);
    const special = lookup(previous_high, prev1 >> @splat(4)) &
        lookup(previous_low, prev1 & @as(V, @splat(15))) &
        lookup(current_high, bytes >> @splat(4));
    const prev2 = load(text, offset - 2);
    const prev3 = load(text, offset - 3);
    const required = (prev2 >= @as(V, @splat(0xe0))) |
        (prev3 >= @as(V, @splat(0xf0)));
    return special ^ @select(u8, required, @as(V, @splat(0x80)), @as(V, @splat(0)));
}

inline fn clean(value: V) bool {
    return @reduce(.And, value == @as(V, @splat(0)));
}

/// Caller selects this path only for inputs of at least 128 bytes.
pub noinline fn isValid(text: []const u8) bool {
    var offset: usize = 0;
    if (text[0] < 0x80) {
        offset = scalar.asciiSpan(text);
        if (offset == text.len) return true;
    }
    // At least three validated prefix bytes make the lookbehind loads
    // readable. One three- or four-byte scalar is enough; an ASCII prefix
    // is consumed just once, even if the first non-ASCII byte is near EOF.
    while (offset < 3) offset += scalar.sequenceLen(text, offset) orelse return false;

    while (offset + 64 <= text.len) : (offset += 64) {
        const a = load(text, offset);
        const b = load(text, offset + 32);
        if (text[offset - 1] < 0x80 and
            @reduce(.And, (a | b) < @as(V, @splat(0x80)))) continue;
        if (!clean(errors(text, offset, a) | errors(text, offset + 32, b))) return false;
    }
    if (offset + 32 <= text.len) {
        if (!clean(errors(text, offset, load(text, offset)))) return false;
        offset += 32;
    }
    if (offset < text.len) {
        const final = text.len - 32;
        if (!clean(errors(text, final, load(text, final)))) return false;
    }

    // Pair checks cannot inspect a lead that is the last byte, or determine
    // that a final continuation belongs to a truncated scalar. Check that
    // last scalar independently, with no padded or out-of-slice loads.
    var tail = text.len - 1;
    var back: usize = 0;
    while (text[tail] & 0xc0 == 0x80 and back < 3) : (back += 1) tail -= 1;
    return scalar.scalarValid(text[tail..]);
}
