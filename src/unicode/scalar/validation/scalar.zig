//! Scalar UTF-8 sequence checking and ASCII scanning.

const std = @import("std");

const ascii_max: u8 = 0x7f;
const cont_min: u8 = 0x80;
const lead2_min: u8 = 0xc2;
const lead3_min: u8 = 0xe0;
const lead4_min: u8 = 0xf0;
const lead4_max: u8 = 0xf4;

/// Leading byte of a two-, three-, or four-byte UTF-8 scalar. ASCII and
/// continuation bytes are excluded; following bytes still need validation.
pub inline fn isMultibyteLead(byte: u8) bool {
    return byte -% lead2_min <= lead4_max - lead2_min;
}

/// Length of the sequence starting at `offset`, or zero when the bytes there
/// are not a well-formed UTF-8 scalar.
pub inline fn sequenceLen(text: []const u8, offset: usize) usize {
    const first = text[offset];
    if (first <= ascii_max) return 1;
    if (first < lead2_min) return 0;
    if (first < lead3_min) {
        if (offset + 2 > text.len) return 0;
        if (text[offset + 1] & 0xc0 != 0x80) return 0;
        return 2;
    }
    if (first < lead4_min) {
        if (offset + 3 > text.len) return 0;
        const second = text[offset + 1];
        if (second & 0xc0 != 0x80) return 0;
        // U+0800..U+0FFF overlongs and the surrogate block.
        if (first == 0xe0 and second < 0xa0) return 0;
        if (first == 0xed and second >= 0xa0) return 0;
        if (text[offset + 2] & 0xc0 != 0x80) return 0;
        return 3;
    }
    if (first <= lead4_max) {
        if (offset + 4 > text.len) return 0;
        const second = text[offset + 1];
        if (second & 0xc0 != 0x80) return 0;
        // U+10000..U+3FFFF overlongs and scalars above U+10FFFF.
        if (first == 0xf0 and second < 0x90) return 0;
        if (first == 0xf4 and second >= 0x90) return 0;
        if (text[offset + 2] & 0xc0 != 0x80) return 0;
        if (text[offset + 3] & 0xc0 != 0x80) return 0;
        return 4;
    }
    return 0;
}

/// True when every byte is ASCII. Callers can then skip UTF-8 decoding and
/// use byte-oriented fast paths.
pub fn asciiOnly(text: []const u8) bool {
    return asciiSpan(text) == text.len;
}

/// Byte length of the leading ASCII span. A pair of vectors shares one
/// high-bit check; only a failing pair needs the individual lane masks.
pub fn asciiSpan(text: []const u8) usize {
    const V = @Vector(32, u8);
    var offset: usize = 0;
    while (offset + 128 <= text.len) : (offset += 128) {
        const a = @as(*align(1) const V, @ptrCast(text.ptr + offset)).*;
        const b = @as(*align(1) const V, @ptrCast(text.ptr + offset + 32)).*;
        const c = @as(*align(1) const V, @ptrCast(text.ptr + offset + 64)).*;
        const d = @as(*align(1) const V, @ptrCast(text.ptr + offset + 96)).*;
        const high: u32 = @bitCast((a | b | c | d) >= @as(V, @splat(0x80)));
        if (high != 0) {
            const first: u32 = @bitCast(a >= @as(V, @splat(0x80)));
            if (first != 0) return offset + @ctz(first);
            const second: u32 = @bitCast(b >= @as(V, @splat(0x80)));
            if (second != 0) return offset + 32 + @ctz(second);
            const third: u32 = @bitCast(c >= @as(V, @splat(0x80)));
            if (third != 0) return offset + 64 + @ctz(third);
            const fourth: u32 = @bitCast(d >= @as(V, @splat(0x80)));
            return offset + 96 + @ctz(fourth);
        }
    }
    while (offset + 64 <= text.len) : (offset += 64) {
        const a = @as(*align(1) const V, @ptrCast(text.ptr + offset)).*;
        const b = @as(*align(1) const V, @ptrCast(text.ptr + offset + 32)).*;
        const high: u32 = @bitCast((a | b) >= @as(V, @splat(0x80)));
        if (high != 0) {
            const first: u32 = @bitCast(a >= @as(V, @splat(0x80)));
            if (first != 0) return offset + @ctz(first);
            const second: u32 = @bitCast(b >= @as(V, @splat(0x80)));
            return offset + 32 + @ctz(second);
        }
    }
    if (offset + 32 <= text.len) {
        const bytes = @as(*align(1) const V, @ptrCast(text.ptr + offset)).*;
        const high: u32 = @bitCast(bytes >= @as(V, @splat(0x80)));
        if (high != 0) return offset + @ctz(high);
        offset += 32;
    }
    return offset + asciiSpanWords(text[offset..]);
}

/// Word-at-a-time ASCII prefix for callers whose input is shorter than a
/// vector window. Keeping this separate avoids a redundant 32-byte guard.
pub inline fn asciiSpanWords(text: []const u8) usize {
    var offset: usize = 0;
    if (text.len >= 8) {
        while (offset + 8 <= text.len) : (offset += 8) {
            const word = std.mem.readInt(u64, text[offset..][0..8], .little);
            const high = word & 0x8080_8080_8080_8080;
            if (high != 0) return offset + @ctz(high) / 8;
        }
        // The overlapping word contains only already-checked ASCII and
        // the remaining tail, so its first high bit is the exact boundary.
        if (offset < text.len) {
            const start = text.len - 8;
            const word = std.mem.readInt(u64, text[start..][0..8], .little);
            const high = word & 0x8080_8080_8080_8080;
            if (high != 0) return start + @ctz(high) / 8;
        }
        return text.len;
    }
    while (offset < text.len) : (offset += 1) {
        if (text[offset] >= 0x80) return offset;
    }
    return offset;
}

/// Scalar validation for short inputs, window prefixes, and tails.
pub fn scalarValid(text: []const u8) bool {
    var offset: usize = 0;
    while (offset < text.len) {
        const length = sequenceLen(text, offset);
        if (length == 0) return false;
        offset += length;
    }
    return true;
}
