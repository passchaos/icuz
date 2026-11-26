//! Independent scalar, surrogate-boundary, and conversion contract tests.
const std = @import("std");
const conversion = @import("transcode.zig");
const validation = @import("validate16.zig");
const big_endian = @import("builtin").cpu.arch.endian() == .big;

test {
    _ = @import("convert/packing_tests.zig");
}

test "UTF conversion rejects unpaired surrogates in every classified span" {
    const a = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(a);
    try output.ensureTotalCapacity(a, 256);
    var failed = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    for ([_]u16{ 0xd800, 0xdbff, 0xdc00, 0xdfff }) |bad| {
        for (0..33) |position| {
            var units = [_]u16{0x41} ** 33;
            units[position] = bad;
            output.clearRetainingCapacity();
            try output.appendSlice(a, "prefix");
            try std.testing.expectError(error.InvalidUtf16, conversion.utf16ToUtf8Into(failed.allocator(), &units, &output));
            try std.testing.expectEqualStrings("prefix", output.items);
        }
    }
}

test "UTF conversion stays inside guarded input and exact output buffers" {
    if (comptime @import("builtin").os.tag != .linux or @import("builtin").cpu.arch.endian() != .little) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const input = try std.posix.mmap(null, 3 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(input);
    const wide_memory = try std.posix.mmap(null, 3 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(wide_memory);
    const narrow_memory = try std.posix.mmap(null, 3 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(narrow_memory);
    for ([_][]u8{ input, wide_memory, narrow_memory }) |memory| {
        try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.os.linux.mprotect(memory.ptr, page, .{})));
        try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.os.linux.mprotect(memory.ptr + 2 * page, page, .{})));
    }
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const patterns = [_][]const u8{ "A", "é", "世", "😀", "aé世😀" };
    var expected: [512]u16 = undefined;
    for (patterns) |pattern| {
        for (0..258) |length| {
            const text = input[2 * page - length .. 2 * page];
            for (text, 0..) |*byte, i| byte.* = pattern[i % pattern.len];
            const storage: []u16 = @alignCast(std.mem.bytesAsSlice(u16, wide_memory[2 * page - length * 2 .. 2 * page]));
            var wide = std.ArrayList(u16){ .items = storage[0..0], .capacity = storage.len };
            const count = std.unicode.utf8ToUtf16Le(&expected, text) catch {
                try std.testing.expectError(error.InvalidUtf8, conversion.utf8ToUtf16Into(failed.allocator(), text, &wide));
                try std.testing.expectEqual(@as(usize, 0), wide.items.len);
                continue;
            };
            try conversion.utf8ToUtf16Into(failed.allocator(), text, &wide);
            try std.testing.expectEqualSlices(u16, expected[0..count], wide.items);
            // Place the exact input and output ends directly before guards.
            const units: []u16 = @alignCast(std.mem.bytesAsSlice(u16, wide_memory[2 * page - count * 2 .. 2 * page]));
            @memcpy(units, expected[0..count]);
            const bytes = narrow_memory[2 * page - length .. 2 * page];
            var narrow = std.ArrayList(u8){ .items = bytes[0..0], .capacity = bytes.len };
            try conversion.utf16ToUtf8Into(failed.allocator(), units, &narrow);
            try std.testing.expectEqualSlices(u8, text, narrow.items);
        }
    }
    for (1..130) |length| {
        const units: []u16 = @alignCast(std.mem.bytesAsSlice(u16, input[2 * page - length * 2 .. 2 * page]));
        @memset(units, 0x41);
        units[length - 1] = 0xdc00;
        const bytes = narrow_memory[2 * page - length * 3 .. 2 * page];
        var narrow = std.ArrayList(u8){ .items = bytes[0..0], .capacity = bytes.len };
        try std.testing.expectError(error.InvalidUtf16, conversion.utf16ToUtf8Into(failed.allocator(), units, &narrow));
        try std.testing.expectEqual(@as(usize, 0), narrow.items.len);
    }
}

test "UTF conversion agrees with std for every scalar and preserves prefixes" {
    const a = std.testing.allocator;
    var wide = std.ArrayList(u16).empty;
    defer wide.deinit(a);
    var narrow = std.ArrayList(u8).empty;
    defer narrow.deinit(a);
    try wide.ensureTotalCapacity(a, 16);
    try narrow.ensureTotalCapacity(a, 16);
    var encoded: [4]u8 = undefined;
    var expected: [2]u16 = undefined;
    for (0..0x110000) |value| {
        if (value >= 0xd800 and value <= 0xdfff) continue;
        const count = try std.unicode.utf8Encode(@intCast(value), &encoded);
        const length = try std.unicode.utf8ToUtf16Le(&expected, encoded[0..count]);
        if (comptime big_endian) for (expected[0..length]) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        wide.clearRetainingCapacity();
        try wide.append(a, 0x41);
        try conversion.utf8ToUtf16Into(a, encoded[0..count], &wide);
        try std.testing.expectEqual(@as(u16, 0x41), wide.items[0]);
        try std.testing.expectEqualSlices(u16, expected[0..length], wide.items[1..]);
        narrow.clearRetainingCapacity();
        try narrow.append(a, '!');
        try conversion.utf16ToUtf8Into(a, wide.items[1..], &narrow);
        try std.testing.expectEqual(@as(u8, '!'), narrow.items[0]);
        try std.testing.expectEqualSlices(u8, encoded[0..count], narrow.items[1..]);
        try std.testing.expectEqual(@as(?usize, count), validation.utf8Size(expected[0..length]));
        try std.testing.expectEqual(@as(?usize, 1), validation.codepointCount(expected[0..length]));
    }
}

const Reference = struct { bytes: usize, scalars: usize };
fn reference(units: []const u16) ?Reference {
    var little: [33]u16 = undefined;
    const input = if (big_endian) block: {
        for (units, 0..) |unit, i| little[i] = @byteSwap(unit);
        break :block little[0..units.len];
    } else units;
    var iterator = std.unicode.Utf16LeIterator.init(input);
    var result = Reference{ .bytes = 0, .scalars = 0 };
    var encoded: [4]u8 = undefined;
    while (iterator.nextCodepoint() catch return null) |cp| {
        result.bytes += std.unicode.utf8Encode(cp, &encoded) catch unreachable;
        result.scalars += 1;
    }
    return result;
}

test "UTF-16 vector validation and sizes match std across surrogate boundaries" {
    var buffer = [_]u16{0x41} ** 33;
    for (0..0x10000) |value| {
        for ([_]usize{ 0, 7, 15, 16, 31, 32 }) |position| {
            buffer[position] = @intCast(value);
            const expected = reference(&buffer);
            try std.testing.expectEqual(expected != null, validation.isValid(&buffer));
            try std.testing.expectEqual(if (expected) |r| @as(?usize, r.bytes) else null, validation.utf8Size(&buffer));
            try std.testing.expectEqual(if (expected) |r| @as(?usize, r.scalars) else null, validation.codepointCount(&buffer));
            buffer[position] = 0x41;
        }
    }
    for (0..1024) |high| {
        for (0..1024) |low| {
            buffer[15] = @intCast(0xd800 + high);
            buffer[16] = @intCast(0xdc00 + low);
            try std.testing.expect(validation.isValid(&buffer));
            try std.testing.expectEqual(@as(?usize, 35), validation.utf8Size(&buffer));
            try std.testing.expectEqual(@as(?usize, 32), validation.codepointCount(&buffer));
        }
    }
    buffer[15] = 0x41;
    buffer[16] = 0x41;
    buffer[31] = 0xd800;
    buffer[32] = 0xdc00;
    try std.testing.expectEqual(@as(?usize, 32), validation.codepointCount(&buffer));
    try std.testing.expectEqual(@as(?usize, 35), validation.utf8Size(&buffer));
}

test "UTF conversion exact allocations and reused buffers match mixed input" {
    const a = std.testing.allocator;
    const pieces = [_][]const u8{ "A", "é", "世", "😀", "\x00", "\xef\xbb\xbf", "\xf4\x8f\xbf\xbf" };
    var random_source = std.Random.DefaultPrng.init(0xd7a49011);
    const random = random_source.random();
    var text = std.ArrayList(u8).empty;
    defer text.deinit(a);
    for (0..500) |_| {
        text.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 128)) |_| try text.appendSlice(a, pieces[random.uintLessThan(usize, pieces.len)]);
        const expected = try std.unicode.utf8ToUtf16LeAlloc(a, text.items);
        defer a.free(expected);
        if (comptime big_endian) for (expected) |*unit| {
            unit.* = @byteSwap(unit.*);
        };
        const actual = try conversion.utf8ToUtf16Alloc(a, text.items);
        defer a.free(actual);
        try std.testing.expectEqualSlices(u16, expected, actual);
        const decoded = try conversion.utf16ToUtf8Alloc(a, actual);
        defer a.free(decoded);
        try std.testing.expectEqualSlices(u8, text.items, decoded);
        try std.testing.expectEqual(@as(?usize, text.items.len), validation.utf8Size(actual));
    }
}

test "UTF conversion leaves buffers unchanged on invalid input and allocation failure" {
    const a = std.testing.allocator;
    var failed = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const fail = failed.allocator();
    try std.testing.expectError(error.InvalidUtf8, conversion.utf8ToUtf16Alloc(fail, "\xff"));
    try std.testing.expectError(error.InvalidUtf16, conversion.utf16ToUtf8Alloc(fail, &.{0xd800}));
    for ([_]bool{ false, true }) |warm| {
        var wide = std.ArrayList(u16).empty;
        defer wide.deinit(a);
        var narrow = std.ArrayList(u8).empty;
        defer narrow.deinit(a);
        try wide.append(a, 0x41);
        try narrow.appendSlice(a, "prefix");
        if (warm) {
            try wide.ensureTotalCapacity(a, 256);
            try narrow.ensureTotalCapacity(a, 256);
        }
        const bad_text = "a" ** 80 ++ "\xff";
        var bad_units = [_]u16{0x41} ** 33;
        bad_units[32] = 0xdc00;
        try std.testing.expectError(error.InvalidUtf8, conversion.utf8ToUtf16Into(fail, bad_text, &wide));
        try std.testing.expectError(error.InvalidUtf16, conversion.utf16ToUtf8Into(fail, &bad_units, &narrow));
        try std.testing.expectEqualSlices(u16, &.{0x41}, wide.items);
        try std.testing.expectEqualStrings("prefix", narrow.items);
        if (!warm) {
            try std.testing.expectError(error.OutOfMemory, conversion.utf8ToUtf16Into(fail, "a" ** 100, &wide));
            try std.testing.expectEqualSlices(u16, &.{0x41}, wide.items);
        }
    }
}
