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

const ascii_classes = buildAsciiClasses();

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
    if (!scalar_value.isValid(codepoint)) return .on;
    if (codepoint < 0x80) return ascii_classes[codepoint];
    return classGenerated(codepoint);
}

pub fn bracket(codepoint: u21) ?Bracket {
    if (!scalar_value.isValid(codepoint)) return null;
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

fn buildAsciiClasses() [128]Class {
    var result: [128]Class = undefined;
    for (&result, 0..) |*entry, codepoint| {
        entry.* = classGenerated(@intCast(codepoint));
    }
    return result;
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}
