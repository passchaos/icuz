//! CLDR 48 locale collation tailorings.
//!
//! The blob is compiled by tools/unicode/collation/generate_tailorings.py.
//! Rules are NFD sequences mapped to collation elements whose weights were
//! allocated in the low bits of the root collation weight space.

const std = @import("std");

pub const blob = @embedFile("tailorings.bin");

const header_len = 28;
const locale_count = std.mem.readInt(u16, blob[8..10], .little);
const rule_count = std.mem.readInt(u32, blob[10..14], .little);
const ce_count = std.mem.readInt(u32, blob[14..18], .little);
const names_length = std.mem.readInt(u32, blob[18..22], .little);
const codepoint_count = std.mem.readInt(u32, blob[22..26], .little);

const locale_offset = header_len;
const rule_offset = locale_offset + @as(usize, locale_count) * 16;
const names_offset = rule_offset + @as(usize, rule_count) * 12;
const codepoints_offset = names_offset + @as(usize, names_length);
const ces_offset = codepoints_offset + @as(usize, codepoint_count) * 4;
const reorder_offset = ces_offset + @as(usize, ce_count) * 16;
const reorder_group_count = readU16(reorder_offset);
const hani_group = readU16(reorder_offset + 2);
const others_group = readU16(reorder_offset + 4);
const reorder_map_count = readU16(reorder_offset + 6);
const reorder_groups_offset = reorder_offset + 12;
const reorder_maps_offset = reorder_groups_offset +
    @as(usize, reorder_group_count) * 8;
const reorder_map_len = 4 + @as(usize, reorder_group_count) * 4;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJTL") or
        blob[4] != 4 or blob[5] != 48 or blob[6] != 0 or blob[7] != 0)
    {
        @compileError("invalid collation tailoring data");
    }
    if (reorder_maps_offset +
        @as(usize, reorder_map_count) * reorder_map_len != blob.len)
    {
        @compileError("invalid collation tailoring data lengths");
    }
}

pub const CaseFirst = enum(u2) { off = 0, upper = 1, lower = 2 };

/// A locale's parametric script-reordering plan. Root collation elements are
/// remapped by their primary weight range; tailored elements are already
/// remapped in the blob.
pub const Reorder = struct {
    index: u16,

    pub fn groupCount(self: Reorder) usize {
        _ = self;
        return reorder_group_count;
    }

    pub fn haniGroup(self: Reorder) u16 {
        _ = self;
        return hani_group;
    }

    pub fn othersGroup(self: Reorder) u16 {
        _ = self;
        return others_group;
    }

    fn mapOffset(self: Reorder) usize {
        return reorder_maps_offset + @as(usize, self.index) * reorder_map_len;
    }

    pub fn contBase(self: Reorder) u32 {
        return readU32(self.mapOffset());
    }

    pub fn newBase(self: Reorder, index: usize) u32 {
        return readU32(self.mapOffset() + 4 + index * 4);
    }

    pub fn oldStart(self: Reorder, index: usize) u32 {
        _ = self;
        return readU32(reorder_groups_offset + index * 8);
    }

    pub fn oldEnd(self: Reorder, index: usize) u32 {
        _ = self;
        return readU32(reorder_groups_offset + index * 8 + 4);
    }
};

pub const Element = struct {
    primary: u32,
    secondary: u32,
    tertiary: u32,
    variable: bool,
};

pub const Rule = struct {
    sequence_offset: u32,
    sequence_len: u8,
    ce_offset: u32,
    ce_count: u8,
};

pub const Tailoring = struct {
    locale: []const u8,
    collation_type: []const u8,
    rule_start: u32,
    rule_count: u32,
    case_first: CaseFirst,
    backwards: bool,
    reorder: ?Reorder,
};

pub const Match = struct {
    rule: Rule,
    length: usize,
};

const LocaleRecord = struct {
    name_offset: u16,
    name_len: u8,
    type_offset: u16,
    type_len: u8,
    rule_start: u32,
    rule_count: u32,
    flags: u8,
    reorder_map: u8,
};

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn localeAt(index: usize) LocaleRecord {
    const base = locale_offset + index * 16;
    return .{
        .name_offset = readU16(base),
        .name_len = blob[base + 2],
        .type_offset = readU16(base + 3),
        .type_len = blob[base + 5],
        .rule_start = readU32(base + 6),
        .rule_count = readU32(base + 10),
        .flags = blob[base + 14],
        .reorder_map = blob[base + 15],
    };
}

fn ruleAt(index: usize) Rule {
    const base = rule_offset + index * 12;
    return .{
        .sequence_offset = readU32(base),
        .sequence_len = blob[base + 4],
        .ce_offset = readU32(base + 5),
        .ce_count = blob[base + 9],
    };
}

pub fn sequenceCodepoint(rule: Rule, index: usize) u21 {
    const offset = codepoints_offset +
        (@as(usize, rule.sequence_offset) + index) * 4;
    return @intCast(readU32(offset));
}

pub fn elementAt(rule: Rule, index: usize) Element {
    const base = ces_offset + (@as(usize, rule.ce_offset) + index) * 16;
    return .{
        .primary = readU32(base),
        .secondary = readU32(base + 4),
        .tertiary = readU32(base + 8),
        .variable = blob[base + 12] != 0,
    };
}

pub fn lookup(locale: []const u8, collation_type: []const u8) ?Tailoring {
    var low: usize = 0;
    var high: usize = locale_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = localeAt(middle);
        const name = blob[names_offset + record.name_offset ..][0..record.name_len];
        const type_name = blob[names_offset + record.type_offset ..][0..record.type_len];
        switch (std.mem.order(u8, name, locale)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => switch (std.mem.order(u8, type_name, collation_type)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return .{
                    .locale = name,
                    .collation_type = type_name,
                    .rule_start = record.rule_start,
                    .rule_count = record.rule_count,
                    .case_first = @enumFromInt(record.flags >> 1 & 3),
                    .backwards = record.flags & 1 != 0,
                    .reorder = if (record.flags & 8 != 0)
                        Reorder{ .index = record.reorder_map }
                    else
                        null,
                },
            },
        }
    }
    return null;
}

/// Resolve a BCP 47-ish locale and collation type to a compiled tailoring,
/// trying the exact tag, an underscore-normalized tag, and the language
/// subtag. Unknown types fall back to the locale's standard tailoring.
pub fn find(locale: []const u8, collation_type: []const u8) ?Tailoring {
    if (lookup(locale, collation_type)) |tailoring| return tailoring;

    const base = stripExtensions(locale);
    var buffer: [64]u8 = undefined;
    var length: usize = 0;
    for (base) |byte| {
        if (length == buffer.len) break;
        buffer[length] = if (byte == '-') '_' else byte;
        length += 1;
    }
    const normalized = buffer[0..length];
    if (lookup(normalized, collation_type)) |tailoring| return tailoring;

    if (std.mem.indexOfAny(u8, normalized, "_")) |position| {
        if (lookup(normalized[0..position], collation_type)) |tailoring| {
            return tailoring;
        }
    }

    if (!std.mem.eql(u8, collation_type, "standard")) {
        if (lookup(locale, "standard")) |tailoring| return tailoring;
        if (lookup(normalized, "standard")) |tailoring| return tailoring;
        if (std.mem.indexOfAny(u8, normalized, "_")) |position| {
            if (lookup(normalized[0..position], "standard")) |tailoring| {
                return tailoring;
            }
        }
    }
    return null;
}

fn stripExtensions(locale: []const u8) []const u8 {
    if (std.mem.indexOf(u8, locale, "-u-")) |position| {
        return locale[0..position];
    }
    if (std.mem.indexOf(u8, locale, "_u_")) |position| {
        return locale[0..position];
    }
    if (std.mem.indexOfScalar(u8, locale, '@')) |position| {
        return locale[0..position];
    }
    return locale;
}

/// Find the longest tailored rule matching contiguously at `index`.
pub const PageIndex = [0x1100]u16;

const IndexSlot = struct {
    /// 0 = empty, 1 = building, 2 = published.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    rule_start: u32 = 0,
    rule_count: u32 = 0,
    pages: PageIndex = undefined,
};

/// Cache of per-tailoring page indexes. Slots are never evicted so published
/// pointers stay valid; when all slots are taken, callers fall back to the
/// plain binary search. Claiming a slot uses one atomic counter instead of a
/// lock so the collation path stays wait-free.
var index_slots = [_]IndexSlot{.{}} ** 4;
var index_slot_next = std.atomic.Value(usize).init(0);

fn buildPageIndex(tailoring: Tailoring, pages: *PageIndex) void {
    @memset(pages, 0);
    var rule_index: usize = 0;
    const end: usize = tailoring.rule_count;
    for (0..0x1100) |page| {
        const page_start: u32 = @intCast(page << 8);
        while (rule_index < end and
            sequenceCodepoint(
                ruleAt(tailoring.rule_start + rule_index),
                0,
            ) < page_start)
        {
            rule_index += 1;
        }
        pages[page] = @intCast(rule_index);
    }
}

/// Return (building on first use) the page index for this tailoring.
pub fn pageIndex(tailoring: Tailoring) ?*const PageIndex {
    for (&index_slots) |*slot| {
        if (slot.state.load(.acquire) == 2 and
            slot.rule_start == tailoring.rule_start and
            slot.rule_count == tailoring.rule_count)
        {
            return &slot.pages;
        }
    }
    const claimed = index_slot_next.fetchAdd(1, .monotonic);
    if (claimed >= index_slots.len) return null;
    const slot = &index_slots[claimed];
    if (slot.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        return null;
    }
    buildPageIndex(tailoring, &slot.pages);
    slot.rule_start = tailoring.rule_start;
    slot.rule_count = tailoring.rule_count;
    slot.state.store(2, .release);
    return &slot.pages;
}

fn lowerBound(start: usize, end: usize, first: u21) usize {
    var low = start;
    var high = end;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const rule = ruleAt(middle);
        if (sequenceCodepoint(rule, 0) < first) low = middle + 1 else high = middle;
    }
    return low;
}

pub fn match(
    tailoring: Tailoring,
    pages: ?*const PageIndex,
    codepoints: []const u21,
    index: usize,
) ?Match {
    const first = codepoints[index];
    const start = if (pages) |page_index| blk: {
        const page: usize = @as(usize, first) >> 8;
        const low = tailoring.rule_start + page_index[page];
        const high = if (page + 1 < 0x1100)
            tailoring.rule_start + page_index[page + 1]
        else
            tailoring.rule_start + tailoring.rule_count;
        break :blk lowerBound(low, high, first);
    } else lowerBound(
        tailoring.rule_start,
        tailoring.rule_start + tailoring.rule_count,
        first,
    );
    const end = tailoring.rule_start + tailoring.rule_count;
    var rule_index = start;
    while (rule_index < end) : (rule_index += 1) {
        const rule = ruleAt(rule_index);
        if (sequenceCodepoint(rule, 0) != first) break;
        const length = @as(usize, rule.sequence_len);
        if (length > codepoints.len - index) continue;
        var matched = true;
        var offset: usize = 1;
        while (offset < length) : (offset += 1) {
            if (sequenceCodepoint(rule, offset) != codepoints[index + offset]) {
                matched = false;
                break;
            }
        }
        if (matched) return .{ .rule = rule, .length = length };
    }
    return null;
}

test "tailoring locale lookup" {
    const testing = @import("std").testing;

    try testing.expect(lookup("sv", "standard") != null);
    try testing.expect(lookup("da", "standard") != null);
    try testing.expect(lookup("es", "standard") != null);
    try testing.expect(lookup("es", "traditional") != null);
    try testing.expect(lookup("de", "phonebook") != null);
    try testing.expect(lookup("root", "search") != null);
    try testing.expect(lookup("zz", "standard") == null);
    try testing.expect(find("sv-SE", "standard") != null);
    try testing.expect(find("sv_SE", "standard") != null);
    try testing.expect(find("sv-SE-u-co-standard", "standard") != null);
    try testing.expect(find("de-AT", "phonebook") != null);
    try testing.expect(find("sv-SE", "no-such-type") != null);
    try testing.expect(find("de-AT", "standard") == null);
}

test "tailoring rules are sorted by first code point" {
    const testing = @import("std").testing;

    const tailoring = lookup("sv", "standard").?;
    var previous: u21 = 0;
    var index: usize = tailoring.rule_start;
    const end = tailoring.rule_start + tailoring.rule_count;
    while (index < end) : (index += 1) {
        const first = sequenceCodepoint(ruleAt(index), 0);
        try testing.expect(first >= previous);
        previous = first;
    }
}
