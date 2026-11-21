//! Shared Unicode scalar-value validation and validated UTF-8 decoding.

const std = @import("std");

pub const Decoded = struct {
    codepoint: u21,
    next: usize,
};

/// Decode one scalar from UTF-8 already proven valid at the source boundary.
///
/// The continuation bytes are masked rather than revalidated. Callers either
/// validated the complete slice (the public iterator entry points) or hold the
/// explicit assume-valid contract; invalid input was already unreachable in
/// those iterators.
pub inline fn decodeValid(text: []const u8, offset: usize) ?Decoded {
    if (offset >= text.len) return null;
    const first = text[offset];
    if (first < 0x80) return .{ .codepoint = first, .next = offset + 1 };
    if (first < 0xc2) return null;
    if (first < 0xe0) {
        if (offset + 2 > text.len) return null;
        return .{
            .codepoint = (@as(u21, first & 0x1f) << 6) |
                @as(u21, text[offset + 1] & 0x3f),
            .next = offset + 2,
        };
    }
    if (first < 0xf0) {
        if (offset + 3 > text.len) return null;
        return .{
            .codepoint = (@as(u21, first & 0x0f) << 12) |
                (@as(u21, text[offset + 1] & 0x3f) << 6) |
                @as(u21, text[offset + 2] & 0x3f),
            .next = offset + 3,
        };
    }
    if (first < 0xf5) {
        if (offset + 4 > text.len) return null;
        return .{
            .codepoint = (@as(u21, first & 0x07) << 18) |
                (@as(u21, text[offset + 1] & 0x3f) << 12) |
                (@as(u21, text[offset + 2] & 0x3f) << 6) |
                @as(u21, text[offset + 3] & 0x3f),
            .next = offset + 4,
        };
    }
    return null;
}

/// Decode one UTF-8 scalar, rejecting truncation, overlong forms,
/// surrogates, and values above U+10FFFF. This is the validating counterpart
/// to `decodeValid` for hot scans that have not pre-validated the input.
pub inline fn decodeValidating(text: []const u8, offset: usize) ?Decoded {
    if (offset >= text.len) return null;
    const first = text[offset];
    if (first < 0x80) return .{ .codepoint = first, .next = offset + 1 };
    if (first < 0xc2) return null;
    if (first < 0xe0) {
        if (offset + 2 > text.len) return null;
        const second = text[offset + 1];
        if (second & 0xc0 != 0x80) return null;
        return .{
            .codepoint = (@as(u21, first & 0x1f) << 6) |
                @as(u21, second & 0x3f),
            .next = offset + 2,
        };
    }
    if (first < 0xf0) {
        if (offset + 3 > text.len) return null;
        const second = text[offset + 1];
        const third = text[offset + 2];
        if (second & 0xc0 != 0x80 or third & 0xc0 != 0x80) return null;
        const codepoint = (@as(u21, first & 0x0f) << 12) |
            (@as(u21, second & 0x3f) << 6) |
            @as(u21, third & 0x3f);
        if (codepoint < 0x800) return null;
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) return null;
        return .{ .codepoint = codepoint, .next = offset + 3 };
    }
    if (first < 0xf5) {
        if (offset + 4 > text.len) return null;
        const second = text[offset + 1];
        const third = text[offset + 2];
        const fourth = text[offset + 3];
        if (second & 0xc0 != 0x80 or third & 0xc0 != 0x80 or
            fourth & 0xc0 != 0x80) return null;
        const codepoint = (@as(u21, first & 0x07) << 18) |
            (@as(u21, second & 0x3f) << 12) |
            (@as(u21, third & 0x3f) << 6) |
            @as(u21, fourth & 0x3f);
        if (codepoint < 0x10000 or codepoint > 0x10ffff) return null;
        return .{ .codepoint = codepoint, .next = offset + 4 };
    }
    return null;
}

/// Packed decoding: `(codepoint + 1) << 3 | (length - 1)`, or zero for an
/// invalid sequence. Returning one `u32` keeps the decoded scalar and its
/// length in a single register, while an `?Decoded` optional makes the
/// compiler spill a 16-byte temporary to the stack in hot loops.
pub const packed_invalid: u32 = 0;

/// Recover the scalar from a value returned by a packed decoder.
/// `value` must not be `packed_invalid`.
pub inline fn packedCodepoint(value: u32) u21 {
    return @intCast((value >> 3) - 1);
}

/// Recover the UTF-8 sequence length from a packed decoder result.
/// `value` must not be `packed_invalid`.
pub inline fn packedLength(value: u32) usize {
    return (value & 7) + 1;
}

/// Packed counterpart of `decodeValid` for input already proven valid.
pub inline fn decodeValidPacked(text: []const u8, offset: usize) u32 {
    if (offset >= text.len) return packed_invalid;
    const first = text[offset];
    if (first < 0x80) return (@as(u32, first) + 1) << 3;
    if (first < 0xc2) return packed_invalid;
    if (first < 0xe0) {
        if (offset + 2 > text.len) return packed_invalid;
        const codepoint = (@as(u32, first & 0x1f) << 6) |
            @as(u32, text[offset + 1] & 0x3f);
        return ((codepoint + 1) << 3) | 1;
    }
    if (first < 0xf0) {
        if (offset + 3 > text.len) return packed_invalid;
        const codepoint = (@as(u32, first & 0x0f) << 12) |
            (@as(u32, text[offset + 1] & 0x3f) << 6) |
            @as(u32, text[offset + 2] & 0x3f);
        return ((codepoint + 1) << 3) | 2;
    }
    if (first < 0xf5) {
        if (offset + 4 > text.len) return packed_invalid;
        const codepoint = (@as(u32, first & 0x07) << 18) |
            (@as(u32, text[offset + 1] & 0x3f) << 12) |
            (@as(u32, text[offset + 2] & 0x3f) << 6) |
            @as(u32, text[offset + 3] & 0x3f);
        return ((codepoint + 1) << 3) | 3;
    }
    return packed_invalid;
}

/// Packed counterpart of `decodeValidating`.
pub inline fn decodeValidatingPacked(text: []const u8, offset: usize) u32 {
    if (offset >= text.len) return packed_invalid;
    const first = text[offset];
    if (first < 0x80) return (@as(u32, first) + 1) << 3;
    if (first < 0xc2) return packed_invalid;
    if (first < 0xe0) {
        if (offset + 2 > text.len) return packed_invalid;
        const second = text[offset + 1];
        if (second & 0xc0 != 0x80) return packed_invalid;
        const codepoint = (@as(u32, first & 0x1f) << 6) |
            @as(u32, second & 0x3f);
        return ((codepoint + 1) << 3) | 1;
    }
    if (first < 0xf0) {
        if (offset + 3 > text.len) return packed_invalid;
        const second = text[offset + 1];
        const third = text[offset + 2];
        if (second & 0xc0 != 0x80 or third & 0xc0 != 0x80) {
            return packed_invalid;
        }
        const codepoint = (@as(u32, first & 0x0f) << 12) |
            (@as(u32, second & 0x3f) << 6) |
            @as(u32, third & 0x3f);
        if (codepoint < 0x800) return packed_invalid;
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) {
            return packed_invalid;
        }
        return ((codepoint + 1) << 3) | 2;
    }
    if (first < 0xf5) {
        if (offset + 4 > text.len) return packed_invalid;
        const second = text[offset + 1];
        const third = text[offset + 2];
        const fourth = text[offset + 3];
        if (second & 0xc0 != 0x80 or third & 0xc0 != 0x80 or
            fourth & 0xc0 != 0x80) return packed_invalid;
        const codepoint = (@as(u32, first & 0x07) << 18) |
            (@as(u32, second & 0x3f) << 12) |
            (@as(u32, third & 0x3f) << 6) |
            @as(u32, fourth & 0x3f);
        if (codepoint < 0x10000 or codepoint > 0x10ffff) {
            return packed_invalid;
        }
        return ((codepoint + 1) << 3) | 3;
    }
    return packed_invalid;
}

/// Zig's `u21` can represent values above Unicode's U+10FFFF limit, and it
/// also includes the surrogate range. Property lookup tables must use this
/// predicate before indexing generated scalar pages.
pub inline fn isValid(value: u21) bool {
    return value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff);
}

/// Check a prevalidated UTF-8 contract only in safe builds.
///
/// `std.debug.assert` is not enough here: even in ReleaseFast its condition
/// still feeds an `unreachable` branch, so the whole validator call stays
/// alive. The `*AssumeValid` entry points must not pay a second validation
/// pass in release builds.
pub inline fn assertValidUtf8(text: []const u8) void {
    if (std.debug.runtime_safety) {
        std.debug.assert(std.unicode.utf8ValidateSlice(text));
    }
}

/// Encode one valid scalar into `dest`, which must have at least four bytes.
/// Inlines the length branches that `std.unicode.utf8Encode` keeps out of
/// line in hot mapping loops.
pub inline fn encodeUtf8(dest: []u8, codepoint: u21) usize {
    if (codepoint < 0x80) {
        dest[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint < 0x800) {
        dest[0] = @intCast(0xC0 | (codepoint >> 6));
        dest[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    }
    if (codepoint < 0x10000) {
        dest[0] = @intCast(0xE0 | (codepoint >> 12));
        dest[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        dest[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    }
    dest[0] = @intCast(0xF0 | (codepoint >> 18));
    dest[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    dest[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    dest[3] = @intCast(0x80 | (codepoint & 0x3F));
    return 4;
}

test "validated scalar decoding matches std for representative sequences" {
    const samples = [_][]const u8{
        "A",
        "\u{00e9}",
        "\u{0628}",
        "\u{0939}",
        "\u{20ac}",
        "\u{1f600}",
    };
    for (samples) |text| {
        const decoded = decodeValid(text, 0).?;
        try std.testing.expectEqual(
            try std.unicode.utf8Decode(text),
            decoded.codepoint,
        );
        try std.testing.expectEqual(text.len, decoded.next);
    }
    try std.testing.expect(decodeValid("", 0) == null);
    try std.testing.expect(decodeValid("\xe0\xa4", 0) == null);
}

test "Unicode scalar validation covers both invalid regions" {
    try std.testing.expect(isValid(0));
    try std.testing.expect(isValid(0x10ffff));
    try std.testing.expect(!isValid(0xd800));
    try std.testing.expect(!isValid(0xdfff));
    try std.testing.expect(!isValid(0x110000));
    try std.testing.expect(!isValid(0x1fffff));
}

test "validating scalar decoding rejects invalid UTF-8" {
    const testing = @import("std").testing;
    const invalid = [_][]const u8{
        "\x80",
        "\xc0\x80",
        "\xc1\xbf",
        "\xe0\x80\x80",
        "\xed\xa0\x80",
        "\xf0\x80\x80\x80",
        "\xf4\x90\x80\x80",
        "\xf5\x80\x80\x80",
        "\xe2\x28\xa1",
        "\xe2\x82",
    };
    for (invalid) |sample| {
        try testing.expect(decodeValidating(sample, 0) == null);
    }
    try testing.expectEqual(@as(u21, 0x1f600), decodeValidating("\u{1f600}", 0).?.codepoint);
    try testing.expectEqual(@as(u21, 'A'), decodeValidating("A", 0).?.codepoint);
    try testing.expectEqual(@as(usize, 4), decodeValidating("\u{1f600}", 0).?.next);
    try testing.expect(decodeValidating("", 0) == null);
}

test "packed decoding matches the struct decoders" {
    const testing = std.testing;
    const samples = [_][]const u8{
        "A",
        "\u{00e9}",
        "\u{0628}",
        "\u{0939}",
        "\u{20ac}",
        "\u{1f600}",
        "\u{10ffff}",
    };
    for (samples) |text| {
        const valid = decodeValidPacked(text, 0);
        const validating = decodeValidatingPacked(text, 0);
        try testing.expectEqual(valid, validating);
        try testing.expectEqual(@as(u21, try std.unicode.utf8Decode(text)), packedCodepoint(valid));
        try testing.expectEqual(text.len, packedLength(valid));
        try testing.expectEqual(@as(u21, 0), packedCodepoint(decodeValidPacked("\x00", 0)));
    }
    try testing.expectEqual(packed_invalid, decodeValidPacked("", 0));
    try testing.expectEqual(packed_invalid, decodeValidPacked("\xe0\xa4", 0));
    const invalid = [_][]const u8{
        "\x80",
        "\xc0\x80",
        "\xc1\xbf",
        "\xe0\x80\x80",
        "\xed\xa0\x80",
        "\xf0\x80\x80\x80",
        "\xf4\x90\x80\x80",
        "\xf5\x80\x80\x80",
        "\xe2\x28\xa1",
        "\xe2\x82",
    };
    for (invalid) |sample| {
        try testing.expectEqual(
            packed_invalid,
            decodeValidatingPacked(sample, 0),
        );
    }
}
