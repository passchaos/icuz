//! ICU-compatible converter selector (`ucnvsel`).
//!
//! A selector is built from an ordered list of converter names. For an input
//! string it reports which converters can encode every code point, ignoring
//! caller-excluded code points.

const std = @import("std");
const charset = @import("../charset.zig");
const set_mod = @import("../set.zig");
const utf16 = @import("../utf16.zig");

pub const UnicodeSetMode = enum {
    roundtrip,
    roundtrip_and_fallback,
};

pub const Error = error{
    UnknownEncoding,
    InvalidUtf8,
    InvalidUtf16,
    InvalidSerialized,
    OutOfMemory,
};

pub const ConverterSelector = struct {
    allocator: std.mem.Allocator,
    names: [][]u8,
    encodings: []charset.Encoding,
    excluded: ?set_mod.Set,
    mode: UnicodeSetMode,

    pub fn init(
        allocator: std.mem.Allocator,
        converter_names: []const []const u8,
        excluded: ?*const set_mod.Set,
        mode: UnicodeSetMode,
    ) Error!ConverterSelector {
        const names = try allocator.alloc([]u8, converter_names.len);
        var initialized: usize = 0;
        errdefer {
            for (names[0..initialized]) |name| allocator.free(name);
            allocator.free(names);
        }
        const encodings = try allocator.alloc(charset.Encoding, converter_names.len);
        errdefer allocator.free(encodings);

        for (converter_names, 0..) |name, index| {
            names[index] = try allocator.dupe(u8, name);
            initialized = index + 1;
            encodings[index] = charset.fromLabel(name) orelse
                return error.UnknownEncoding;
        }

        var excluded_copy: ?set_mod.Set = null;
        errdefer if (excluded_copy) |*set| set.deinit();
        if (excluded) |set| {
            excluded_copy = try set.clone(allocator);
        }

        return .{
            .allocator = allocator,
            .names = names,
            .encodings = encodings,
            .excluded = excluded_copy,
            .mode = mode,
        };
    }

    pub fn deinit(self: *ConverterSelector) void {
        for (self.names) |name| self.allocator.free(name);
        self.allocator.free(self.names);
        self.allocator.free(self.encodings);
        if (self.excluded) |*set| set.deinit();
    }

    pub fn converterNames(self: *const ConverterSelector) []const []const u8 {
        return self.names;
    }

    /// Serialize the selector into an icuz-owned, versioned format.
    pub fn serializeAlloc(
        self: *const ConverterSelector,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);

        try output.appendSlice(allocator, "CJSS");
        try output.appendSlice(allocator, &.{ 1, 0, 0, 0 });
        try appendU16(allocator, &output, @intCast(self.names.len));
        try output.append(allocator, @intFromEnum(self.mode));
        try output.append(allocator, 0);
        const range_count: u32 = if (self.excluded) |set| @intCast(set.rangeIterator().ranges.len) else 0;
        const string_count: u32 = if (self.excluded) |set| @intCast(set.stringCount()) else 0;
        try appendU32(allocator, &output, range_count);
        try appendU32(allocator, &output, string_count);

        for (self.names) |name| {
            try appendU16(allocator, &output, @intCast(name.len));
            try output.appendSlice(allocator, name);
        }
        if (self.excluded) |set| {
            var ranges = set.rangeIterator();
            while (ranges.next()) |range| {
                try appendU32(allocator, &output, range.first);
                try appendU32(allocator, &output, range.last);
            }
            var index: usize = 0;
            while (index < set.stringCount()) : (index += 1) {
                const text = set.stringAt(index);
                try appendU16(allocator, &output, @intCast(text.len));
                try output.appendSlice(allocator, text);
            }
        }
        return output.toOwnedSlice(allocator);
    }

    /// Open a selector produced by `serializeAlloc`.
    pub fn initFromSerialized(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) Error!ConverterSelector {
        var reader = SerializedReader{ .data = bytes };
        const magic = try reader.readBytes(4);
        if (!std.mem.eql(u8, magic, "CJSS")) return error.InvalidSerialized;
        const version = try reader.readBytes(4);
        if (!std.mem.eql(u8, version, &.{ 1, 0, 0, 0 })) return error.InvalidSerialized;
        const converter_count = try reader.readU16();
        const mode_value = try reader.readU8();
        _ = try reader.readU8();
        const range_count = try reader.readU32();
        const string_count = try reader.readU32();
        if (mode_value > @intFromEnum(UnicodeSetMode.roundtrip_and_fallback)) {
            return error.InvalidSerialized;
        }

        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        for (0..converter_count) |_| {
            const length = try reader.readU16();
            try names.append(allocator, try reader.readBytes(length));
        }

        var excluded = set_mod.Set.init(allocator);
        defer excluded.deinit();
        for (0..range_count) |_| {
            const first = try reader.readU32();
            const last = try reader.readU32();
            if (first > last or last > 0x10ffff) return error.InvalidSerialized;
            try excluded.addRange(@intCast(first), @intCast(last));
        }
        for (0..string_count) |_| {
            const length = try reader.readU16();
            try excluded.addString(try reader.readBytes(length));
        }
        try excluded.finalize();
        if (reader.index != bytes.len) return error.InvalidSerialized;

        return ConverterSelector.init(
            allocator,
            names.items,
            if (range_count != 0 or string_count != 0) &excluded else null,
            @enumFromInt(mode_value),
        );
    }

    /// Returns one flag per converter, in the order supplied to `init`.
    pub fn selectForUTF8Alloc(
        self: *const ConverterSelector,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) Error![]bool {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        const selected = try allocator.alloc(bool, self.encodings.len);
        for (self.encodings, 0..) |encoding, index| {
            selected[index] = self.canEncode(text, encoding);
        }
        return selected;
    }

    /// Returns the selected converter names. The slices are borrowed from the
    /// selector; only the returned outer slice is owned by the caller.
    pub fn selectForUTF8NamesAlloc(
        self: *const ConverterSelector,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) Error![][]const u8 {
        const selected = try self.selectForUTF8Alloc(allocator, text);
        defer allocator.free(selected);
        var count: usize = 0;
        for (selected) |flag| {
            if (flag) count += 1;
        }
        const result = try allocator.alloc([]const u8, count);
        var cursor: usize = 0;
        for (selected, 0..) |flag, index| {
            if (flag) {
                result[cursor] = self.names[index];
                cursor += 1;
            }
        }
        return result;
    }

    pub fn selectForStringAlloc(
        self: *const ConverterSelector,
        allocator: std.mem.Allocator,
        units: []const u16,
    ) Error![]bool {
        const text = utf16.utf16ToUtf8Alloc(allocator, units) catch |err| switch (err) {
            error.InvalidUtf16 => return error.InvalidUtf16,
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return error.InvalidUtf8,
        };
        defer allocator.free(text);
        return self.selectForUTF8Alloc(allocator, text);
    }

    fn canEncode(
        self: *const ConverterSelector,
        text: []const u8,
        encoding: charset.Encoding,
    ) bool {
        var encoder = charset.Encoder.init(encoding);
        var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (self.excluded) |set| {
                if (set.contains(codepoint)) continue;
            }
            switch (encoding) {
                .utf8, .utf16_le, .utf16_be, .utf32_le, .utf32_be => {},
                else => {
                    var buffer: [16]u8 = undefined;
                    switch (encoder.encode(codepoint, &buffer)) {
                        .unmappable => return false,
                        .written => {},
                    }
                },
            }
        }
        return true;
    }
};

test "converter selector basic selection" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const names = [_][]const u8{
        "UTF-8",
        "US-ASCII",
        "ISO-8859-1",
        "ISO-8859-15",
        "windows-1252",
        "windows-1251",
        "Shift_JIS",
        "GB18030",
    };
    var selector = try ConverterSelector.init(allocator, &names, null, .roundtrip);
    defer selector.deinit();

    const ascii = try selector.selectForUTF8Alloc(allocator, "hello");
    defer allocator.free(ascii);
    try testing.expect(ascii[0] and ascii[1] and ascii[2]);

    const euro = try selector.selectForUTF8Alloc(allocator, "€");
    defer allocator.free(euro);
    try testing.expect(euro[0]);
    try testing.expect(!euro[1]);
    try testing.expect(!euro[2]);
    try testing.expect(euro[3]);
    try testing.expect(euro[4]);

    const cyrillic = try selector.selectForUTF8Alloc(allocator, "Привет");
    defer allocator.free(cyrillic);
    try testing.expect(cyrillic[5]);
    try testing.expect(!cyrillic[1]);

    const emoji = try selector.selectForUTF8Alloc(allocator, "😀");
    defer allocator.free(emoji);
    try testing.expect(emoji[0]);
    try testing.expect(emoji[7]);
    try testing.expect(!emoji[2]);
}

test "converter selector excluded code points" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var excluded = try set_mod.parse(allocator, "[€]");
    defer excluded.deinit();
    const names = [_][]const u8{ "US-ASCII", "ISO-8859-1" };
    var selector = try ConverterSelector.init(allocator, &names, &excluded, .roundtrip);
    defer selector.deinit();
    const selected = try selector.selectForUTF8Alloc(allocator, "a€");
    defer allocator.free(selected);
    try testing.expect(selected[0]);
    try testing.expect(selected[1]);
}

const SerializedReader = struct {
    data: []const u8,
    index: usize = 0,

    fn readU8(self: *SerializedReader) Error!u8 {
        if (self.index >= self.data.len) return error.InvalidSerialized;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    fn readU16(self: *SerializedReader) Error!u16 {
        if (self.index + 2 > self.data.len) return error.InvalidSerialized;
        const value = std.mem.readInt(u16, self.data[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn readU32(self: *SerializedReader) Error!u32 {
        if (self.index + 4 > self.data.len) return error.InvalidSerialized;
        const value = std.mem.readInt(u32, self.data[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    fn readBytes(self: *SerializedReader, length: usize) Error![]const u8 {
        if (self.index + length > self.data.len) return error.InvalidSerialized;
        const value = self.data[self.index..][0..length];
        self.index += length;
        return value;
    }
};

fn appendU16(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: u16,
) Error!void {
    var buffer: [2]u8 = undefined;
    std.mem.writeInt(u16, &buffer, value, .little);
    try output.appendSlice(allocator, &buffer);
}

fn appendU32(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: u32,
) Error!void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);
    try output.appendSlice(allocator, &buffer);
}

const Fixture = struct {
    data: []const u8,
    index: usize = 0,

    fn readU8(self: *Fixture) !u8 {
        if (self.index >= self.data.len) return error.Truncated;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    fn readU16(self: *Fixture) !u16 {
        if (self.index + 2 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u16, self.data[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn readU32(self: *Fixture) !u32 {
        if (self.index + 4 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u32, self.data[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    fn string(self: *Fixture) ![]const u8 {
        const length = try self.readU16();
        if (self.index + length > self.data.len) return error.Truncated;
        const value = self.data[self.index..][0..length];
        self.index += length;
        return value;
    }
};

test "converter selector ICU conformance fixture" {
    const fixture_data = @embedFile("selector_conformance.bin");
    try std.testing.expectEqualSlices(u8, "CJVS", fixture_data[0..4]);
    var fixture = Fixture{ .data = fixture_data, .index = 8 };
    const case_count = std.mem.readInt(u32, fixture.data[fixture.index..][0..4], .little);
    fixture.index += 4;
    const allocator = std.testing.allocator;

    var passed: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const converter_count = try fixture.readU16();
        var converter_names: [64][]const u8 = undefined;
        for (0..converter_count) |index| {
            converter_names[index] = try fixture.string();
        }
        const excluded_pattern = try fixture.string();
        const text = try fixture.string();
        const selected_count = try fixture.readU16();
        var expected: [64][]const u8 = undefined;
        for (0..selected_count) |index| {
            expected[index] = try fixture.string();
        }

        var excluded_set: ?set_mod.Set = null;
        defer if (excluded_set) |*set| set.deinit();
        if (excluded_pattern.len != 0) {
            excluded_set = try set_mod.parse(allocator, excluded_pattern);
        }

        var selector = try ConverterSelector.init(
            allocator,
            converter_names[0..converter_count],
            if (excluded_set) |*set| set else null,
            .roundtrip,
        );
        defer selector.deinit();

        const selected = try selector.selectForUTF8NamesAlloc(allocator, text);
        defer allocator.free(selected);
        if (selected.len != selected_count) {
            std.debug.print("selector case {d} text {s}: expected {d}, found {d}\n", .{
                case_index, text, selected_count, selected.len,
            });
            std.debug.print("expected:", .{});
            for (expected[0..selected_count]) |name| std.debug.print(" {s}", .{name});
            std.debug.print("\nactual:", .{});
            for (selected) |name| std.debug.print(" {s}", .{name});
            std.debug.print("\n", .{});
        }
        try std.testing.expectEqual(@as(usize, selected_count), selected.len);
        for (expected[0..selected_count], selected) |expected_name, actual_name| {
            try std.testing.expectEqualStrings(expected_name, actual_name);
        }
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), fixture_data.len - fixture.index);
    std.debug.print("converter selector conformance: {}/{} passed\n", .{ passed, case_count });
}

test "converter selector serialization" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const names = [_][]const u8{ "UTF-8", "US-ASCII", "ISO-8859-1" };
    var excluded = try set_mod.parse(allocator, "[€]");
    defer excluded.deinit();
    var selector = try ConverterSelector.init(allocator, &names, &excluded, .roundtrip);
    defer selector.deinit();

    const bytes = try selector.serializeAlloc(allocator);
    defer allocator.free(bytes);

    var restored = try ConverterSelector.initFromSerialized(allocator, bytes);
    defer restored.deinit();

    for ([_][]const u8{ "", "hello", "a€", "Привет" }) |text| {
        const original = try selector.selectForUTF8Alloc(allocator, text);
        defer allocator.free(original);
        const copy = try restored.selectForUTF8Alloc(allocator, text);
        defer allocator.free(copy);
        try testing.expectEqualSlices(bool, original, copy);
    }

    try testing.expectError(
        error.InvalidSerialized,
        ConverterSelector.initFromSerialized(allocator, ""),
    );
    try testing.expectError(
        error.InvalidSerialized,
        ConverterSelector.initFromSerialized(allocator, "nope"),
    );
    try testing.expectError(
        error.InvalidSerialized,
        ConverterSelector.initFromSerialized(allocator, bytes[0 .. bytes.len - 1]),
    );
}
