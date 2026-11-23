//! Vectorized UTF-8 validation.
//!
//! `std.unicode.utf8ValidateSlice` walks the text scalar by scalar, which
//! costs about one nanosecond per byte on non-ASCII input. This validator
//! classifies 32 bytes at a time: it derives the set of positions that must
//! hold a continuation byte from the three preceding bytes and compares that
//! against the actual continuation bytes, then rejects the four overlong and
//! out-of-range second-byte windows (U+0000..U+07FF overlongs, surrogates,
//! and scalars above U+10FFFF). The first and last few bytes are validated
//! with the scalar sequence checker so window edges never need carry state.

const std = @import("std");

const vector_len = 32;
const V = @Vector(vector_len, u8);

const ascii_max: u8 = 0x7f;
const cont_min: u8 = 0x80;
const lead2_min: u8 = 0xc2;
const lead3_min: u8 = 0xe0;
const lead4_min: u8 = 0xf0;
const lead4_max: u8 = 0xf4;

/// Length of the sequence starting at `offset`, or null when the bytes there
/// are not a well-formed UTF-8 scalar.
inline fn sequenceLen(text: []const u8, offset: usize) ?usize {
    const first = text[offset];
    if (first <= ascii_max) return 1;
    if (first < lead2_min) return null;
    if (first < lead3_min) {
        if (offset + 2 > text.len) return null;
        if (text[offset + 1] & 0xc0 != 0x80) return null;
        return 2;
    }
    if (first < lead4_min) {
        if (offset + 3 > text.len) return null;
        const second = text[offset + 1];
        if (second & 0xc0 != 0x80) return null;
        // U+0800..U+0FFF overlongs and the surrogate block.
        if (first == 0xe0 and second < 0xa0) return null;
        if (first == 0xed and second >= 0xa0) return null;
        if (text[offset + 2] & 0xc0 != 0x80) return null;
        return 3;
    }
    if (first <= lead4_max) {
        if (offset + 4 > text.len) return null;
        const second = text[offset + 1];
        if (second & 0xc0 != 0x80) return null;
        // U+10000..U+3FFFF overlongs and scalars above U+10FFFF.
        if (first == 0xf0 and second < 0x90) return null;
        if (first == 0xf4 and second >= 0x90) return null;
        if (text[offset + 2] & 0xc0 != 0x80) return null;
        if (text[offset + 3] & 0xc0 != 0x80) return null;
        return 4;
    }
    return null;
}

/// True when every byte is ASCII. Eight bytes per step keeps short ASCII
/// strings, the common `compare` input, away from the scalar sequence loop.
fn asciiOnly(text: []const u8) bool {
    var offset: usize = 0;
    while (offset + 8 <= text.len) : (offset += 8) {
        const word = std.mem.readInt(u64, text[offset..][0..8], .little);
        if (word & 0x8080_8080_8080_8080 != 0) return false;
    }
    while (offset < text.len) : (offset += 1) {
        if (text[offset] >= 0x80) return false;
    }
    return true;
}

/// Scalar validation for short inputs, window prefixes, and tails.
pub fn scalarValid(text: []const u8) bool {
    var offset: usize = 0;
    while (offset < text.len) {
        offset += sequenceLen(text, offset) orelse return false;
    }
    return true;
}

/// Lane mask that shifts `input` right by `shift` lanes, taking the first
/// lanes from the four bytes before the window.
fn shiftMask(comptime shift: usize) [vector_len]i32 {
    var mask: [vector_len]i32 = undefined;
    for (0..vector_len) |lane| {
        mask[lane] = if (lane < shift)
            ~@as(i32, @intCast(3 - shift + lane))
        else
            @as(i32, @intCast(lane - shift));
    }
    return mask;
}

/// Validate one 32-byte window starting at `offset`. The caller guarantees
/// `offset >= 3` and `offset + 33 <= text.len`, so the three preceding bytes
/// and the one following byte are readable.
inline fn windowValid(text: []const u8, offset: usize) bool {
    const bytes: V = text[offset..][0..vector_len].*;
    const carry: @Vector(4, u8) = @bitCast(text[offset - 3 ..][0..4].*);
    const after: @Vector(1, u8) = @bitCast(text[offset + vector_len ..][0..1].*);

    // ASCII-heavy windows need no classification at all: when the window is
    // all ASCII and the byte before it is too, no earlier lead can reach into
    // it (a crossing lead would have needed a continuation there).
    if (text[offset - 1] < 0x80 and
        @reduce(.And, bytes < @as(V, @splat(0x80))))
    {
        return true;
    }

    const next = @shuffle(
        u8,
        bytes,
        after,
        blk: {
            var mask: [vector_len]i32 = undefined;
            for (0..vector_len - 1) |lane| mask[lane] = @intCast(lane + 1);
            mask[vector_len - 1] = ~@as(i32, 0);
            break :blk mask;
        },
    );

    const mask_c0: V = @splat(0xc0);
    const mask_e0: V = @splat(0xe0);
    const mask_f0: V = @splat(0xf0);
    const mask_f8: V = @splat(0xf8);
    const cont_marker: V = @splat(cont_min);
    const lead2_marker: V = @splat(0xc0);
    const lead3_marker: V = @splat(lead3_min);
    const lead4_marker: V = @splat(lead4_min);

    const is_cont = (bytes & mask_c0) == cont_marker;
    const lead2 = (bytes & mask_e0) == lead2_marker;
    const lead3 = (bytes & mask_f0) == lead3_marker;
    const lead4 = (bytes & mask_f8) == lead4_marker;
    const carry2 = (carry & @as(@Vector(4, u8), @splat(0xe0))) ==
        @as(@Vector(4, u8), @splat(0xc0));
    const carry3 = (carry & @as(@Vector(4, u8), @splat(0xf0))) ==
        @as(@Vector(4, u8), @splat(0xe0));
    const carry4 = (carry & @as(@Vector(4, u8), @splat(0xf8))) ==
        @as(@Vector(4, u8), @splat(0xf0));

    // A position must hold a continuation byte when the byte one, two, or
    // three positions earlier starts a sequence that reaches it.
    const prev1 = @shuffle(bool, lead2 | lead3 | lead4, carry2 | carry3 | carry4, shiftMask(1));
    const prev2 = @shuffle(bool, lead3 | lead4, carry3 | carry4, shiftMask(2));
    const prev3 = @shuffle(bool, lead4, carry4, shiftMask(3));
    const expected = prev1 | prev2 | prev3;
    if (@reduce(.Or, is_cont != expected)) return false;

    // C0 and C1 encode overlongs, and F5..FF exceed U+10FFFF or are not
    // leads at all. Only the second byte of a sequence needs a range check:
    // E0 below A0, ED at A0 or above, F0 below 90, and F4 at 90 or above are
    // invalid.
    const bad_lead = (bytes == @as(V, @splat(0xc0))) |
        (bytes == @as(V, @splat(0xc1))) |
        (bytes >= @as(V, @splat(0xf5)));
    const overlong3 = (bytes == @as(V, @splat(0xe0))) &
        (next < @as(V, @splat(0xa0)));
    const surrogate = (bytes == @as(V, @splat(0xed))) &
        (next >= @as(V, @splat(0xa0)));
    const overlong4 = (bytes == @as(V, @splat(0xf0))) &
        (next < @as(V, @splat(0x90)));
    const too_large = (bytes == @as(V, @splat(0xf4))) &
        (next >= @as(V, @splat(0x90)));
    if (@reduce(.Or, bad_lead | overlong3 | surrogate | overlong4 | too_large)) {
        return false;
    }
    return true;
}

/// True when `text` is well-formed UTF-8.
pub fn isValid(text: []const u8) bool {
    // Below this length the scalar prefix and tail would cover most of the
    // text, so the scalar checker is cheaper.
    if (text.len < vector_len + 16) {
        return asciiOnly(text) or scalarValid(text);
    }

    // Validate the first three sequences scalar-wise so the window scan can
    // look three bytes back and still start on a sequence boundary.
    var offset: usize = 0;
    var sequences: usize = 0;
    while (sequences < 3) : (sequences += 1) {
        offset += sequenceLen(text, offset) orelse return false;
    }

    while (offset + vector_len + 1 <= text.len) : (offset += vector_len) {
        if (!windowValid(text, offset)) return false;
    }

    // An ASCII tail after an ASCII byte cannot continue a lead, so it needs
    // no scalar walk.
    if (text[offset - 1] < 0x80 and asciiOnly(text[offset..])) return true;

    // The window scan may stop inside a sequence. Back up at least three
    // bytes, then to the start of the sequence that crosses the boundary, so
    // truncated and oversized tails are rejected.
    var tail = offset;
    var steps: usize = 0;
    while (tail > 0 and (steps < 3 or text[tail] & 0xc0 == 0x80)) : (steps += 1) {
        tail -= 1;
    }
    return scalarValid(text[tail..]);
}

fn expectSame(text: []const u8) !void {
    const expected = std.unicode.utf8ValidateSlice(text);
    const actual = isValid(text);
    if (expected != actual) {
        std.debug.print("validation mismatch for {any}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

test "vector validation matches the scalar validator" {
    // Every one- and two-byte string.
    var two: [2]u8 = undefined;
    for (0..256) |first| {
        two[0] = @intCast(first);
        try expectSame(two[0..1]);
        for (0..256) |second| {
            two[1] = @intCast(second);
            try expectSame(two[0..2]);
        }
    }

    // Every three-byte string.
    var three: [3]u8 = undefined;
    for (0..256) |first| {
        three[0] = @intCast(first);
        for (0..256) |second| {
            three[1] = @intCast(second);
            for (0..256) |third| {
                three[2] = @intCast(third);
                try expectSame(three[0..3]);
            }
        }
    }

    // Every four-byte string with the lead and second byte varying and the
    // continuation bytes sampled around the range edges.
    var four: [4]u8 = undefined;
    const third_values = [_]u8{ 0x00, 0x7f, 0x80, 0x9f, 0xbf, 0xc0, 0xff };
    for (0..256) |first| {
        four[0] = @intCast(first);
        for (0..256) |second| {
            four[1] = @intCast(second);
            for (third_values) |third| {
                four[2] = third;
                for (third_values) |fourth| {
                    four[3] = fourth;
                    try expectSame(four[0..4]);
                }
            }
        }
    }
}

test "vector validation rejects leads crossing the tail boundary" {
    const testing = std.testing;
    // 229 bytes make the last window start at 227, so a lead at 226 reaches
    // into the scalar tail. The tail scan must back up far enough to recheck
    // it.
    var buffer = [_]u8{'a'} ** 229;
    buffer[226] = 0xeb;
    buffer[227] = 'x';
    try testing.expect(!isValid(&buffer));
    try testing.expect(!std.unicode.utf8ValidateSlice(&buffer));

    buffer[226] = 0xc3;
    try testing.expect(!isValid(&buffer));

    buffer[227] = 0xa9;
    try testing.expect(isValid(&buffer));
    try testing.expect(std.unicode.utf8ValidateSlice(&buffer));

    // A three-byte scalar ending exactly at the last byte is valid.
    buffer[226] = 0xe4;
    buffer[227] = 0x96;
    buffer[228] = 0x87;
    try testing.expect(isValid(&buffer));
    try testing.expect(std.unicode.utf8ValidateSlice(&buffer));

    // Truncating it must fail.
    try testing.expect(!isValid(buffer[0..228]));
    try testing.expect(!std.unicode.utf8ValidateSlice(buffer[0..228]));
}

test "vector validation matches on window boundaries" {
    var buffer: [160]u8 = undefined;

    // Build valid text of every length in the window range, then mutate each
    // byte to a set of interesting values.
    const piece = "a\u{00e9}\u{4e16}\u{1f600}\u{0301}";
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const random = prng.random();

    var round: usize = 0;
    while (round < 4000) : (round += 1) {
        const length = 60 + random.uintLessThan(usize, 100);
        var filled: usize = 0;
        while (filled < length) {
            const scalar = piece[random.uintLessThan(usize, piece.len)];
            buffer[filled] = scalar;
            filled += 1;
        }
        // The random fill is not necessarily valid; compare either way.
        try expectSame(buffer[0..length]);

        const position = random.uintLessThan(usize, length);
        const original = buffer[position];
        const replacements = [_]u8{
            0x00, 0x41, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0,
            0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xef,
            0xf0, 0xf4, 0xf5, 0xff,
        };
        for (replacements) |replacement| {
            buffer[position] = replacement;
            try expectSame(buffer[0..length]);
        }
        buffer[position] = original;
    }
}

test "vector validation matches on valid text and mutations" {
    const testing = std.testing;
    var buffer: [256]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x243f6a8885a308d3);
    const random = prng.random();

    var round: usize = 0;
    while (round < 3000) : (round += 1) {
        // Generate valid text: random scalars, including ASCII runs.
        var filled: usize = 0;
        while (filled + 4 <= buffer.len) {
            const choice = random.uintLessThan(u8, 8);
            const codepoint: u21 = if (choice < 4)
                random.uintLessThan(u8, 0x80)
            else if (choice < 6)
                0x80 + random.uintLessThan(u21, 0x780)
            else if (choice < 7)
                0x800 + random.uintLessThan(u21, 0xd000)
            else if (choice == 7)
                0xe000 + random.uintLessThan(u21, 0x2000)
            else
                0x10000 + random.uintLessThan(u21, 0x100000);
            const length = std.unicode.utf8Encode(codepoint, buffer[filled..][0..4]) catch unreachable;
            filled += length;
        }
        try testing.expect(isValid(buffer[0..filled]));
        try expectSame(buffer[0..filled]);

        // Single-byte mutations at random positions.
        for (0..8) |_| {
            const position = random.uintLessThan(usize, filled);
            const original = buffer[position];
            buffer[position] = random.int(u8);
            try expectSame(buffer[0..filled]);
            buffer[position] = original;
        }
    }
}
