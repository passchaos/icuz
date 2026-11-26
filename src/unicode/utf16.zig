//! UTF-16 validation, iteration, and conversion helpers.
//!
//! Slices use native-endian `u16` units. Callers that read serialized UTF-16
//! should convert byte order before constructing the slice.

const std = @import("std");
const validation = @import("utf/validate16.zig");
const transcode = @import("utf/transcode.zig");

pub const Error = error{ InvalidUtf8, InvalidUtf16, OutOfMemory };

/// Validate a UTF-16 slice, including surrogate pairing.
pub const validate = validation.isValid;

/// Iterate code points from a UTF-16 slice already proven valid.
pub const Iterator = struct {
    units: []const u16,
    index: usize = 0,

    pub fn next(self: *Iterator) ?u21 {
        if (self.index >= self.units.len) return null;
        const unit = self.units[self.index];
        if (unit < 0xD800 or unit > 0xDFFF) {
            self.index += 1;
            return unit;
        }
        if (unit >= 0xDC00 or self.index + 1 >= self.units.len) return null;
        const low = self.units[self.index + 1];
        if (low < 0xDC00 or low > 0xDFFF) return null;
        self.index += 2;
        return 0x10000 +
            ((@as(u21, unit - 0xD800) << 10) | @as(u21, low - 0xDC00));
    }
};

/// Return the number of code points, or null for invalid UTF-16.
pub const codepointCount = validation.codepointCount;

/// Packed UTF-16 decode: `(codepoint + 1) << 1 | (length - 1)`, or zero for
/// an invalid sequence. Returning one register keeps the scalar and its unit
/// length out of an optional-struct temporary.
pub const packed_invalid: u32 = 0;

pub inline fn decodePacked(units: []const u16, index: usize) u32 {
    const unit = units[index];
    if (unit < 0xD800 or unit > 0xDFFF) {
        return (@as(u32, unit) + 1) << 1;
    }
    if (unit > 0xDBFF or index + 1 >= units.len) return packed_invalid;
    const low = units[index + 1];
    if (low < 0xDC00 or low > 0xDFFF) return packed_invalid;
    const value = (@as(u32, unit - 0xD800) << 10) | (low - 0xDC00);
    return ((0x10000 + value + 1) << 1) | 1;
}

pub inline fn packedCodepoint(value: u32) u21 {
    return @intCast((value >> 1) - 1);
}

pub inline fn packedLength(value: u32) usize {
    return (value & 1) + 1;
}

/// Decode a validated UTF-16 slice into code points.
pub fn decodeAlloc(
    allocator: std.mem.Allocator,
    units: []const u16,
) Error![]u21 {
    if (!validate(units)) return error.InvalidUtf16;
    var result = std.ArrayList(u21).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, units.len);

    var iterator = Iterator{ .units = units };
    while (iterator.next()) |codepoint| {
        try result.append(allocator, codepoint);
    }
    return result.toOwnedSlice(allocator);
}

/// Encode code points as UTF-16.
pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
) Error![]u16 {
    var result = std.ArrayList(u16).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, codepoints.len);

    for (codepoints) |codepoint| {
        if (codepoint <= 0xFFFF) {
            if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
                return error.InvalidUtf16;
            }
            try result.append(allocator, @intCast(codepoint));
            continue;
        }
        if (codepoint > 0x10FFFF) return error.InvalidUtf16;
        const value = codepoint - 0x10000;
        try result.append(
            allocator,
            @intCast(0xD800 + (value >> 10)),
        );
        try result.append(
            allocator,
            @intCast(0xDC00 + (value & 0x3FF)),
        );
    }
    return result.toOwnedSlice(allocator);
}

/// Convert UTF-8 to an owned native-endian UTF-16 slice.
pub const utf8ToUtf16Alloc = transcode.utf8ToUtf16Alloc;
/// Convert native-endian UTF-16 to an owned UTF-8 slice.
pub const utf16ToUtf8Alloc = transcode.utf16ToUtf8Alloc;
/// Append converted UTF-8 to a reusable UTF-16 list, preserving contents on error.
pub const utf8ToUtf16Into = transcode.utf8ToUtf16Into;
/// Append converted UTF-16 to a reusable UTF-8 list, preserving contents on error.
pub const utf16ToUtf8Into = transcode.utf16ToUtf8Into;

test {
    _ = @import("utf/tests.zig");
}

test "UTF-16 validation and surrogate pairs" {
    const testing = @import("std").testing;
    try testing.expect(validate(&.{ 0x0041, 0x00e9 }));
    try testing.expect(validate(&.{ 0xD83D, 0xDE00 }));
    try testing.expect(!validate(&.{0xD800}));
    try testing.expect(!validate(&.{0xDC00}));
    try testing.expect(!validate(&.{ 0xD800, 0x0041 }));

    const decoded = try decodeAlloc(testing.allocator, &.{ 0xD83D, 0xDE00 });
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u21, &.{0x1F600}, decoded);
}

test "UTF-8 and UTF-16 round trip" {
    const testing = @import("std").testing;
    const text = "Hello, 世界 \u{1F600}";
    const units = try utf8ToUtf16Alloc(testing.allocator, text);
    defer testing.allocator.free(units);
    try testing.expect(validate(units));
    try testing.expectEqual(@as(?usize, 11), codepointCount(units));

    const round_trip = try utf16ToUtf8Alloc(testing.allocator, units);
    defer testing.allocator.free(round_trip);
    try testing.expectEqualStrings(text, round_trip);
}

test "packed UTF-16 decoding matches the iterator" {
    const testing = @import("std").testing;
    const samples = [_][]const u16{
        &.{0x0041},
        &.{0x00e9},
        &.{ 0x1100, 0x1161, 0x11a8 },
        &.{ 0xD83D, 0xDE00 },
        &.{ 0x0041, 0xD83D, 0xDE00, 0x42 },
        &.{ 0xDBFF, 0xDFFF },
    };
    for (samples) |units| {
        var cursor: usize = 0;
        var expected = Iterator{ .units = units };
        while (expected.next()) |codepoint| {
            const decoded = decodePacked(units, cursor);
            try testing.expect(decoded != packed_invalid);
            try testing.expectEqual(codepoint, packedCodepoint(decoded));
            cursor += packedLength(decoded);
        }
        try testing.expectEqual(units.len, cursor);
    }
    try testing.expectEqual(packed_invalid, decodePacked(&.{0xD800}, 0));
    try testing.expectEqual(
        packed_invalid,
        decodePacked(&.{ 0xD800, 0x0041 }, 0),
    );
    try testing.expectEqual(packed_invalid, decodePacked(&.{0xDC00}, 0));
}
