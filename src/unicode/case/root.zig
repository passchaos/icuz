//! Unicode 17 case mapping and case folding.
//!
//! Simple mappings are one scalar to one scalar. Full case folding may expand
//! one scalar to several scalars and is the form used for caseless matching.

const std = @import("std");
const data = @import("data.zig");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{ InvalidUtf8, OutOfMemory };

pub const simpleLower = data.simpleLower;
pub const simpleUpper = data.simpleUpper;
pub const simpleTitle = data.simpleTitle;

/// Simple case folding for caseless matching.
pub const simpleFold = data.simpleFold;

/// Full case folding. Returns null when the scalar folds to itself.
pub const fullFold = data.fullFold;

/// Lowercase UTF-8 text using simple one-to-one mappings.
pub fn lowerAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    return mapSimpleAlloc(allocator, text, simpleLower);
}

/// Uppercase UTF-8 text using simple one-to-one mappings.
pub fn upperAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    return mapSimpleAlloc(allocator, text, simpleUpper);
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

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);

    var encoded: [4]u8 = undefined;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (data.fullFold(codepoint)) |components| {
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
    comptime map: fn (u21) u21,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);

    var encoded: [4]u8 = undefined;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const len = std.unicode.utf8Encode(map(codepoint), &encoded) catch
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
