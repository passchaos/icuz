//! Numeric_Value, Numeric_Type, and decimal digit values.
//!
//! Values are stored as exact rationals from Unicode 17's
//! `DerivedNumericValues.txt`, with the type from `DerivedNumericType.txt`.
//! Adjacent code points with the same value are merged into ranges.

const std = @import("std");

const blob = @embedFile("numeric_data.bin");
const header_len = 16;
const record_len = 28;
const record_count = readU32(8);

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJNV") or
        blob[4] != 1 or blob[5] != 17 or blob[6] != 0 or blob[7] != 0)
    {
        @compileError("invalid numeric property data");
    }
    if (header_len + @as(usize, record_count) * record_len != blob.len) {
        @compileError("invalid numeric property data lengths");
    }
}

pub const NumericType = enum(u2) { none = 0, decimal = 1, digit = 2, numeric = 3 };

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn readI64(offset: usize) i64 {
    return std.mem.readInt(i64, blob[offset..][0..8], .little);
}

fn readU64(offset: usize) u64 {
    return std.mem.readInt(u64, blob[offset..][0..8], .little);
}

const Record = struct {
    first: u32,
    last: u32,
    numerator: i64,
    denominator: u64,
    kind: NumericType,
};

fn recordAt(index: usize) Record {
    const base = header_len + index * record_len;
    return .{
        .first = readU32(base),
        .last = readU32(base + 4),
        .numerator = readI64(base + 8),
        .denominator = readU64(base + 16),
        .kind = @enumFromInt(blob[base + 24]),
    };
}

fn find(codepoint: u21) ?Record {
    var low: usize = 0;
    var high: usize = record_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = recordAt(middle);
        if (codepoint < record.first) {
            high = middle;
        } else if (codepoint > record.last) {
            low = middle + 1;
        } else {
            return record;
        }
    }
    return null;
}

/// Unicode's Numeric_Type property.
pub fn numericType(codepoint: u21) NumericType {
    if (codepoint < 0x80) {
        return if (codepoint >= '0' and codepoint <= '9') .decimal else .none;
    }
    return (find(codepoint) orelse return .none).kind;
}

/// Unicode's Numeric_Value property, or null when the scalar has none.
pub fn numericValue(codepoint: u21) ?f64 {
    if (codepoint < 0x80) {
        if (codepoint >= '0' and codepoint <= '9') {
            return @floatFromInt(codepoint - '0');
        }
        return null;
    }
    const record = find(codepoint) orelse return null;
    return @as(f64, @floatFromInt(record.numerator)) /
        @as(f64, @floatFromInt(record.denominator));
}

/// Decimal digit value (0-9) for Numeric_Type=Decimal scalars.
pub fn digitValue(codepoint: u21) ?u8 {
    if (codepoint < 0x80) {
        if (codepoint >= '0' and codepoint <= '9') {
            return @intCast(codepoint - '0');
        }
        return null;
    }
    const record = find(codepoint) orelse return null;
    if (record.kind != .decimal or record.denominator != 1 or
        record.numerator < 0 or record.numerator > 9)
    {
        return null;
    }
    return @intCast(record.numerator);
}

test "numeric values and types" {
    const testing = @import("std").testing;

    try testing.expectEqual(@as(f64, 5), numericValue('5').?);
    try testing.expectEqual(@as(?u8, 5), digitValue('5'));
    try testing.expectEqual(NumericType.decimal, numericType('5'));
    try testing.expectEqual(@as(f64, 5), numericValue(0x0665).?);
    try testing.expectEqual(@as(?u8, 5), digitValue(0x0665));
    try testing.expectEqual(@as(f64, 0.5), numericValue(0x00bd).?);
    try testing.expectEqual(NumericType.numeric, numericType(0x00bd));
    try testing.expectEqual(@as(f64, 12), numericValue(0x216b).?);
    try testing.expectEqual(@as(f64, -0.5), numericValue(0x0f33).?);
    try testing.expectEqual(NumericType.digit, numericType(0x00b2));
    try testing.expectEqual(@as(?u8, null), digitValue(0x00b2));
    try testing.expectEqual(@as(f64, 10000), numericValue(0x4e07).?);
    try testing.expectEqual(@as(f64, 10000000000000000), numericValue(0x4eac).?);
    try testing.expectEqual(@as(f64, 1), numericValue(0x4e00).?);
    try testing.expectEqual(@as(f64, 0), numericValue(0x3007).?);
    try testing.expectEqual(@as(f64, 10), numericValue(0x62fe).?);
    try testing.expectEqual(@as(f64, 100), numericValue(0x767e).?);
    try testing.expectEqual(@as(f64, 1000), numericValue(0x5343).?);
    try testing.expectEqual(@as(?f64, null), numericValue('A'));
    try testing.expectEqual(NumericType.none, numericType('A'));
}

test "numeric table is consistent" {
    for (0..record_count) |index| {
        const record = recordAt(index);
        const codepoint: u21 = @intCast(record.first);
        try std.testing.expect(record.kind != .none);
        try std.testing.expect(record.denominator != 0);
        try std.testing.expect(record.first <= record.last);
        try std.testing.expect(numericValue(codepoint) != null);
        try std.testing.expectEqual(record.kind, numericType(codepoint));
        if (record.kind == .decimal and record.numerator >= 0 and
            record.numerator <= 9 and record.denominator == 1)
        {
            try std.testing.expectEqual(
                @as(?u8, @intCast(record.numerator)),
                digitValue(codepoint),
            );
        }
    }
}
