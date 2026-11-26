//! Vector windows and cross-window continuation masks for UTF-8 validation.

const std = @import("std");
const scalar = @import("scalar.zig");
const sequenceLen = scalar.sequenceLen;
const scalarValid = scalar.scalarValid;
const asciiOnly = scalar.asciiOnly;
const vector_len = 32;
const V = @Vector(vector_len, u8);

/// Validate one 32-byte window starting at `offset`. The caller guarantees
/// `offset + 33 <= text.len`, so the window and its one-byte lookahead
/// are readable. The carry describes continuation requirements at its start.
inline fn windowValid(text: []const u8, offset: usize, carry: u32) ?u32 {
    const bytes = @as(*align(1) const V, @ptrCast(text.ptr + offset)).*;
    const high: u32 = @bitCast(bytes >= @as(V, @splat(0x80)));

    // ASCII-heavy windows need no classification at all: when the window is
    // all ASCII and the byte before it is too, no earlier lead can reach into
    // it (a crossing lead would have needed a continuation there). The carry
    // and lookahead loads stay on the non-ASCII path.
    if (carry == 0 and high == 0) {
        return 0;
    }

    // Invalid leads are rejected below; including them here makes the lead
    // classes three unsigned comparisons instead of masked classifications.
    const lead234: u32 = @bitCast(bytes >= @as(V, @splat(0xc0)));
    const continuations = high ^ lead234;
    const lead34: u32 = @bitCast(bytes >= @as(V, @splat(0xe0)));

    // Accented Latin and every two-byte script fill most windows with ASCII
    // and two-byte sequences. Those windows need no lookahead shuffle and
    // none of the three- and four-byte range checks, so they take a compact
    // branch of their own.
    if (lead34 == 0) {
        const expected = (@as(u64, lead234) << 1) | carry;
        if (continuations != @as(u32, @truncate(expected))) return null;
        // C0 and C1 encode overlongs, and F5..FF exceed U+10FFFF or are not
        // leads at all.
        const bad_lead = (bytes == @as(V, @splat(0xc0))) |
            (bytes == @as(V, @splat(0xc1))) |
            (bytes >= @as(V, @splat(0xf5)));
        if (@reduce(.Or, bad_lead)) return null;
        return @intCast(expected >> vector_len);
    }

    const lead4_only: u32 = @bitCast(bytes >= @as(V, @splat(0xf0)));
    // Preserve the three bits beyond this window for the next window. The
    // validated preceding window supplies all cross-window continuation
    // requirements, with no scalar carry reconstruction in the hot loop.
    const expected = (@as(u64, lead234) << 1) |
        (@as(u64, lead34) << 2) | (@as(u64, lead4_only) << 3) | carry;
    if (continuations != @as(u32, @truncate(expected))) return null;
    const next_carry: u32 = @intCast(expected >> vector_len);

    // Only the second byte of a sequence needs a range check: E0 below A0,
    // ED at A0 or above, F0 below 90, and F4 at 90 or above are invalid.
    const bad_lead = (bytes == @as(V, @splat(0xc0))) |
        (bytes == @as(V, @splat(0xc1))) |
        (bytes >= @as(V, @splat(0xf5)));
    // CJK prose is entirely three-byte sequences: a window without four-byte
    // leads skips the F0/F4 checks, and without E0 or ED leads it needs no
    // lookahead at all.
    if (lead4_only == 0) {
        if (!@reduce(.Or, (bytes == @as(V, @splat(0xe0))) |
            (bytes == @as(V, @splat(0xed)))))
        {
            if (@reduce(.Or, bad_lead)) return null;
            return next_carry;
        }
        const next = @as(*align(1) const V, @ptrCast(text.ptr + offset + 1)).*;
        const overlong3 = (bytes == @as(V, @splat(0xe0))) &
            (next < @as(V, @splat(0xa0)));
        const surrogate = (bytes == @as(V, @splat(0xed))) &
            (next >= @as(V, @splat(0xa0)));
        if (@reduce(.Or, bad_lead | overlong3 | surrogate)) return null;
        return next_carry;
    }
    const next = @as(*align(1) const V, @ptrCast(text.ptr + offset + 1)).*;
    const overlong3 = (bytes == @as(V, @splat(0xe0))) &
        (next < @as(V, @splat(0xa0)));
    const surrogate = (bytes == @as(V, @splat(0xed))) &
        (next >= @as(V, @splat(0xa0)));
    const overlong4 = (bytes == @as(V, @splat(0xf0))) &
        (next < @as(V, @splat(0x90)));
    const too_large = (bytes == @as(V, @splat(0xf4))) &
        (next >= @as(V, @splat(0x90)));
    if (@reduce(.Or, bad_lead | overlong3 | surrogate | overlong4 | too_large)) {
        return null;
    }
    return next_carry;
}

/// Reconstruct carry only for the overlapping final window, which need not
/// line up with the previous window. The main loop carries the mask directly.
inline fn carryBefore(text: []const u8, offset: usize) u32 {
    const a = text[offset - 1];
    const b = text[offset - 2];
    const c = text[offset - 3];
    var carry: u32 = 0;
    if (a >= 0xc2 and a <= 0xf4) carry |= 1;
    if (b >= 0xe0 and b <= 0xf4) carry |= 1;
    if (c >= 0xf0 and c <= 0xf4) carry |= 1;
    if (a >= 0xe0 and a <= 0xf4) carry |= 2;
    if (b >= 0xf0 and b <= 0xf4) carry |= 2;
    if (a >= 0xf0 and a <= 0xf4) carry |= 4;
    return carry;
}

/// True when `text` is well-formed UTF-8.
pub fn isValid(text: []const u8) bool {
    // Below this length the scalar prefix and tail would cover most of the
    // text, so the scalar checker is cheaper.
    if (text.len < vector_len + 1) {
        return asciiOnly(text) or scalarValid(text);
    }
    return scan(text);
}

// Keep the window loop in its own function so large callers do not spill
// vector constants or carry state into their surrounding stack frame.
noinline fn scan(text: []const u8) bool {
    // Catch an invalid initial byte before entering the window loop. The
    // first window starts at zero, so no scalar prefix needs revalidation.
    if (text[0] >= 0x80 and sequenceLen(text, 0) == null) return false;
    var offset: usize = 0;
    var carry: u32 = 0;
    while (offset + vector_len + 1 <= text.len) : (offset += vector_len) {
        carry = windowValid(text, offset, carry) orelse return false;
    }

    // An ASCII tail after an ASCII byte cannot continue a lead, so it needs
    // no scalar walk.
    if (text[offset - 1] < 0x80 and asciiOnly(text[offset..])) return true;

    // The remaining bytes are fewer than one window. Re-validate them with an
    // overlapping window, which leaves only the final sequence for the scalar
    // checker; on short inputs the plain tail used to cover a tenth of the
    // text.
    if (offset < text.len and text.len >= vector_len + 4) {
        const final_offset = text.len - vector_len - 1;
        _ = windowValid(text, final_offset, carryBefore(text, final_offset)) orelse return false;
        // The window stops one byte short, and a lead at its last position
        // can reach past the end, so the scalar check starts at the sequence
        // containing the final window byte.
        var tail = text.len - 2;
        var steps: usize = 0;
        while (tail > 0 and text[tail] & 0xc0 == 0x80 and steps < 3) : (steps += 1) {
            tail -= 1;
        }
        return scalarValid(text[tail..]);
    }

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
