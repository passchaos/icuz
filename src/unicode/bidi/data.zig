//! Generated Unicode 17 UAX #9 properties and sparse bracket/mirror maps.

const std = @import("std");
const scalar_value = @import("../scalar/root.zig");

const data = @embedFile("data.bin");

pub const unicode_version = std.SemanticVersion{
    .major = 17,
    .minor = 0,
    .patch = 0,
};

/// Exact Unicode `Bidi_Class` values.
///
/// Declaration order is part of the generated binary format and the compact
/// BidiTest fixture. Keep it synchronized with both generators.
pub const Class = enum(u5) {
    l,
    r,
    al,
    en,
    es,
    et,
    an,
    cs,
    nsm,
    bn,
    b,
    s,
    ws,
    on,
    lre,
    lro,
    rle,
    rlo,
    pdf,
    lri,
    rli,
    fsi,
    pdi,
};

pub const Bracket = struct {
    opening: u21,
    is_open: bool,
};

const header_len = 16;
const index_count = readU16(8);
const page_count = readU16(10);
const bracket_count = readU16(12);
const mirror_count = readU16(14);
const index_offset = header_len;
const pages_offset = index_offset + @as(usize, index_count) * 2;
const brackets_offset = pages_offset + @as(usize, page_count) * 256;
const mirrors_offset = brackets_offset + @as(usize, bracket_count) * 12;

/// Flat Bidi_Class table generated from the packed pages. A single load
/// avoids the index-then-page dependency, which dominates random lookups.
const flat_classes = @embedFile("flat_classes.bin");
const flat_header_len = 16;
const flat_count = readU32At(flat_classes, 8);

comptime {
    if (flat_classes.len < flat_header_len or
        !std.mem.eql(u8, flat_classes[0..4], "CJZ0") or
        flat_classes[4] != 1 or
        flat_classes[5] != 17 or flat_classes[6] != 0 or flat_classes[7] != 0)
    {
        @compileError("invalid flat Bidi_Class data");
    }
    if (flat_count != 0x110001 or flat_header_len + flat_count != flat_classes.len) {
        @compileError("invalid flat Bidi_Class data lengths");
    }
}

/// One bit per 256-scalar page that contains at least one mirrored scalar.
/// Valid scalars occupy pages `0..0x1100`; every RTL-shaping hotspot page
/// (Arabic, Syriac, Hebrew presentation forms) is absent, so the bitmap turns
/// the sparse-table search into a single rejected load for almost every glyph.
const mirror_page_count = 0x1100;
const mirror_page_bits = buildMirrorPageBits();

fn buildMirrorPageBits() [mirror_page_count / 64]u64 {
    @setEvalBranchQuota(100_000);
    var result = [_]u64{0} ** (mirror_page_count / 64);
    for (0..mirror_count) |index| {
        const codepoint = readU32(mirrors_offset + index * 8);
        const page = codepoint >> 8;
        result[page / 64] |= @as(u64, 1) << @intCast(page % 64);
    }
    return result;
}

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJB1") or
        data[4] != 1 or data[5] != 17 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid Unicode bidi data");
    }
    if (index_count != 0x1100 or
        mirrors_offset + @as(usize, mirror_count) * 8 != data.len)
    {
        @compileError("invalid Unicode bidi data lengths");
    }
}

pub inline fn class(codepoint: u21) Class {
    // The generator patches surrogates and appends an out-of-range sentinel,
    // both `on`, so a clamped load matches the validity rule.
    const index: usize = @min(
        @as(usize, codepoint),
        @as(usize, flat_count) - 1,
    );
    return @enumFromInt(flat_classes[flat_header_len + index]);
}

pub inline fn bracket(codepoint: u21) ?Bracket {
    if (codepoint < 0x80) return ascii_brackets[codepoint];
    if (!scalar_value.isValid(codepoint)) return null;
    // Brackets are sparse; a page bitmap rejects almost every scalar with one
    // load instead of a binary search over the table.
    const page = @as(usize, codepoint) >> 8;
    if (page >= bracket_page_count or
        (bracket_page_bits[page / 64] >> @intCast(page % 64)) & 1 == 0)
    {
        return null;
    }
    return bracketGenerated(codepoint);
}

fn bracketGenerated(codepoint: u21) ?Bracket {
    var low: usize = 0;
    var high: usize = bracket_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const offset = brackets_offset + mid * 12;
        const candidate = readU32(offset);
        if (codepoint < candidate) {
            high = mid;
        } else if (codepoint > candidate) {
            low = mid + 1;
        } else {
            return .{
                .opening = @intCast(readU32(offset + 4)),
                .is_open = data[offset + 8] != 0,
            };
        }
    }
    return null;
}

const bracket_page_count = 0x1100;
const bracket_page_bits = buildBracketPageBits();

fn buildBracketPageBits() [bracket_page_count / 64]u64 {
    @setEvalBranchQuota(100_000);
    var result = [_]u64{0} ** (bracket_page_count / 64);
    for (0..bracket_count) |index| {
        const codepoint = readU32(brackets_offset + index * 12);
        const page = codepoint >> 8;
        result[page / 64] |= @as(u64, 1) << @intCast(page % 64);
    }
    return result;
}

const ascii_brackets = buildAsciiBrackets();

fn buildAsciiBrackets() [128]?Bracket {
    @setEvalBranchQuota(100_000);
    var result: [128]?Bracket = undefined;
    for (&result, 0..) |*entry, codepoint| {
        entry.* = bracketGenerated(@intCast(codepoint));
    }
    return result;
}

pub fn mirrored(codepoint: u21) u21 {
    if (!scalar_value.isValid(codepoint)) return codepoint;
    // Most scalars have no mirrored counterpart. A page bitmap rejects them
    // with one load instead of a full binary search over the sparse table;
    // the Arabic blocks that dominate RTL shaping are all absent from it.
    const page = @as(usize, codepoint) >> 8;
    if ((mirror_page_bits[page / 64] >> @intCast(page % 64)) & 1 == 0) {
        return codepoint;
    }
    var low: usize = 0;
    var high: usize = mirror_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const offset = mirrors_offset + mid * 8;
        const candidate = readU32(offset);
        if (codepoint < candidate) {
            high = mid;
        } else if (codepoint > candidate) {
            low = mid + 1;
        } else {
            return @intCast(readU32(offset + 4));
        }
    }
    return codepoint;
}

fn classGenerated(codepoint: u21) Class {
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(index_offset + page * 2);
    return @enumFromInt(data[
        pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ]);
}

fn readU32At(blob: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

test "flat bidi classes match the packed table" {
    const testing = std.testing;
    var codepoint: u32 = 0;
    while (codepoint <= 0x1fffff) : (codepoint += 1) {
        const value: u21 = @intCast(codepoint);
        const expected: Class = if (!scalar_value.isValid(value))
            .on
        else
            classGenerated(value);
        try testing.expectEqual(expected, class(value));
    }
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}
