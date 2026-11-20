//! Right-to-left script detection from CLDR script metadata.

const std = @import("std");

const data = @import("direction_data.zig");

/// True when the ISO 15924 script code is right-to-left. The comparison is
/// case-insensitive for the four-letter code.
pub fn isRightToLeft(script: []const u8) bool {
    if (script.len != 4) return false;
    var buffer: [4]u8 = undefined;
    buffer[0] = std.ascii.toUpper(script[0]);
    for (script[1..], 1..) |byte, index| {
        buffer[index] = std.ascii.toLower(byte);
    }
    var low: usize = 0;
    var high = data.rtl_scripts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, data.rtl_scripts[middle], &buffer)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

test "RTL scripts" {
    const testing = @import("std").testing;

    try testing.expect(isRightToLeft("Arab"));
    try testing.expect(isRightToLeft("arab"));
    try testing.expect(isRightToLeft("Hebr"));
    try testing.expect(isRightToLeft("Thaa"));
    try testing.expect(!isRightToLeft("Latn"));
    try testing.expect(!isRightToLeft("Cyrl"));
    try testing.expect(!isRightToLeft(""));
}
