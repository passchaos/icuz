//! NFKC_Casefold (NFKC_CF) mapping from Unicode 17.0.0.
//!
//! The derived property maps each code point to its NFKC, case-folded,
//! default-ignorable-removed form. Because the mapped code points can interact
//! across character boundaries, the result is normalized to NFC after the
//! per-character mapping, as UAX #15 and UAX #44 require.

const std = @import("std");

const normalization = @import("root.zig");

const blob = @embedFile("casefold_data.bin");
const header_len = 32;
const mapping_count = readU32(8);
const removal_count = readU32(12);
const pool_count = readU32(16);
const mapping_offset = readU32(20);
const removal_offset = readU32(24);
const pool_offset = readU32(28);

const mapping_record_len = 12;
const removal_record_len = 8;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJQF") or
        blob[4] != 1 or blob[5] != 17 or blob[6] != 0 or blob[7] != 0)
    {
        @compileError("invalid NFKC_Casefold data");
    }
    if (mapping_offset != header_len or
        removal_offset != mapping_offset + @as(usize, mapping_count) * mapping_record_len or
        pool_offset != removal_offset + @as(usize, removal_count) * removal_record_len or
        pool_offset + @as(usize, pool_count) * 4 != blob.len)
    {
        @compileError("invalid NFKC_Casefold data lengths");
    }
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

const Match = union(enum) {
    target: struct { offset: u32, length: u16 },
    remove,
};

fn lookup(codepoint: u21) ?Match {
    var low: usize = 0;
    var high: usize = mapping_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = readU32(mapping_offset + middle * mapping_record_len);
        if (candidate < codepoint) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < mapping_count) {
        const record = mapping_offset + low * mapping_record_len;
        if (readU32(record) == codepoint) {
            return .{ .target = .{
                .offset = readU32(record + 4),
                .length = readU16(record + 8),
            } };
        }
    }
    low = 0;
    high = removal_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = removal_offset + middle * removal_record_len;
        if (readU32(record + 4) < codepoint) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < removal_count) {
        const record = removal_offset + low * removal_record_len;
        if (readU32(record) <= codepoint and codepoint <= readU32(record + 4)) {
            return .remove;
        }
    }
    return null;
}

fn targetCodepoint(offset: u32, index: usize) u21 {
    return @intCast(readU32(pool_offset + (@as(usize, offset) + index) * 4));
}

/// Apply Unicode's NFKC_Casefold mapping to UTF-8 `text`.
pub fn nfkcCasefoldAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ InvalidUtf8, OutOfMemory }![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    // NFKC_Casefold maps ASCII A-Z to lowercase and leaves the rest unchanged;
    // ASCII is already NFC, so the whole pipeline collapses to a byte loop.
    if (isAscii(text)) {
        const output = try allocator.alloc(u8, text.len);
        for (text, 0..) |byte, index| {
            output[index] = if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
        }
        return output;
    }

    var mapped = std.ArrayList(u21).empty;
    defer mapped.deinit(allocator);
    try mapped.ensureTotalCapacity(allocator, text.len);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
            return error.InvalidUtf8;
        index += length;
        if (lookup(codepoint)) |match| switch (match) {
            .remove => {},
            .target => |target| {
                for (0..target.length) |offset| {
                    try mapped.append(
                        allocator,
                        targetCodepoint(target.offset, offset),
                    );
                }
            },
        } else {
            try mapped.append(allocator, codepoint);
        }
    }

    const nfc_owned = try normalization.normalizeCodepointsAlloc(
        allocator,
        mapped.items,
        .nfc,
    );
    defer if (nfc_owned) |owned| allocator.free(owned);
    const result = nfc_owned orelse mapped.items;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, result.len * 2);
    var buffer: [4]u8 = undefined;
    for (result) |codepoint| {
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch
            return error.InvalidUtf8;
        try output.appendSlice(allocator, buffer[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

fn isAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

test "NFKC_Casefold examples" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Stra\u{00df}e", .expected = "strasse" },
        .{ .input = "\u{0391}\u{0392}\u{0393}", .expected = "\u{03b1}\u{03b2}\u{03b3}" },
        .{ .input = "\u{2460}", .expected = "1" },
        .{ .input = "\u{ff21}\u{ff22}\u{ff23}", .expected = "abc" },
        .{ .input = "\u{fb01}", .expected = "fi" },
        .{ .input = "\u{0130}", .expected = "i\u{0307}" },
        .{ .input = "a\u{0301}", .expected = "\u{00e1}" },
        .{ .input = "A\u{0301}", .expected = "\u{00e1}" },
        .{ .input = "A\u{00ad}B", .expected = "ab" },
        .{ .input = "A\u{200d}B", .expected = "ab" },
        .{ .input = "A\u{fe0f}B", .expected = "ab" },
        .{ .input = "Hello World", .expected = "hello world" },
    };
    for (cases) |case| {
        const actual = try nfkcCasefoldAlloc(allocator, case.input);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "NFKC_Casefold mapping table round trips" {
    const allocator = std.testing.allocator;
    var input_buffer: [4]u8 = undefined;
    var expected_buffer: [64]u8 = undefined;
    for (0..mapping_count) |index| {
        const record = mapping_offset + index * mapping_record_len;
        const codepoint: u21 = @intCast(readU32(record));
        const input_length = std.unicode.utf8Encode(codepoint, &input_buffer) catch
            continue;
        const target = Match{ .target = .{
            .offset = readU32(record + 4),
            .length = readU16(record + 8),
        } };
        var expected_len: usize = 0;
        for (0..target.target.length) |offset| {
            expected_len += std.unicode.utf8Encode(
                targetCodepoint(target.target.offset, offset),
                expected_buffer[expected_len..][0..4],
            ) catch unreachable;
        }
        const actual = try nfkcCasefoldAlloc(
            allocator,
            input_buffer[0..input_length],
        );
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(
            expected_buffer[0..expected_len],
            actual,
        );
    }
}

test "NFKC_Casefold removes default ignorables" {
    const allocator = std.testing.allocator;
    for (0..removal_count) |index| {
        const record = removal_offset + index * removal_record_len;
        const first = readU32(record);
        const last = readU32(record + 4);
        const samples = [_]u32{ first, (first + last) / 2, last };
        for (samples) |codepoint| {
            if (codepoint > 0x10FFFF) continue;
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(
                @intCast(codepoint),
                &buffer,
            ) catch continue;
            const actual = try nfkcCasefoldAlloc(allocator, buffer[0..length]);
            defer allocator.free(actual);
            try std.testing.expectEqualStrings("", actual);
        }
    }
}

test "NFKC_Casefold is idempotent" {
    const allocator = std.testing.allocator;
    const input = "Stra\u{00df}e \u{ff21}\u{2460} A\u{0301}\u{200d}\u{0130}";
    const first = try nfkcCasefoldAlloc(allocator, input);
    defer allocator.free(first);
    const second = try nfkcCasefoldAlloc(allocator, first);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "NFKC_Casefold rejects invalid UTF-8" {
    try std.testing.expectError(
        error.InvalidUtf8,
        nfkcCasefoldAlloc(std.testing.allocator, "\xff"),
    );
}
