//! Accessors for the generated `data.bin` charset tables.
//!
//! The blob layout is produced by tools/unicode/charset/generate_data.py:
//! a 12-byte header, a table of 12-byte section records, then 4-byte-aligned
//! payloads.

const std = @import("std");

pub const blob = @embedFile("data.bin");

pub const Section = struct {
    offset: usize,
    length: usize,
};

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

const section_count = std.mem.readInt(u16, blob[8..10], .little);

fn sectionAt(index: usize) Section {
    const base = 12 + index * 12;
    return .{
        .offset = std.mem.readInt(u32, blob[base + 4 ..][0..4], .little),
        .length = std.mem.readInt(u32, blob[base + 8 ..][0..4], .little),
    };
}

fn findSection(comptime id: u16) Section {
    var index: usize = 0;
    while (index < section_count) : (index += 1) {
        const base = 12 + index * 12;
        if (std.mem.readInt(u16, blob[base..][0..2], .little) == id) {
            return sectionAt(index);
        }
    }
    @compileError("charset data.bin is missing a required section");
}

pub const single_byte_forward = findSection(1);
pub const single_byte_reverse = findSection(2);
pub const jis0208_forward = findSection(3);
pub const jis0208_reverse = findSection(4);
pub const jis0212_forward = findSection(5);
pub const gb18030_forward = findSection(6);
pub const gb18030_reverse = findSection(7);
pub const gb18030_ranges_by_pointer = findSection(8);
pub const gb18030_ranges_by_codepoint = findSection(9);
pub const big5_forward = findSection(10);
pub const big5_reverse = findSection(11);
pub const euc_kr_forward = findSection(12);
pub const euc_kr_reverse = findSection(13);
pub const iso2022jp_katakana_forward = findSection(14);
pub const iso2022jp_katakana_reverse = findSection(15);
pub const jis0212_reverse = findSection(16);
pub const shift_jis_reverse = findSection(17);

pub fn singleByteForward(table_index: usize, byte: u8) ?u21 {
    const base = single_byte_forward.offset;
    const table_count = readU16(base);
    const entries = readU16(base + 2);
    if (table_index >= table_count or entries != 128 or byte < 0x80) return null;
    const value = readU16(base + 4 + (table_index * entries + byte - 0x80) * 2);
    return if (value == 0) null else value;
}

pub fn singleByteReverse(table_index: usize, codepoint: u21) ?u8 {
    const base = single_byte_reverse.offset;
    const table_count = readU16(base);
    if (table_index >= table_count) return null;
    const count = readU16(base + 2 + table_index * 2);
    var records = base + 2 + table_count * 2;
    var index: usize = 0;
    while (index < table_index) : (index += 1) {
        records += @as(usize, readU16(base + 2 + index * 2)) * 3;
    }
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const value = readU16(records + mid * 3);
        if (value == codepoint) return blob[records + mid * 3 + 2];
        if (value < codepoint) low = mid + 1 else high = mid;
    }
    return null;
}

/// Look up a pointer in a forward index. Zero marks an unmapped pointer.
pub fn forwardLookup(section: Section, pointer: usize) ?u21 {
    const count = readU32(section.offset);
    if (pointer >= count) return null;
    const value = readU32(section.offset + 4 + pointer * 4);
    if (value == 0 or value > 0x10FFFF) return null;
    return @intCast(value);
}

/// Look up a code point in a reverse index (records sorted by code point).
pub fn reverseLookup(section: Section, codepoint: u21) ?u32 {
    const count = readU32(section.offset);
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record = section.offset + 4 + mid * 8;
        const value = readU32(record);
        if (value == codepoint) return readU32(record + 4);
        if (value < codepoint) low = mid + 1 else high = mid;
    }
    return null;
}

const Pair = struct {
    key: u32,
    value: u32,
};

fn pairFloor(section: Section, key: u32) ?Pair {
    const count = readU32(section.offset);
    if (count == 0) return null;
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record = section.offset + 4 + mid * 8;
        if (readU32(record) <= key) low = mid + 1 else high = mid;
    }
    if (low == 0) return null;
    const record = section.offset + 4 + (low - 1) * 8;
    return .{ .key = readU32(record), .value = readU32(record + 4) };
}

/// Decode a GB18030 four-byte pointer to a code point.
pub fn gb18030RangeByPointer(pointer: u32) ?u21 {
    const pair = pairFloor(gb18030_ranges_by_pointer, pointer) orelse return null;
    const codepoint = pair.value + (pointer - pair.key);
    if (codepoint > 0x10FFFF) return null;
    return @intCast(codepoint);
}

/// Encode a code point to a GB18030 four-byte pointer.
pub fn gb18030RangeByCodepoint(codepoint: u21) ?u32 {
    if (codepoint == 0xE7C7) return 7457;
    const pair = pairFloor(gb18030_ranges_by_codepoint, codepoint) orelse return null;
    return pair.value + (codepoint - pair.key);
}

test "charset tables are structurally valid" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u16, 17), section_count);
    try testing.expectEqual(@as(u21, 0x20AC), singleByteForward(20, 0x80).?);
    try testing.expectEqual(@as(u8, 0x80), singleByteReverse(20, 0x20AC).?);
    try testing.expectEqual(@as(u21, 0x3000), forwardLookup(jis0208_forward, 0).?);
    try testing.expectEqual(@as(u32, 0), reverseLookup(jis0208_reverse, 0x3000).?);
    try testing.expectEqual(@as(u21, 0x10000), gb18030RangeByPointer(189000).?);
    try testing.expectEqual(@as(u32, 189000), gb18030RangeByCodepoint(0x10000).?);
}
