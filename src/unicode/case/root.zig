//! Unicode 17 case mapping and case folding.
//!
//! Simple mappings are one scalar to one scalar. Full case folding may expand
//! one scalar to several scalars and is the form used for caseless matching.

const std = @import("std");
const data = @import("data.zig");
const scalar = @import("../scalar/root.zig");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{ InvalidUtf8, OutOfMemory };

pub const full = @import("full.zig");
pub const Locale = full.Locale;
pub const CaseOptions = full.Options;
pub const fullLowerAlloc = full.fullLowerAlloc;
pub const fullUpperAlloc = full.fullUpperAlloc;
pub const fullTitleAlloc = full.fullTitleAlloc;
pub const Edits = full.Edits;
pub const fullLowerWithEditsAlloc = full.fullLowerWithEditsAlloc;
pub const fullUpperWithEditsAlloc = full.fullUpperWithEditsAlloc;
pub const fullTitleWithEditsAlloc = full.fullTitleWithEditsAlloc;
pub const foldWithEditsAlloc = full.foldWithEditsAlloc;

/// Simple lowercase mapping. ASCII is handled arithmetically so prose case
/// conversion does not enter the generated record search.
const latin1_lower: [128]u21 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [128]u21 = undefined;
    for (&table, 0..) |*entry, index| {
        entry.* = data.simpleLower(@intCast(0x80 + index));
    }
    break :blk table;
};

const latin1_upper: [128]u21 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [128]u21 = undefined;
    for (&table, 0..) |*entry, index| {
        entry.* = data.simpleUpper(@intCast(0x80 + index));
    }
    break :blk table;
};

const latin1_title: [128]u21 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [128]u21 = undefined;
    for (&table, 0..) |*entry, index| {
        entry.* = data.simpleTitle(@intCast(0x80 + index));
    }
    break :blk table;
};

const latin1_fold: [128]u21 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [128]u21 = undefined;
    for (&table, 0..) |*entry, index| {
        entry.* = data.simpleFold(@intCast(0x80 + index));
    }
    break :blk table;
};

pub inline fn simpleLower(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'A' and codepoint <= 'Z')
            codepoint + ('a' - 'A')
        else
            codepoint;
    }
    if (codepoint < 0x100) return latin1_lower[codepoint - 0x80];
    return data.simpleLower(codepoint);
}

pub inline fn simpleUpper(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'a' and codepoint <= 'z')
            codepoint - ('a' - 'A')
        else
            codepoint;
    }
    if (codepoint < 0x100) return latin1_upper[codepoint - 0x80];
    return data.simpleUpper(codepoint);
}

pub inline fn simpleTitle(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'a' and codepoint <= 'z')
            codepoint - ('a' - 'A')
        else
            codepoint;
    }
    if (codepoint < 0x100) return latin1_title[codepoint - 0x80];
    return data.simpleTitle(codepoint);
}

/// Simple case folding for caseless matching.
pub inline fn simpleFold(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'A' and codepoint <= 'Z')
            codepoint + ('a' - 'A')
        else
            codepoint;
    }
    if (codepoint < 0x100) return latin1_fold[codepoint - 0x80];
    return data.simpleFold(codepoint);
}

const ascii_fold = [26]u21{
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
};

/// Full case folding. Returns null when the scalar folds to itself.
pub inline fn fullFold(codepoint: u21) ?[]const u21 {
    if (codepoint < 0x80) {
        if (codepoint >= 'A' and codepoint <= 'Z') {
            return ascii_fold[@as(usize, codepoint - 'A')..][0..1];
        }
        return null;
    }
    return data.fullFold(codepoint);
}

fn asciiPrefixLen(text: []const u8) usize {
    const high_bits: u64 = 0x8080_8080_8080_8080;
    var index: usize = 0;
    while (index + 8 <= text.len) : (index += 8) {
        const word = std.mem.readInt(u64, text[index..][0..8], .little);
        if (word & high_bits != 0) break;
    }
    while (index < text.len and text[index] < 0x80) : (index += 1) {}
    return index;
}

/// Lowercase UTF-8 text using simple one-to-one mappings.
pub fn lowerAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    return mapSimpleAlloc(allocator, text, .lower);
}

/// Uppercase UTF-8 text using simple one-to-one mappings.
pub fn upperAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    return mapSimpleAlloc(allocator, text, .upper);
}

/// Apply full case folding to UTF-8 text.
///
/// The returned string is owned by the caller. Invalid UTF-8 is rejected
/// before any allocation.
pub fn foldAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    if (asciiPrefixLen(text) == text.len) {
        const output = try allocator.alloc(u8, text.len);
        for (text, 0..) |byte, index| {
            output[index] = if (byte >= 'A' and byte <= 'Z')
                byte + ('a' - 'A')
            else
                byte;
        }
        return output;
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len + 8);

    var index: usize = 0;
    while (index < text.len) {
        const first = text[index];
        if (first < 0x80) {
            // Map ASCII runs straight into the spare capacity; folding only
            // changes A-Z and never changes the byte length.
            try output.ensureUnusedCapacity(allocator, 8);
            const spare = output.unusedCapacitySlice();
            var written: usize = 0;
            while (index < text.len and text[index] < 0x80 and
                written < spare.len)
            {
                const byte = text[index];
                spare[written] = if (byte >= 'A' and byte <= 'Z')
                    byte + ('a' - 'A')
                else
                    byte;
                written += 1;
                index += 1;
            }
            output.items.len += written;
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);
        if (fullFold(codepoint)) |components| {
            // Unicode 17 folds expand to at most three scalars.
            try output.ensureUnusedCapacity(allocator, 12);
            const dest = output.unusedCapacitySlice();
            var written: usize = 0;
            for (components) |component| {
                written += scalar.encodeUtf8(dest[written..], component);
            }
            output.items.len += written;
        } else {
            try output.ensureUnusedCapacity(allocator, 4);
            const dest = output.unusedCapacitySlice();
            output.items.len += scalar.encodeUtf8(dest, codepoint);
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn mapSimpleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime kind: enum { lower, upper },
) Error![]u8 {
    if (asciiPrefixLen(text) == text.len) {
        const output = try allocator.alloc(u8, text.len);
        for (text, 0..) |byte, index| {
            output[index] = switch (kind) {
                .lower => if (byte >= 'A' and byte <= 'Z')
                    byte + ('a' - 'A')
                else
                    byte,
                .upper => if (byte >= 'a' and byte <= 'z')
                    byte - ('a' - 'A')
                else
                    byte,
            };
        }
        return output;
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len + 8);

    var index: usize = 0;
    while (index < text.len) {
        const first = text[index];
        if (first < 0x80) {
            try output.ensureUnusedCapacity(allocator, 8);
            const spare = output.unusedCapacitySlice();
            var written: usize = 0;
            while (index < text.len and text[index] < 0x80 and
                written < spare.len)
            {
                const byte = text[index];
                spare[written] = switch (kind) {
                    .lower => if (byte >= 'A' and byte <= 'Z')
                        byte + ('a' - 'A')
                    else
                        byte,
                    .upper => if (byte >= 'a' and byte <= 'z')
                        byte - ('a' - 'A')
                    else
                        byte,
                };
                written += 1;
                index += 1;
            }
            output.items.len += written;
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);
        const mapped = switch (kind) {
            .lower => simpleLower(codepoint),
            .upper => simpleUpper(codepoint),
        };
        try output.ensureUnusedCapacity(allocator, 4);
        const dest = output.unusedCapacitySlice();
        output.items.len += scalar.encodeUtf8(dest, mapped);
    }
    return try output.toOwnedSlice(allocator);
}

test "case folding expands sharp s and dotted capital I" {
    const allocator = std.testing.allocator;
    const folded = try foldAlloc(allocator, "Stra\u{00df}e");
    defer allocator.free(folded);
    try std.testing.expectEqualStrings("strasse", folded);

    const dotted = try foldAlloc(allocator, "\u{0130}");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("i\u{0307}", dotted);
}

test "simple lower and upper mapping" {
    const allocator = std.testing.allocator;
    const lower = try lowerAlloc(allocator, "HELLO \u{00c5}");
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("hello \u{00e5}", lower);

    const upper = try upperAlloc(allocator, "hello \u{00e5}");
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("HELLO \u{00c5}", upper);
}

test "case folding rejects invalid UTF-8" {
    try std.testing.expectError(error.InvalidUtf8, foldAlloc(std.testing.allocator, "\xff"));
}

test "pure ASCII text uses the direct byte path" {
    const allocator = std.testing.allocator;
    const lower = try lowerAlloc(allocator, "HELLO 123!");
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("hello 123!", lower);

    const upper = try upperAlloc(allocator, "hello 123!");
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("HELLO 123!", upper);

    const folded = try foldAlloc(allocator, "ABC xyz");
    defer allocator.free(folded);
    try std.testing.expectEqualStrings("abc xyz", folded);
}

test {
    _ = full;
}
