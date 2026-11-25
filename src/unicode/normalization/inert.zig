//! Per-code-point normalization inertness tables, one per form.
//!
//! `data.isSimplePage` handles whole pages that are inert for a form. This
//! table covers the remaining pages so ordinary letters in mixed-script text
//! (Hebrew, Arabic, Devanagari, emoji, and so on) can skip the quick-check,
//! combining-class, and composition lookups during a normalization scan.
//!
//! Inertness is form specific: `é` is inert under NFC/NFKC but must decompose
//! under NFD/NFKD, and `™` is inert under NFC/NFD but not under NFKC/NFKD.

const std = @import("std");
const data = @import("data.zig");
const combining_class = @import("../canonical/combining_class.zig");

const form_count = 4;
const page_count = 0x1100;

fn isCompat(form: data.Form) bool {
    return form == .nfkc or form == .nfkd;
}

/// True when every scalar on `page` is inert for `form`.
fn pageFullyInert(page: u21, form: data.Form) bool {
    return data.isSimplePage(page, isCompat(form));
}

/// True when `codepoint` is unchanged by `form` and cannot compose with a
/// preceding starter.
///
/// Quick_Check=Maybe is exactly the set of scalars that can compose with a
/// previous starter, so requiring `yes` covers composition seconds (including
/// algorithmic Hangul jamo) without a separate table.
fn codepointInert(codepoint: u21, form: data.Form) bool {
    if (data.quickCheck(codepoint, form) != .yes) return false;
    return combining_class.forCodepoint(codepoint) == 0;
}

const Layout = struct {
    counts: [form_count]u16,
    offsets: [form_count]u16,
    total_slots: u16,
};

fn computeLayout() Layout {
    @setEvalBranchQuota(2_000_000);
    var counts = [_]u16{0} ** form_count;
    for (0..page_count) |page| {
        const base: u21 = @intCast(page << 8);
        for (0..form_count) |form_index| {
            const form: data.Form = @enumFromInt(form_index);
            if (pageFullyInert(base, form)) continue;
            counts[form_index] += 1;
        }
    }
    var offsets = [_]u16{0} ** form_count;
    var total: u16 = 0;
    for (0..form_count) |form_index| {
        offsets[form_index] = total;
        total += counts[form_index];
    }
    return .{ .counts = counts, .offsets = offsets, .total_slots = total };
}

const layout = computeLayout();
const masks_len = @as(usize, layout.total_slots) * 32;

fn buildSlots() [form_count][page_count]u16 {
    @setEvalBranchQuota(20_000_000);
    var table = [_][page_count]u16{[_]u16{0xFFFF} ** page_count} ** form_count;
    var next = layout.offsets;
    for (0..page_count) |page| {
        const base: u21 = @intCast(page << 8);
        for (0..form_count) |form_index| {
            const form: data.Form = @enumFromInt(form_index);
            if (pageFullyInert(base, form)) continue;
            table[form_index][page] = next[form_index];
            next[form_index] += 1;
        }
    }
    return table;
}

fn buildMasks() [masks_len]u8 {
    @setEvalBranchQuota(20_000_000);
    var mask_data = [_]u8{0} ** masks_len;
    var next = layout.offsets;
    for (0..page_count) |page| {
        const base: u21 = @intCast(page << 8);
        for (0..form_count) |form_index| {
            const form: data.Form = @enumFromInt(form_index);
            if (pageFullyInert(base, form)) continue;
            const slot: usize = next[form_index];
            for (0..256) |low| {
                const codepoint: u21 = base + @as(u21, @intCast(low));
                if (codepoint > 0x10FFFF) break;
                if (codepointInert(codepoint, form)) {
                    mask_data[slot * 32 + low / 8] |=
                        @as(u8, 1) << @intCast(low & 7);
                }
            }
            next[form_index] += 1;
        }
    }
    return mask_data;
}

const slots = buildSlots();
const masks = buildMasks();

/// Inertness of two-byte scalars (U+0080..U+07FF), indexed by lead byte minus
/// 0xC2 and the low six bits of the second byte. Hebrew, Arabic, and other
/// two-byte prose can then test inertness with a single load.
const two_byte_masks: [4][30]u64 = blk: {
    @setEvalBranchQuota(400_000);
    var table: [4][30]u64 = [_][30]u64{[_]u64{0} ** 30} ** 4;
    for (0..4) |form_index| {
        const form: data.Form = @enumFromInt(form_index);
        for (0xc2..0xe0) |lead| {
            for (0x80..0xc0) |second| {
                const codepoint: u21 = @intCast(
                    (@as(u21, lead & 0x1f) << 6) | (second & 0x3f),
                );
                if (isInert(codepoint, form)) {
                    table[form_index][lead - 0xc2] |=
                        @as(u64, 1) << @intCast(second & 0x3f);
                }
            }
        }
    }
    break :blk table;
};

/// True when `form` leaves the scalar unchanged and it cannot compose with a
/// previous starter, so a normalization scan can treat it as a plain starter.
pub inline fn isInert(codepoint: u21, form: data.Form) bool {
    const form_index = @intFromEnum(form);
    const slot = slots[form_index][codepoint >> 8];
    if (slot == 0xFFFF) return true;
    const base = @as(usize, slot) * 32;
    return masks[base + ((codepoint & 0xff) >> 3)] &
        (@as(u8, 1) << @intCast(codepoint & 7)) != 0;
}

/// Flat inertness bitmap for the BMP, indexed by UTF-16 unit. UTF-16 scans
/// test a unit with one load instead of the page slot plus mask pair.
const bmp_masks: [4][1024]u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [4][1024]u64 = [_][1024]u64{[_]u64{0} ** 1024} ** 4;
    for (0..4) |form_index| {
        const form: data.Form = @enumFromInt(form_index);
        for (0..0x10000) |unit| {
            if (isInert(@intCast(unit), form)) {
                table[form_index][unit >> 6] |=
                    @as(u64, 1) << @intCast(unit & 63);
            }
        }
    }
    break :blk table;
};

/// `isInert` for a BMP UTF-16 unit. Surrogates are decoded before this test.
pub inline fn bmpInert(unit: u16, form: data.Form) bool {
    return (bmp_masks[@intFromEnum(form)][unit >> 6] >>
        @intCast(unit & 63)) & 1 != 0;
}

/// `isInert` for a validated two-byte sequence whose lead is 0xC2..0xDF.
pub inline fn twoByteInert(lead: u8, second: u8, form: data.Form) bool {
    const row = lead - 0xc2;
    return (two_byte_masks[@intFromEnum(form)][row] >>
        @intCast(second & 0x3f)) & 1 != 0;
}

/// Combining class of a validated two-byte scalar when it is a simple mark
/// for `form` (unchanged and unable to compose with a previous starter), or
/// zero otherwise. One load replaces the quick-check plus class pair.
const two_byte_mark_classes: [4][30][64]u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var table: [4][30][64]u8 =
        [_][30][64]u8{[_][64]u8{[_]u8{0} ** 64} ** 30} ** 4;
    for (0..4) |form_index| {
        const form: data.Form = @enumFromInt(form_index);
        for (0xc2..0xe0) |lead| {
            for (0x80..0xc0) |second| {
                const codepoint: u21 = @intCast(
                    (@as(u21, lead & 0x1f) << 6) | (second & 0x3f),
                );
                if (data.quickCheck(codepoint, form) != .yes) continue;
                const class = combining_class.forCodepoint(codepoint);
                if (class == 0) continue;
                table[form_index][lead - 0xc2][second & 0x3f] = class;
            }
        }
    }
    break :blk table;
};

pub inline fn twoByteMarkClass(lead: u8, second: u8, form: data.Form) u8 {
    return two_byte_mark_classes[@intFromEnum(form)][lead - 0xc2][second & 0x3f];
}

/// Inertness of three-byte scalars with lead 0xE0 (U+0800..U+0FFF), indexed
/// by the eleven-bit offset from U+0800. This covers Devanagari, Thai, Lao,
/// Tibetan, Myanmar, and the other Indic scripts.
const e0_masks: [4][32]u64 = blk: {
    @setEvalBranchQuota(400_000);
    var table: [4][32]u64 = [_][32]u64{[_]u64{0} ** 32} ** 4;
    for (0..4) |form_index| {
        const form: data.Form = @enumFromInt(form_index);
        for (0x800..0x1000) |codepoint| {
            if (isInert(@intCast(codepoint), form)) {
                const low = codepoint - 0x800;
                table[form_index][low >> 6] |=
                    @as(u64, 1) << @intCast(low & 0x3f);
            }
        }
    }
    break :blk table;
};

/// `isInert` for a validated three-byte sequence with lead 0xE0 and
/// `low` = (second & 0x3F) << 6 | (third & 0x3F) - 0x800.
pub inline fn e0Inert(low: u11, form: data.Form) bool {
    return (e0_masks[@intFromEnum(form)][low >> 6] >>
        @intCast(low & 0x3f)) & 1 != 0;
}

/// Inertness of three-byte scalars with lead 0xE1 (U+1000..U+1FFF), indexed
/// by the twelve-bit offset from U+1000. This covers Georgian, Myanmar,
/// Ethiopic, and the Latin Extended Additional block. Hangul jamo share the
/// lead byte but are rejected by the scanner before this table is read.
const e1_masks: [4][64]u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [4][64]u64 = [_][64]u64{[_]u64{0} ** 64} ** 4;
    for (0..4) |form_index| {
        const form: data.Form = @enumFromInt(form_index);
        for (0x1000..0x2000) |codepoint| {
            if (isInert(@intCast(codepoint), form)) {
                const low = codepoint - 0x1000;
                table[form_index][low >> 6] |=
                    @as(u64, 1) << @intCast(low & 0x3f);
            }
        }
    }
    break :blk table;
};

/// `isInert` for a validated three-byte sequence with lead 0xE1 and
/// `low` = (second & 0x3F) << 6 | (third & 0x3F).
pub inline fn e1Inert(low: u12, form: data.Form) bool {
    return (e1_masks[@intFromEnum(form)][low >> 6] >>
        @intCast(low & 0x3f)) & 1 != 0;
}

/// `e1Inert` for two scalars at once. Word-internal scalars usually share a
/// 64-codepoint group, so one mask load answers both.
pub inline fn e1InertPair(low0: u12, low1: u12, form: data.Form) bool {
    const group = low0 >> 6;
    if (group != low1 >> 6) {
        return e1Inert(low0, form) and e1Inert(low1, form);
    }
    const mask = e1_masks[@intFromEnum(form)][group];
    const bits = (@as(u64, 1) << @intCast(low0 & 0x3f)) |
        (@as(u64, 1) << @intCast(low1 & 0x3f));
    return mask & bits == bits;
}

test "inert tables follow each normalization form" {
    const testing = @import("std").testing;
    inline for ([_]data.Form{ .nfc, .nfd, .nfkc, .nfkd }) |form| {
        try testing.expect(isInert('A', form));
        try testing.expect(isInert(0x05D0, form)); // Hebrew alef
        try testing.expect(isInert(0x0627, form)); // Arabic alef
        try testing.expect(isInert(0x0915, form)); // Devanagari ka
        try testing.expect(isInert(0x1F600, form)); // emoji
        try testing.expect(!isInert(0x0301, form)); // combining acute
    }
    // Precomposed e-acute is stable under the composed forms only.
    try testing.expect(isInert(0x00E9, .nfc));
    try testing.expect(isInert(0x00E9, .nfkc));
    try testing.expect(!isInert(0x00E9, .nfd));
    try testing.expect(!isInert(0x00E9, .nfkd));
    // Trade mark sign has a compatibility decomposition only.
    try testing.expect(isInert(0x2122, .nfc));
    try testing.expect(isInert(0x2122, .nfd));
    try testing.expect(!isInert(0x2122, .nfkc));
    try testing.expect(!isInert(0x2122, .nfkd));
    // Hangul V jamo composes with a preceding L jamo.
    try testing.expect(!isInert(0x1161, .nfc));
    try testing.expect(isInert(0x1161, .nfd));
    // Precomposed Hangul syllables decompose only under the decomposed forms.
    try testing.expect(isInert(0xAC00, .nfc));
    try testing.expect(!isInert(0xAC00, .nfd));
}
