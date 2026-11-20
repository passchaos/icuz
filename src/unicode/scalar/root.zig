//! Shared Unicode scalar-value validation and validated UTF-8 decoding.

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

/// Zig's `u21` can represent values above Unicode's U+10FFFF limit, and it
/// also includes the surrogate range. Property lookup tables must use this
/// predicate before indexing generated scalar pages.
pub inline fn isValid(value: u21) bool {
    return value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff);
}

test "validated scalar decoding matches std for representative sequences" {
    const std = @import("std");
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
    const std = @import("std");
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
