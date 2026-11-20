//! NFKC_Casefold (NFKC_CF) and NFKC_Simple_Casefold (NFKC_SCF) mappings from
//! Unicode 17.0.0.
//!
//! The derived properties map each code point to its NFKC, case-folded,
//! default-ignorable-removed form. Because the mapped code points can interact
//! across character boundaries, the result is normalized to NFC after the
//! per-character mapping, as UAX #15 and UAX #44 require.

const std = @import("std");

const normalization = @import("root.zig");

const header_len = 32;
const mapping_record_len = 12;
const removal_record_len = 8;

const Match = union(enum) {
    target: struct { offset: u32, length: u16 },
    remove,
};

const Table = struct {
    blob: []const u8,
    mapping_count: u32,
    removal_count: u32,
    pool_count: u32,
    mapping_offset: u32,
    removal_offset: u32,
    pool_offset: u32,

    fn init(comptime blob: []const u8) Table {
        comptime {
            if (blob.len < header_len or
                !std.mem.eql(u8, blob[0..4], "CJQF") or
                blob[4] != 1 or blob[5] != 17 or blob[6] != 0 or blob[7] != 0)
            {
                @compileError("invalid NFKC_Casefold data");
            }
            const mapping_count = std.mem.readInt(u32, blob[8..12], .little);
            const removal_count = std.mem.readInt(u32, blob[12..16], .little);
            const pool_count = std.mem.readInt(u32, blob[16..20], .little);
            const mapping_offset = std.mem.readInt(u32, blob[20..24], .little);
            const removal_offset = std.mem.readInt(u32, blob[24..28], .little);
            const pool_offset = std.mem.readInt(u32, blob[28..32], .little);
            if (mapping_offset != header_len or
                removal_offset != mapping_offset +
                    @as(u32, mapping_count) * mapping_record_len or
                pool_offset != removal_offset +
                    @as(u32, removal_count) * removal_record_len or
                pool_offset + @as(u32, pool_count) * 4 != blob.len)
            {
                @compileError("invalid NFKC_Casefold data lengths");
            }
        }
        return .{
            .blob = blob,
            .mapping_count = readU32(blob, 8),
            .removal_count = readU32(blob, 12),
            .pool_count = readU32(blob, 16),
            .mapping_offset = readU32(blob, 20),
            .removal_offset = readU32(blob, 24),
            .pool_offset = readU32(blob, 28),
        };
    }

    fn lookup(self: *const Table, codepoint: u21) ?Match {
        var low: usize = 0;
        var high: usize = self.mapping_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = self.mapping_offset + middle * mapping_record_len;
            const candidate = readU32(self.blob, record);
            if (candidate < codepoint) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low < self.mapping_count) {
            const record = self.mapping_offset + low * mapping_record_len;
            if (readU32(self.blob, record) == codepoint) {
                return .{ .target = .{
                    .offset = readU32(self.blob, record + 4),
                    .length = readU16(self.blob, record + 8),
                } };
            }
        }
        low = 0;
        high = self.removal_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = self.removal_offset + middle * removal_record_len;
            if (readU32(self.blob, record + 4) < codepoint) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low < self.removal_count) {
            const record = self.removal_offset + low * removal_record_len;
            if (readU32(self.blob, record) <= codepoint and
                codepoint <= readU32(self.blob, record + 4))
            {
                return .remove;
            }
        }
        return null;
    }

    fn targetCodepoint(self: *const Table, offset: u32, index: usize) u21 {
        return @intCast(readU32(
            self.blob,
            self.pool_offset + (@as(usize, offset) + index) * 4,
        ));
    }
};

const cf_table = Table.init(@embedFile("casefold_data.bin"));
const scf_table = Table.init(@embedFile("casefold_simple_data.bin"));

fn readU32(blob: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn readU16(blob: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

/// Apply Unicode's NFKC_Casefold mapping to UTF-8 `text`.
pub fn nfkcCasefoldAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ InvalidUtf8, OutOfMemory }![]u8 {
    return mapAlloc(&cf_table, allocator, text);
}

/// Apply Unicode's NFKC_Simple_Casefold mapping to UTF-8 `text`.
pub fn nfkcSimpleCasefoldAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ InvalidUtf8, OutOfMemory }![]u8 {
    return mapAlloc(&scf_table, allocator, text);
}

fn mapAlloc(
    table: *const Table,
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ InvalidUtf8, OutOfMemory }![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    // Both mappings send ASCII A-Z to lowercase and leave the rest unchanged;
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
        if (table.lookup(codepoint)) |match| switch (match) {
            .remove => {},
            .target => |target| {
                for (0..target.length) |offset| {
                    try mapped.append(
                        allocator,
                        table.targetCodepoint(target.offset, offset),
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

test "NFKC_Simple_Casefold examples" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Stra\u{00df}e", .expected = "stra\u{00df}e" },
        .{ .input = "\u{1e9e}", .expected = "\u{00df}" },
        .{ .input = "\u{2460}", .expected = "1" },
        .{ .input = "\u{ff21}\u{ff22}\u{ff23}", .expected = "abc" },
        .{ .input = "A\u{00ad}B", .expected = "ab" },
        .{ .input = "Hello World", .expected = "hello world" },
    };
    for (cases) |case| {
        const actual = try nfkcSimpleCasefoldAlloc(allocator, case.input);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "NFKC_Casefold mapping table round trips" {
    const allocator = std.testing.allocator;
    var input_buffer: [4]u8 = undefined;
    var expected_buffer: [64]u8 = undefined;
    for (0..cf_table.mapping_count) |index| {
        const record = cf_table.mapping_offset + index * mapping_record_len;
        const codepoint: u21 = @intCast(readU32(cf_table.blob, record));
        const input_length = std.unicode.utf8Encode(codepoint, &input_buffer) catch
            continue;
        var expected_len: usize = 0;
        const target_len = readU16(cf_table.blob, record + 8);
        const target_offset = readU32(cf_table.blob, record + 4);
        for (0..target_len) |offset| {
            expected_len += std.unicode.utf8Encode(
                cf_table.targetCodepoint(target_offset, offset),
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
    for (0..cf_table.removal_count) |index| {
        const record = cf_table.removal_offset + index * removal_record_len;
        const first = readU32(cf_table.blob, record);
        const last = readU32(cf_table.blob, record + 4);
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
