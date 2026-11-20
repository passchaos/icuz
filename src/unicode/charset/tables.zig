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

/// Build a per-page start offset into a reverse index at compile time so
/// lookups only binary-search the records of one 256-code-point page.
fn buildPageIndex(comptime section: Section) [0x1100]u16 {
    @setEvalBranchQuota(8_000_000);
    const count = std.mem.readInt(u32, blob[section.offset..][0..4], .little);
    var pages = [_]u16{0} ** 0x1100;
    var record: u32 = 0;
    for (0..0x1100) |page| {
        const page_start: u32 = @intCast(page << 8);
        while (record < count and
            std.mem.readInt(
                u32,
                blob[section.offset + 4 + @as(usize, record) * 4 ..][0..4],
                .little,
            ) < page_start)
        {
            record += 1;
        }
        pages[page] = @intCast(record);
    }
    return pages;
}

pub const gb18030_reverse_pages = buildPageIndex(gb18030_reverse);
pub const big5_reverse_pages = buildPageIndex(big5_reverse);
pub const euc_kr_reverse_pages = buildPageIndex(euc_kr_reverse);
pub const jis0208_reverse_pages = buildPageIndex(jis0208_reverse);
pub const jis0212_reverse_pages = buildPageIndex(jis0212_reverse);
pub const shift_jis_reverse_pages = buildPageIndex(shift_jis_reverse);
pub const iso2022jp_katakana_reverse_pages =
    buildPageIndex(iso2022jp_katakana_reverse);

/// Paged reverse lookup: `pages` narrows the binary search to one page.
pub fn reverseLookupPaged(
    section: Section,
    pages: *const [0x1100]u16,
    codepoint: u21,
) ?u32 {
    const count = readU32(section.offset);
    const codepoints_base = section.offset + 4;
    const pointers_base = codepoints_base + count * 4;
    const page: usize = @as(usize, codepoint) >> 8;
    const low: usize = pages[page];
    const high: usize = if (page + 1 < 0x1100) pages[page + 1] else count;
    // A page holds only a handful of records; a sequential scan touches one
    // or two cache lines instead of chasing dependent binary-search probes.
    if (high - low <= 8) {
        var cursor = low;
        while (cursor < high) : (cursor += 1) {
            const value = readU32(codepoints_base + cursor * 4);
            if (value == codepoint) return readU16(pointers_base + cursor * 2);
            if (value > codepoint) break;
        }
        return null;
    }
    var low_mut = low;
    var high_mut = high;
    while (low_mut < high_mut) {
        const mid = low_mut + (high_mut - low_mut) / 2;
        const value = readU32(codepoints_base + mid * 4);
        if (value == codepoint) return readU16(pointers_base + mid * 2);
        if (value < codepoint) low_mut = mid + 1 else high_mut = mid;
    }
    return null;
}

/// A direct-mapped cache of recent reverse lookups. Entries pack the code
/// point in the high half and `pointer + 1` in the low half; zero means
/// empty. Stores are atomic so encoders stay safe when called concurrently.
pub const ReverseCache = [256]std.atomic.Value(u64);

pub const empty_reverse_cache: ReverseCache =
    @splat(std.atomic.Value(u64).init(0));

/// Reverse lookup with a small cache in front of the paged index. Repeated
/// characters, the common case in real text, cost one load.
pub fn reverseLookupCached(
    cache: *ReverseCache,
    section: Section,
    pages: *const [0x1100]u16,
    codepoint: u21,
) ?u32 {
    const hash: usize = (@as(u32, codepoint) *% 0x9E3779B1) >> 24;
    const cached = cache[hash].load(.monotonic);
    if (@as(u32, @truncate(cached >> 32)) == codepoint) {
        const stored: u32 = @truncate(cached);
        if (stored != 0) return stored - 1;
    }
    const pointer = reverseLookupPaged(section, pages, codepoint) orelse
        return null;
    cache[hash].store(
        (@as(u64, codepoint) << 32) | (@as(u64, pointer) + 1),
        .monotonic,
    );
    return pointer;
}

/// Look up a code point in a reverse index (records sorted by code point).
pub fn reverseLookup(section: Section, codepoint: u21) ?u32 {
    const count = readU32(section.offset);
    const codepoints_base = section.offset + 4;
    const pointers_base = codepoints_base + count * 4;
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const value = readU32(codepoints_base + mid * 4);
        if (value == codepoint) return readU16(pointers_base + mid * 2);
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

pub const ibm_blob = @embedFile("ibm_pages.bin");
const ibm_page_count = std.mem.readInt(u16, ibm_blob[8..10], .little);

const IbmPage = struct {
    name: []const u8,
    ascii_compatible: bool,
    table: usize,
};

fn ibmPageAt(index: usize) ?IbmPage {
    var offset: usize = 12;
    var page: usize = 0;
    while (page < ibm_page_count) : (page += 1) {
        if (offset + 2 > ibm_blob.len) return null;
        const name_length = std.mem.readInt(
            u16,
            ibm_blob[offset..][0..2],
            .little,
        );
        const name_start = offset + 2;
        const flags = name_start + name_length;
        if (flags + 2 + 512 > ibm_blob.len) return null;
        if (page == index) {
            return .{
                .name = ibm_blob[name_start..][0..name_length],
                .ascii_compatible = ibm_blob[flags] != 0,
                .table = flags + 2,
            };
        }
        offset = flags + 2 + 512;
    }
    return null;
}

pub fn ibmPageCount() usize {
    return ibm_page_count;
}

pub fn ibmPageName(index: usize) ?[]const u8 {
    return (ibmPageAt(index) orelse return null).name;
}

pub fn ibmPageAsciiCompatible(index: usize) bool {
    return (ibmPageAt(index) orelse return false).ascii_compatible;
}

pub fn ibmForward(index: usize, byte: u8) ?u21 {
    const page = ibmPageAt(index) orelse return null;
    const value = std.mem.readInt(
        u16,
        ibm_blob[page.table + @as(usize, byte) * 2 ..][0..2],
        .little,
    );
    if (value == 0xFFFF or value == 0xFFFD) return null;
    return value;
}

pub fn ibmReverse(index: usize, codepoint: u21) ?u8 {
    const page = ibmPageAt(index) orelse return null;
    var byte: usize = 0;
    while (byte < 256) : (byte += 1) {
        const value = std.mem.readInt(
            u16,
            ibm_blob[page.table + byte * 2 ..][0..2],
            .little,
        );
        if (value == codepoint) return @intCast(byte);
    }
    return null;
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
