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
    const prev2 = load(text, offset - 2);
    const prev3 = load(text, offset - 3);
    return errorsWithPrevious(bytes, prev1, prev2, prev3);
}

inline fn errorsWithPrevious(bytes: V, prev1: V, prev2: V, prev3: V) V {
    const special = lookup(previous_high, prev1 >> @splat(4)) &
        lookup(previous_low, prev1 & @as(V, @splat(15))) &
        lookup(current_high, bytes >> @splat(4));
    const required = (prev2 >= @as(V, @splat(0xe0))) |
        (prev3 >= @as(V, @splat(0xf0)));
    return special ^ @select(u8, required, @as(V, @splat(0x80)), @as(V, @splat(0)));
}

inline fn clean(value: V) bool {
    return @reduce(.And, value == @as(V, @splat(0)));
}

/// Check 16-32 bytes with one lookup window. Three ASCII padding bytes make
/// lookbehind readable. Trailing ASCII padding detects incomplete scalars;
/// a full 32-byte input instead needs the independent tail-completeness check.
pub noinline fn isValidShort(text: []const u8) bool {
    if (text.len == 32) {
        const bytes = load(text, 0);
        const half = @shuffle(u8, @as(V, @splat(0)), bytes, blk: {
            var mask: [32]i32 = undefined;
            for (0..16) |i| {
                mask[i] = @intCast(i);
                mask[16 + i] = ~@as(i32, @intCast(i));
            }
            break :blk mask;
        });
        const e = errorsWithPrevious(bytes, previous(1, bytes, half), previous(2, bytes, half), previous(3, bytes, half));
        return clean(e) and completeTail(text);
    }
    var padded = [_]u8{0} ** 35;
    @memcpy(padded[3..][0..text.len], text);
    if (!clean(errors(&padded, 3, load(&padded, 3)))) return false;
    return true;
}

// Both 128-bit lanes share the same carried half; three lane alignments
// then produce the preceding bytes without loads before the input slice.
inline fn previous(comptime count: u5, bytes: V, half: V) V {
    return asm ("vpalignr %[amount], %[half], %[bytes], %[result]"
        : [result] "=x" (-> V),
        : [amount] "i" (@as(u8, 16 - count)),
          [half] "x" (half),
          [bytes] "x" (bytes),
    );
}

/// Validate the bytes inside a 64-byte prefix starting at a scalar boundary.
/// A final scalar may need bytes beyond the prefix; the decoder must defer it.
pub inline fn validPrefix64(a: V, b: V) bool {
    if (comptime !supported) return false;
    const first = @shuffle(u8, @as(V, @splat(0)), a, blk: {
        var mask: [32]i32 = undefined;
        for (0..16) |i| {
            mask[i] = @intCast(i);
            mask[16 + i] = ~@as(i32, @intCast(i));
        }
        break :blk mask;
    });
    const second = @shuffle(u8, a, b, blk: {
        var mask: [32]i32 = undefined;
        for (0..16) |i| {
            mask[i] = @intCast(16 + i);
            mask[16 + i] = ~@as(i32, @intCast(i));
        }
        break :blk mask;
    });
    return clean(errorsWithPrevious(a, previous(1, a, first), previous(2, a, first), previous(3, a, first)) |
        errorsWithPrevious(b, previous(1, b, second), previous(2, b, second), previous(3, b, second)));
}

/// Caller selects this path only for inputs of at least 35 bytes. A nonzero
/// prefix is the length of the first scalar already validated by the caller;
/// zero means that the first byte is ASCII and its run is still to be scanned.
pub noinline fn isValid(text: []const u8, prefix: usize) bool {
    var offset = prefix;
    if (offset == 0) {
        offset = scalar.asciiSpan(text);
        if (offset == text.len) return true;
    }
    // At least three validated prefix bytes make the lookbehind loads
    // readable. One three- or four-byte scalar is enough; an ASCII prefix
    // is consumed just once, even if the first non-ASCII byte is near EOF.
    while (offset < 3) {
        const length = scalar.sequenceLen(text, offset);
        if (length == 0) return false;
        offset += length;
    }

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

    // Pair checks have rejected all invalid adjacent-byte combinations.
    // Only leads that need more bytes than remain at EOF can be incomplete.
    return completeTail(text);
}

inline fn completeTail(text: []const u8) bool {
    return text[text.len - 1] < 0xc0 and
        text[text.len - 2] < 0xe0 and
        text[text.len - 3] < 0xf0;
}
