//! Block and UAX break-property lookups (Line_Break, Word_Break,
//! Sentence_Break, Grapheme_Cluster_Break) from Unicode 17.

const std = @import("std");
const data = @import("extra_data.zig");

pub const unicode_version = [3]u8{ 17, 0, 0 };

pub const Block = data.Block;
pub const Range = data.Range;
pub const blocks = data.blocks;
pub const LineBreak = data.LineBreak;
pub const WordBreak = data.WordBreak;
pub const SentenceBreak = data.SentenceBreak;
pub const GraphemeBreak = data.GraphemeBreak;

pub const line_break_ranges = data.line_break_ranges;
pub const word_break_ranges = data.word_break_ranges;
pub const sentence_break_ranges = data.sentence_break_ranges;
pub const grapheme_break_ranges = data.grapheme_break_ranges;

/// Return the Unicode block containing `codepoint`, or null in an unassigned
/// gap between blocks (`No_Block`).
pub fn blockForCodepoint(codepoint: u21) ?Block {
    var low: usize = 0;
    var high = data.blocks.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const block = data.blocks[middle];
        if (codepoint < block.first) {
            high = middle;
        } else if (codepoint > block.last) {
            low = middle + 1;
        } else {
            return block;
        }
    }
    return null;
}

/// Resolve a block name or alias such as `Arabic`, `Basic_Latin`, or `ASCII`.
pub fn blockFromName(name: []const u8) ?Block {
    var buffer: [64]u8 = undefined;
    const key = normalizeName(&buffer, name) orelse return null;
    var low: usize = 0;
    var high = data.block_aliases.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.block_aliases[middle];
        switch (std.mem.order(u8, entry.key, key)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return data.blocks[entry.value],
        }
    }
    return null;
}

/// True when the name resolves to `No_Block`, the gaps between blocks.
pub fn isNoBlockName(name: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const key = normalizeName(&buffer, name) orelse return false;
    return std.mem.eql(u8, key, "noblock");
}

pub inline fn lineBreakClass(codepoint: u21) LineBreak {
    return @enumFromInt(rangeValue(
        &data.line_break_ranges,
        codepoint,
        @intFromEnum(LineBreak.XX),
    ));
}

pub inline fn wordBreakClass(codepoint: u21) WordBreak {
    return @enumFromInt(rangeValue(
        &data.word_break_ranges,
        codepoint,
        @intFromEnum(WordBreak.Other),
    ));
}

pub inline fn sentenceBreakClass(codepoint: u21) SentenceBreak {
    return @enumFromInt(rangeValue(
        &data.sentence_break_ranges,
        codepoint,
        @intFromEnum(SentenceBreak.Other),
    ));
}

pub inline fn graphemeBreakClass(codepoint: u21) GraphemeBreak {
    return @enumFromInt(rangeValue(
        &data.grapheme_break_ranges,
        codepoint,
        @intFromEnum(GraphemeBreak.Other),
    ));
}

pub fn lineBreakFromName(name: []const u8) ?LineBreak {
    return @enumFromInt(aliasValue(
        &data.line_break_aliases,
        name,
    ) orelse return null);
}

pub fn wordBreakFromName(name: []const u8) ?WordBreak {
    return @enumFromInt(aliasValue(
        &data.word_break_aliases,
        name,
    ) orelse return null);
}

pub fn sentenceBreakFromName(name: []const u8) ?SentenceBreak {
    return @enumFromInt(aliasValue(
        &data.sentence_break_aliases,
        name,
    ) orelse return null);
}

pub fn graphemeBreakFromName(name: []const u8) ?GraphemeBreak {
    return @enumFromInt(aliasValue(
        &data.grapheme_break_aliases,
        name,
    ) orelse return null);
}

fn rangeValue(
    ranges: []const data.Range,
    codepoint: u21,
    default: u8,
) u8 {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = ranges[middle];
        if (codepoint < range.first) {
            high = middle;
        } else if (codepoint > range.last) {
            low = middle + 1;
        } else {
            return range.value;
        }
    }
    return default;
}

fn aliasValue(aliases: []const data.Alias, name: []const u8) ?u8 {
    var buffer: [64]u8 = undefined;
    const key = normalizeName(&buffer, name) orelse return null;
    var low: usize = 0;
    var high = aliases.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = aliases[middle];
        switch (std.mem.order(u8, entry.key, key)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return entry.value,
        }
    }
    return null;
}

/// Lowercase ASCII alphanumerics and drop spaces, underscores, and hyphens so
/// `Basic Latin`, `Basic_Latin`, and `basic-latin` share one key.
fn normalizeName(buffer: *[64]u8, name: []const u8) ?[]const u8 {
    var length: usize = 0;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (length == buffer.len) return null;
        buffer[length] = std.ascii.toLower(byte);
        length += 1;
    }
    if (length == 0) return null;
    return buffer[0..length];
}

test "block and break property lookups" {
    const testing = @import("std").testing;

    try testing.expectEqualStrings(
        "Arabic",
        blockForCodepoint(0x0627).?.name,
    );
    try testing.expect(blockForCodepoint(0x0870) != null);
    try testing.expectEqualStrings(
        "Basic Latin",
        blockFromName("Basic_Latin").?.name,
    );
    try testing.expectEqualStrings("Basic Latin", blockFromName("ASCII").?.name);
    try testing.expect(blockFromName("No_Block") == null);
    try testing.expect(isNoBlockName("No_Block"));

    try testing.expectEqual(LineBreak.AL, lineBreakClass('A'));
    try testing.expectEqual(LineBreak.LF, lineBreakClass('\n'));
    try testing.expectEqual(WordBreak.ALetter, wordBreakClass('A'));
    try testing.expectEqual(WordBreak.Numeric, wordBreakClass('1'));
    try testing.expectEqual(
        GraphemeBreak.Regional_Indicator,
        graphemeBreakClass(0x1F1E6),
    );
    try testing.expectEqual(
        SentenceBreak.ATerm,
        sentenceBreakClass('.'),
    );
    try testing.expectEqual(LineBreak.AI, lineBreakFromName("Ambiguous").?);
    try testing.expectEqual(LineBreak.XX, lineBreakFromName("Unknown").?);
}
