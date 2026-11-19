//! Locale-aware string search.
//!
//! A match is a contiguous substring whose collation sort key equals the
//! pattern's key at the configured strength, so searching is accent- and
//! case-insensitive at the primary level. Candidate substrings are extended
//! until any level holds more weights than the pattern (or holds the same
//! count with different weights), which no extension can undo, so no match
//! is missed.

const std = @import("std");
const collation = @import("collation/root.zig");
const combining_class = @import("canonical/combining_class.zig");

pub const Options = collation.Options;
pub const Error = error{ InvalidUtf8, OutOfMemory };

const max_levels = 8;

/// Reusable searcher for one pattern and collation configuration.
pub const Search = struct {
    allocator: std.mem.Allocator,
    collator: collation.Collator,
    needle_key: std.ArrayList(u32),
    needle_primary: std.ArrayList(u32),
    needle_counts: [max_levels]usize,
    candidate_key: std.ArrayList(u32),
    text_codepoints: std.ArrayList(u21),
    text_offsets: std.ArrayList(usize),
    needle_empty: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        needle: []const u8,
        options: Options,
    ) Error!Search {
        var search = Search{
            .allocator = allocator,
            .collator = collation.Collator.init(options),
            .needle_key = .empty,
            .needle_primary = .empty,
            .needle_counts = @splat(0),
            .candidate_key = .empty,
            .text_codepoints = .empty,
            .text_offsets = .empty,
            .needle_empty = needle.len == 0,
        };
        errdefer search.deinit();
        if (!search.needle_empty) {
            try search.collator.sortKeyInto(
                allocator,
                needle,
                &search.needle_key,
            );
            search.needle_counts = countLevels(search.needle_key.items);
            const primary_length = primaryLength(search.needle_key.items);
            try search.needle_primary.appendSlice(
                allocator,
                search.needle_key.items[0..primary_length],
            );
        }
        return search;
    }

    pub fn deinit(self: *Search) void {
        self.needle_key.deinit(self.allocator);
        self.needle_primary.deinit(self.allocator);
        self.candidate_key.deinit(self.allocator);
        self.text_codepoints.deinit(self.allocator);
        self.text_offsets.deinit(self.allocator);
    }

    /// Find the first match at or after the byte offset `start`.
    pub fn find(self: *Search, text: []const u8, start: usize) Error!?usize {
        if (self.needle_empty) return if (start <= text.len) start else null;
        try self.decodeText(text);

        const codepoints = self.text_codepoints.items;
        const offsets = self.text_offsets.items;
        var index: usize = 0;
        while (index < offsets.len and offsets[index] < start) index += 1;

        while (index < codepoints.len) {
            // Matches start at character boundaries, not inside a combining
            // sequence.
            if (index != 0 and
                combining_class.forCodepoint(codepoints[index]) != 0)
            {
                index += 1;
                continue;
            }
            var end = index + 1;
            try self.collator.sortKeyCodepointsInto(
                self.allocator,
                codepoints[index..end],
                &self.candidate_key,
            );
            // When no contraction can start here, the first character's
            // primary weights must prefix the pattern's primary weights.
            if (!self.collator.startsContraction(codepoints[index])) {
                const length = primaryLength(self.candidate_key.items);
                if (length > self.needle_primary.items.len or
                    !std.mem.eql(
                        u32,
                        self.candidate_key.items[0..length],
                        self.needle_primary.items[0..length],
                    ))
                {
                    index += 1;
                    continue;
                }
            }
            while (true) {
                if (std.mem.eql(
                    u32,
                    self.candidate_key.items,
                    self.needle_key.items,
                )) {
                    return offsets[index];
                }
                const counts = countLevels(self.candidate_key.items);
                if (exceeds(counts, self.needle_counts)) break;
                if (std.meta.eql(counts, self.needle_counts)) {
                    // Same weight counts but a different key: any further
                    // code point either adds a weight or changes nothing.
                    break;
                }
                if (end == codepoints.len) break;
                end += 1;
                try self.collator.sortKeyCodepointsInto(
                    self.allocator,
                    codepoints[index..end],
                    &self.candidate_key,
                );
            }
            index += 1;
        }
        return null;
    }

    fn decodeText(self: *Search, text: []const u8) Error!void {
        self.text_codepoints.clearRetainingCapacity();
        self.text_offsets.clearRetainingCapacity();
        try self.text_codepoints.ensureTotalCapacity(
            self.allocator,
            text.len,
        );
        try self.text_offsets.ensureTotalCapacity(self.allocator, text.len);
        var cursor: usize = 0;
        while (cursor < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[cursor]) catch
                return error.InvalidUtf8;
            if (cursor + length > text.len) return error.InvalidUtf8;
            const codepoint = std.unicode.utf8Decode(
                text[cursor..][0..length],
            ) catch return error.InvalidUtf8;
            try self.text_codepoints.append(self.allocator, codepoint);
            try self.text_offsets.append(self.allocator, cursor);
            cursor += length;
        }
    }
};

/// Find the first match of `needle` in `text`.
pub fn indexOf(
    allocator: std.mem.Allocator,
    text: []const u8,
    needle: []const u8,
    options: Options,
) Error!?usize {
    var search = try Search.init(allocator, needle, options);
    defer search.deinit();
    return search.find(text, 0);
}

fn primaryLength(key: []const u32) usize {
    for (key, 0..) |weight, index| {
        if (weight == 0) return index;
    }
    return key.len;
}

fn countLevels(key: []const u32) [max_levels]usize {
    var counts: [max_levels]usize = @splat(0);
    var level: usize = 0;
    for (key) |weight| {
        if (weight == 0) {
            level += 1;
            if (level == max_levels) break;
            continue;
        }
        counts[level] += 1;
    }
    return counts;
}

fn exceeds(
    counts: [max_levels]usize,
    limits: [max_levels]usize,
) bool {
    for (counts, limits) |count, limit| {
        if (count > limit) return true;
    }
    return false;
}

test "locale-aware search" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const ascii = "The quick brown fox jumps over the lazy dog.";
    const primary = Options{ .strength = .primary };
    try testing.expectEqual(
        @as(?usize, 16),
        try indexOf(allocator, ascii, "FOX", primary),
    );
    try testing.expectEqual(
        @as(?usize, 4),
        try indexOf(allocator, ascii, "quick", primary),
    );
    try testing.expectEqual(
        @as(?usize, null),
        try indexOf(allocator, ascii, "zebra", primary),
    );

    // Root collation treats ring-accented letters as their base at the
    // primary level; the Swedish tailoring makes them distinct letters.
    const swedish = "En \u{00c5}ngstr\u{00f6}m \u{00e4}lskar bl\u{00e5}b\u{00e4}r";
    try testing.expectEqual(
        @as(?usize, 3),
        try indexOf(allocator, swedish, "angstrom", primary),
    );
    try testing.expectEqual(
        @as(?usize, null),
        try indexOf(
            allocator,
            swedish,
            "angstrom",
            .{ .strength = .primary, .locale = "sv" },
        ),
    );
    try testing.expectEqual(
        @as(?usize, 3),
        try indexOf(
            allocator,
            swedish,
            "\u{00c5}ngstr\u{00f6}m",
            .{ .strength = .primary, .locale = "sv" },
        ),
    );
    try testing.expectEqual(
        @as(?usize, 3),
        try indexOf(
            allocator,
            swedish,
            "\u{00e5}ngstr\u{00f6}m",
            .{ .strength = .secondary, .locale = "sv" },
        ),
    );

    const german = "Die Stra\u{00df}e";
    try testing.expectEqual(
        @as(?usize, 4),
        try indexOf(allocator, german, "strasse", primary),
    );

    // Accents differ at the secondary level.
    const cafe = "caf\u{00e9} au lait";
    try testing.expectEqual(
        @as(?usize, 0),
        try indexOf(allocator, cafe, "cafe", primary),
    );
    try testing.expectEqual(
        @as(?usize, null),
        try indexOf(allocator, cafe, "cafe", .{ .strength = .secondary }),
    );

    // Matches do not start inside a combining sequence.
    const marked = "a\u{0301}b";
    try testing.expectEqual(
        @as(?usize, 3),
        try indexOf(allocator, marked, "b", primary),
    );

    try testing.expectEqual(
        @as(?usize, 0),
        try indexOf(allocator, ascii, "", primary),
    );
    try testing.expectError(
        error.InvalidUtf8,
        indexOf(allocator, "\xff", "a", primary),
    );
}
