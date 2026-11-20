//! ICU `UText`-style text abstraction over UTF-8, UTF-16, and UTF-32.
//!
//! Native indexes are byte offsets for UTF-8, code-unit offsets for UTF-16,
//! and code-point offsets for UTF-32, matching ICU's text providers. The
//! input storage is borrowed and must outlive the `Text` value.

const std = @import("std");

pub const Error = error{ InvalidUtf8, OutOfMemory };

pub const Kind = enum { utf8, utf16, utf32 };

pub const Text = struct {
    storage: Storage,
    index: i64 = 0,

    pub const Storage = union(Kind) {
        utf8: []const u8,
        utf16: []const u16,
        utf32: []const u21,
    };

    pub fn initUtf8(text: []const u8) Text {
        return .{ .storage = .{ .utf8 = text } };
    }

    pub fn initUtf16(units: []const u16) Text {
        return .{ .storage = .{ .utf16 = units } };
    }

    pub fn initUtf32(codepoints: []const u21) Text {
        return .{ .storage = .{ .utf32 = codepoints } };
    }

    /// Text borrows its backing storage; there is nothing to release.
    pub fn deinit(self: *Text) void {
        self.* = undefined;
    }

    pub fn clone(self: Text) Text {
        return self;
    }

    pub fn kind(self: Text) Kind {
        return self.storage;
    }

    pub fn nativeLength(self: Text) i64 {
        return switch (self.storage) {
            .utf8 => |value| @intCast(value.len),
            .utf16 => |value| @intCast(value.len),
            .utf32 => |value| @intCast(value.len),
        };
    }

    pub fn nativeIndex(self: Text) i64 {
        return self.index;
    }

    /// ICU `utext_setNativeIndex`: clamp to the text and snap backward to a
    /// code point boundary when the index points inside a character.
    pub fn setNativeIndex(self: *Text, index: i64) void {
        self.index = self.snapIndex(index);
    }

    pub fn isAtEnd(self: Text) bool {
        return self.index >= self.nativeLength();
    }

    /// Code point at the current index without moving.
    pub fn current(self: Text) Error!?u21 {
        if (self.index >= self.nativeLength()) return null;
        return try self.codepointAt(self.index);
    }

    /// ICU `utext_next32`: return the current code point and advance.
    pub fn next(self: *Text) Error!?u21 {
        const codepoint = (try self.current()) orelse return null;
        const length = self.unitLengthAt(self.index);
        self.index = @min(self.index + length, self.nativeLength());
        return codepoint;
    }

    /// ICU `utext_previous32`: move back one code point and return it.
    pub fn previous(self: *Text) Error!?u21 {
        if (self.index <= 0) return null;
        self.index = self.previousBoundary(self.index);
        return try self.codepointAt(self.index);
    }

    /// ICU `utext_moveIndex32`: move by `delta` code points. The index stops
    /// at the text boundary and the result is false when it could not move
    /// the full distance.
    pub fn moveIndex32(self: *Text, delta: i64) bool {
        var remaining = if (delta < 0) -delta else delta;
        var complete = true;
        if (delta >= 0) {
            while (remaining > 0) : (remaining -= 1) {
                if (self.index >= self.nativeLength()) {
                    complete = false;
                    break;
                }
                self.index = @min(
                    self.index + self.unitLengthAt(self.index),
                    self.nativeLength(),
                );
            }
        } else {
            while (remaining > 0) : (remaining -= 1) {
                if (self.index <= 0) {
                    complete = false;
                    break;
                }
                self.index = self.previousBoundary(self.index);
            }
        }
        return complete;
    }

    /// Append the code points in the native range `[start, limit)`.
    ///
    /// ICU snaps both bounds backward to code point boundaries, so a limit
    /// inside a character excludes that partial character.
    pub fn extractInto(
        self: Text,
        allocator: std.mem.Allocator,
        start: i64,
        limit: i64,
        output: *std.ArrayList(u21),
    ) Error!void {
        var cursor = self.snapIndex(start);
        const end = self.snapIndex(limit);
        while (cursor < end) {
            try output.append(allocator, try self.codepointAt(cursor));
            cursor = @min(
                cursor + self.unitLengthAt(cursor),
                self.nativeLength(),
            );
        }
    }

    /// Return the code points in the native range `[start, limit)`.
    pub fn extractAlloc(
        self: Text,
        allocator: std.mem.Allocator,
        start: i64,
        limit: i64,
    ) Error![]u21 {
        var output = std.ArrayList(u21).empty;
        errdefer output.deinit(allocator);
        try self.extractInto(allocator, start, limit, &output);
        return output.toOwnedSlice(allocator);
    }

    fn snapIndex(self: Text, index: i64) i64 {
        const length = self.nativeLength();
        if (index <= 0) return 0;
        if (index >= length) return length;
        return self.snapBackward(index);
    }

    fn snapBackward(self: Text, index: i64) i64 {
        switch (self.storage) {
            .utf8 => |value| {
                var result = index;
                while (result > 0 and
                    (value[@intCast(result)] & 0xC0) == 0x80)
                {
                    result -= 1;
                }
                return result;
            },
            .utf16 => |value| {
                const position: usize = @intCast(index);
                if (position < value.len and isLowSurrogate(value[position]) and
                    position > 0 and isHighSurrogate(value[position - 1]))
                {
                    return index - 1;
                }
                return index;
            },
            .utf32 => return index,
        }
    }

    fn previousBoundary(self: Text, index: i64) i64 {
        var result = index - 1;
        switch (self.storage) {
            .utf8 => |value| {
                while (result > 0 and
                    (value[@intCast(result)] & 0xC0) == 0x80)
                {
                    result -= 1;
                }
            },
            .utf16 => |value| {
                const position: usize = @intCast(result);
                if (isLowSurrogate(value[position]) and position > 0 and
                    isHighSurrogate(value[position - 1]))
                {
                    result -= 1;
                }
            },
            .utf32 => {},
        }
        return result;
    }

    fn unitLengthAt(self: Text, index: i64) i64 {
        switch (self.storage) {
            .utf8 => |value| {
                const position: usize = @intCast(index);
                return std.unicode.utf8ByteSequenceLength(
                    value[position],
                ) catch 1;
            },
            .utf16 => |value| {
                const position: usize = @intCast(index);
                if (isHighSurrogate(value[position]) and
                    position + 1 < value.len and
                    isLowSurrogate(value[position + 1]))
                {
                    return 2;
                }
                return 1;
            },
            .utf32 => return 1,
        }
    }

    fn codepointAt(self: Text, index: i64) Error!u21 {
        switch (self.storage) {
            .utf8 => |value| {
                const position: usize = @intCast(index);
                const length = std.unicode.utf8ByteSequenceLength(
                    value[position],
                ) catch return error.InvalidUtf8;
                if (position + length > value.len) return error.InvalidUtf8;
                return std.unicode.utf8Decode(
                    value[position..][0..length],
                ) catch error.InvalidUtf8;
            },
            .utf16 => |value| {
                const position: usize = @intCast(index);
                const first = value[position];
                if (isHighSurrogate(first) and position + 1 < value.len) {
                    const second = value[position + 1];
                    if (isLowSurrogate(second)) {
                        const high: u21 = first - 0xD800;
                        const low: u21 = second - 0xDC00;
                        return 0x10000 + (high << 10) + low;
                    }
                }
                return first;
            },
            .utf32 => |value| return value[@intCast(index)],
        }
    }
};

fn isHighSurrogate(value: u16) bool {
    return value >= 0xD800 and value <= 0xDBFF;
}

fn isLowSurrogate(value: u16) bool {
    return value >= 0xDC00 and value <= 0xDFFF;
}

test "UTF-8 native indexes match ICU UText" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var text = Text.initUtf8("a\u{1F600}b");
    try testing.expectEqual(@as(i64, 6), text.nativeLength());
    try testing.expectEqual(@as(?u21, 'a'), try text.next());
    try testing.expectEqual(@as(?u21, 0x1F600), try text.next());
    try testing.expectEqual(@as(i64, 5), text.nativeIndex());
    try testing.expectEqual(@as(?u21, 'b'), try text.next());
    try testing.expectEqual(@as(?u21, null), try text.next());
    try testing.expectEqual(@as(?u21, 'b'), try text.previous());
    try testing.expectEqual(@as(?u21, 0x1F600), try text.previous());
    try testing.expectEqual(@as(i64, 1), text.nativeIndex());
    try testing.expectEqual(@as(?u21, 'a'), try text.previous());
    try testing.expectEqual(@as(?u21, null), try text.previous());

    // Indices inside a character snap backward.
    text.setNativeIndex(3);
    try testing.expectEqual(@as(i64, 1), text.nativeIndex());
    text.setNativeIndex(100);
    try testing.expectEqual(@as(i64, 6), text.nativeIndex());
    text.setNativeIndex(-5);
    try testing.expectEqual(@as(i64, 0), text.nativeIndex());

    text.setNativeIndex(0);
    try testing.expect(text.moveIndex32(2));
    try testing.expectEqual(@as(i64, 5), text.nativeIndex());
    try testing.expect(!text.moveIndex32(2));
    try testing.expectEqual(@as(i64, 6), text.nativeIndex());
    try testing.expect(text.moveIndex32(-3));
    try testing.expectEqual(@as(i64, 0), text.nativeIndex());
    try testing.expect(!text.moveIndex32(-1));

    const extracted = try text.extractAlloc(allocator, 1, 5);
    defer allocator.free(extracted);
    try testing.expectEqualSlices(u21, &[_]u21{0x1F600}, extracted);
    const partial = try text.extractAlloc(allocator, 1, 4);
    defer allocator.free(partial);
    try testing.expectEqual(@as(usize, 0), partial.len);
    const snapped = try text.extractAlloc(allocator, 4, 5);
    defer allocator.free(snapped);
    try testing.expectEqualSlices(u21, &[_]u21{0x1F600}, snapped);
}

test "UTF-16 native indexes match ICU UText" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const units = [_]u16{ 'a', 0xD83D, 0xDE00, 'b' };
    var text = Text.initUtf16(&units);
    try testing.expectEqual(@as(i64, 4), text.nativeLength());
    try testing.expectEqual(@as(?u21, 'a'), try text.next());
    try testing.expectEqual(@as(?u21, 0x1F600), try text.next());
    try testing.expectEqual(@as(i64, 3), text.nativeIndex());
    try testing.expectEqual(@as(?u21, 'b'), try text.next());

    text.setNativeIndex(2);
    try testing.expectEqual(@as(i64, 1), text.nativeIndex());
    try testing.expectEqual(@as(?u21, 'a'), try text.previous());
    try testing.expectEqual(@as(?u21, null), try text.previous());

    text.setNativeIndex(4);
    try testing.expectEqual(@as(?u21, 'b'), try text.previous());
    try testing.expectEqual(@as(?u21, 0x1F600), try text.previous());
    try testing.expectEqual(@as(i64, 1), text.nativeIndex());
    try testing.expectEqual(@as(?u21, 'a'), try text.previous());

    text.setNativeIndex(0);
    try testing.expect(text.moveIndex32(2));
    try testing.expectEqual(@as(i64, 3), text.nativeIndex());
    try testing.expect(!text.moveIndex32(2));
    try testing.expectEqual(@as(i64, 4), text.nativeIndex());

    const extracted = try text.extractAlloc(allocator, 0, 3);
    defer allocator.free(extracted);
    try testing.expectEqualSlices(u21, &[_]u21{ 'a', 0x1F600 }, extracted);
}

test "UTF-32 native indexes and invalid UTF-8" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const codepoints = [_]u21{ 'a', 0x1F600, 'b' };
    var text = Text.initUtf32(&codepoints);
    try testing.expectEqual(@as(i64, 3), text.nativeLength());
    try testing.expectEqual(@as(?u21, 'a'), try text.next());
    try testing.expectEqual(@as(?u21, 0x1F600), try text.next());
    try testing.expectEqual(@as(?u21, 0x1F600), try text.previous());
    try testing.expectEqual(@as(i64, 1), text.nativeIndex());
    try testing.expectEqual(@as(?u21, 'a'), try text.previous());

    var invalid = Text.initUtf8("\xff");
    try testing.expectError(error.InvalidUtf8, invalid.current());
    try testing.expectError(error.InvalidUtf8, invalid.next());

    const extracted = try Text.initUtf8("abc").extractAlloc(
        allocator,
        0,
        3,
    );
    defer allocator.free(extracted);
    try testing.expectEqualSlices(u21, &[_]u21{ 'a', 'b', 'c' }, extracted);
}

test "ICU UText conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("text_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJUT", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const kind = fixture[cursor];
        const input_len = std.mem.readInt(
            u16,
            fixture[cursor + 1 ..][0..2],
            .little,
        );
        cursor += 3;
        const input = fixture[cursor..][0..input_len];
        cursor += input_len;

        var units = std.ArrayList(u16).empty;
        defer units.deinit(allocator);
        var text = if (kind == 0)
            Text.initUtf8(input)
        else blk: {
            var index: usize = 0;
            while (index + 1 < input.len) : (index += 2) {
                try units.append(
                    allocator,
                    std.mem.readInt(u16, input[index..][0..2], .little),
                );
            }
            break :blk Text.initUtf16(units.items);
        };

        const op_count = std.mem.readInt(
            u32,
            fixture[cursor..][0..4],
            .little,
        );
        cursor += 4;
        var op_index: usize = 0;
        while (op_index < op_count) : (op_index += 1) {
            const opcode = fixture[cursor];
            const arg0 = std.mem.readInt(
                i64,
                fixture[cursor + 1 ..][0..8],
                .little,
            );
            const arg1 = std.mem.readInt(
                i64,
                fixture[cursor + 9 ..][0..8],
                .little,
            );
            const expected = std.mem.readInt(
                i64,
                fixture[cursor + 17 ..][0..8],
                .little,
            );
            const extra_count = std.mem.readInt(
                u32,
                fixture[cursor + 25 ..][0..4],
                .little,
            );
            cursor += 29;
            const extra = fixture[cursor..][0 .. extra_count * 4];
            cursor += extra_count * 4;

            switch (opcode) {
                0 => {
                    text.setNativeIndex(arg0);
                    if (text.nativeIndex() != expected) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "utext set mismatch: {d} -> {d} want {d}\n",
                                .{ arg0, text.nativeIndex(), expected },
                            );
                        }
                    }
                },
                1, 2 => {
                    const codepoint = if (opcode == 1)
                        try text.next()
                    else
                        try text.previous();
                    const actual: i64 = if (codepoint) |value|
                        value
                    else
                        -1;
                    if (actual != expected) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "utext step mismatch: op {d} got {d} want {d}\n",
                                .{ opcode, actual, expected },
                            );
                        }
                    }
                },
                3 => {
                    const ok = text.moveIndex32(arg0);
                    if ((@intFromBool(ok)) != expected or
                        text.nativeIndex() != arg1)
                    {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "utext move mismatch: {d} ok={} index={d} want {d}/{d}\n",
                                .{ arg0, ok, text.nativeIndex(), expected, arg1 },
                            );
                        }
                    }
                },
                4 => {
                    const extracted = try text.extractAlloc(
                        allocator,
                        arg0,
                        arg1,
                    );
                    defer allocator.free(extracted);
                    var matches = extracted.len == expected;
                    if (matches) {
                        var index: usize = 0;
                        while (index < extracted.len) : (index += 1) {
                            const want = std.mem.readInt(
                                u32,
                                extra[index * 4 ..][0..4],
                                .little,
                            );
                            if (extracted[index] != want) {
                                matches = false;
                                break;
                            }
                        }
                    }
                    if (!matches) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "utext extract mismatch: case {d} kind {d} {d}..{d} got {d} want {d}\n",
                                .{ case_index, kind, arg0, arg1, extracted.len, expected },
                            );
                        }
                    }
                },
                else => return error.InvalidFixture,
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "UText conformance: {}/{} cases passed\n",
        .{ case_count - failures, case_count },
    );
}
