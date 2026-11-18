//! CLDR 48 root collation (UTS #10 / UTS #35) with UCA 17.0.0 implicit weights.
//!
//! Input is normalized to NFD before lookup. Explicit DUCET entries, including
//! contractions, are used first; code points without an entry receive the
//! standard implicit weights. Root weights carry twelve low bits reserved for
//! locale tailorings. Sort keys are sequences of `u32` weights with zero
//! separators between levels, so comparison is lexicographic.

const std = @import("std");
const implicit = @import("implicit.zig");
const tailorings = @import("tailorings.zig");
const normalization = @import("../normalization/root.zig");
const properties = @import("../properties.zig");
const scalar = @import("../scalar/root.zig");
const combining_class = @import("../canonical/combining_class.zig");

pub const uca_version = [3]u8{ 17, 0, 0 };
pub const cldr_version = "48";

pub const Strength = enum { primary, secondary, tertiary, quaternary };
pub const VariableWeighting = enum { non_ignorable, shifted };
pub const CaseFirst = tailorings.CaseFirst;

pub const Options = struct {
    strength: Strength = .tertiary,
    variable_weighting: VariableWeighting = .non_ignorable,
    /// BCP 47 locale tag. When a CLDR tailoring exists it is applied before
    /// the root collation; otherwise the root order is used.
    locale: ?[]const u8 = null,
    /// CLDR collation type such as `standard`, `search`, `phonebook`,
    /// `traditional`, `stroke`, or `zhuyin`. Unknown types fall back to the
    /// locale's standard tailoring.
    collation: []const u8 = "standard",
    /// Overrides the locale tailoring's `caseFirst` setting. `null` uses the
    /// tailoring setting (default `off`, which orders lowercase first).
    case_first: ?CaseFirst = null,
    /// Overrides the locale tailoring's backwards-secondary setting (French
    /// style accent ordering). `null` uses the tailoring setting.
    backwards_secondary: ?bool = null,
};

const data = @embedFile("data.bin");
const header_len = 20;
const index_count = readU16(8);
const page_count = readU16(10);
const entry_count = readU32(12);
const ce_count = readU32(16);
const index_offset = header_len;
const pages_offset = index_offset + @as(usize, index_count) * 2;
const entries_offset = pages_offset + @as(usize, page_count) * 256 * 2;
const ces_offset = entries_offset + @as(usize, entry_count) * 20;

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJCL") or
        data[4] != 2 or data[5] != 17 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid UCA collation data");
    }
    if (index_count != 0x1100 or
        ces_offset + @as(usize, ce_count) * 16 != data.len)
    {
        @compileError("invalid UCA collation data lengths");
    }
}

const CollationElement = struct {
    primary: u32,
    secondary: u32,
    tertiary: u32,
    variable: bool,
};

const WeightedElement = struct {
    primary: u32,
    secondary: u32,
    tertiary: u32,
    quaternary: u32,
};

const Entry = struct {
    first: u21,
    second: u21,
    third: u21,
    ce_offset: u32,
    ce_count: u8,
    len: u8,
};

fn entryAt(index: usize) Entry {
    const base = entries_offset + index * 20;
    return .{
        .first = @intCast(readU32(base)),
        .second = @intCast(readU32(base + 4)),
        .third = @intCast(readU32(base + 8)),
        .ce_offset = readU32(base + 12),
        .ce_count = data[base + 16],
        .len = data[base + 17],
    };
}

fn ceAt(index: usize) CollationElement {
    const base = ces_offset + index * 16;
    return .{
        .primary = readU32(base),
        .secondary = readU32(base + 4),
        .tertiary = readU32(base + 8),
        .variable = data[base + 12] != 0,
    };
}

fn pageStart(codepoint: u21) usize {
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(index_offset + page * 2);
    return readU16(
        pages_offset + (@as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)) * 2,
    );
}

/// Return an allocator-owned sort key for UTF-8 text.
pub fn sortKeyAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) error{ InvalidUtf8, OutOfMemory }![]u32 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, text.len);

    var cursor: usize = 0;
    while (scalar.decodeValid(text, cursor)) |decoded| {
        try codepoints.append(allocator, decoded.codepoint);
        cursor = decoded.next;
    }

    var key = std.ArrayList(u32).empty;
    errdefer key.deinit(allocator);
    try sortKeyCodepointsInto(allocator, codepoints.items, options, &key);
    return key.toOwnedSlice(allocator);
}

/// Append a sort key for a code-point slice to `output`.
pub fn sortKeyCodepointsInto(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    options: Options,
    output: *std.ArrayList(u32),
) error{OutOfMemory}!void {
    output.clearRetainingCapacity();

    const normalized = try normalization.normalizeCodepointsAlloc(
        allocator,
        codepoints,
        .nfd,
    );
    defer if (normalized) |owned| allocator.free(owned);
    const source = normalized orelse codepoints;
    const locale_tailoring = if (options.locale) |locale|
        tailorings.find(locale, options.collation)
    else
        null;
    const reorder = if (locale_tailoring) |tailoring| tailoring.reorder else null;

    var ces = std.ArrayList(CollationElement).empty;
    defer ces.deinit(allocator);
    try ces.ensureTotalCapacity(allocator, source.len * 2 + 8);

    var index: usize = 0;
    while (index < source.len) {
        if (locale_tailoring) |tailoring| {
            if (tailorings.match(tailoring, source, index)) |matched| {
                try appendTailored(allocator, &ces, matched.rule);
                index += matched.length;
                continue;
            }
        }
        index += try appendElements(allocator, &ces, source, index, reorder);
    }

    const shifted = options.variable_weighting == .shifted;
    const elements = try allocator.alloc(WeightedElement, ces.items.len);
    defer allocator.free(elements);
    transform(ces.items, elements, shifted);

    const case_first = options.case_first orelse
        (if (locale_tailoring) |tailoring| tailoring.case_first else .off);
    const backwards = options.backwards_secondary orelse
        (if (locale_tailoring) |tailoring| tailoring.backwards else false);
    if (case_first == .upper) applyCaseFirstUpper(elements);

    try appendLevel(allocator, output, elements, .primary);
    if (options.strength == .primary) return;

    if (backwards) {
        try appendSecondaryLevelBackwards(allocator, output, elements);
    } else {
        try appendLevel(allocator, output, elements, .secondary);
    }
    if (options.strength == .secondary) return;

    try appendLevel(allocator, output, elements, .tertiary);
    if (options.strength == .tertiary) return;

    if (shifted) {
        try appendLevel(allocator, output, elements, .quaternary);
    } else {
        try output.append(allocator, 0);
    }
}

/// Compare two UTF-8 strings under the requested collation options.
pub fn compare(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    options: Options,
) error{ InvalidUtf8, OutOfMemory }!std.math.Order {
    const key_a = try sortKeyAlloc(allocator, a, options);
    defer allocator.free(key_a);
    const key_b = try sortKeyAlloc(allocator, b, options);
    defer allocator.free(key_b);
    return std.mem.order(u32, key_a, key_b);
}

const EntryMatch = struct {
    entry: Entry,
    length: usize,
};

fn findContiguous(codepoints: []const u21, index: usize) ?EntryMatch {
    const first = codepoints[index];
    var entry_index = pageStart(first);
    while (entry_index < @as(usize, entry_count)) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.first != first) break;

        const length = @as(usize, entry.len);
        if (length > codepoints.len - index) continue;
        if (length > 1 and entry.second != codepoints[index + 1]) continue;
        if (length > 2 and entry.third != codepoints[index + 2]) continue;
        return .{ .entry = entry, .length = length };
    }
    return null;
}

fn findEntryExact(sequence: []const u21) ?Entry {
    const first = sequence[0];
    var entry_index = pageStart(first);
    while (entry_index < @as(usize, entry_count)) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.first != first) break;
        if (entry.len != sequence.len) continue;
        if (sequence.len > 1 and entry.second != sequence[1]) continue;
        if (sequence.len > 2 and entry.third != sequence[2]) continue;
        return entry;
    }
    return null;
}

fn reorderPrimary(map: tailorings.Reorder, primary: u32) u32 {
    if (primary == 0 or primary >= 0xFFFD000) return primary;
    var low: usize = 0;
    var high = map.groupCount();
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (map.oldStart(middle) <= primary) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == 0) return primary;
    const index = low - 1;
    if (primary >= map.oldEnd(index)) return primary;
    return map.newBase(index) + (primary - map.oldStart(index));
}

fn appendEntry(
    allocator: std.mem.Allocator,
    ces: *std.ArrayList(CollationElement),
    entry: Entry,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!void {
    var last_group_primary: u32 = 0;
    var ce_index: usize = 0;
    while (ce_index < @as(usize, entry.ce_count)) : (ce_index += 1) {
        const element = ceAt(@as(usize, entry.ce_offset) + ce_index);
        var primary = element.primary;
        if (reorder) |map| {
            if (primary >= 0xFFFD000) {
                // Reserved and trailing weights are never reordered.
                last_group_primary = 0;
            } else if (primary != 0) {
                if (primary >= 0x8000000 and primary < 0xFB40000 and
                    last_group_primary >= 0xFB40000)
                {
                    // Implicit continuation of the preceding Han/unassigned CE.
                    primary = map.contBase() + (primary - 0x8000000);
                } else {
                    primary = reorderPrimary(map, primary);
                    last_group_primary = element.primary;
                }
            }
        }
        try ces.append(allocator, .{
            .primary = primary,
            .secondary = element.secondary,
            .tertiary = element.tertiary,
            .variable = element.variable,
        });
    }
}

fn appendTailored(
    allocator: std.mem.Allocator,
    ces: *std.ArrayList(CollationElement),
    rule: tailorings.Rule,
) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < @as(usize, rule.ce_count)) : (index += 1) {
        const element = tailorings.elementAt(rule, index);
        try ces.append(allocator, .{
            .primary = element.primary,
            .secondary = element.secondary,
            .tertiary = element.tertiary,
            .variable = element.variable,
        });
    }
}

fn appendImplicit(
    allocator: std.mem.Allocator,
    ces: *std.ArrayList(CollationElement),
    codepoint: u21,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!void {
    const weights = implicitWeights(codepoint);
    var first = weights[0];
    var second = weights[1];
    if (reorder) |map| {
        const group = if (properties.isUnifiedIdeograph(codepoint))
            map.haniGroup()
        else
            map.othersGroup();
        if (group < map.groupCount()) {
            const old_start = map.oldStart(group);
            if (first >= old_start) {
                first = map.newBase(group) + (first - old_start);
            }
        }
        second = map.contBase() + (second - 0x8000000);
    }
    try ces.append(allocator, .{
        .primary = first,
        .secondary = 0x20000,
        .tertiary = 0x02000,
        .variable = false,
    });
    try ces.append(allocator, .{
        .primary = second,
        .secondary = 0,
        .tertiary = 0,
        .variable = false,
    });
}

fn appendSingle(
    allocator: std.mem.Allocator,
    ces: *std.ArrayList(CollationElement),
    codepoint: u21,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!void {
    const sequence = [_]u21{codepoint};
    if (findEntryExact(&sequence)) |entry| {
        return appendEntry(allocator, ces, entry, reorder);
    }
    return appendImplicit(allocator, ces, codepoint, reorder);
}

fn appendElements(
    allocator: std.mem.Allocator,
    ces: *std.ArrayList(CollationElement),
    codepoints: []const u21,
    index: usize,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!usize {
    var sequence: [3]u21 = .{ codepoints[index], 0, 0 };
    var length: usize = 1;
    var entry: ?Entry = null;

    if (findContiguous(codepoints, index)) |matched| {
        entry = matched.entry;
        length = matched.length;
        if (length > 1) sequence[1] = codepoints[index + 1];
        if (length > 2) sequence[2] = codepoints[index + 2];
    }

    // S2.1.1-S2.1.3: extend the initial match with unblocked following
    // non-starters, which handles discontiguous contractions. Skipped
    // non-starters are emitted after the contraction's collation elements.
    var skipped = std.ArrayList(u21).empty;
    defer skipped.deinit(allocator);

    var cursor = index + length;
    while (cursor < codepoints.len) {
        const candidate = codepoints[cursor];
        const candidate_class = combining_class.forCodepoint(candidate);
        if (candidate_class == 0) break;

        var blocked = false;
        for (skipped.items) |skipped_codepoint| {
            if (combining_class.forCodepoint(skipped_codepoint) >=
                candidate_class)
            {
                blocked = true;
                break;
            }
        }

        if (!blocked and length < sequence.len) {
            sequence[length] = candidate;
            if (findEntryExact(sequence[0 .. length + 1])) |extended| {
                entry = extended;
                length += 1;
                cursor += 1;
                continue;
            }
        }

        try skipped.append(allocator, candidate);
        cursor += 1;
    }

    if (entry) |matched| {
        try appendEntry(allocator, ces, matched, reorder);
    } else {
        try appendImplicit(allocator, ces, sequence[0], reorder);
    }
    var skipped_offset: usize = 0;
    while (skipped_offset < skipped.items.len) {
        skipped_offset += try appendElements(
            allocator,
            ces,
            skipped.items,
            skipped_offset,
            reorder,
        );
    }
    return cursor - index;
}

fn implicitWeights(codepoint: u21) [2]u32 {
    if (properties.category(codepoint) != .Cn) {
        for (implicit.ranges) |range| {
            if (codepoint < range.first or codepoint > range.last) continue;
            const bbbb: u32 = @as(u32, codepoint) - @as(u32, range.origin);
            return .{
                range.base,
                ((bbbb | 0x8000) << 12),
            };
        }
    }

    if (properties.isUnifiedIdeograph(codepoint)) {
        const core = (codepoint >= 0x4e00 and codepoint <= 0x9fff) or
            (codepoint >= 0xf900 and codepoint <= 0xfaff);
        const base: u32 = if (core) 0xFB40 else 0xFB80;
        return .{
            (base + @as(u32, codepoint >> 15)) << 12,
            ((@as(u32, codepoint) & 0x7fff) | 0x8000) << 12,
        };
    }

    return .{
        (0xFBC0 + @as(u32, codepoint >> 15)) << 12,
        ((@as(u32, codepoint) & 0x7fff) | 0x8000) << 12,
    };
}

fn transform(
    source: []const CollationElement,
    destination: []WeightedElement,
    shifted: bool,
) void {
    var after_variable = false;
    for (source, destination) |element, *out| {
        if (!shifted) {
            out.* = .{
                .primary = element.primary,
                .secondary = element.secondary,
                .tertiary = element.tertiary,
                .quaternary = 0,
            };
            continue;
        }

        if (element.variable) {
            out.* = .{
                .primary = 0,
                .secondary = 0,
                .tertiary = 0,
                .quaternary = element.primary,
            };
            after_variable = true;
            continue;
        }

        if (element.primary == 0) {
            if (after_variable or
                (element.secondary == 0 and element.tertiary == 0))
            {
                out.* = .{
                    .primary = 0,
                    .secondary = 0,
                    .tertiary = 0,
                    .quaternary = 0,
                };
            } else {
                out.* = .{
                    .primary = 0,
                    .secondary = element.secondary,
                    .tertiary = element.tertiary,
                    .quaternary = 0xFFFFFFFF,
                };
            }
            continue;
        }

        out.* = .{
            .primary = element.primary,
            .secondary = element.secondary,
            .tertiary = element.tertiary,
            .quaternary = 0xFFFFFFFF,
        };
        after_variable = false;
    }
}

const Level = enum { primary, secondary, tertiary, quaternary };

fn appendLevel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const WeightedElement,
    level: Level,
) error{OutOfMemory}!void {
    for (elements) |element| {
        const weight = switch (level) {
            .primary => element.primary,
            .secondary => element.secondary,
            .tertiary => element.tertiary,
            .quaternary => element.quaternary,
        };
        if (weight != 0) try output.append(allocator, weight);
    }
    try output.append(allocator, 0);
}

/// Tertiary weights with the UCA uppercase case bits (see UTS #35, Case
/// Parameters). The root table has no mixed-case tertiary values.
fn isUpperCaseTertiary(tertiary: u32) bool {
    return switch (tertiary >> 12) {
        0x08...0x0C, 0x0E, 0x11, 0x12, 0x1D => true,
        else => false,
    };
}

/// `caseFirst=upper`: uppercase sorts before lowercase at the tertiary level.
/// The case class becomes the high part of the tertiary weight so that
/// variants within a class keep their relative order.
fn applyCaseFirstUpper(elements: []WeightedElement) void {
    for (elements) |*element| {
        if (element.tertiary == 0) continue;
        if (element.primary == 0 and element.secondary == 0) {
            // Tertiary-only CEs must stay greater than the tertiary weights of
            // primary and secondary CEs (UTS #10 WF2).
            element.tertiary += 3 << 24;
            continue;
        }
        const rank: u32 = if (isUpperCaseTertiary(element.tertiary)) 0 else 2;
        element.tertiary += rank << 24;
    }
}

/// French secondary ordering: compare secondary weights from the end of the
/// string. ICU delimits reversal segments with U+FFFE (the merge separator);
/// for normal text this is a whole-string reversal.
fn appendSecondaryLevelBackwards(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const WeightedElement,
) error{OutOfMemory}!void {
    var index = elements.len;
    while (index > 0) {
        index -= 1;
        if (elements[index].secondary != 0) {
            try output.append(allocator, elements[index].secondary);
        }
    }
    try output.append(allocator, 0);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

test "basic collation ordering" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const options = Options{};

    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "b", options),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "A", options),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "\u{00e1}", options),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "\u{00e4}", "a", options),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a", "a", options),
    );
}

test "locale collation tailorings" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const sv = Options{ .locale = "sv" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "z", "\u{00e5}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "\u{00e4}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e4}", "\u{00f6}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "\u{00c5}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00c5}", "\u{00e4}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "z",
            "\u{00e5}",
            .{ .locale = "sv-SE" },
        ),
    );

    const da = Options{ .locale = "da" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "z", "\u{00e6}", da),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e6}", "\u{00f8}", da),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00f8}", "\u{00e5}", da),
    );

    const no = Options{ .locale = "no" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00f8}", "\u{00e5}", no),
    );

    const es = Options{ .locale = "es" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "n", "\u{00f1}", es),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00f1}", "o", es),
    );

    const tr = Options{ .locale = "tr" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "h", "\u{0131}", tr),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{0131}", "i", tr),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "i", "j", tr),
    );

    const cs = Options{ .locale = "cs" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "c", "\u{010d}", cs),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{010d}", "d", cs),
    );

    const fi = Options{ .locale = "fi" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "z", "\u{00e5}", fi),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "\u{00e4}", fi),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e4}", "\u{00f6}", fi),
    );

    // Unknown locales and root requests keep the root order.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "z", .{}),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "z", .{ .locale = "zz" }),
    );
}

test "caseFirst and backwards secondary" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // The root order is lowercase-first.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "A", .{}),
    );

    // Danish standard collation requests caseFirst=upper.
    const da = Options{ .locale = "da" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "A", "a", da),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "A", "\u{00e1}", da),
    );
    // Tailored letters carry the case bits of their source strings.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{0110}", "\u{0111}", da),
    );
    // An explicit option overrides the locale setting.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "a",
            "A",
            .{ .locale = "da", .case_first = .lower },
        ),
    );

    // fr-CA uses backwards secondary ordering: accents are compared from the
    // end of the string, so côte sorts before coté.
    const fr_ca = Options{ .locale = "fr-CA" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "cote", "c\u{00f4}te", fr_ca),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "c\u{00f4}te", "cot\u{00e9}", fr_ca),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "cot\u{00e9}", "c\u{00f4}t\u{00e9}", fr_ca),
    );
    // Forward secondary ordering keeps the accent-on-o word last.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "cot\u{00e9}", "c\u{00f4}te", .{}),
    );
    // French France uses the root order, not the Canadian reversal.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "cot\u{00e9}",
            "c\u{00f4}te",
            .{ .locale = "fr" },
        ),
    );
}

test "script reordering" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const lt = std.math.Order.lt;

    // Root order: Latin before Greek, Cyrillic, Hebrew, Arabic, Indic, Thai,
    // and Han.
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{03b1}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{044f}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{05d0}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{0627}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{0905}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{0e01}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{6c49}", .{}));

    // Locale reordering moves the native script group first.
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{044f}", "a", .{ .locale = "ru" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{03b1}", "a", .{ .locale = "el" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{05d0}", "a", .{ .locale = "he" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{0627}", "a", .{ .locale = "ar" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{0905}", "a", .{ .locale = "hi" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{0e01}", "a", .{ .locale = "th" }),
    );
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "\u{6c49}",
            "a",
            .{ .locale = "zh", .collation = "pinyin" },
        ),
    );
    // Tailored pinyin Han weights stay inside the reordered Hani block.
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "\u{6c49}",
            "\u{5b57}",
            .{ .locale = "zh", .collation = "pinyin" },
        ),
    );
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "\u{6c49}",
            "a",
            .{ .locale = "zh", .collation = "stroke" },
        ),
    );

    // Korean: Hangul, then Han, then other groups.
    const ko = Options{ .locale = "ko" };
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{ac00}", "\u{6c49}", ko),
    );
    try testing.expectEqual(lt, try compare(allocator, "\u{6c49}", "a", ko));

    // German EOR moves digits after all other groups.
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "a",
            "1",
            .{ .locale = "de", .collation = "eor" },
        ),
    );
    try testing.expectEqual(lt, try compare(allocator, "1", "a", .{}));
}

test "collation types" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const de_phonebook = Options{
        .locale = "de",
        .collation = "phonebook",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "ae", "\u{00e4}", de_phonebook),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e4}", "af", de_phonebook),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "\u{00e4}",
            "ae",
            .{ .locale = "de" },
        ),
    );

    const es_traditional = Options{
        .locale = "es",
        .collation = "traditional",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "c", "ch", es_traditional),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "ch", "d", es_traditional),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "l", "ll", es_traditional),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "ll", "m", es_traditional),
    );

    const root_search = Options{
        .locale = "root",
        .collation = "search",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "=", "\u{2260}", root_search),
    );

    const zh_pinyin = Options{
        .locale = "zh",
        .collation = "pinyin",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{963F}", "\u{516B}", zh_pinyin),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{516B}", "\u{64E6}", zh_pinyin),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{56FD}", "\u{4E2D}", zh_pinyin),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{4E2D}", "\u{56FD}", .{}),
    );

    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "z",
            "\u{00e5}",
            .{ .locale = "sv", .collation = "no-such-type" },
        ),
    );
}

test "contractions are longer than their first code point" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const options = Options{};

    // DUCET has an explicit contraction for l + middle dot.
    const contraction = try sortKeyAlloc(allocator, "l\u{00b7}", options);
    defer allocator.free(contraction);
    const separate = try sortKeyAlloc(allocator, "l\u{00b7}x", options);
    defer allocator.free(separate);
    try testing.expect(contraction.len > 0);
    try testing.expect(separate.len > contraction.len);
}

test "shifted variable weighting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const shifted_tertiary = Options{
        .strength = .tertiary,
        .variable_weighting = .shifted,
    };
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a b", "ab", shifted_tertiary),
    );

    const shifted_quaternary = Options{
        .strength = .quaternary,
        .variable_weighting = .shifted,
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a b", "ab", shifted_quaternary),
    );
}

const non_ignorable_conformance = @embedFile("conformance_non_ignorable.bin");
const shifted_conformance = @embedFile("conformance_shifted.bin");

fn runConformance(fixture: []const u8, options: Options) !void {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    if (fixture.len < 12 or !std.mem.eql(u8, fixture[0..4], "CJCT") or
        fixture[4] != 1 or fixture[5] != 17 or fixture[6] != 0 or fixture[7] != 0)
    {
        return error.InvalidFixture;
    }

    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    // The fixtures contain the full CLDR root short suites. The default
    // sampled run keeps `zig build test` fast; set this to true for a full
    // conformance pass.
    const full_conformance = false;
    const stride: usize = if (full_conformance) 1 else 16;

    var offset: usize = 12;
    var previous = std.ArrayList(u32).empty;
    defer previous.deinit(allocator);
    var current = std.ArrayList(u32).empty;
    defer current.deinit(allocator);
    var codepoints: [256]u21 = undefined;
    var sampled: usize = 0;

    for (0..case_count) |case_index| {
        if (offset >= fixture.len) return error.InvalidFixture;
        const length = fixture[offset];
        offset += 1;
        if (length > codepoints.len or
            offset + @as(usize, length) * 4 > fixture.len)
        {
            return error.InvalidFixture;
        }
        for (0..length) |index| {
            codepoints[index] = @intCast(std.mem.readInt(
                u32,
                fixture[offset..][0..4],
                .little,
            ));
            offset += 4;
        }
        if (case_index % stride != 0) continue;

        try sortKeyCodepointsInto(
            allocator,
            codepoints[0..length],
            options,
            &current,
        );
        if (sampled > 0 and
            std.mem.order(u32, previous.items, current.items) == .gt)
        {
            std.debug.print(
                "collation conformance failure at case {d}: {any} > {any}\n",
                .{ case_index, previous.items, current.items },
            );
            return error.TestUnexpectedResult;
        }
        sampled += 1;
        std.mem.swap(std.ArrayList(u32), &previous, &current);
    }
    if (offset != fixture.len) return error.InvalidFixture;
}

test "CLDR 48 non-ignorable conformance" {
    try runConformance(
        non_ignorable_conformance,
        .{ .strength = .tertiary, .variable_weighting = .non_ignorable },
    );
}

test "CLDR 48 shifted conformance" {
    try runConformance(
        shifted_conformance,
        .{ .strength = .quaternary, .variable_weighting = .shifted },
    );
}
