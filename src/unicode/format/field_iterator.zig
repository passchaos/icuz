//! Typed iterators over formatted field-position spans.

const std = @import("std");

pub fn Iterator(comptime Field: type) type {
    return struct {
        fields: []const Field,
        index: usize = 0,

        pub fn init(fields: []const Field) @This() {
            return .{ .fields = fields };
        }

        pub fn next(self: *@This()) ?Field {
            if (self.index >= self.fields.len) return null;
            const field = self.fields[self.index];
            self.index += 1;
            return field;
        }

        pub fn reset(self: *@This()) void {
            self.index = 0;
        }

        pub fn count(self: @This()) usize {
            return self.fields.len;
        }
    };
}

test "field position iterator" {
    const testing = std.testing;
    const Field = struct { field: u8, start: usize, end: usize };
    const fields = [_]Field{
        .{ .field = 'y', .start = 0, .end = 4 },
        .{ .field = 'M', .start = 5, .end = 7 },
    };
    var iterator = Iterator(Field).init(&fields);
    try testing.expectEqual(@as(usize, 2), iterator.count());
    const first = iterator.next().?;
    try testing.expectEqual(@as(u8, 'y'), first.field);
    const second = iterator.next().?;
    try testing.expectEqual(@as(usize, 7), second.end);
    try testing.expect(iterator.next() == null);
    iterator.reset();
    try testing.expectEqual(@as(usize, 0), iterator.next().?.start);
}

test "number field iterator over formatted output" {
    const testing = std.testing;
    const number = @import("number.zig");
    const allocator = testing.allocator;

    var fields = std.ArrayList(number.NumberFieldPosition).empty;
    defer fields.deinit(allocator);
    const text = try number.formatFieldsAlloc(
        allocator,
        1234.5,
        "en",
        .{},
        &fields,
    );
    defer allocator.free(text);
    try testing.expect(fields.items.len > 0);

    var iterator = Iterator(number.NumberFieldPosition).init(fields.items);
    var count: usize = 0;
    while (iterator.next()) |field| {
        try testing.expect(field.end <= text.len);
        try testing.expect(field.start < field.end);
        count += 1;
    }
    try testing.expectEqual(fields.items.len, count);
}
