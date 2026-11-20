//! Bidirectional character iterator over UTF-8 or UTF-16, following ICU's
//! `UCharIterator` movement model. UTF-8 indices are byte offsets; UTF-16
//! indices are code-unit offsets.

const std = @import("std");
const utf16_mod = @import("utf16.zig");

pub const Error = error{ InvalidUtf8, InvalidUtf16 };

pub const Origin = enum(u8) {
    start = 0,
    current = 1,
    limit = 2,
};

pub const CharIterator = struct {
    storage: Storage,
    position: usize = 0,

    pub const Storage = union(enum) {
        utf8: []const u8,
        utf16: []const u16,
    };

    pub fn initUTF8(text: []const u8) Error!CharIterator {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return .{ .storage = .{ .utf8 = text } };
    }

    pub fn initUTF16(units: []const u16) Error!CharIterator {
        if (!utf16_mod.validate(units)) return error.InvalidUtf16;
        return .{ .storage = .{ .utf16 = units } };
    }

    pub fn reset(self: *CharIterator) void {
        self.position = 0;
    }

    pub fn index(self: *const CharIterator) usize {
        return self.position;
    }

    pub fn length(self: *const CharIterator) usize {
        return switch (self.storage) {
            .utf8 => |text| text.len,
            .utf16 => |units| units.len,
        };
    }

    pub fn first(self: *CharIterator) ?u21 {
        self.position = 0;
        return self.current();
    }

    pub fn last(self: *CharIterator) ?u21 {
        switch (self.storage) {
            .utf8 => |text| {
                if (text.len == 0) return null;
                var start = text.len - 1;
                while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
                self.position = start;
            },
            .utf16 => |units| {
                if (units.len == 0) return null;
                var start = units.len - 1;
                if (start > 0 and isLowSurrogate(units[start]) and
                    isHighSurrogate(units[start - 1]))
                {
                    start -= 1;
                }
                self.position = start;
            },
        }
        return self.current();
    }

    pub fn next(self: *CharIterator) ?u21 {
        switch (self.storage) {
            .utf8 => |text| {
                if (self.position >= text.len) return null;
                const sequence_length = std.unicode.utf8ByteSequenceLength(
                    text[self.position],
                ) catch return null;
                if (self.position + sequence_length > text.len) return null;
                const codepoint = std.unicode.utf8Decode(
                    text[self.position..][0..sequence_length],
                ) catch return null;
                self.position += sequence_length;
                return codepoint;
            },
            .utf16 => |units| {
                if (self.position >= units.len) return null;
                const unit = units[self.position];
                if (isHighSurrogate(unit) and self.position + 1 < units.len and
                    isLowSurrogate(units[self.position + 1]))
                {
                    const codepoint = decodeSurrogate(unit, units[self.position + 1]);
                    self.position += 2;
                    return codepoint;
                }
                self.position += 1;
                return unit;
            },
        }
    }

    pub fn previous(self: *CharIterator) ?u21 {
        if (self.position == 0) return null;
        switch (self.storage) {
            .utf8 => |text| {
                var start = self.position - 1;
                while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
                const codepoint = std.unicode.utf8Decode(
                    text[start..self.position],
                ) catch return null;
                self.position = start;
                return codepoint;
            },
            .utf16 => |units| {
                if (self.position >= 2 and isLowSurrogate(units[self.position - 1]) and
                    isHighSurrogate(units[self.position - 2]))
                {
                    const codepoint = decodeSurrogate(
                        units[self.position - 2],
                        units[self.position - 1],
                    );
                    self.position -= 2;
                    return codepoint;
                }
                self.position -= 1;
                return units[self.position];
            },
        }
    }

    pub fn current(self: *const CharIterator) ?u21 {
        switch (self.storage) {
            .utf8 => |text| {
                if (self.position >= text.len) return null;
                const sequence_length = std.unicode.utf8ByteSequenceLength(
                    text[self.position],
                ) catch return null;
                if (self.position + sequence_length > text.len) return null;
                return std.unicode.utf8Decode(
                    text[self.position..][0..sequence_length],
                ) catch null;
            },
            .utf16 => |units| {
                if (self.position >= units.len) return null;
                const unit = units[self.position];
                if (isHighSurrogate(unit) and self.position + 1 < units.len and
                    isLowSurrogate(units[self.position + 1]))
                {
                    return decodeSurrogate(unit, units[self.position + 1]);
                }
                return unit;
            },
        }
    }

    pub fn move(self: *CharIterator, delta: i64, origin: Origin) ?u21 {
        const base: i64 = switch (origin) {
            .start => 0,
            .current => @intCast(self.position),
            .limit => @intCast(self.length()),
        };
        var target = base + delta;
        if (target < 0) target = 0;
        const limit: i64 = @intCast(self.length());
        if (target > limit) target = limit;
        var position: usize = @intCast(target);
        position = self.snapToBoundary(position);
        self.position = position;
        return self.current();
    }

    fn snapToBoundary(self: *const CharIterator, position: usize) usize {
        switch (self.storage) {
            .utf8 => |text| {
                var cursor = @min(position, text.len);
                while (cursor < text.len and (text[cursor] & 0xc0) == 0x80) {
                    cursor += 1;
                }
                return cursor;
            },
            .utf16 => |units| {
                var cursor = @min(position, units.len);
                if (cursor > 0 and cursor < units.len and
                    isLowSurrogate(units[cursor]) and
                    isHighSurrogate(units[cursor - 1]))
                {
                    cursor -= 1;
                }
                return cursor;
            },
        }
    }
};

fn isHighSurrogate(value: u16) bool {
    return value >= 0xD800 and value <= 0xDBFF;
}

fn isLowSurrogate(value: u16) bool {
    return value >= 0xDC00 and value <= 0xDFFF;
}

fn decodeSurrogate(high: u16, low: u16) u21 {
    return @intCast(0x10000 + ((@as(u32, high) - 0xD800) << 10) +
        (@as(u32, low) - 0xDC00));
}

test "character iterator UTF-8 and UTF-16" {
    const testing = std.testing;
    var utf8 = try CharIterator.initUTF8("aé😀");
    try testing.expectEqual(@as(?u21, 'a'), utf8.first());
    // `next` is post-increment, like ICU's uiter_next32.
    try testing.expectEqual(@as(?u21, 'a'), utf8.next());
    try testing.expectEqual(@as(?u21, 0xE9), utf8.next());
    try testing.expectEqual(@as(?u21, 0x1F600), utf8.next());
    try testing.expectEqual(@as(?u21, null), utf8.next());
    try testing.expectEqual(@as(?u21, 0x1F600), utf8.previous());
    try testing.expectEqual(@as(?u21, 0xE9), utf8.previous());
    try testing.expectEqual(@as(?u21, 'a'), utf8.previous());
    try testing.expectEqual(@as(?u21, null), utf8.previous());

    const units = [_]u16{ 'a', 0x00E9, 0xD83D, 0xDE00 };
    var utf16 = try CharIterator.initUTF16(&units);
    try testing.expectEqual(@as(?u21, 'a'), utf16.first());
    try testing.expectEqual(@as(?u21, 'a'), utf16.next());
    try testing.expectEqual(@as(?u21, 0xE9), utf16.next());
    try testing.expectEqual(@as(?u21, 0x1F600), utf16.next());
    try testing.expectEqual(@as(?u21, 0x1F600), utf16.previous());
    try testing.expectEqual(@as(usize, 2), utf16.index());
    try testing.expectEqual(@as(?u21, 0xE9), utf16.move(-1, .current));
    try testing.expectEqual(@as(usize, 1), utf16.index());
}
