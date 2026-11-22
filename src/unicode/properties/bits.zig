//! Trimmed membership bitmaps for the hottest binary properties.
//!
//! `property_bits.bin` is generated from `data.bin` by
//! `tools/unicode/properties/generate_property_bits.py`. Each bitmap ends with
//! a zero sentinel word, so membership is one clamped load instead of a walk
//! through the packed page table.

const std = @import("std");
const general_category = @import("general_category.zig");

const blob = @embedFile("property_bits.bin");
const header_len = 16;
const entry_len = 12;
const property_count = readU16(8);
const total_words = readU32(12);
const entries_offset = header_len;
const data_offset = entries_offset + @as(usize, property_count) * entry_len;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJQZ") or
        blob[4] != 1 or
        blob[5] != 17 or blob[6] != 0 or blob[7] != 0)
    {
        @compileError("invalid binary property bitmap data");
    }
    if (data_offset + @as(usize, total_words) * 8 != blob.len) {
        @compileError("invalid binary property bitmap lengths");
    }
}

pub const Bitmap = struct {
    offset: u32,
    words: u32,
};

fn lookup(bit: u6) ?Bitmap {
    var index: usize = 0;
    while (index < property_count) : (index += 1) {
        const base = entries_offset + index * entry_len;
        if (readU32(base) != bit) continue;
        return .{
            .offset = readU32(base + 4),
            .words = readU32(base + 8),
        };
    }
    return null;
}

pub inline fn has(bitmap: Bitmap, codepoint: u21) bool {
    // The final word is an always-zero sentinel, so clamping keeps the
    // lookup branchless for scalars past the trimmed range.
    const index = @min(
        @as(usize, codepoint) >> 6,
        @as(usize, bitmap.words) - 1,
    );
    const start = data_offset + (@as(usize, bitmap.offset) + index) * 8;
    const word = std.mem.readInt(u64, blob[start..][0..8], .little);
    return (word & (@as(u64, 1) << @as(u6, @intCast(codepoint & 63)))) != 0;
}

const white_space = lookup(
    @intFromEnum(general_category.BinaryProperty.white_space),
) orelse @compileError("missing white_space bitmap");
const alphabetic = lookup(
    @intFromEnum(general_category.BinaryProperty.alphabetic),
) orelse @compileError("missing alphabetic bitmap");
const uppercase = lookup(
    @intFromEnum(general_category.BinaryProperty.uppercase),
) orelse @compileError("missing uppercase bitmap");
const lowercase = lookup(
    @intFromEnum(general_category.BinaryProperty.lowercase),
) orelse @compileError("missing lowercase bitmap");
const math = lookup(
    @intFromEnum(general_category.BinaryProperty.math),
) orelse @compileError("missing math bitmap");
const cased = lookup(
    @intFromEnum(general_category.BinaryProperty.cased),
) orelse @compileError("missing cased bitmap");

pub inline fn isWhiteSpace(codepoint: u21) bool {
    return has(white_space, codepoint);
}

pub inline fn isAlphabetic(codepoint: u21) bool {
    return has(alphabetic, codepoint);
}

pub inline fn isUppercase(codepoint: u21) bool {
    return has(uppercase, codepoint);
}

pub inline fn isLowercase(codepoint: u21) bool {
    return has(lowercase, codepoint);
}

pub inline fn isMath(codepoint: u21) bool {
    return has(math, codepoint);
}

pub inline fn isCased(codepoint: u21) bool {
    return has(cased, codepoint);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn expectMatches(bitmap: Bitmap, comptime expected: anytype) !void {
    const testing = std.testing;
    var codepoint: u32 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        const value: u21 = @intCast(codepoint);
        try testing.expectEqual(expected(value), has(bitmap, value));
    }
}

test "bitmap properties match the packed table" {
    try expectMatches(white_space, general_category.isWhiteSpace);
    try expectMatches(alphabetic, general_category.isAlphabetic);
    try expectMatches(uppercase, general_category.isUppercase);
    try expectMatches(lowercase, general_category.isLowercase);
    try expectMatches(math, general_category.isMath);
    try expectMatches(cased, general_category.isCased);
}
