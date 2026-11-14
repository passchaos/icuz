const std = @import("std");
const streaming = @import("cursor.zig").SentenceCursorIterator;
const continuous = @import("iterator.zig").assumeValid;
const support = @import("../tests/scalar_cursor_test_support.zig");

test "sentence scalar cursor Unicode 17 conformance and every fragmented seam" {
    try support.expectConformance(streaming, continuous, @embedFile("conformance.bin"), "CJST", 512);
}

test "sentence scalar cursor retains SB8 lower lookahead terminator state and paragraph resets" {
    const samples = [_][]const u8{
        "",
        "etc. there is more. Next.",
        "a.\u{200e})\u{0308}  -- lower. Next.",
        "A.B. C 1.2 ١.٢! Next",
        ".,,.,) , -- lower!\r\n\u{200e}Next.",
        ".,,.,) , -- Upper!\u{2029}\u{0308}lower.",
        "A.!? ) \u{200e}\u{0308}\n👩‍💻.",
        "\r\n\u{200e}\u{0308}a\n\u{200e}b",
    };
    for (samples) |text| try support.expectAllChunkings(streaming, continuous, text);
}

test "sentence scalar cursor source errors never become seam EOF" {
    try support.expectSourceErrors(streaming);
}

test "sentence scalar cursor repeated terminators and SB8 long lookahead read linearly without query allocations" {
    const allocator = std.testing.allocator;
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    // Each ATerm would scan the remainder again without the SB8 cache.
    for (0..32768) |_| try text.appendSlice(allocator, ".\u{200e},) - ");
    try text.appendSlice(allocator, "lower. Next.\r\n");
    for (0..32768) |_| try text.appendSlice(allocator, ".\u{2060},) - ");
    try text.appendSlice(allocator, "Upper. ");
    for (0..131072) |_| try text.appendSlice(allocator, "\u{200e}");
    try text.appendSlice(allocator, "lower. Next.");
    const chunks = try allocator.alloc([]const u8, (text.items.len + 28) / 29);
    defer allocator.free(chunks);
    for (chunks, 0..) |*chunk, index| chunk.* = text.items[index * 29 .. @min(text.items.len, (index + 1) * 29)];
    try support.expectEquivalent(streaming, continuous, text.items, chunks);
}
