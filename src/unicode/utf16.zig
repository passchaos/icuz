//! UTF-16 validation, iteration, and conversion helpers.
//!
//! Slices use native-endian `u16` units. Callers that read serialized UTF-16
//! should convert byte order before constructing the slice.

const std = @import("std");

pub const Error = error{ InvalidUtf8, InvalidUtf16, OutOfMemory };

/// Validate a UTF-16 slice, including surrogate pairing.
pub fn validate(units: []const u16) bool {
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (unit < 0xD800 or unit > 0xDFFF) {
            index += 1;
            continue;
        }
        if (unit >= 0xDC00 or index + 1 >= units.len) return false;
        const low = units[index + 1];
        if (low < 0xDC00 or low > 0xDFFF) return false;
        index += 2;
    }
    return true;
}

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
pub fn codepointCount(units: []const u16) ?usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (unit < 0xD800 or unit > 0xDFFF) {
            index += 1;
            count += 1;
            continue;
        }
        if (unit >= 0xDC00 or index + 1 >= units.len) return null;
        const low = units[index + 1];
        if (low < 0xDC00 or low > 0xDFFF) return null;
        index += 2;
        count += 1;
    }
    return count;
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

/// Convert UTF-8 to UTF-16.
pub fn utf8ToUtf16Alloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u16 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

    var result = std.ArrayList(u16).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, text.len);

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xFFFF) {
            try result.append(allocator, @intCast(codepoint));
            continue;
        }
        const value = codepoint - 0x10000;
        try result.append(allocator, @intCast(0xD800 + (value >> 10)));
        try result.append(allocator, @intCast(0xDC00 + (value & 0x3FF)));
    }
    return result.toOwnedSlice(allocator);
}

/// Convert UTF-16 to UTF-8.
pub fn utf16ToUtf8Alloc(
    allocator: std.mem.Allocator,
    units: []const u16,
) Error![]u8 {
    if (!validate(units)) return error.InvalidUtf16;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, units.len);

    var encoded: [4]u8 = undefined;
    var iterator = Iterator{ .units = units };
    while (iterator.next()) |codepoint| {
        const len = std.unicode.utf8Encode(codepoint, &encoded) catch
            unreachable;
        try result.appendSlice(allocator, encoded[0..len]);
    }
    return result.toOwnedSlice(allocator);
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
