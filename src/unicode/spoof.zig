//! UTS #39 confusable detection.
//!
//! A skeleton is computed by NFD-normalizing the input, replacing every code
//! point with its prototype from the Unicode security data, and
//! NFD-normalizing the result. Two strings are confusable when their
//! skeletons match.

const std = @import("std");
const normalization = @import("normalization/root.zig");
const case = @import("case/root.zig");
const properties = @import("properties.zig");

const blob = @embedFile("spoof/confusables_data.bin");
const conformance = @embedFile("spoof/conformance.bin");

const header_len = 16;
const record_count = readU32(8);
const pool_length = readU32(12);
const records_offset = header_len;
const pool_offset = records_offset + @as(usize, record_count) * 12;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJXC") or
        blob[4] != 1)
    {
        @compileError("invalid confusables data");
    }
    if (pool_offset + @as(usize, pool_length) * 4 != blob.len) {
        @compileError("invalid confusables data lengths");
    }
}

pub const Error = error{ InvalidUtf8, OutOfMemory };

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

/// Longest prototype sequence in the pinned confusables data.
pub const max_mapping_length = 18;

/// Prototype sequence for a code point, or null when it maps to itself.
/// The values are read into `buffer` because the embedded blob has byte
/// alignment.
pub fn mappingInto(
    codepoint: u21,
    buffer: *[max_mapping_length]u32,
) ?[]const u32 {
    var low: usize = 0;
    var high: usize = record_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = records_offset + middle * 12;
        const source = readU32(base);
        if (source < codepoint) {
            low = middle + 1;
        } else if (source > codepoint) {
            high = middle;
        } else {
            const offset = readU32(base + 4);
            const length = blob[base + 8];
            std.debug.assert(length <= max_mapping_length);
            const start = pool_offset + @as(usize, offset) * 4;
            for (0..length) |index| {
                buffer[index] = readU32(start + index * 4);
            }
            return buffer[0..length];
        }
    }
    return null;
}

fn decodeUtf8(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u21),
) Error!void {
    try output.ensureTotalCapacity(allocator, text.len);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[cursor]) catch
            return error.InvalidUtf8;
        if (cursor + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(
            text[cursor..][0..length],
        ) catch return error.InvalidUtf8;
        try output.append(allocator, codepoint);
        cursor += length;
    }
}

/// Append the skeleton of UTF-8 `text` to `output` as code points.
pub fn skeletonCodepointsInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u21),
) Error!void {
    var decoded = std.ArrayList(u21).empty;
    defer decoded.deinit(allocator);
    try decodeUtf8(allocator, text, &decoded);

    const decomposed = try normalization.normalizeCodepointsAlloc(
        allocator,
        decoded.items,
        .nfd,
    );
    defer if (decomposed) |owned| allocator.free(owned);
    const source = decomposed orelse decoded.items;

    var mapped = std.ArrayList(u21).empty;
    defer mapped.deinit(allocator);
    try mapped.ensureTotalCapacity(allocator, source.len);
    var mapping_buffer: [max_mapping_length]u32 = undefined;
    for (source) |codepoint| {
        if (mappingInto(codepoint, &mapping_buffer)) |target| {
            for (target) |value| try mapped.append(allocator, @intCast(value));
        } else {
            try mapped.append(allocator, codepoint);
        }
    }

    const normalized = try normalization.normalizeCodepointsAlloc(
        allocator,
        mapped.items,
        .nfd,
    );
    defer if (normalized) |owned| allocator.free(owned);
    // Default-ignorable characters cannot affect a visual comparison.
    for (normalized orelse mapped.items) |codepoint| {
        if (properties.isDefaultIgnorableCodePoint(codepoint)) continue;
        try output.append(allocator, codepoint);
    }
}

/// Return the allocator-owned UTF-8 skeleton of `text`.
pub fn skeletonAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try skeletonCodepointsInto(allocator, text, &codepoints);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, codepoints.items.len * 4);
    var buffer: [4]u8 = undefined;
    for (codepoints.items) |codepoint| {
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch
            return error.InvalidUtf8;
        try output.appendSlice(allocator, buffer[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

/// Report whether two strings have the same skeleton. When `case_fold` is
/// set, both inputs are case-folded first, matching ICU's case-insensitive
/// confusable check.
pub fn areConfusable(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    case_fold: bool,
) Error!bool {
    var folded_a: ?[]u8 = null;
    defer if (folded_a) |owned| allocator.free(owned);
    var folded_b: ?[]u8 = null;
    defer if (folded_b) |owned| allocator.free(owned);
    var first = a;
    var second = b;
    if (case_fold) {
        folded_a = try case.foldAlloc(allocator, a);
        folded_b = try case.foldAlloc(allocator, b);
        first = folded_a.?;
        second = folded_b.?;
    }

    var skeleton_a = std.ArrayList(u21).empty;
    defer skeleton_a.deinit(allocator);
    var skeleton_b = std.ArrayList(u21).empty;
    defer skeleton_b.deinit(allocator);
    try skeletonCodepointsInto(allocator, first, &skeleton_a);
    try skeletonCodepointsInto(allocator, second, &skeleton_b);
    return std.mem.eql(u21, skeleton_a.items, skeleton_b.items);
}

test "confusable skeletons" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const latin = try skeletonAlloc(allocator, "paypal");
    defer allocator.free(latin);
    const cyrillic = try skeletonAlloc(allocator, "p\u{0430}ypal");
    defer allocator.free(cyrillic);
    try testing.expectEqualStrings(latin, cyrillic);

    try testing.expect(try areConfusable(
        allocator,
        "paypal",
        "p\u{0430}ypal",
        false,
    ));
    try testing.expect(!(try areConfusable(
        allocator,
        "hello",
        "world",
        false,
    )));
    try testing.expect(try areConfusable(
        allocator,
        "PayPal",
        "p\u{0430}ypal",
        true,
    ));

    const angstrom = try skeletonAlloc(allocator, "\u{212b}");
    defer allocator.free(angstrom);
    const composed = try skeletonAlloc(allocator, "\u{00c5}");
    defer allocator.free(composed);
    try testing.expectEqualStrings(angstrom, composed);

    try testing.expectError(
        error.InvalidUtf8,
        skeletonAlloc(allocator, "\xff"),
    );
}

test "UTS 39 skeleton conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    try testing.expect(conformance.len >= 12);
    try testing.expectEqualStrings("CJXS", conformance[0..4]);
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const input_len = std.mem.readInt(
            u16,
            conformance[cursor..][0..2],
            .little,
        );
        const skeleton_len = std.mem.readInt(
            u16,
            conformance[cursor + 2 ..][0..2],
            .little,
        );
        cursor += 4;
        const input = conformance[cursor..][0..input_len];
        cursor += input_len;
        const expected = conformance[cursor..][0..skeleton_len];
        cursor += skeleton_len;

        const actual = try skeletonAlloc(allocator, input);
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print("skeleton mismatch: {s} -> {s} (want {s})\n", .{
                    input,
                    actual,
                    expected,
                });
            }
        }
    }
    try testing.expectEqual(conformance.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
}
