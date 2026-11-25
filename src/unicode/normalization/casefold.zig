//! NFKC_Casefold (NFKC_CF) and NFKC_Simple_Casefold (NFKC_SCF) mappings from
//! Unicode 17.0.0.
//!
//! The derived properties map each code point to its NFKC, case-folded,
//! default-ignorable-removed form. Because the mapped code points can interact
//! across character boundaries, the result is normalized to NFC after the
//! per-character mapping, as UAX #15 and UAX #44 require.

const std = @import("std");
const scalar = @import("../scalar/root.zig");

const inert = @import("inert.zig");
const normalization = @import("root.zig");

const header_len = 32;
const mapping_record_len = 12;
const removal_record_len = 8;

const Match = union(enum) {
    target: struct { offset: u32, length: u16 },
    remove,
};

const page_count = 0x1100;
/// Pages with at least one mapping record. Both tables stay below this, and
/// the comptime builder rejects data that outgrows the table.
const max_mapping_pages = 64;

const MappingIndex = struct {
    /// Direct-table slot of the page, or 0xFFFF when it has no mappings.
    slots: [page_count]u16,
    /// Mapping record for each low byte of a mapped page, or 0xFFFF.
    direct: [max_mapping_pages][256]u16,
};

/// A page-direct index turns the per-scalar mapping lookup into two loads.
fn buildMappingIndex(
    comptime blob: []const u8,
    comptime mapping_count: u32,
    comptime mapping_offset: u32,
) MappingIndex {
    @setEvalBranchQuota(400_000);
    var index = MappingIndex{
        .slots = [_]u16{0xffff} ** page_count,
        .direct = [_][256]u16{[_]u16{0xffff} ** 256} ** max_mapping_pages,
    };
    var next_slot: u16 = 0;
    for (0..mapping_count) |record| {
        const codepoint = readU32(
            blob,
            mapping_offset + record * mapping_record_len,
        );
        const page: usize = @intCast(codepoint >> 8);
        if (index.slots[page] == 0xffff) {
            if (next_slot == max_mapping_pages) {
                @compileError("NFKC_Casefold mapping pages outgrew the index");
            }
            index.slots[page] = next_slot;
            next_slot += 1;
        }
        index.direct[index.slots[page]][@intCast(codepoint & 0xff)] =
            @intCast(record);
    }
    return index;
}

/// First removal record whose last codepoint is at or above each page base.
fn buildRemovalPages(
    comptime blob: []const u8,
    comptime removal_count: u32,
    comptime removal_offset: u32,
) [page_count + 1]u16 {
    @setEvalBranchQuota(200_000);
    var pages: [page_count + 1]u16 = undefined;
    var record: usize = 0;
    for (0..page_count + 1) |page| {
        const base: u32 = @intCast(page << 8);
        while (record < removal_count and
            readU32(
                blob,
                removal_offset + record * removal_record_len + 4,
            ) < base)
        {
            record += 1;
        }
        pages[page] = @intCast(record);
    }
    return pages;
}

/// Pages that any removal range overlaps. Most pages have none, so their
/// scalars skip the removal search entirely.
fn buildRemovalCoverage(
    comptime blob: []const u8,
    comptime removal_count: u32,
    comptime removal_offset: u32,
) [page_count]bool {
    @setEvalBranchQuota(200_000);
    var covered = [_]bool{false} ** page_count;
    for (0..removal_count) |record| {
        const first = readU32(blob, removal_offset + record * removal_record_len);
        const last = readU32(
            blob,
            removal_offset + record * removal_record_len + 4,
        );
        const first_page: usize = @intCast(first >> 8);
        const last_page: usize = @intCast(@min(last >> 8, page_count - 1));
        for (first_page..last_page + 1) |page| covered[page] = true;
    }
    return covered;
}

/// Mapping record for each two-byte scalar (U+0080..U+07FF), indexed by lead
/// byte minus 0xC2 and the low six bits of the second byte. Greek, Cyrillic,
/// and other two-byte prose then maps with one table load.
fn buildTwoByteMap(
    comptime blob: []const u8,
    comptime mapping_count: u32,
    comptime mapping_offset: u32,
    comptime removal_count: u32,
    comptime removal_offset: u32,
) [30][64]u16 {
    @setEvalBranchQuota(400_000);
    var map: [30][64]u16 = [_][64]u16{[_]u16{0xffff} ** 64} ** 30;
    for (0..mapping_count) |record| {
        const codepoint = readU32(
            blob,
            mapping_offset + record * mapping_record_len,
        );
        if (codepoint < 0x80 or codepoint >= 0x800) continue;
        const lead: usize = @intCast((0xc0 | (codepoint >> 6)) - 0xc2);
        const second: usize = @intCast(codepoint & 0x3f);
        map[lead][second] = @intCast(record);
    }
    // Default-ignorable scalars in the two-byte range get their own marker,
    // so the hot path needs no removal-table lookup.
    for (0..removal_count) |record| {
        const first = readU32(
            blob,
            removal_offset + record * removal_record_len,
        );
        const last = readU32(
            blob,
            removal_offset + record * removal_record_len + 4,
        );
        var codepoint: u32 = @max(first, 0x80);
        while (codepoint <= last and codepoint < 0x800) : (codepoint += 1) {
            const lead: usize = @intCast((0xc0 | (codepoint >> 6)) - 0xc2);
            const second: usize = @intCast(codepoint & 0x3f);
            // A mapping takes precedence, matching the lookup order.
            if (map[lead][second] == 0xffff) map[lead][second] = 0xfffe;
        }
    }
    return map;
}

const Table = struct {
    blob: []const u8,
    mapping_count: u32,
    removal_count: u32,
    pool_count: u32,
    mapping_offset: u32,
    removal_offset: u32,
    pool_offset: u32,
    mapping: MappingIndex,
    two_byte_map: [30][64]u16,
    removal_pages: [page_count + 1]u16,
    removal_covered: [page_count]bool,

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
            // Mapping targets are encoded without a validity check, so
            // reject malformed pool entries here.
            @setEvalBranchQuota(200_000);
            for (0..pool_count) |index| {
                const target = std.mem.readInt(
                    u32,
                    blob[pool_offset + index * 4 ..][0..4],
                    .little,
                );
                if (target > 0x10ffff or
                    (target >= 0xd800 and target <= 0xdfff))
                {
                    @compileError("invalid NFKC_Casefold mapping target");
                }
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
            .mapping = buildMappingIndex(
                blob,
                readU32(blob, 8),
                readU32(blob, 20),
            ),
            .two_byte_map = buildTwoByteMap(
                blob,
                readU32(blob, 8),
                readU32(blob, 20),
                readU32(blob, 12),
                readU32(blob, 24),
            ),
            .removal_pages = buildRemovalPages(
                blob,
                readU32(blob, 12),
                readU32(blob, 24),
            ),
            .removal_covered = buildRemovalCoverage(
                blob,
                readU32(blob, 12),
                readU32(blob, 24),
            ),
        };
    }

    fn lookup(self: *const Table, codepoint: u21) ?Match {
        const page: usize = @intCast(codepoint >> 8);
        const slot = self.mapping.slots[page];
        if (slot != 0xffff) {
            const record_index = self.mapping.direct[slot][
                @intCast(codepoint & 0xff)
            ];
            if (record_index != 0xffff) {
                const record = self.mapping_offset +
                    @as(usize, record_index) * mapping_record_len;
                return .{ .target = .{
                    .offset = readU32(self.blob, record + 4),
                    .length = readU16(self.blob, record + 8),
                } };
            }
        }
        if (!self.removal_covered[page]) return null;
        return if (self.removalMatches(codepoint, page)) .remove else null;
    }

    /// True when `codepoint` falls inside a default-ignorable removal range.
    fn removalMatches(self: *const Table, codepoint: u21, page: usize) bool {
        var low: usize = self.removal_pages[page];
        // The range that ends past this page may start inside it, so include
        // one record beyond the page boundary.
        var removal_end: usize = self.removal_pages[page + 1];
        if (removal_end < self.removal_count) removal_end += 1;
        var high = removal_end;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = self.removal_offset + middle * removal_record_len;
            if (readU32(self.blob, record + 4) < codepoint) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low >= removal_end) return false;
        const record = self.removal_offset + low * removal_record_len;
        return readU32(self.blob, record) <= codepoint and
            codepoint <= readU32(self.blob, record + 4);
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
    // Both mappings send ASCII A-Z to lowercase and leave the rest unchanged;
    // ASCII is already NFC, so the whole pipeline collapses to a byte loop.
    if (isAscii(text)) {
        const output = try allocator.alloc(u8, text.len);
        for (text, 0..) |byte, index| {
            output[index] = if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
        }
        return output;
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);
    // Bytes between `pending` and the current position pass through verbatim
    // and are copied in bulk, so scripts with no mappings cost one copy.
    var pending: usize = 0;
    var index: usize = 0;
    // When every emitted scalar is NFC-inert, the output cannot compose or
    // reorder across boundaries and the final NFC scan is unnecessary.
    var nfc_safe = true;
    while (index < text.len) {
        // ASCII maps to lowercase and never appears in either table, so a
        // run can be copied and lowered in one pass.
        if (text[index] < 0x80) {
            if (pending < index) {
                try output.appendSlice(allocator, text[pending..index]);
            }
            var end = index + 1;
            while (end < text.len and text[end] < 0x80) end += 1;
            const dest = try output.addManyAsSlice(allocator, end - index);
            for (text[index..end], dest) |byte, *slot| {
                slot.* = if (byte >= 'A' and byte <= 'Z')
                    byte + ('a' - 'A')
                else
                    byte;
            }
            index = end;
            pending = index;
            continue;
        }
        if (text[index] < 0xe0) {
            const lead = text[index];
            if (lead >= 0xc2 and index + 1 < text.len) {
                const second = text[index + 1];
                if ((second & 0xc0) == 0x80) {
                    const record_index = table.two_byte_map[lead - 0xc2][
                        @intCast(second & 0x3f)
                    ];
                    if (record_index == 0xfffe) {
                        if (pending < index) {
                            try output.appendSlice(
                                allocator,
                                text[pending..index],
                            );
                        }
                        index += 2;
                        pending = index;
                        continue;
                    }
                    if (record_index != 0xffff) {
                        if (pending < index) {
                            try output.appendSlice(
                                allocator,
                                text[pending..index],
                            );
                        }
                        index += 2;
                        const record = table.mapping_offset +
                            @as(usize, record_index) * mapping_record_len;
                        const target_offset = readU32(table.blob, record + 4);
                        const target_length = readU16(table.blob, record + 8);
                        for (0..target_length) |target_index| {
                            const target_codepoint = table.targetCodepoint(
                                target_offset,
                                target_index,
                            );
                            if (!inert.isInert(target_codepoint, .nfc)) {
                                nfc_safe = false;
                            }
                            if (output.unusedCapacitySlice().len < 4) {
                                try output.ensureUnusedCapacity(allocator, 4);
                            }
                            const dest = output.unusedCapacitySlice();
                            const written = scalar.encodeUtf8(
                                dest,
                                target_codepoint,
                            );
                            output.items.len += written;
                        }
                        pending = index;
                        continue;
                    }
                    if (!inert.twoByteInert(lead, second, .nfc)) {
                        nfc_safe = false;
                    }
                    index += 2;
                    continue;
                }
            }
        }
        // CJK ideographs occupy pages with no mapping or removal records and
        // cannot be overlong, so their three bytes validate with two checks.
        // Advance two ideographs per check on the common prose run.
        if (text[index] >= 0xe4 and text[index] <= 0xe9) {
            var cursor = index;
            while (cursor + 6 <= text.len and
                text[cursor] >= 0xe4 and text[cursor] <= 0xe9 and
                text[cursor + 3] >= 0xe4 and text[cursor + 3] <= 0xe9 and
                ((text[cursor + 1] | text[cursor + 2] |
                    text[cursor + 4] | text[cursor + 5]) & 0xc0) == 0x80)
            {
                cursor += 6;
            }
            if (cursor < text.len and text[cursor] >= 0xe4 and
                text[cursor] <= 0xe9)
            {
                if (cursor + 3 > text.len or
                    (text[cursor + 1] & 0xc0) != 0x80 or
                    (text[cursor + 2] & 0xc0) != 0x80)
                {
                    return error.InvalidUtf8;
                }
                cursor += 3;
            }
            index = cursor;
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar.packedCodepoint(decoded);
        const length = scalar.packedLength(decoded);
        // Scalars with no mapping stay in the verbatim run, so runs of
        // unmapped non-ASCII text (most prose) copy in bulk.
        const match = table.lookup(codepoint);
        if (match == null) {
            if (!inert.isInert(codepoint, .nfc)) nfc_safe = false;
            index += length;
            continue;
        }
        if (pending < index) {
            try output.appendSlice(allocator, text[pending..index]);
        }
        index += length;
        switch (match.?) {
            .remove => {},
            .target => |target| {
                for (0..target.length) |offset| {
                    const target_codepoint =
                        table.targetCodepoint(target.offset, offset);
                    if (!inert.isInert(target_codepoint, .nfc)) {
                        nfc_safe = false;
                    }
                    if (output.unusedCapacitySlice().len < 4) {
                        try output.ensureUnusedCapacity(allocator, 4);
                    }
                    const dest = output.unusedCapacitySlice();
                    const written = scalar.encodeUtf8(dest, target_codepoint);
                    output.items.len += written;
                }
            },
        }
        pending = index;
    }
    if (pending < text.len) {
        try output.appendSlice(allocator, text[pending..]);
    }

    // The per-scalar mappings can compose across boundaries, so the result
    // still needs an NFC pass. Most mapped prose is already NFC, and the
    // scan avoids the second buffer and rewrite in that case.
    if (nfc_safe or normalization.isNormalizedAssumeValid(output.items)) {
        return output.toOwnedSlice(allocator);
    }
    var normalized = std.ArrayList(u8).empty;
    defer normalized.deinit(allocator);
    _ = try normalization.normalizeFormInto(
        allocator,
        output.items,
        .nfc,
        &normalized,
    );
    return normalized.toOwnedSlice(allocator);
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

test "NFKC_Casefold normalizes mapped sequences" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        // A removed ignorable joins a starter and a mark, which composes.
        .{ .input = "A\u{00ad}\u{0301}", .expected = "\u{00e1}" },
        // A mapped sequence ending in a mark reorders and recomposes.
        .{
            .input = "\u{0130}\u{0323}",
            .expected = "\u{1ecb}\u{0307}",
        },
        // Inert targets keep the fast path.
        .{ .input = "\u{00c5}", .expected = "\u{00e5}" },
        .{ .input = "\u{ff21}\u{ff22}", .expected = "ab" },
        .{
            .input = "\u{041f}\u{0420}\u{0418}",
            .expected = "\u{043f}\u{0440}\u{0438}",
        },
        .{ .input = "\u{0391}\u{03a3}", .expected = "\u{03b1}\u{03c3}" },
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
