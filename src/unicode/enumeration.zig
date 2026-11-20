//! Generic string enumeration, matching ICU's `UEnumeration` traversal model.

const std = @import("std");

pub const StringEnumeration = struct {
    items: []const []const u8,
    index: usize = 0,

    pub fn init(items: []const []const u8) StringEnumeration {
        return .{ .items = items };
    }

    pub fn next(self: *StringEnumeration) ?[]const u8 {
        if (self.index >= self.items.len) return null;
        const value = self.items[self.index];
        self.index += 1;
        return value;
    }

    pub fn reset(self: *StringEnumeration) void {
        self.index = 0;
    }

    pub fn count(self: StringEnumeration) usize {
        return self.items.len;
    }
};

test "string enumeration" {
    const testing = std.testing;
    const items = [_][]const u8{ "en", "fr", "de" };
    var enumeration = StringEnumeration.init(&items);
    try testing.expectEqual(@as(usize, 3), enumeration.count());
    try testing.expectEqualStrings("en", enumeration.next().?);
    try testing.expectEqualStrings("fr", enumeration.next().?);
    try testing.expectEqualStrings("de", enumeration.next().?);
    try testing.expect(enumeration.next() == null);
    enumeration.reset();
    try testing.expectEqualStrings("en", enumeration.next().?);
}
