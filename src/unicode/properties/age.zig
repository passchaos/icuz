//! Unicode Age property: the version that first assigned each scalar.
//!
//! Ranges and versions come from Unicode 17's `DerivedAge.txt`. Unassigned
//! scalars have no age.

const std = @import("std");

const blob = @embedFile("age_data.bin");
const header_len = 16;
const record_len = 12;
const record_count = readU32(8);

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJXV") or
        blob[4] != 1 or blob[5] != 17 or blob[6] != 0 or blob[7] != 0)
    {
        @compileError("invalid Age property data");
    }
    if (header_len + @as(usize, record_count) * record_len != blob.len) {
        @compileError("invalid Age property data lengths");
    }
}

pub const Age = struct {
    major: u8,
    minor: u8,
};

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn versionAt(index: usize) u16 {
    return readU16(header_len + index * record_len + 8);
}

fn decodeVersion(version: u16) Age {
    return .{ .major = @intCast(version >> 8), .minor = @intCast(version & 0xFF) };
}

pub const Range = struct {
    first: u21,
    last: u21,
    version: u16,
};

pub fn rangeCount() usize {
    return record_count;
}

/// Age range at `index`, in code-point order.
pub fn rangeAt(index: usize) Range {
    const base = header_len + index * record_len;
    return .{
        .first = @intCast(readU32(base)),
        .last = @intCast(readU32(base + 4)),
        .version = readU16(base + 8),
    };
}

/// Age of `codepoint`, or null when it is unassigned.
pub fn age(codepoint: u21) ?Age {
    return decodeVersion(ageVersion(codepoint) orelse return null);
}

/// Encoded age as `(major << 8) | minor`, or null when unassigned.
pub fn ageVersion(codepoint: u21) ?u16 {
    if (codepoint < 0x80) return 0x0101;
    var low: usize = 0;
    var high: usize = record_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = header_len + middle * record_len;
        const first = readU32(base);
        const last = readU32(base + 4);
        if (codepoint < first) {
            high = middle;
        } else if (codepoint > last) {
            low = middle + 1;
        } else {
            return readU16(base + 8);
        }
    }
    return null;
}

test "Age property values" {
    const testing = @import("std").testing;

    try testing.expectEqual(Age{ .major = 1, .minor = 1 }, age('A').?);
    try testing.expectEqual(Age{ .major = 2, .minor = 1 }, age(0x20ac).?);
    try testing.expectEqual(Age{ .major = 6, .minor = 1 }, age(0x1f600).?);
    try testing.expectEqual(Age{ .major = 15, .minor = 0 }, age(0x1fae8).?);
    try testing.expect(age(0x0378) == null);
    try testing.expectEqual(Age{ .major = 2, .minor = 0 }, age(0x10ffff).?);
    try testing.expectEqual(@as(?u16, 0x0101), ageVersion(0x0000));
}

test "Age table is consistent" {
    for (0..record_count) |index| {
        const base = header_len + index * record_len;
        const first = readU32(base);
        const last = readU32(base + 4);
        try std.testing.expect(first <= last);
        try std.testing.expect(last <= 0x10ffff);
        const version = readU16(base + 8);
        try std.testing.expect(version >> 8 <= 17);
        try std.testing.expectEqual(version, ageVersion(@intCast(first)).?);
        try std.testing.expectEqual(version, ageVersion(@intCast(last)).?);
    }
}
