//! Legacy East Asian multi-byte decoders and encoders.
//!
//! Algorithms follow the WHATWG Encoding Standard; the mapping tables come
//! from the generated `data.bin` indexes.

const std = @import("std");
const tables = @import("tables.zig");
const types = @import("types.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

// Reverse-lookup caches shared by the encoders. The mappings are immutable,
// so entries never need invalidation.
var gb_reverse_cache: tables.ReverseCache = tables.empty_reverse_cache;
var big5_reverse_cache: tables.ReverseCache = tables.empty_reverse_cache;
var euc_kr_reverse_cache: tables.ReverseCache = tables.empty_reverse_cache;
var shift_jis_reverse_cache: tables.ReverseCache = tables.empty_reverse_cache;
var jis0208_reverse_cache: tables.ReverseCache = tables.empty_reverse_cache;
var jis0212_reverse_cache: tables.ReverseCache = tables.empty_reverse_cache;

fn malformed(index: *usize, start: usize) DecodeResult {
    index.* = start + 1;
    return .{ .malformed = 1 };
}

fn incomplete(index: *usize, start: usize) DecodeResult {
    index.* = start;
    return .incomplete;
}

fn firstByte(input: []const u8, index: *usize) ?u8 {
    if (index.* >= input.len) return null;
    const byte = input[index.*];
    index.* += 1;
    return byte;
}

pub fn gb18030Next(input: []const u8, index: *usize) DecodeResult {
    return gbNext(input, index, false);
}

pub fn gbkNext(input: []const u8, index: *usize) DecodeResult {
    return gbNext(input, index, true);
}

/// Inline GBK decode for converters. Returns null for end-of-input and for
/// any malformed or incomplete sequence, so the caller can fall back to the
/// generic decoder that owns error handling. On success `index` advances.
pub inline fn gbkNextFast(input: []const u8, index: *usize) ?u21 {
    const start = index.*;
    if (start >= input.len) return null;
    const first = input[start];
    if (first <= 0x7F) {
        index.* = start + 1;
        return first;
    }
    if (first == 0x80) {
        index.* = start + 1;
        return 0x20AC;
    }
    if (first < 0x81 or first > 0xFE or start + 2 > input.len) return null;
    const second = input[start + 1];
    const offset: u8 = if (second >= 0x40 and second <= 0x7E)
        0x40
    else if (second >= 0x80 and second <= 0xFE)
        0x41
    else
        return null;
    const pointer = (@as(u32, first) - 0x81) * 190 +
        (@as(u32, second) - offset);
    const codepoint = tables.forwardLookup(tables.gb18030_forward, pointer) orelse
        return null;
    index.* = start + 2;
    return codepoint;
}

fn gbNext(input: []const u8, index: *usize, comptime gbk: bool) DecodeResult {
    const start = index.*;
    const first = firstByte(input, index) orelse return .end;
    if (first <= 0x7F) return .{ .codepoint = first };
    if (first == 0x80) return .{ .codepoint = 0x20AC };
    if (first < 0x81 or first > 0xFE) return malformed(index, start);

    const second = firstByte(input, index) orelse return incomplete(index, start);
    if (second >= 0x30 and second <= 0x39) {
        if (gbk) return malformed(index, start);
        const third = firstByte(input, index) orelse return incomplete(index, start);
        if (third < 0x81 or third > 0xFE) return malformed(index, start);
        const fourth = firstByte(input, index) orelse return incomplete(index, start);
        if (fourth < 0x30 or fourth > 0x39) return malformed(index, start);

        const pointer = (@as(u32, first) - 0x81) * 12600 +
            (@as(u32, second) - 0x30) * 1260 +
            (@as(u32, third) - 0x81) * 10 +
            (@as(u32, fourth) - 0x30);
        if ((pointer > 39419 and pointer < 189000) or pointer > 1237575) {
            return malformed(index, start);
        }
        if (pointer == 7457) return .{ .codepoint = 0xE7C7 };
        const codepoint = tables.gb18030RangeByPointer(pointer) orelse
            return malformed(index, start);
        return .{ .codepoint = codepoint };
    }

    const offset: u8 = if (second >= 0x40 and second <= 0x7E)
        0x40
    else if (second >= 0x80 and second <= 0xFE)
        0x41
    else
        return malformed(index, start);

    const pointer = (@as(u32, first) - 0x81) * 190 +
        (@as(u32, second) - offset);
    const codepoint = tables.forwardLookup(tables.gb18030_forward, pointer) orelse
        return malformed(index, start);
    return .{ .codepoint = codepoint };
}

/// Encode one scalar for the GBK fast path. Returns the byte count (1 or
/// 2), or 0 when the scalar needs the generic encoder (unmappable or the
/// E5E5 special case).
pub fn gbkEncodeFast(codepoint: u21, out: *[4]u8) u8 {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint == 0xE5E5) return 0;
    if (codepoint == 0x20AC) {
        out[0] = 0x80;
        return 1;
    }
    const code = tables.reverseLookupCached(
        &gb_reverse_cache,
        tables.gb18030_reverse,
        &tables.gb18030_reverse_pages,
        codepoint,
    ) orelse return 0;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return 2;
}

/// Encode one scalar for the Big5 fast path. Returns 0 when unmappable.
pub fn big5EncodeFast(codepoint: u21, out: *[4]u8) u8 {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    const special: ?u16 = switch (codepoint) {
        0x00CA => 0x8862,
        0x00EA => 0x8864,
        0x0304 => 0x88A3,
        0x030C => 0x88A5,
        else => null,
    };
    const code = special orelse tables.reverseLookupCached(
        &big5_reverse_cache,
        tables.big5_reverse,
        &tables.big5_reverse_pages,
        codepoint,
    ) orelse return 0;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return 2;
}

/// Encode one scalar for the EUC-KR fast path. Returns 0 when unmappable.
pub fn eucKrEncodeFast(codepoint: u21, out: *[4]u8) u8 {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    const code = tables.reverseLookupCached(
        &euc_kr_reverse_cache,
        tables.euc_kr_reverse,
        &tables.euc_kr_reverse_pages,
        codepoint,
    ) orelse return 0;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return 2;
}

/// Encode one scalar for the Shift_JIS fast path. Returns 0 when unmappable.
pub fn shiftJisEncodeFast(codepoint: u21, out: *[4]u8) u8 {
    // Japanese prose is overwhelmingly kana and CJK above U+2FFF, where
    // halfwidth katakana is the only single-byte exception. Testing that
    // range first keeps the three below-U+3000 special cases off the common
    // path.
    if (codepoint >= 0x3000) {
        // Hiragana and katakana occupy contiguous JIS X 0208 rows, so their
        // Shift_JIS codes are linear in the code point (katakana skips one
        // unassigned cell at U+30E0). The generic reverse lookup is reserved
        // for kanji and punctuation.
        if (codepoint >= 0x3041 and codepoint <= 0x3093) {
            const code: u16 = 0x829F + @as(u16, @intCast(codepoint - 0x3041));
            out[0] = @truncate(code >> 8);
            out[1] = @truncate(code);
            return 2;
        }
        if (codepoint >= 0x30A1 and codepoint <= 0x30F6) {
            const code: u16 = 0x8340 +
                @as(u16, @intCast(codepoint - 0x30A1)) +
                @as(u16, @intFromBool(codepoint >= 0x30E0));
            out[0] = @truncate(code >> 8);
            out[1] = @truncate(code);
            return 2;
        }
        if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
            out[0] = @intCast(0xA1 + codepoint - 0xFF61);
            return 1;
        }
    } else {
        if (codepoint < 0x80 or codepoint == 0x80) {
            out[0] = @intCast(codepoint);
            return 1;
        }
        if (codepoint == 0x00A5) {
            out[0] = 0x5C;
            return 1;
        }
        if (codepoint == 0x203E) {
            out[0] = 0x7E;
            return 1;
        }
    }
    const target: u21 = if (codepoint == 0x2212) 0xFF0D else codepoint;
    const code = tables.reverseLookupCached(
        &shift_jis_reverse_cache,
        tables.shift_jis_reverse,
        &tables.shift_jis_reverse_pages,
        target,
    ) orelse return 0;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return 2;
}

/// Encode one scalar for the EUC-JP fast path. Returns 0 when unmappable.
pub fn eucJpEncodeFast(codepoint: u21, out: *[4]u8) u8 {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    // Hiragana and katakana occupy contiguous JIS X 0208 rows, so their
    // EUC-JP codes are linear in the code point.
    if (codepoint >= 0x3041 and codepoint <= 0x3093) {
        const code: u16 = 0xA4A1 + @as(u16, @intCast(codepoint - 0x3041));
        out[0] = @truncate(code >> 8);
        out[1] = @truncate(code);
        return 2;
    }
    if (codepoint >= 0x30A1 and codepoint <= 0x30F6) {
        const code: u16 = 0xA5A1 + @as(u16, @intCast(codepoint - 0x30A1));
        out[0] = @truncate(code >> 8);
        out[1] = @truncate(code);
        return 2;
    }
    if (codepoint == 0x00A5) {
        out[0] = 0x5C;
        return 1;
    }
    if (codepoint == 0x203E) {
        out[0] = 0x7E;
        return 1;
    }
    if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
        out[0] = 0x8E;
        out[1] = @intCast(0xA1 + codepoint - 0xFF61);
        return 2;
    }
    const target: u21 = if (codepoint == 0x2212) 0xFF0D else codepoint;
    if (tables.reverseLookupCached(
        &jis0208_reverse_cache,
        tables.jis0208_reverse,
        &tables.jis0208_reverse_pages,
        target,
    )) |code| {
        out[0] = @truncate(code >> 8);
        out[1] = @truncate(code);
        return 2;
    }
    if (tables.reverseLookupCached(
        &jis0212_reverse_cache,
        tables.jis0212_reverse,
        &tables.jis0212_reverse_pages,
        target,
    )) |code| {
        out[0] = 0x8F;
        out[1] = @truncate(code >> 8);
        out[2] = @truncate(code);
        return 3;
    }
    return 0;
}

pub fn gbkEncode(codepoint: u21, out: []u8) EncodeResult {
    return gbEncode(codepoint, out, false);
}

pub fn gb18030Encode(codepoint: u21, out: []u8) EncodeResult {
    return gbEncode(codepoint, out, true);
}

fn gbEncode(codepoint: u21, out: []u8, comptime full: bool) EncodeResult {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    if (codepoint == 0xE5E5) return .unmappable;
    if (codepoint == 0x20AC) {
        out[0] = 0x80;
        return .{ .written = 1 };
    }
    if (tables.reverseLookupCached(
        &gb_reverse_cache,
        tables.gb18030_reverse,
        &tables.gb18030_reverse_pages,
        codepoint,
    )) |code| {
        out[0] = @truncate(code >> 8);
        out[1] = @truncate(code);
        return .{ .written = 2 };
    }
    if (!full) return .unmappable;

    const pointer = tables.gb18030RangeByCodepoint(codepoint) orelse
        return .unmappable;
    out[0] = @intCast(pointer / 12600 + 0x81);
    out[1] = @intCast((pointer % 12600) / 1260 + 0x30);
    out[2] = @intCast((pointer % 1260) / 10 + 0x81);
    out[3] = @intCast(pointer % 10 + 0x30);
    return .{ .written = 4 };
}

pub fn big5Next(input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    const first = firstByte(input, index) orelse return .end;
    if (first <= 0x7F) return .{ .codepoint = first };
    if (first < 0x81 or first > 0xFE) return malformed(index, start);

    const second = firstByte(input, index) orelse return incomplete(index, start);
    const offset: u8 = if (second >= 0x40 and second <= 0x7E)
        0x40
    else if (second >= 0xA1 and second <= 0xFE)
        0x62
    else
        return malformed(index, start);

    const pointer = (@as(u32, first) - 0x81) * 157 +
        (@as(u32, second) - offset);
    const codepoint: u21 = switch (pointer) {
        1133 => 0x00CA,
        1135 => 0x00EA,
        1164 => 0x0304,
        1166 => 0x030C,
        else => tables.forwardLookup(tables.big5_forward, pointer) orelse
            return malformed(index, start),
    };
    return .{ .codepoint = codepoint };
}

pub fn big5Encode(codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    const special: ?u16 = switch (codepoint) {
        0x00CA => 0x8862,
        0x00EA => 0x8864,
        0x0304 => 0x88A3,
        0x030C => 0x88A5,
        else => null,
    };
    const code = special orelse
        tables.reverseLookupCached(
            &big5_reverse_cache,
            tables.big5_reverse,
            &tables.big5_reverse_pages,
            codepoint,
        ) orelse
        return .unmappable;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return .{ .written = 2 };
}

pub fn eucKrNext(input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    const first = firstByte(input, index) orelse return .end;
    if (first <= 0x7F) return .{ .codepoint = first };
    if (first < 0x81 or first > 0xFE) return malformed(index, start);

    const second = firstByte(input, index) orelse return incomplete(index, start);
    if (second < 0x41 or second > 0xFE) return malformed(index, start);
    const pointer = (@as(u32, first) - 0x81) * 190 +
        (@as(u32, second) - 0x41);
    const codepoint = tables.forwardLookup(tables.euc_kr_forward, pointer) orelse
        return malformed(index, start);
    return .{ .codepoint = codepoint };
}

pub fn eucKrEncode(codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    const code = tables.reverseLookupCached(
        &euc_kr_reverse_cache,
        tables.euc_kr_reverse,
        &tables.euc_kr_reverse_pages,
        codepoint,
    ) orelse
        return .unmappable;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return .{ .written = 2 };
}

pub fn shiftJisNext(input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    const first = firstByte(input, index) orelse return .end;
    if (first <= 0x7F) return .{ .codepoint = first };
    if (first == 0x80) return .{ .codepoint = 0x80 };
    if (first >= 0xA1 and first <= 0xDF) {
        return .{ .codepoint = @as(u21, 0xFF61) + first - 0xA1 };
    }
    if (first == 0xA0) return .{ .codepoint = 0xF8F0 };
    if (first >= 0xFD and first <= 0xFF) {
        return .{ .codepoint = @as(u21, 0xF8F1) + first - 0xFD };
    }
    if (!((first >= 0x81 and first <= 0x9F) or
        (first >= 0xE0 and first <= 0xFC)))
    {
        return malformed(index, start);
    }

    const second = firstByte(input, index) orelse return incomplete(index, start);
    const offset: u8 = if (second >= 0x40 and second <= 0x7E)
        0x40
    else if (second >= 0x80 and second <= 0xFC)
        0x41
    else
        return malformed(index, start);

    const lead_offset: u8 = if (first < 0xA0) 0x81 else 0xC1;
    const pointer = (@as(u32, first) - lead_offset) * 188 +
        (@as(u32, second) - offset);
    if (pointer >= 8836 and pointer <= 10715) {
        return .{ .codepoint = @intCast(0xE000 + pointer - 8836) };
    }
    const codepoint = tables.forwardLookup(tables.jis0208_forward, pointer) orelse
        return malformed(index, start);
    return .{ .codepoint = codepoint };
}

pub fn shiftJisEncode(codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80 or codepoint == 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    if (codepoint == 0x00A5) {
        out[0] = 0x5C;
        return .{ .written = 1 };
    }
    if (codepoint == 0x203E) {
        out[0] = 0x7E;
        return .{ .written = 1 };
    }
    if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
        out[0] = @intCast(0xA1 + codepoint - 0xFF61);
        return .{ .written = 1 };
    }
    const target: u21 = if (codepoint == 0x2212) 0xFF0D else codepoint;
    const code = tables.reverseLookupCached(
        &shift_jis_reverse_cache,
        tables.shift_jis_reverse,
        &tables.shift_jis_reverse_pages,
        target,
    ) orelse return .unmappable;
    out[0] = @truncate(code >> 8);
    out[1] = @truncate(code);
    return .{ .written = 2 };
}

pub fn eucJpNext(input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    const first = firstByte(input, index) orelse return .end;
    if (first <= 0x7F) return .{ .codepoint = first };

    if (first == 0x8E) {
        const second = firstByte(input, index) orelse return incomplete(index, start);
        if (second < 0xA1 or second > 0xDF) return malformed(index, start);
        return .{ .codepoint = @as(u21, 0xFF61) + second - 0xA1 };
    }
    if (first == 0x8F) {
        const second = firstByte(input, index) orelse return incomplete(index, start);
        if (second < 0xA1 or second > 0xFE) return malformed(index, start);
        const third = firstByte(input, index) orelse return incomplete(index, start);
        if (third < 0xA1 or third > 0xFE) return malformed(index, start);
        const pointer = (@as(u32, second) - 0xA1) * 94 +
            (@as(u32, third) - 0xA1);
        const codepoint = tables.forwardLookup(tables.jis0212_forward, pointer) orelse
            return malformed(index, start);
        return .{ .codepoint = codepoint };
    }
    if (first < 0xA1 or first > 0xFE) return malformed(index, start);

    const second = firstByte(input, index) orelse return incomplete(index, start);
    if (second < 0xA1 or second > 0xFE) return malformed(index, start);
    const pointer = (@as(u32, first) - 0xA1) * 94 +
        (@as(u32, second) - 0xA1);
    const codepoint = tables.forwardLookup(tables.jis0208_forward, pointer) orelse
        return malformed(index, start);
    return .{ .codepoint = codepoint };
}

pub fn eucJpEncode(codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return .{ .written = 1 };
    }
    if (codepoint == 0x00A5) {
        out[0] = 0x5C;
        return .{ .written = 1 };
    }
    if (codepoint == 0x203E) {
        out[0] = 0x7E;
        return .{ .written = 1 };
    }
    if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
        out[0] = 0x8E;
        out[1] = @intCast(0xA1 + codepoint - 0xFF61);
        return .{ .written = 2 };
    }
    const target: u21 = if (codepoint == 0x2212) 0xFF0D else codepoint;
    if (tables.reverseLookupCached(
        &jis0208_reverse_cache,
        tables.jis0208_reverse,
        &tables.jis0208_reverse_pages,
        target,
    )) |code| {
        out[0] = @truncate(code >> 8);
        out[1] = @truncate(code);
        return .{ .written = 2 };
    }
    if (tables.reverseLookupCached(
        &jis0212_reverse_cache,
        tables.jis0212_reverse,
        &tables.jis0212_reverse_pages,
        target,
    )) |code| {
        out[0] = 0x8F;
        out[1] = @truncate(code >> 8);
        out[2] = @truncate(code);
        return .{ .written = 3 };
    }
    return .unmappable;
}

test "CJK decode and encode round trips" {
    const testing = @import("std").testing;

    // Shift_JIS: あ U+3042 is 0x82 0xA0.
    {
        var index: usize = 0;
        const decoded = shiftJisNext(&.{ 0x82, 0xA0 }, &index);
        try testing.expectEqual(@as(u21, 0x3042), decoded.codepoint);
        try testing.expectEqual(@as(usize, 2), index);
        var out: [8]u8 = undefined;
        const encoded = shiftJisEncode(0x3042, &out);
        try testing.expectEqual(@as(u8, 2), encoded.written);
        try testing.expectEqualSlices(u8, &.{ 0x82, 0xA0 }, out[0..2]);
    }
    // EUC-JP: あ U+3042 is 0xA4 0xA2.
    {
        var index: usize = 0;
        const decoded = eucJpNext(&.{ 0xA4, 0xA2 }, &index);
        try testing.expectEqual(@as(u21, 0x3042), decoded.codepoint);
        var out: [8]u8 = undefined;
        const encoded = eucJpEncode(0x3042, &out);
        try testing.expectEqual(@as(u8, 2), encoded.written);
        try testing.expectEqualSlices(u8, &.{ 0xA4, 0xA2 }, out[0..2]);
    }
    // GBK: 你 U+4F60 is 0xC4 0xE3.
    {
        var index: usize = 0;
        const decoded = gbkNext(&.{ 0xC4, 0xE3 }, &index);
        try testing.expectEqual(@as(u21, 0x4F60), decoded.codepoint);
        var out: [8]u8 = undefined;
        const encoded = gbkEncode(0x4F60, &out);
        try testing.expectEqual(@as(u8, 2), encoded.written);
        try testing.expectEqualSlices(u8, &.{ 0xC4, 0xE3 }, out[0..2]);
    }
    // Big5: 你 U+4F60 is 0xA7 0x41.
    {
        var index: usize = 0;
        const decoded = big5Next(&.{ 0xA7, 0x41 }, &index);
        try testing.expectEqual(@as(u21, 0x4F60), decoded.codepoint);
        var out: [8]u8 = undefined;
        const encoded = big5Encode(0x4F60, &out);
        try testing.expectEqual(@as(u8, 2), encoded.written);
        try testing.expectEqualSlices(u8, &.{ 0xA7, 0x41 }, out[0..2]);
    }
    // EUC-KR: 가 U+AC00 is 0xB0 0xA1.
    {
        var index: usize = 0;
        const decoded = eucKrNext(&.{ 0xB0, 0xA1 }, &index);
        try testing.expectEqual(@as(u21, 0xAC00), decoded.codepoint);
        var out: [8]u8 = undefined;
        const encoded = eucKrEncode(0xAC00, &out);
        try testing.expectEqual(@as(u8, 2), encoded.written);
        try testing.expectEqualSlices(u8, &.{ 0xB0, 0xA1 }, out[0..2]);
    }
    // GB18030 four-byte: U+10000 is 0x90 0x30 0x81 0x30.
    {
        var index: usize = 0;
        const decoded = gb18030Next(&.{ 0x90, 0x30, 0x81, 0x30 }, &index);
        try testing.expectEqual(@as(u21, 0x10000), decoded.codepoint);
        var out: [8]u8 = undefined;
        const encoded = gb18030Encode(0x10000, &out);
        try testing.expectEqual(@as(u8, 4), encoded.written);
        try testing.expectEqualSlices(
            u8,
            &.{ 0x90, 0x30, 0x81, 0x30 },
            out[0..4],
        );
    }
    // Shift_JIS special mappings.
    {
        var out: [8]u8 = undefined;
        var encoded = shiftJisEncode(0x00A5, &out);
        try testing.expectEqualSlices(u8, &.{0x5C}, out[0..encoded.written]);
        encoded = shiftJisEncode(0x203E, &out);
        try testing.expectEqualSlices(u8, &.{0x7E}, out[0..encoded.written]);
        encoded = shiftJisEncode(0xFF61, &out);
        try testing.expectEqualSlices(u8, &.{0xA1}, out[0..encoded.written]);
        encoded = shiftJisEncode(0x2212, &out);
        try testing.expectEqualSlices(u8, &.{ 0x81, 0x7C }, out[0..encoded.written]);
    }
    // EUC-JP special mappings.
    {
        var out: [8]u8 = undefined;
        var encoded = eucJpEncode(0x00A5, &out);
        try testing.expectEqualSlices(u8, &.{0x5C}, out[0..encoded.written]);
        encoded = eucJpEncode(0x203E, &out);
        try testing.expectEqualSlices(u8, &.{0x7E}, out[0..encoded.written]);
        encoded = eucJpEncode(0xFF61, &out);
        try testing.expectEqualSlices(u8, &.{ 0x8E, 0xA1 }, out[0..encoded.written]);
        encoded = eucJpEncode(0x2212, &out);
        try testing.expectEqualSlices(u8, &.{ 0xA1, 0xDD }, out[0..encoded.written]);
    }
    // Big5 uses the last pointer for selected duplicate code points.
    {
        var out: [8]u8 = undefined;
        const encoded = big5Encode(0x2550, &out);
        try testing.expectEqualSlices(u8, &.{ 0xF9, 0xF9 }, out[0..encoded.written]);
    }
    // GB18030 special code points.
    {
        var out: [8]u8 = undefined;
        const encoded = gb18030Encode(0xE7C7, &out);
        try testing.expectEqualSlices(
            u8,
            &.{ 0x81, 0x35, 0xF4, 0x37 },
            out[0..encoded.written],
        );
        switch (gb18030Encode(0xE5E5, &out)) {
            .unmappable => {},
            else => return error.TestUnexpectedResult,
        }
    }
}
