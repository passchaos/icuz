//! CLDR 48 locale collation tailorings.
//!
//! The blob is compiled by tools/unicode/collation/generate_tailorings.py.
//! Rules are NFD sequences mapped to collation elements whose weights were
//! allocated in the low bits of the root collation weight space.

const std = @import("std");
const combining_class = @import("../canonical/combining_class.zig");

pub const blob = @embedFile("tailorings.bin");

const header_len = 28;
const locale_count = std.mem.readInt(u16, blob[8..10], .little);
const rule_count = std.mem.readInt(u32, blob[10..14], .little);
const ce_count = std.mem.readInt(u32, blob[14..18], .little);
const names_length = std.mem.readInt(u32, blob[18..22], .little);
const codepoint_count = std.mem.readInt(u32, blob[22..26], .little);

const locale_offset = header_len;
const locale_record_len = 16;
const defaults_offset = locale_offset +
    @as(usize, locale_count) * locale_record_len;
const default_count = readU16(defaults_offset);
const default_record_len = 6;
const rule_offset = defaults_offset + 2 +
    @as(usize, default_count) * default_record_len;
const names_offset = rule_offset + @as(usize, rule_count) * 16;
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
        blob[4] != 6 or blob[5] != 48 or blob[6] != 0 or blob[7] != 0)
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
    /// First code point of the sequence, stored inline so binary-search
    /// probes touch one cache line instead of two dependent loads.
    first: u21,
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
    const base = locale_offset + index * locale_record_len;
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

pub fn ruleAt(index: usize) Rule {
    const base = rule_offset + index * 16;
    return .{
        .sequence_offset = readU32(base),
        .sequence_len = blob[base + 4],
        .ce_offset = readU32(base + 5),
        .ce_count = blob[base + 9],
        .first = @intCast(readU32(base + 12)),
    };
}

pub fn sequenceCodepoint(rule: Rule, index: usize) u21 {
    const offset = codepoints_offset +
        (@as(usize, rule.sequence_offset) + index) * 4;
    return @intCast(readU32(offset));
}

/// Chinese `BASE+A-Z` index boundaries present in this tailoring.
pub fn baseLetterBoundaries(tailoring: Tailoring) [26]bool {
    var result = [_]bool{false} ** 26;
    var index = tailoring.rule_start;
    const end = tailoring.rule_start + tailoring.rule_count;
    while (index < end) : (index += 1) {
        const rule = ruleAt(index);
        if (rule.first > 0xFDD0) break;
        if (rule.first != 0xFDD0 or rule.sequence_len != 2) continue;
        const second = sequenceCodepoint(rule, 1);
        if (second >= 'A' and second <= 'Z') {
            result[second - 'A'] = true;
        }
    }
    return result;
}

/// True when a multi-codepoint rule continues with a non-combining-mark
/// scalar, so a per-code-point primary search cannot ignore contractions.
pub fn hasNonMarkContraction(tailoring: Tailoring) bool {
    var index: usize = tailoring.rule_start;
    const end = tailoring.rule_start + tailoring.rule_count;
    while (index < end) : (index += 1) {
        const rule = ruleAt(index);
        if (rule.sequence_len > 1 and
            combining_class.forCodepoint(sequenceCodepoint(rule, 1)) == 0)
        {
            return true;
        }
    }
    return false;
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

/// Thread-local cache of collation elements for single-code-point,
/// single-element rules. Tailored text repeats the same code points, so the
/// cached weights replace the page lookup and the two dependent blob reads
/// with one table load.
pub const CachedElement = struct {
    /// `cacheTag(tailoring, codepoint)`; 0 marks an empty slot.
    tag: u64 = 0,
    primary: u32 = 0,
    secondary: u32 = 0,
    tertiary: u32 = 0,
    kind: Kind = .empty,
    variable: bool = false,

    pub const Kind = enum(u8) {
        empty = 0,
        /// The tailoring has no rule for the code point.
        absent = 1,
        /// A single-code-point rule with exactly one collation element.
        single = 2,
        /// Like `single`, with non-zero primary, secondary, and tertiary
        /// weights. Runs of these emit without per-weight checks.
        single_full = 3,
        /// Any other rule; callers fall back to `match`.
        complex = 4,
    };
};

const element_cache_len = 256;

threadlocal var element_cache: [element_cache_len]CachedElement =
    [_]CachedElement{.{}} ** element_cache_len;

/// Cache slot for `codepoint`.
pub inline fn cachedElement(codepoint: u21) *CachedElement {
    const hash: usize = (@as(u32, codepoint) *% 0x9E3779B1) >> 24;
    return &element_cache[hash & (element_cache_len - 1)];
}

/// Tag bits shared by every code point under `tailoring`. Callers that tag
/// many scalars hoist this out of their loop.
pub inline fn cacheTagBase(tailoring: Tailoring) u64 {
    return (@as(u64, tailoring.rule_start) << 39) |
        (@as(u64, tailoring.rule_count) << 21);
}

/// Cache tag for `codepoint` under `tailoring`. The tag carries the rule
/// range, so switching locales only misses; it never reuses another locale's
/// rule. Zero is reserved for empty slots.
pub inline fn cacheTag(tailoring: Tailoring, codepoint: u21) u64 {
    return cacheTagBase(tailoring) + codepoint + 1;
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

/// One-entry memo of the last resolved locale and type. The module-level
/// sort-key and compare entry points resolve the same tailoring on every
/// call, and the binary search over the locale table costs more than the
/// comparison here.
const find_cache_locale_max = 32;
const find_cache_collation_max = 16;

const FindCache = struct {
    locale: [find_cache_locale_max]u8 = undefined,
    collation: [find_cache_collation_max]u8 = undefined,
    locale_len: u8 = 0,
    collation_len: u8 = 0,
    result: ?Tailoring = null,
};

threadlocal var find_cache: ?FindCache = null;

/// Resolve a BCP 47-ish locale and collation type to a compiled tailoring,
/// trying the exact tag, an underscore-normalized tag, and the language
/// subtag. Unknown types fall back to the locale's standard tailoring.
pub fn find(locale: []const u8, collation_type: []const u8) ?Tailoring {
    const cacheable = locale.len <= find_cache_locale_max and
        collation_type.len <= find_cache_collation_max;
    if (cacheable) {
        if (find_cache) |entry| {
            if (@as(usize, entry.locale_len) == locale.len and
                @as(usize, entry.collation_len) == collation_type.len and
                std.mem.eql(u8, entry.locale[0..entry.locale_len], locale) and
                std.mem.eql(
                    u8,
                    entry.collation[0..entry.collation_len],
                    collation_type,
                ))
            {
                return entry.result;
            }
        }
    }
    const result = findUncached(locale, collation_type);
    if (cacheable) {
        var entry = FindCache{
            .locale_len = @intCast(locale.len),
            .collation_len = @intCast(collation_type.len),
            .result = result,
        };
        @memcpy(entry.locale[0..locale.len], locale);
        @memcpy(entry.collation[0..collation_type.len], collation_type);
        find_cache = entry;
    }
    return result;
}

fn findUncached(locale: []const u8, collation_type: []const u8) ?Tailoring {
    const base = stripExtensions(locale);
    var buffer: [64]u8 = undefined;
    var length: usize = 0;
    for (base) |byte| {
        if (length == buffer.len) break;
        buffer[length] = if (byte == '-') '_' else byte;
        length += 1;
    }
    const normalized = buffer[0..length];
    const language = if (std.mem.indexOfAny(u8, normalized, "_")) |position|
        normalized[0..position]
    else
        normalized;

    // Prefer the requested type on the most specific tag, then on the
    // normalized tag and the language.
    if (lookup(locale, collation_type)) |tailoring| return tailoring;
    if (lookup(normalized, collation_type)) |tailoring| return tailoring;
    if (lookup(language, collation_type)) |tailoring| return tailoring;

    // The requested type is unavailable. CLDR locales such as zh and
    // zh_Hant define their own default collation (pinyin, stroke). Taiwan,
    // Hong Kong, and Macau default to the Traditional script.
    var traditional_zh = false;
    if (std.mem.eql(u8, language, "zh")) {
        if (regionOf(normalized)) |region| {
            traditional_zh = std.mem.eql(u8, region, "TW") or
                std.mem.eql(u8, region, "HK") or
                std.mem.eql(u8, region, "MO");
        }
    }
    const default_type = defaultTypeFor(normalized) orelse
        defaultTypeFor(locale) orelse
        (if (traditional_zh) defaultTypeFor("zh_Hant") else null) orelse
        defaultTypeFor(language) orelse "standard";
    if (std.mem.eql(u8, default_type, collation_type)) return null;
    if (lookup(locale, default_type)) |tailoring| return tailoring;
    if (lookup(normalized, default_type)) |tailoring| return tailoring;
    if (lookup(language, default_type)) |tailoring| return tailoring;
    return null;
}

fn regionOf(tag: []const u8) ?[]const u8 {
    const position = std.mem.lastIndexOfScalar(u8, tag, '_') orelse return null;
    const region = tag[position + 1 ..];
    if (region.len == 2) {
        for (region) |byte| {
            if (!std.ascii.isAlphabetic(byte)) return null;
        }
        return region;
    }
    if (region.len == 3) {
        for (region) |byte| {
            if (!std.ascii.isDigit(byte)) return null;
        }
        return region;
    }
    return null;
}

/// CLDR's default collation type for a locale tag, if it is not `standard`.
fn defaultTypeFor(locale: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = default_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = defaults_offset + 2 + middle * default_record_len;
        const name_offset = readU16(base);
        const name_len = blob[base + 2];
        const name = blob[names_offset + name_offset ..][0..name_len];
        switch (std.mem.order(u8, name, locale)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => {
                const type_offset = readU16(base + 3);
                const type_len = blob[base + 5];
                return blob[names_offset + type_offset ..][0..type_len];
            },
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
///
/// `rules` maps each 256-code-point page to its first rule. `direct` maps
/// code points below `direct_limit` straight to the offset of their first
/// rule within the page (0xFFFF when the tailoring has no rule for it), so
/// Latin and other early scripts skip the binary search entirely. `cache`
/// remembers the first rule of recently matched code points; it is written
/// atomically and only ever holds entries for this tailoring.
pub const PageIndex = struct {
    rules: [0x1100]u16,
    direct: [direct_limit]u16,
    /// Latin code points below 0x370: 0 = no tailoring, 1 = contraction or
    /// multiple rules, otherwise the single-code-point rule index + 2.
    single_rules: [0x370]u32,
    /// True when every rule for the code point is a contraction whose second
    /// scalar is a combining mark. The matcher cannot match unless the next
    /// scalar is a mark, so callers can keep plain letters on the root path.
    mark_only: [0x370]bool,
    /// Two-scalar rules keyed by their scalar pair. `pair_keys` holds
    /// `(first << 21) | second` and 0 marks an empty slot; `pair_rules` holds
    /// the absolute rule index, `pair_ambiguous` when a longer rule shares
    /// the pair, so those pairs use the full matcher.
    pair_keys: [pair_slot_count]u64,
    pair_rules: [pair_slot_count]u32,
    cache: [256]std.atomic.Value(u64),
    /// True when no rule starts with an ASCII code point, so ASCII text
    /// sorts exactly like the root collation.
    ascii_untailored: bool,
};

const direct_limit: usize = 0x1000;
const direct_absent: u16 = 0xFFFF;

const pair_slot_count = 512;
const pair_probe_limit = 8;
const pair_empty: u32 = 0xFFFFFFFF;
const pair_ambiguous: u32 = 0xFFFFFFFE;

inline fn pairKey(first: u21, second: u21) u64 {
    return (@as(u64, first) << 21) | second;
}

inline fn pairStart(key: u64) usize {
    const mixed = (@as(u32, @truncate(key)) *% 0x9E3779B1) ^
        (@as(u32, @truncate(key >> 21)) *% 0x85EBCA6B);
    return (mixed >> 23) & (pair_slot_count - 1);
}

/// Rule for the two-scalar sequence `first` + `second`, or null when no
/// unambiguous two-scalar rule starts with the pair. Callers fall back to
/// `match` on null.
pub inline fn pairRule(
    pages: *const PageIndex,
    first: u21,
    second: u21,
) ?Rule {
    const key = pairKey(first, second);
    var probe = pairStart(key);
    var attempt: usize = 0;
    while (attempt < pair_probe_limit) : (attempt += 1) {
        const slot = probe & (pair_slot_count - 1);
        const stored = pages.pair_keys[slot];
        if (stored == 0) return null;
        if (stored == key) {
            const index = pages.pair_rules[slot];
            if (index == pair_ambiguous) return null;
            return ruleAt(index);
        }
        probe += 1;
    }
    return null;
}

/// True when `codepoint` may start a tailored rule. Callers use this to skip
/// the full `match` call for code points the locale does not touch.
pub inline fn couldMatch(pages: ?*PageIndex, codepoint: u21) bool {
    const page_index = pages orelse return true;
    if (codepoint >= direct_limit) return true;
    return page_index.direct[codepoint] != direct_absent;
}

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
    @memset(&pages.rules, 0);
    @memset(&pages.direct, direct_absent);
    @memset(&pages.single_rules, 0);
    @memset(&pages.mark_only, false);
    for (&pages.cache) |*entry| entry.* = std.atomic.Value(u64).init(0);
    var single_rule: [0x370]bool = [_]bool{false} ** 0x370;
    var nonmark_second: [0x370]bool = [_]bool{false} ** 0x370;
    var rule_index: usize = 0;
    const end: usize = tailoring.rule_count;
    for (0..0x1100) |page| {
        const page_start: u32 = @intCast(page << 8);
        while (rule_index < end and
            ruleAt(tailoring.rule_start + rule_index).first < page_start)
        {
            rule_index += 1;
        }
        pages.rules[page] = @intCast(rule_index);
    }
    for (0..end) |index| {
        const rule = ruleAt(tailoring.rule_start + index);
        const first = rule.first;
        if (first >= direct_limit) break;
        if (pages.direct[first] == direct_absent) {
            const page = @as(usize, first) >> 8;
            pages.direct[first] = @intCast(
                index - pages.rules[page],
            );
        }
        if (first < pages.single_rules.len) {
            if (rule.sequence_len != 1 or pages.single_rules[first] != 0) {
                // A contraction or a second rule for the same first code
                // point needs the full matcher.
                pages.single_rules[first] = 1;
            } else {
                pages.single_rules[first] = @intCast(index + 2);
            }
            if (rule.sequence_len == 1) {
                single_rule[first] = true;
            } else if (combining_class.forCodepoint(
                sequenceCodepoint(rule, 1),
            ) == 0) {
                nonmark_second[first] = true;
            }
        }
    }
    for (0..pages.mark_only.len) |first| {
        pages.mark_only[first] = pages.single_rules[first] == 1 and
            !single_rule[first] and !nonmark_second[first];
    }
    @memset(&pages.pair_keys, 0);
    @memset(&pages.pair_rules, pair_empty);
    for (0..end) |index| {
        const rule = ruleAt(tailoring.rule_start + index);
        if (rule.sequence_len != 2) continue;
        const key = pairKey(rule.first, sequenceCodepoint(rule, 1));
        var probe = pairStart(key);
        var attempt: usize = 0;
        while (attempt < pair_probe_limit) : (attempt += 1) {
            const slot = probe & (pair_slot_count - 1);
            const stored = pages.pair_keys[slot];
            if (stored == 0) {
                pages.pair_keys[slot] = key;
                pages.pair_rules[slot] = @intCast(tailoring.rule_start + index);
                break;
            }
            if (stored == key) {
                // Duplicate pairs need the ordered matcher.
                pages.pair_rules[slot] = pair_ambiguous;
                break;
            }
            probe += 1;
        }
    }
    // A longer rule sharing the pair prefix makes the two-scalar rule
    // incomplete.
    for (0..end) |index| {
        const rule = ruleAt(tailoring.rule_start + index);
        if (rule.sequence_len <= 2) continue;
        const key = pairKey(rule.first, sequenceCodepoint(rule, 1));
        var probe = pairStart(key);
        var attempt: usize = 0;
        while (attempt < pair_probe_limit) : (attempt += 1) {
            const slot = probe & (pair_slot_count - 1);
            const stored = pages.pair_keys[slot];
            if (stored == 0) break;
            if (stored == key) {
                pages.pair_rules[slot] = pair_ambiguous;
                break;
            }
            probe += 1;
        }
    }
    pages.ascii_untailored = for (0..128) |codepoint| {
        if (pages.single_rules[codepoint] != 0) break false;
    } else true;
}

/// Last page index handed out per thread. Module-level collation entry
/// points resolve the same tailoring on every call, so the slot scan and
/// its acquire loads are skipped for repeated keys.
threadlocal var cached_index: ?struct {
    rule_start: u32,
    rule_count: u32,
    pages: ?*PageIndex,
} = null;

/// Return (building on first use) the page index for this tailoring.
pub fn pageIndex(tailoring: Tailoring) ?*PageIndex {
    // Page offsets are 16-bit; very large tailorings (Chinese stroke) keep
    // the plain binary search instead.
    if (tailoring.rule_count > 0xFFFF) return null;
    if (cached_index) |entry| {
        if (entry.rule_start == tailoring.rule_start and
            entry.rule_count == tailoring.rule_count)
        {
            return entry.pages;
        }
    }
    for (&index_slots) |*slot| {
        if (slot.state.load(.acquire) == 2 and
            slot.rule_start == tailoring.rule_start and
            slot.rule_count == tailoring.rule_count)
        {
            cached_index = .{
                .rule_start = tailoring.rule_start,
                .rule_count = tailoring.rule_count,
                .pages = &slot.pages,
            };
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
    cached_index = .{
        .rule_start = tailoring.rule_start,
        .rule_count = tailoring.rule_count,
        .pages = &slot.pages,
    };
    return &slot.pages;
}

fn lowerBound(start: usize, end: usize, first: u21) usize {
    var low = start;
    var high = end;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const rule = ruleAt(middle);
        if (rule.first < first) low = middle + 1 else high = middle;
    }
    return low;
}

/// True when a rule starting with `first` and continuing with `second`
/// exists, so a contraction can consume the following code point.
pub fn longerRuleMatches(
    tailoring: Tailoring,
    pages: ?*PageIndex,
    first: u21,
    second: u21,
) bool {
    const end = tailoring.rule_start + tailoring.rule_count;
    const start = if (pages) |page_index| blk: {
        const page: usize = @as(usize, first) >> 8;
        const low = tailoring.rule_start + page_index.rules[page];
        if (first < direct_limit) {
            const offset = page_index.direct[first];
            if (offset == direct_absent) return false;
            break :blk low + offset;
        }
        const high = if (page + 1 < 0x1100)
            tailoring.rule_start + page_index.rules[page + 1]
        else
            end;
        break :blk lowerBound(low, high, first);
    } else lowerBound(tailoring.rule_start, end, first);

    var index = start;
    while (index < end) : (index += 1) {
        const rule = ruleAt(index);
        if (rule.first != first) break;
        if (rule.sequence_len > 1 and sequenceCodepoint(rule, 1) == second) {
            return true;
        }
    }
    return false;
}

/// True when a rule with this first code point has more than one code
/// point, so a single-character key is not context independent.
pub fn startsLongerRule(
    tailoring: Tailoring,
    pages: ?*PageIndex,
    codepoint: u21,
) bool {
    const end = tailoring.rule_start + tailoring.rule_count;
    const start = if (pages) |page_index| blk: {
        const page: usize = @as(usize, codepoint) >> 8;
        const low = tailoring.rule_start + page_index.rules[page];
        if (codepoint < direct_limit) {
            const offset = page_index.direct[codepoint];
            if (offset == direct_absent) return false;
            break :blk low + offset;
        }
        const high = if (page + 1 < 0x1100)
            tailoring.rule_start + page_index.rules[page + 1]
        else
            end;
        break :blk lowerBound(low, high, codepoint);
    } else lowerBound(tailoring.rule_start, end, codepoint);

    var index = start;
    while (index < end) : (index += 1) {
        const rule = ruleAt(index);
        if (rule.first != codepoint) break;
        if (rule.sequence_len > 1) return true;
    }
    return false;
}

pub fn match(
    tailoring: Tailoring,
    pages: ?*PageIndex,
    codepoints: []const u21,
    index: usize,
) ?Match {
    const first = codepoints[index];
    const end = tailoring.rule_start + tailoring.rule_count;
    const start = if (pages) |page_index| blk: {
        const page: usize = @as(usize, first) >> 8;
        if (first < direct_limit) {
            // The direct table is populated for every low code point, so
            // probing the hash cache here could never hit.
            const offset = page_index.direct[first];
            if (offset == direct_absent) return null;
            break :blk tailoring.rule_start + page_index.rules[page] + offset;
        }
        const hash: usize = (@as(u32, first) *% 0x9E3779B1) >> 24;
        const cached = page_index.cache[hash].load(.monotonic);
        if (@as(u32, @truncate(cached >> 32)) == first) {
            const offset: u32 = @truncate(cached);
            if (offset != 0) break :blk tailoring.rule_start + (offset - 1);
        }
        const low = tailoring.rule_start + page_index.rules[page];
        const high = if (page + 1 < 0x1100)
            tailoring.rule_start + page_index.rules[page + 1]
        else
            end;
        const found = lowerBound(low, high, first);
        if (found < high and ruleAt(found).first == first) {
            page_index.cache[hash].store(
                (@as(u64, first) << 32) |
                    (@as(u64, found - tailoring.rule_start) + 1),
                .monotonic,
            );
        }
        break :blk found;
    } else lowerBound(
        tailoring.rule_start,
        end,
        first,
    );
    var rule_index = start;
    while (rule_index < end) : (rule_index += 1) {
        const rule = ruleAt(rule_index);
        if (rule.first != first) break;
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

test "locale default collation types" {
    const testing = @import("std").testing;

    try testing.expectEqualStrings(
        "pinyin",
        find("zh", "standard").?.collation_type,
    );
    try testing.expectEqualStrings(
        "pinyin",
        find("zh-Hans", "standard").?.collation_type,
    );
    try testing.expectEqualStrings(
        "stroke",
        find("zh-Hant", "standard").?.collation_type,
    );
    try testing.expectEqualStrings(
        "stroke",
        find("zh-TW", "standard").?.collation_type,
    );
    try testing.expectEqualStrings(
        "pinyin",
        find("zh-CN", "standard").?.collation_type,
    );
    // An explicit collation type still wins over the default.
    try testing.expectEqualStrings(
        "zhuyin",
        find("zh", "zhuyin").?.collation_type,
    );
    try testing.expectEqualStrings(
        "stroke",
        find("zh", "stroke").?.collation_type,
    );
}

test "pair rules agree with the ordered matcher" {
    const testing = @import("std").testing;

    var checked: usize = 0;
    var pages: PageIndex = undefined;
    for (0..locale_count) |locale_index| {
        const record = localeAt(locale_index);
        const tailoring = Tailoring{
            .locale = "",
            .collation_type = "",
            .rule_start = record.rule_start,
            .rule_count = record.rule_count,
            .case_first = .off,
            .backwards = false,
            .reorder = null,
        };
        // Page offsets are 16-bit, so very large tailorings keep the plain
        // binary search and never build a page index.
        if (tailoring.rule_count > 0xFFFF) continue;
        buildPageIndex(tailoring, &pages);
        var index: usize = tailoring.rule_start;
        const end = tailoring.rule_start + tailoring.rule_count;
        while (index < end) : (index += 1) {
            const rule = ruleAt(index);
            if (rule.sequence_len == 1) continue;
            const second = sequenceCodepoint(rule, 1);
            const pair = pairRule(&pages, rule.first, second);
            if (rule.sequence_len > 2) {
                // A longer rule sharing the pair prefix must fall back to
                // the ordered matcher.
                try testing.expect(pair == null);
                continue;
            }
            const sequence = [2]u21{ rule.first, second };
            const matched = match(tailoring, &pages, &sequence, 0).?;
            if (pair) |found| {
                // The pair table may only answer when the matcher would
                // return the same two-scalar rule.
                try testing.expectEqual(@as(usize, 2), matched.length);
                try testing.expectEqual(
                    matched.rule.sequence_offset,
                    found.sequence_offset,
                );
                try testing.expectEqual(
                    matched.rule.ce_offset,
                    found.ce_offset,
                );
                try testing.expectEqual(matched.rule.ce_count, found.ce_count);
                checked += 1;
            }
        }
    }
    try testing.expect(checked > 0);
}

test "tailoring rules are sorted by first code point" {
    const testing = @import("std").testing;

    const tailoring = lookup("sv", "standard").?;
    var previous: u21 = 0;
    var index: usize = tailoring.rule_start;
    const end = tailoring.rule_start + tailoring.rule_count;
    while (index < end) : (index += 1) {
        const first = ruleAt(index).first;
        try testing.expect(first >= previous);
        previous = first;
    }
}
