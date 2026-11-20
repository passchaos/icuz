//! Unicode 17 case mapping and case folding.
//!
//! Simple mappings are one scalar to one scalar. Full case folding may expand
//! one scalar to several scalars and is the form used for caseless matching.

const std = @import("std");
const data = @import("data.zig");

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
pub inline fn simpleLower(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'A' and codepoint <= 'Z')
            codepoint + ('a' - 'A')
        else
            codepoint;
    }
    return data.simpleLower(codepoint);
}

pub inline fn simpleUpper(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'a' and codepoint <= 'z')
            codepoint - ('a' - 'A')
        else
            codepoint;
    }
    return data.simpleUpper(codepoint);
}

pub inline fn simpleTitle(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'a' and codepoint <= 'z')
            codepoint - ('a' - 'A')
        else
            codepoint;
    }
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
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
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
    try output.ensureTotalCapacity(allocator, text.len);

    var encoded: [4]u8 = undefined;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (fullFold(codepoint)) |components| {
            for (components) |component| {
                const len = std.unicode.utf8Encode(component, &encoded) catch
                    unreachable;
                try output.appendSlice(allocator, encoded[0..len]);
            }
        } else {
            const len = std.unicode.utf8Encode(codepoint, &encoded) catch
                unreachable;
            try output.appendSlice(allocator, encoded[0..len]);
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn mapSimpleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime kind: enum { lower, upper },
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
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
    try output.ensureTotalCapacity(allocator, text.len);

    var encoded: [4]u8 = undefined;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const mapped = switch (kind) {
            .lower => simpleLower(codepoint),
            .upper => simpleUpper(codepoint),
        };
        const len = std.unicode.utf8Encode(mapped, &encoded) catch
            unreachable;
        try output.appendSlice(allocator, encoded[0..len]);
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
