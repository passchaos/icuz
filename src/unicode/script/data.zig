//! Generated Unicode 17 Script-property lookup.
//!
//! The byte values are discriminants of `root.Script`; the generator reads the
//! enum order directly. The header also records that enum's stable fingerprint,
//! so reordering it without regenerating the blob fails at compile time.
//!
//! `flat_scripts.bin` is derived from `data.bin` by
//! `tools/unicode/script/generate_flat_scripts.py`. A flat table is one load
//! per scalar; the packed table needs a dependent index-then-page load, which
//! dominates random lookups.

const std = @import("std");
const scalar_value = @import("../scalar/root.zig");

const data = @embedFile("data.bin");
const script_root = @import("types.zig");
const header_len = 16;
const index_count = readU16(12);
const page_count = readU16(14);
const index_offset = header_len;
const pages_offset = index_offset + @as(usize, index_count) * 2;

const flat = @embedFile("flat_scripts.bin");
const flat_header_len = 16;
const flat_count = readU32At(flat, 8);

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJS1") or
        data[4] != 1 or data[5] != 17 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid Unicode Script data");
    }
    if (index_count != 0x1100 or
        pages_offset + @as(usize, page_count) * 256 != data.len)
    {
        @compileError("invalid Unicode Script data lengths");
    }
    if (readU32(8) != scriptEnumFingerprint()) {
        @compileError("Unicode Script data was generated for a different Script enum");
    }
    if (flat.len < flat_header_len or !std.mem.eql(u8, flat[0..4], "CJZ5") or
        flat[4] != 1 or flat[5] != 17 or flat[6] != 0 or flat[7] != 0)
    {
        @compileError("invalid flat Script data");
    }
    if (flat_count != 0x110001 or flat_header_len + flat_count != flat.len) {
        @compileError("invalid flat Script data lengths");
    }
}

pub inline fn scriptId(codepoint: u21) u8 {
    // The generator patches surrogates and appends an out-of-range sentinel,
    // both Unknown, so a clamped load matches the validity rule.
    const index: usize = @min(
        @as(usize, codepoint),
        @as(usize, flat_count) - 1,
    );
    return flat[flat_header_len + index];
}

/// Packed-table lookup, kept as the reference for the flat table's test.
fn scriptIdPacked(codepoint: u21) u8 {
    if (!scalar_value.isValid(codepoint)) return @intFromEnum(script_root.Script.unknown);
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(index_offset + page * 2);
    return data[
        pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ];
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn readU32At(blob: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn scriptEnumFingerprint() u32 {
    @setEvalBranchQuota(10_000);
    var value: u32 = 2166136261;
    inline for (@typeInfo(script_root.Script).@"enum".fields) |field| {
        for (field.name) |byte| {
            value = (value ^ byte) *% 16777619;
        }
        value = (value ^ 0xff) *% 16777619;
    }
    return value;
}

test "flat script ids match the packed table" {
    const testing = std.testing;
    var codepoint: u32 = 0;
    while (codepoint <= 0x1fffff) : (codepoint += 1) {
        const value: u21 = @intCast(codepoint);
        try testing.expectEqual(scriptIdPacked(value), scriptId(value));
    }
}
