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
const tailorings = @import("collation/tailorings.zig");
const combining_class = @import("canonical/combining_class.zig");
const decomposition = @import("canonical/decomposition.zig");
const scalar = @import("scalar/root.zig");

pub const Options = collation.Options;
pub const Error = error{ InvalidUtf8, OutOfMemory };

const max_levels = 8;
/// Look-ahead allowed for a contraction to finish merging weights.
const max_contraction_span = 32;

/// Reusable searcher for one pattern and collation configuration.
const LatinPrimary = struct {
    count: u8 = 0,
    values: [4]u32 = .{ 0, 0, 0, 0 },
};

const LatinPrimaryCacheEntry = struct {
    codepoint: u21 = 0x110000,
    primary: LatinPrimary = .{},
};

const Decoded = struct { codepoint: u21, next: usize };

pub const Search = struct {
    allocator: std.mem.Allocator,
    collator: collation.Collator,
    needle_key: std.ArrayList(u32),
    needle_primary: std.ArrayList(u32),
    needle_counts: [max_levels]usize,
    candidate_key: std.ArrayList(u32),
    text_codepoints: std.ArrayList(u21),
    text_offsets: std.ArrayList(usize),
    /// Direct-mapped cache of the first primary weight per code point.
    primary_cache: [64]u64,
    needle_empty: bool,
    fast_ascii_primary: bool,
    latin_fast: bool,
    latin_primary_cache: [128]LatinPrimaryCacheEntry =
        [_]LatinPrimaryCacheEntry{.{}} ** 128,
    /// Root primary weights per ASCII scalar, materialized once at init so
    /// the ASCII search loop is a table read instead of an element walk.
    ascii_primaries: [128]collation.Collator.AsciiPrimary =
        [_]collation.Collator.AsciiPrimary{.{}} ** 128,

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
            .primary_cache = @splat(0),
            .needle_empty = needle.len == 0,
            .fast_ascii_primary = false,
            .latin_fast = false,
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
            search.fast_ascii_primary = search.needle_primary.items.len > 0 and
                isAscii(needle) and
                options.strength == .primary and
                options.variable_weighting == .non_ignorable and
                !options.numeric and
                !options.case_level and
                options.case_first == null and
                options.backwards_secondary == null and
                search.collator.asciiFastPathUsable();
            search.latin_fast = search.needle_primary.items.len > 0 and
                options.strength == .primary and
                options.variable_weighting == .non_ignorable and
                !options.numeric and
                !options.case_level and
                options.case_first == null and
                options.backwards_secondary == null and
                search.latinFastNeedle(needle) and
                search.latinFastTailoring();
            if (search.fast_ascii_primary) {
                for (&search.ascii_primaries, 0..) |*entry, value| {
                    entry.* = search.collator.asciiPrimaryWeights(
                        @intCast(value),
                    );
                }
            }
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
        if (self.fast_ascii_primary and isAscii(text)) {
            return self.findAsciiPrimary(text, start);
        }
        if (self.latin_fast) {
            var fallback = false;
            const result = self.findLatinPrimary(text, start, &fallback);
            if (!fallback) return result;
        }
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
            const can_extend = self.collator.contractionExtends(
                codepoints,
                index,
            );
            // A context-free ASCII start can be rejected from its first
            // primary weight without building a key.
            if (!can_extend and self.needle_primary.items.len > 0) {
                const first_primary = self.collator.asciiFirstPrimary(
                    codepoints[index],
                ) orelse self.firstPrimary(codepoints[index]);
                if (first_primary) |primary| {
                    if (primary != self.needle_primary.items[0]) {
                        index += 1;
                        continue;
                    }
                }
            }
            var end = index + 1;
            try self.collator.sortKeyCodepointsInto(
                self.allocator,
                codepoints[index..end],
                &self.candidate_key,
            );
            // When no contraction can consume the next character here, the
            // first character's primary weights must prefix the pattern's.
            if (!can_extend) {
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
            // Extending a contraction can merge weights, so the "too many
            // weights" cut-off is only safe once no contraction starting
            // inside the candidate can still consume another code point.
            // The look-ahead is bounded by the longest rule plus a wide
            // margin for discontiguous mark matching.
            var breakable = !can_extend;
            var contraction_limit: usize = if (can_extend)
                index + max_contraction_span
            else
                0;
            while (true) {
                if (std.mem.eql(
                    u32,
                    self.candidate_key.items,
                    self.needle_key.items,
                )) {
                    return offsets[index];
                }
                if (breakable) {
                    const counts = countLevels(self.candidate_key.items);
                    if (exceeds(counts, self.needle_counts)) break;
                }
                if (end == codepoints.len) break;
                end += 1;
                try self.collator.sortKeyCodepointsInto(
                    self.allocator,
                    codepoints[index..end],
                    &self.candidate_key,
                );
                if (self.collator.contractionExtends(
                    codepoints,
                    end - 1,
                )) {
                    const limit = end - 1 + max_contraction_span;
                    if (limit > contraction_limit) contraction_limit = limit;
                }
                if (!breakable and end >= contraction_limit) breakable = true;
            }
            index += 1;
        }
        return null;
    }

    /// Last match starting at or before byte offset `limit`.
    pub fn findLast(
        self: *Search,
        text: []const u8,
        limit: usize,
    ) Error!?usize {
        var position: usize = 0;
        var result: ?usize = null;
        while (position <= limit) {
            const found = (try self.find(text, position)) orelse break;
            if (found > limit) break;
            result = found;
            position = found + 1;
        }
        return result;
    }

    /// Last match in `text`.
    pub fn last(self: *Search, text: []const u8) Error!?usize {
        return self.findLast(text, text.len);
    }

    /// Root-collation primary search for ASCII text. Avoids decoding and
    /// building a sort key per candidate.
    fn findAsciiPrimary(self: *Search, text: []const u8, start: usize) ?usize {
        if (start > text.len) return null;
        const needle = self.needle_primary.items;
        const first = needle[0];
        var position = start;
        while (position < text.len) {
            const weights = self.ascii_primaries[text[position]];
            if (weights.count != 0 and weights.values[0] != first) {
                position += 1;
                continue;
            }
            var needle_index: usize = 0;
            var cursor = position;
            var matched = true;
            while (needle_index < needle.len and cursor < text.len) {
                const current = self.ascii_primaries[text[cursor]];
                var element_index: usize = 0;
                while (element_index < current.count) : (element_index += 1) {
                    if (needle_index == needle.len or
                        current.values[element_index] != needle[needle_index])
                    {
                        matched = false;
                        break;
                    }
                    needle_index += 1;
                }
                if (!matched) break;
                cursor += 1;
            }
            if (matched and needle_index == needle.len) return position;
            position += 1;
        }
        return null;
    }

    fn latinFastNeedle(self: *Search, needle: []const u8) bool {
        _ = self;
        var cursor: usize = 0;
        while (cursor < needle.len) {
            const decoded = decodeAt(needle, cursor) orelse return false;
            if (!latinFastCodepoint(decoded.codepoint)) return false;
            cursor = decoded.next;
        }
        return true;
    }

    fn latinFastTailoring(self: *Search) bool {
        const tailoring = self.collator.tailoring orelse return true;
        return tailoring.reorder == null and
            tailoring.case_first == .off and
            !tailoring.backwards and
            !tailorings.hasNonMarkContraction(tailoring);
    }

    /// Cached per-code-point primary weights; the probe stays inline so the
    /// position loop pays one compare per character instead of a call.
    inline fn latinPrimaryFor(self: *Search, codepoint: u21) ?LatinPrimary {
        const hash: usize = (@as(u32, codepoint) *% 0x9E3779B1) >> 25;
        const entry = &self.latin_primary_cache[hash];
        if (entry.codepoint == codepoint) return entry.primary;
        return self.latinPrimaryForSlow(codepoint, entry);
    }

    fn latinPrimaryForSlow(
        self: *Search,
        codepoint: u21,
        entry: *LatinPrimaryCacheEntry,
    ) ?LatinPrimary {
        const single = [_]u21{codepoint};
        self.collator.sortKeyCodepointsInto(
            self.allocator,
            &single,
            &self.candidate_key,
        ) catch return null;
        const length = primaryLength(self.candidate_key.items);
        if (length > 4) return null;
        var primary = LatinPrimary{ .count = @intCast(length) };
        for (self.candidate_key.items[0..length], 0..) |weight, index| {
            primary.values[index] = weight;
        }
        entry.* = .{ .codepoint = codepoint, .primary = primary };
        return primary;
    }

    /// Primary search for precomposed Latin text. Per-code-point keys are
    /// valid here because the text has no combining marks and the tailoring
    /// has no non-mark contractions. Falls back to the general search when a
    /// code point cannot be handled this way.
    fn findLatinPrimary(
        self: *Search,
        text: []const u8,
        start: usize,
        fallback: *bool,
    ) ?usize {
        fallback.* = false;
        if (start > text.len) return null;
        const needle = self.needle_primary.items;
        const first = needle[0];
        var position = start;
        while (position < text.len) {
            const decoded = decodeAt(text, position) orelse {
                fallback.* = true;
                return null;
            };
            if (!latinFastCodepoint(decoded.codepoint)) {
                fallback.* = true;
                return null;
            }
            const weights = self.latinPrimaryFor(decoded.codepoint) orelse {
                fallback.* = true;
                return null;
            };
            if (weights.count != 0 and weights.values[0] != first) {
                position = decoded.next;
                continue;
            }
            var needle_index: usize = 0;
            var cursor = position;
            var matched = true;
            while (needle_index < needle.len and cursor < text.len) {
                const current = decodeAt(text, cursor) orelse {
                    fallback.* = true;
                    return null;
                };
                if (!latinFastCodepoint(current.codepoint)) {
                    fallback.* = true;
                    return null;
                }
                const current_primary = self.latinPrimaryFor(
                    current.codepoint,
                ) orelse {
                    fallback.* = true;
                    return null;
                };
                var element_index: usize = 0;
                while (element_index < current_primary.count) : (element_index += 1) {
                    if (needle_index == needle.len or
                        current_primary.values[element_index] !=
                            needle[needle_index])
                    {
                        matched = false;
                        break;
                    }
                    needle_index += 1;
                }
                if (!matched) break;
                cursor = current.next;
            }
            if (matched and needle_index == needle.len) {
                // A contraction could extend the last matched code point.
                if (cursor < text.len) {
                    const next = decodeAt(text, cursor) orelse {
                        fallback.* = true;
                        return null;
                    };
                    if (!latinFastCodepoint(next.codepoint)) {
                        fallback.* = true;
                        return null;
                    }
                }
                return position;
            }
            position = decoded.next;
        }
        return null;
    }

    /// First primary weight of a context-free single code point, cached.
    fn firstPrimary(self: *Search, codepoint: u21) ?u32 {
        const hash: usize = (@as(u32, codepoint) *% 0x9E3779B1) >> 26;
        const cached = self.primary_cache[hash];
        if (@as(u32, @truncate(cached >> 32)) == codepoint) {
            const stored: u32 = @truncate(cached);
            if (stored != 0) return stored - 1;
        }
        const codepoints = [_]u21{codepoint};
        self.collator.sortKeyCodepointsInto(
            self.allocator,
            &codepoints,
            &self.candidate_key,
        ) catch return null;
        const length = primaryLength(self.candidate_key.items);
        const primary: u32 = if (length == 0)
            0
        else
            self.candidate_key.items[0];
        self.primary_cache[hash] = (@as(u64, codepoint) << 32) |
            (@as(u64, primary) + 1);
        return primary;
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
            const decoded = scalar.decodeValidatingPacked(text, cursor);
            if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
            self.text_codepoints.appendAssumeCapacity(
                scalar.packedCodepoint(decoded),
            );
            self.text_offsets.appendAssumeCapacity(cursor);
            cursor += scalar.packedLength(decoded);
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

/// Last match in `text`, or null when there is none.
pub fn lastIndexOf(
    allocator: std.mem.Allocator,
    text: []const u8,
    needle: []const u8,
    options: Options,
) Error!?usize {
    var search = try Search.init(allocator, needle, options);
    defer search.deinit();
    return search.last(text);
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
    try testing.expectEqual(
        @as(?usize, 31),
        try lastIndexOf(allocator, ascii, "the", primary),
    );
    try testing.expectEqual(
        @as(?usize, null),
        try lastIndexOf(allocator, ascii, "zebra", primary),
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

    // A tailored contraction must still match when the first character
    // alone has the same weight count as the whole pattern.
    try testing.expectEqual(
        @as(?usize, 0),
        try indexOf(
            allocator,
            "a\u{0308}",
            "a\u{0308}",
            .{ .strength = .primary, .locale = "sv" },
        ),
    );

    // A three-code-point tailoring contraction must survive its two-code-
    // point prefix, which holds more weights than the whole pattern.
    const bengali = "\u{0995}\u{09c7}\u{09be}";
    try testing.expectEqual(
        @as(?usize, 0),
        try indexOf(
            allocator,
            bengali,
            bengali,
            .{
                .strength = .primary,
                .locale = "bn",
                .collation = "traditional",
            },
        ),
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

inline fn decodeAt(text: []const u8, offset: usize) ?Decoded {
    if (offset >= text.len) return null;
    const decoded = scalar.decodeValidatingPacked(text, offset);
    if (decoded == scalar.packed_invalid) return null;
    return .{
        .codepoint = scalar.packedCodepoint(decoded),
        .next = offset + scalar.packedLength(decoded),
    };
}

/// Codepoints below `latin_limit` that need no decomposition and no mark
/// reordering. Materializing the predicate once turns the per-position check
/// into a single bit test instead of a combining-class load plus a
/// mark-leading record search.
const latin_fast_bits = blk: {
    @setEvalBranchQuota(1_000_000);
    const count = collation.latin_limit;
    var bits: [count / 8]u8 = @splat(0);
    for (0..count) |value| {
        const codepoint: u21 = @intCast(value);
        if (codepoint == 0xb7) continue;
        if (combining_class.forCodepoint(codepoint) != 0) continue;
        if (decomposition.markLeadingForCodepoint(codepoint) != null) continue;
        bits[value >> 3] |= @as(u8, 1) << @intCast(value & 7);
    }
    break :blk bits;
};

inline fn latinFastCodepoint(codepoint: u21) bool {
    if (codepoint >= collation.latin_limit) return false;
    return latin_fast_bits[codepoint >> 3] &
        (@as(u8, 1) << @intCast(codepoint & 7)) != 0;
}

fn isAscii(text: []const u8) bool {
    const high_bits: u64 = 0x8080_8080_8080_8080;
    var index: usize = 0;
    while (index + 8 <= text.len) : (index += 8) {
        const word = std.mem.readInt(u64, text[index..][0..8], .little);
        if (word & high_bits != 0) return false;
    }
    while (index < text.len) : (index += 1) {
        if (text[index] >= 0x80) return false;
    }
    return true;
}

test "ASCII primary fast path matches the general search" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const options = Options{ .strength = .primary };
    const texts = [_][]const u8{
        "The quick brown fox jumps over the lazy dog.",
        "fffox fox FOX",
        "a b c",
        "x\nfox",
        "no match here",
        "",
    };
    const needles = [_][]const u8{
        "fox",
        "FOX",
        "o",
        " ",
        "a",
        "wombat",
        "\n",
        "\nfox",
        " f",
        "f",
        "ff",
        "b c",
    };
    for (texts) |text| {
        for (needles) |needle| {
            var fast = try Search.init(allocator, needle, options);
            defer fast.deinit();
            var general = try Search.init(allocator, needle, options);
            defer general.deinit();
            try testing.expect(fast.fast_ascii_primary or
                !isAscii(text) or
                needle.len == 0);
            general.fast_ascii_primary = false;
            var start: usize = 0;
            while (start <= text.len) : (start += 1) {
                try testing.expectEqual(
                    general.find(text, start),
                    fast.find(text, start),
                );
            }
        }
    }
}

test "Latin primary fast path matches the general search" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        needle: []const u8,
        options: Options,
    }{
        .{
            .text = "Ångström älskar blåbär och öar.",
            .needle = "älskar",
            .options = .{ .strength = .primary, .locale = "sv" },
        },
        .{
            .text = "Böttger Mühsam Überlingen ÄÖÜ äöü",
            .needle = "mühsam",
            .options = .{
                .strength = .primary,
                .locale = "de",
                .collation = "phonebook",
            },
        },
        .{
            .text = "café naïve Straße",
            .needle = "CAFÉ",
            .options = .{ .strength = .primary },
        },
        .{
            .text = "cafe\u{0301} naïve",
            .needle = "café",
            .options = .{ .strength = .primary },
        },
        .{
            .text = "L·L test",
            .needle = "l·l",
            .options = .{ .strength = .primary },
        },
        .{
            .text = "hola chico",
            .needle = "ch",
            .options = .{
                .strength = .primary,
                .locale = "es",
                .collation = "traditional",
            },
        },
    };
    for (cases) |case| {
        var fast = try Search.init(allocator, case.needle, case.options);
        defer fast.deinit();
        var general = try Search.init(allocator, case.needle, case.options);
        defer general.deinit();
        general.fast_ascii_primary = false;
        general.latin_fast = false;
        var start: usize = 0;
        while (start <= case.text.len) : (start += 1) {
            try testing.expectEqual(
                general.find(case.text, start),
                fast.find(case.text, start),
            );
        }
    }
}
