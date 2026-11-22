//! Precomputed Script and Script_Extensions scalar ranges.
//!
//! `set_ranges.bin` is generated from the committed Script and
//! Script_Extensions blobs by `tools/unicode/script/generate_set_ranges.py`.
//! Each entry holds coalesced, non-adjacent inclusive ranges, so set
//! construction copies ranges instead of scanning every scalar.

const std = @import("std");
const types = @import("types.zig");

const blob = @embedFile("set_ranges.bin");
const header_len = 16;
const script_count = readU16(8);
const extension_count = readU16(10);
const range_count = readU32(12);
const script_offset = header_len;
const extension_offset = script_offset + @as(usize, script_count) * 8;
const ranges_offset = extension_offset + @as(usize, extension_count) * 8;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJSS") or
        blob[4] != 1 or
        blob[5] != 17 or blob[6] != 0 or blob[7] != 0)
    {
        @compileError("invalid precomputed script range data");
    }
    if (script_count != extension_count or
        script_count != @typeInfo(types.Script).@"enum".fields.len or
        ranges_offset + @as(usize, range_count) * 8 != blob.len)
    {
        @compileError("invalid precomputed script range data lengths");
    }
}

pub const RangeEntry = struct {
    offset: u32,
    count: u32,
};

/// Precomputed ranges for one primary Script value.
pub fn scriptEntry(target: types.Script) RangeEntry {
    return entryAt(script_offset, @intFromEnum(target));
}

/// Precomputed ranges for one Script_Extensions value.
pub fn extensionEntry(target: types.Script) RangeEntry {
    return entryAt(extension_offset, @intFromEnum(target));
}

fn entryAt(base: usize, index: usize) RangeEntry {
    const offset = base + index * 8;
    return .{
        .offset = readU32(offset),
        .count = readU32(offset + 4),
    };
}

pub fn rangeFirst(entry: RangeEntry, index: usize) u21 {
    return @intCast(readU32(ranges_offset + (@as(usize, entry.offset) + index) * 8));
}

pub fn rangeLast(entry: RangeEntry, index: usize) u21 {
    return @intCast(readU32(ranges_offset + (@as(usize, entry.offset) + index) * 8 + 4));
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}
