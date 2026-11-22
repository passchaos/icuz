//! Unicode 17 character names, aliases, and loose name lookup.
//!
//! Explicit names and aliases come from the generated `data.bin` pool.
//! Algorithmic names such as `CJK UNIFIED IDEOGRAPH-4E00` are expanded from the
//! generated pattern ranges, so the embedded pool stays compact.

const std = @import("std");
const ranges = @import("name/ranges.zig");

const data = @embedFile("name/data.bin");
const header_len = 16;
const record_count = readU32(8);
const pool_len = readU32(12);
const records_offset = header_len;
const pool_offset = records_offset + @as(usize, record_count) * 12;
const record_len = 12;

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJNM") or
        data[4] != 1 or data[5] != 17 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid Unicode name data");
    }
    if (pool_offset + @as(usize, pool_len) != data.len) {
        @compileError("invalid Unicode name data lengths");
    }
}

pub const NameType = enum(u8) {
    name = 0,
    correction = 1,
    control = 2,
    alternate = 3,
    figment = 4,
    abbreviation = 5,
};

const Record = struct {
    codepoint: u21,
    offset: u32,
    len: u16,
    kind: u8,
};

fn recordAt(index: usize) Record {
    const base = records_offset + index * record_len;
    return .{
        .codepoint = @intCast(readU32(base)),
        .offset = readU32(base + 4),
        .len = readU16(base + 8),
        .kind = data[base + 10],
    };
}

fn recordName(record: Record) []const u8 {
    return data[pool_offset + @as(usize, record.offset) ..][0..record.len];
}

fn firstIndexFor(codepoint: u21) usize {
    var low: usize = 0;
    var high: usize = record_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (recordAt(mid).codepoint < codepoint) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn findFirst(codepoint: u21, kind: u8) ?Record {
    var index = firstIndexFor(codepoint);
    while (index < record_count) : (index += 1) {
        const record = recordAt(index);
        if (record.codepoint != codepoint) break;
        if (record.kind == kind) return record;
    }
    return null;
}

/// Return the stored name for one scalar, including control aliases.
///
/// Algorithmic names are not materialized here; use `nameInto` or `nameAlloc`
/// for CJK, Tangut, Egyptian, Khitan, and Nushu characters.
pub fn name(codepoint: u21) ?[]const u8 {
    // One lower-bound search reaches every record for the scalar; the name
    // and control alias are adjacent, so a second search is wasted.
    var index = firstIndexFor(codepoint);
    var name_record: ?Record = null;
    var control_record: ?Record = null;
    while (index < record_count) : (index += 1) {
        const record = recordAt(index);
        if (record.codepoint != codepoint) break;
        const kind = record.kind;
        if (kind == @intFromEnum(NameType.name)) {
            if (name_record == null) name_record = record;
        } else if (kind == @intFromEnum(NameType.control)) {
            if (control_record == null) control_record = record;
        }
    }
    if (name_record) |record| return recordName(record);
    if (control_record) |record| return recordName(record);
    return null;
}

/// Write the full name for one scalar, expanding algorithmic patterns.
pub fn nameInto(codepoint: u21, buffer: []u8) ?[]const u8 {
    if (name(codepoint)) |stored| return stored;
    for (ranges.patterns) |pattern| {
        if (codepoint < pattern.first or codepoint > pattern.last) continue;
        return std.fmt.bufPrint(
            buffer,
            "{s}{X}",
            .{ pattern.prefix, codepoint },
        ) catch null;
    }
    return null;
}

/// Return an allocator-owned full name, or null when the scalar has no name.
pub fn nameAlloc(
    allocator: std.mem.Allocator,
    codepoint: u21,
) error{OutOfMemory}!?[]u8 {
    var buffer: [64]u8 = undefined;
    const result = nameInto(codepoint, &buffer) orelse return null;
    return try allocator.dupe(u8, result);
}

/// Return one alias of the requested type.
pub fn alias(codepoint: u21, name_type: NameType) ?[]const u8 {
    if (name_type == .name) return name(codepoint);
    const record = findFirst(codepoint, @intFromEnum(name_type)) orelse
        return null;
    return recordName(record);
}

/// Return the first non-primary alias for one scalar.
pub fn firstAlias(codepoint: u21) ?[]const u8 {
    var index = firstIndexFor(codepoint);
    while (index < record_count) : (index += 1) {
        const record = recordAt(index);
        if (record.codepoint != codepoint) break;
        if (record.kind != @intFromEnum(NameType.name)) {
            return recordName(record);
        }
    }
    return null;
}

/// Find a scalar by name using UAX #44 loose matching.
///
/// Matching is ASCII case-insensitive and ignores spaces, hyphens, and
/// underscores. Algorithmic pattern names are parsed directly; explicit names
/// and aliases are scanned from the generated pool.
pub fn findByName(query: []const u8) ?u21 {
    var normalized_buffer: [128]u8 = undefined;
    const normalized = normalizeLoose(query, &normalized_buffer) orelse
        return null;
    if (normalized.len == 0) return null;

    for (ranges.patterns) |pattern| {
        var prefix_buffer: [128]u8 = undefined;
        const prefix = normalizeLoose(pattern.prefix, &prefix_buffer) orelse
            continue;
        if (!std.mem.startsWith(u8, normalized, prefix)) continue;
        const hex = normalized[prefix.len..];
        if (hex.len == 0) continue;
        const codepoint = std.fmt.parseInt(u21, hex, 16) catch continue;
        if (codepoint >= pattern.first and codepoint <= pattern.last) {
            return codepoint;
        }
    }

    for (0..record_count) |index| {
        const record = recordAt(index);
        if (looseEqual(query, recordName(record))) return record.codepoint;
    }
    return null;
}

fn looseEqual(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and isLooseIgnored(a[i])) i += 1;
        while (j < b.len and isLooseIgnored(b[j])) j += 1;
        if (i == a.len or j == b.len) {
            return i == a.len and j == b.len;
        }
        if (toUpperAscii(a[i]) != toUpperAscii(b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn normalizeLoose(name_text: []const u8, buffer: []u8) ?[]const u8 {
    if (name_text.len > buffer.len) return null;
    var len: usize = 0;
    for (name_text) |byte| {
        if (isLooseIgnored(byte)) continue;
        if (byte >= 0x80) return null;
        buffer[len] = toUpperAscii(byte);
        len += 1;
    }
    return buffer[0..len];
}

fn isLooseIgnored(byte: u8) bool {
    return byte == ' ' or byte == '-' or byte == '_';
}

fn toUpperAscii(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - ('a' - 'A') else byte;
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

test "explicit and algorithmic names" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("LATIN CAPITAL LETTER A", name('A').?);
    try testing.expectEqualStrings("HANGUL SYLLABLE GA", name(0xac00).?);

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "CJK UNIFIED IDEOGRAPH-4E00",
        nameInto(0x4e00, &buffer).?,
    );
    try testing.expectEqualStrings(
        "TANGUT IDEOGRAPH-17000",
        nameInto(0x17000, &buffer).?,
    );
    try testing.expectEqualStrings(
        "EGYPTIAN HIEROGLYPH A001",
        nameInto(0x13000, &buffer).?,
    );
    try testing.expectEqualStrings(
        "EGYPTIAN HIEROGLYPH-13460",
        nameInto(0x13460, &buffer).?,
    );
    try testing.expectEqualStrings(
        "KHITAN SMALL SCRIPT CHARACTER-18B00",
        nameInto(0x18b00, &buffer).?,
    );
    try testing.expectEqualStrings(
        "NUSHU CHARACTER-1B170",
        nameInto(0x1b170, &buffer).?,
    );
    try testing.expect(name(0x0378) == null);
}

test "control aliases and loose name lookup" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("NULL", name(0x0000).?);
    try testing.expectEqualStrings("NUL", alias(0x0000, .abbreviation).?);

    try testing.expectEqual(@as(?u21, 'A'), findByName("latin capital letter a"));
    try testing.expectEqual(
        @as(?u21, 0x4e00),
        findByName("CJK UNIFIED IDEOGRAPH-4E00"),
    );
    try testing.expectEqual(
        @as(?u21, 0x17000),
        findByName("tangut ideograph-17000"),
    );
    try testing.expectEqual(
        @as(?u21, 0xac00),
        findByName("HANGUL SYLLABLE GA"),
    );
    try testing.expectEqual(@as(?u21, null), findByName("not a real name"));
}

test "nameAlloc owns algorithmic names" {
    const testing = @import("std").testing;
    const owned = (try nameAlloc(testing.allocator, 0x4e00)).?;
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("CJK UNIFIED IDEOGRAPH-4E00", owned);
}
