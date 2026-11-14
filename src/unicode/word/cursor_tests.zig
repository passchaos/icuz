const std = @import("std");
const streaming = @import("cursor.zig").WordCursorIterator;
const continuous = @import("iterator.zig").assumeValid;
const support = @import("../tests/scalar_cursor_test_support.zig");

test "word scalar cursor Unicode 17 conformance and every fragmented seam" {
    try support.expectConformance(streaming, continuous, @embedFile("conformance.bin"), "CJWT", 1944);
}

test "word scalar cursor keeps actual ZWJ history numeric Hebrew and RI parity" {
    const samples = [_][]const u8{
        "",
        "can't 3.14 一丁 ក",
        "a\u{200e}:\u{0308}b 12\u{2060},\u{200e}34",
        "א\u{200e}' ב\u{0308}\"\u{2060}ג",
        "🇦\u{200e}🇧🇨🇩🇪🇫🇬",
        "\u{200d}👩 \u{200d}\u{0308}👩 👩‍💻",
        "\r\n\u{200e}\u{0308}a\n\u{200e}b  \u{0308}  c",
        "foo_bar _123_ a:b a::b 1,2 1,,2",
    };
    for (samples) |text| try support.expectAllChunkings(streaming, continuous, text);
}

test "word scalar cursor source errors never become seam EOF" {
    try support.expectSourceErrors(streaming);
}

test "word scalar cursor long ignored runs and midpoint lookahead read linearly without query allocations" {
    const allocator = std.testing.allocator;
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    const repeated = [_][]const u8{
        "a\u{200e}:\u{2060}b ",
        "1\u{200e},\u{2060}2 ",
        "א\u{200e}\"\u{2060}ב ",
        "🇦\u{200e}🇧🇨🇩 ",
        "\u{200d}👩 \u{200d}\u{0308}👩 ",
    };
    for (0..2048) |_| for (repeated) |sample| try text.appendSlice(allocator, sample);
    // Long uninterrupted RI history crosses tens of thousands of returned
    // pairs; ignored scalars preserve parity, while following ZWJ/Extend runs
    // still distinguish WB3c adjacency from WB4 replacement.
    for (0..32768) |_| try text.appendSlice(allocator, "🇦\u{200e}🇧");
    try text.appendSlice(allocator, " ");
    for (0..16384) |_| try text.appendSlice(allocator, "\u{200d}\u{0308}");
    try text.appendSlice(allocator, "👩 ");
    try text.appendSlice(allocator, "a");
    for (0..131072) |_| try text.appendSlice(allocator, "\u{200e}");
    try text.appendSlice(allocator, ":");
    for (0..131072) |_| try text.appendSlice(allocator, "\u{2060}");
    try text.appendSlice(allocator, "b 1");
    for (0..65536) |_| try text.appendSlice(allocator, "\u{200e}");
    try text.appendSlice(allocator, ",");
    for (0..65536) |_| try text.appendSlice(allocator, "\u{2060}");
    try text.appendSlice(allocator, "2 א");
    for (0..65536) |_| try text.appendSlice(allocator, "\u{200e}");
    try text.appendSlice(allocator, "\"");
    for (0..65536) |_| try text.appendSlice(allocator, "\u{2060}");
    try text.appendSlice(allocator, "ב");
    const chunks = try allocator.alloc([]const u8, (text.items.len + 30) / 31);
    defer allocator.free(chunks);
    for (chunks, 0..) |*chunk, index| chunk.* = text.items[index * 31 .. @min(text.items.len, (index + 1) * 31)];
    // All memory belongs to fixture construction; the query has no allocator.
    try support.expectEquivalent(streaming, continuous, text.items, chunks);
}
