//! BCP 47 locale tag canonicalization.
//!
//! Canonicalizes case and separators, applies the CLDR language, script,
//! territory, and variant aliases as language-script-region-variant
//! replacement rules (including multi-field replacements, wildcard rules,
//! and multi-step chains), sorts variants, and keeps extension and
//! private-use subtags. The rule set and ordering match CLDR's reference
//! canonicalizer. BCP 47 key/type aliases inside extensions are not applied.

const std = @import("std");

const alias_blob = @embedFile("locale/aliases.bin");
const conformance_blob = @embedFile("locale/canonicalization_conformance.bin");

pub const Error = error{ InvalidLocale, OutOfMemory };

const alias_header_len = 36;
const rule_len = 4 + 9 * 3;
const max_variants = 16;
const max_rule_iterations = 32;
const candidate_capacity = 96;

const slot_type_language = 0;
const slot_type_script = 1;
const slot_type_region = 2;
const slot_type_variant0 = 3;
const slot_type_variant1 = 4;
const slot_repl_language = 5;
const slot_repl_script = 6;
const slot_repl_region = 7;
const slot_repl_variant0 = 8;

const rule_count = readU16(alias_blob, 8);
const language_index_offset = readU32(alias_blob, 12);
const script_index_offset = readU32(alias_blob, 16);
const region_index_offset = readU32(alias_blob, 20);
const variant_index_offset = readU32(alias_blob, 24);
const rules_offset = readU32(alias_blob, 28);
const pool_offset = readU32(alias_blob, 32);

comptime {
    if (alias_blob.len < alias_header_len or
        !std.mem.eql(u8, alias_blob[0..4], "CJLX") or
        alias_blob[4] != 2)
    {
        @compileError("invalid locale alias data");
    }
    if (rule_count == 0 or
        rules_offset + @as(usize, rule_count) * rule_len > alias_blob.len or
        pool_offset > alias_blob.len or
        variant_index_offset > rules_offset)
    {
        @compileError("invalid locale alias data layout");
    }
    if (conformance_blob.len < 12 or
        !std.mem.eql(u8, conformance_blob[0..4], "CJLY") or
        conformance_blob[4] != 1)
    {
        @compileError("invalid locale conformance data");
    }
}

fn readU16(blob: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(blob: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn ruleSlot(ordinal: usize, slot: usize) []const u8 {
    const base = rules_offset + ordinal * rule_len + 4 + slot * 3;
    const offset = readU16(alias_blob, base);
    const length = alias_blob[base + 2];
    return alias_blob[pool_offset + offset ..][0..length];
}

const IndexEntry = struct {
    key_offset: u16,
    key_len: u8,
    start: u16,
    count: u16,
};

fn indexEntryCount(index_offset: usize) usize {
    return readU16(alias_blob, index_offset);
}

fn indexEntry(index_offset: usize, entry: usize) IndexEntry {
    const base = index_offset + 4 + entry * 8;
    return .{
        .key_offset = readU16(alias_blob, base),
        .key_len = alias_blob[base + 2],
        .start = readU16(alias_blob, base + 4),
        .count = readU16(alias_blob, base + 6),
    };
}

const IndexRange = struct { start: usize, count: usize };

fn lookupIndex(index_offset: usize, key: []const u8) ?IndexRange {
    var low: usize = 0;
    var high = indexEntryCount(index_offset);
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = indexEntry(index_offset, middle);
        const entry_key = alias_blob[pool_offset + entry.key_offset ..][0..entry.key_len];
        switch (std.mem.order(u8, entry_key, key)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return .{ .start = entry.start, .count = entry.count },
        }
    }
    return null;
}

fn indexOrdinal(index_offset: usize, ordinal: usize) u16 {
    const base = index_offset + 4 + indexEntryCount(index_offset) * 8;
    return readU16(alias_blob, base + ordinal * 2);
}

const CandidateBuffer = struct {
    items: [candidate_capacity]u16 = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn add(self: *CandidateBuffer, ordinal: u16) void {
        if (self.len == self.items.len) {
            self.overflow = true;
            return;
        }
        self.items[self.len] = ordinal;
        self.len += 1;
    }
};

fn gatherIndex(buffer: *CandidateBuffer, index_offset: usize, key: []const u8) void {
    const range = lookupIndex(index_offset, key) orelse return;
    for (range.start..range.start + range.count) |ordinal| {
        buffer.add(indexOrdinal(index_offset, ordinal));
    }
}

fn gatherCandidates(tag: *const Tag, buffer: *CandidateBuffer) void {
    gatherIndex(buffer, language_index_offset, tag.language);
    if (tag.script.len != 0) {
        gatherIndex(buffer, script_index_offset, tag.script);
    }
    if (tag.region.len != 0) {
        gatherIndex(buffer, region_index_offset, tag.region);
    }
    for (tag.variants[0..tag.variant_count]) |variant| {
        gatherIndex(buffer, variant_index_offset, variant);
    }
}

fn sortUnique(items: []u16) usize {
    var length: usize = 0;
    for (items) |value| {
        var insert: usize = 0;
        while (insert < length and items[insert] < value) : (insert += 1) {}
        if (insert < length and items[insert] == value) continue;
        var index = length;
        while (index > insert) : (index -= 1) {
            items[index] = items[index - 1];
        }
        items[insert] = value;
        length += 1;
    }
    return length;
}

const Tag = struct {
    language: []const u8,
    script: []const u8,
    region: []const u8,
    variants: [max_variants][]const u8 = undefined,
    variant_count: usize = 0,
    /// Extension and private-use subtags, starting at the first singleton.
    tail: []const u8 = "",
};

fn isAlpha(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isAlphabetic(byte)) return false;
    }
    return text.len != 0;
}

fn isDigitText(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return text.len != 0;
}

fn isVariant(text: []const u8) bool {
    if (text.len >= 5 and text.len <= 8) {
        for (text) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) return false;
        }
        return true;
    }
    if (text.len == 4 and std.ascii.isDigit(text[0])) {
        for (text) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) return false;
        }
        return true;
    }
    return false;
}

fn hasVariant(tag: *const Tag, variant: []const u8) bool {
    for (tag.variants[0..tag.variant_count]) |existing| {
        if (std.mem.eql(u8, existing, variant)) return true;
    }
    return false;
}

fn parseTag(tag: []const u8) Error!Tag {
    var parsed = Tag{ .language = "", .script = "", .region = "" };
    var index: usize = 0;
    var first = true;
    while (index < tag.len) {
        const start = index;
        while (index < tag.len and tag[index] != '-' and tag[index] != '_') {
            index += 1;
        }
        const subtag = tag[start..index];
        if (index < tag.len) index += 1;
        if (subtag.len == 0) return error.InvalidLocale;
        if (first) {
            if (subtag.len < 2 or subtag.len > 8 or !isAlpha(subtag)) {
                return error.InvalidLocale;
            }
            parsed.language = subtag;
            first = false;
            continue;
        }
        if (parsed.tail.len != 0) continue;
        if (parsed.script.len == 0 and subtag.len == 4 and isAlpha(subtag)) {
            parsed.script = subtag;
            continue;
        }
        if (parsed.region.len == 0 and
            ((subtag.len == 2 and isAlpha(subtag)) or
                (subtag.len == 3 and isDigitText(subtag))))
        {
            parsed.region = subtag;
            continue;
        }
        if (isVariant(subtag)) {
            if (hasVariant(&parsed, subtag)) continue;
            if (parsed.variant_count == parsed.variants.len) {
                return error.InvalidLocale;
            }
            parsed.variants[parsed.variant_count] = subtag;
            parsed.variant_count += 1;
            continue;
        }
        parsed.tail = tag[start..];
        break;
    }
    if (first) return error.InvalidLocale;
    return parsed;
}

fn lowerAscii(text: []u8) void {
    for (text) |*byte| byte.* = std.ascii.toLower(byte.*);
}

fn upperAscii(text: []u8) void {
    for (text) |*byte| byte.* = std.ascii.toUpper(byte.*);
}

fn titleAscii(text: []u8) void {
    if (text.len == 0) return;
    text[0] = std.ascii.toUpper(text[0]);
    for (text[1..]) |*byte| byte.* = std.ascii.toLower(byte.*);
}

fn ruleMatches(tag: *const Tag, ordinal: usize) bool {
    const type_language = ruleSlot(ordinal, slot_type_language);
    if (type_language.len != 0 and
        !std.mem.eql(u8, tag.language, type_language)) return false;
    const type_script = ruleSlot(ordinal, slot_type_script);
    if (type_script.len != 0 and
        !std.mem.eql(u8, tag.script, type_script)) return false;
    const type_region = ruleSlot(ordinal, slot_type_region);
    if (type_region.len != 0 and
        !std.mem.eql(u8, tag.region, type_region)) return false;
    const type_variant0 = ruleSlot(ordinal, slot_type_variant0);
    if (type_variant0.len != 0 and !hasVariant(tag, type_variant0)) return false;
    const type_variant1 = ruleSlot(ordinal, slot_type_variant1);
    if (type_variant1.len != 0 and !hasVariant(tag, type_variant1)) return false;
    return true;
}

fn setField(
    current: *[]const u8,
    type_value: []const u8,
    replacement: []const u8,
) bool {
    if (type_value.len != 0) {
        if (replacement.len != 0) {
            if (!std.mem.eql(u8, current.*, replacement)) {
                current.* = replacement;
                return true;
            }
        } else if (current.*.len != 0) {
            current.* = "";
            return true;
        }
        return false;
    }
    if (replacement.len != 0 and current.*.len == 0) {
        current.* = replacement;
        return true;
    }
    return false;
}

fn removeVariant(tag: *Tag, variant: []const u8) bool {
    var index: usize = 0;
    while (index < tag.variant_count) {
        if (std.mem.eql(u8, tag.variants[index], variant)) {
            var move = index;
            while (move + 1 < tag.variant_count) : (move += 1) {
                tag.variants[move] = tag.variants[move + 1];
            }
            tag.variant_count -= 1;
            return true;
        }
        index += 1;
    }
    return false;
}

fn applyVariants(
    tag: *Tag,
    type_variant0: []const u8,
    type_variant1: []const u8,
    replacement: []const u8,
) bool {
    var changed = false;
    if (type_variant0.len != 0 and removeVariant(tag, type_variant0)) {
        changed = true;
    }
    if (type_variant1.len != 0 and removeVariant(tag, type_variant1)) {
        changed = true;
    }
    if (replacement.len != 0 and !hasVariant(tag, replacement)) {
        if (tag.variant_count < tag.variants.len) {
            tag.variants[tag.variant_count] = replacement;
            tag.variant_count += 1;
            changed = true;
        }
    }
    return changed;
}

fn applyRule(tag: *Tag, ordinal: usize) bool {
    var changed = false;
    if (setField(
        &tag.language,
        ruleSlot(ordinal, slot_type_language),
        ruleSlot(ordinal, slot_repl_language),
    )) changed = true;
    if (setField(
        &tag.script,
        ruleSlot(ordinal, slot_type_script),
        ruleSlot(ordinal, slot_repl_script),
    )) changed = true;
    if (setField(
        &tag.region,
        ruleSlot(ordinal, slot_type_region),
        ruleSlot(ordinal, slot_repl_region),
    )) changed = true;
    if (applyVariants(
        tag,
        ruleSlot(ordinal, slot_type_variant0),
        ruleSlot(ordinal, slot_type_variant1),
        ruleSlot(ordinal, slot_repl_variant0),
    )) changed = true;
    return changed;
}

fn applyFirstMatching(tag: *Tag, ordinals: []const u16) bool {
    for (ordinals) |ordinal| {
        if (ruleMatches(tag, ordinal) and applyRule(tag, ordinal)) {
            return true;
        }
    }
    return false;
}

fn applyFullScan(tag: *Tag) bool {
    var ordinal: usize = 0;
    while (ordinal < rule_count) : (ordinal += 1) {
        if (ruleMatches(tag, ordinal) and applyRule(tag, ordinal)) {
            return true;
        }
    }
    return false;
}

fn applyAliases(tag: *Tag) void {
    var iteration: usize = 0;
    while (iteration < max_rule_iterations) : (iteration += 1) {
        var buffer = CandidateBuffer{};
        gatherCandidates(tag, &buffer);
        const applied = if (buffer.overflow)
            applyFullScan(tag)
        else blk: {
            const length = sortUnique(buffer.items[0..buffer.len]);
            break :blk applyFirstMatching(tag, buffer.items[0..length]);
        };
        if (!applied) return;
    }
}

fn appendLowered(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
) Error!void {
    if (text.len == 0) return;
    if (output.items.len != 0) try output.append(allocator, '-');
    for (text) |byte| {
        if (byte == '_') {
            try output.append(allocator, '-');
        } else {
            try output.append(allocator, std.ascii.toLower(byte));
        }
    }
}

pub const matcher = @import("locale/matcher.zig");
pub const bestMatchAlloc = matcher.bestMatchAlloc;
pub const localeDistanceAlloc = matcher.distanceAlloc;
pub const localeIsMatchAlloc = matcher.isMatchAlloc;

/// Canonicalize a BCP 47 locale tag.
pub fn canonicalizeAlloc(
    allocator: std.mem.Allocator,
    tag: []const u8,
) Error![]u8 {
    if (tag.len == 0 or tag.len > 128) return error.InvalidLocale;
    var buffer: [128]u8 = undefined;
    @memcpy(buffer[0..tag.len], tag);
    var parsed = try parseTag(buffer[0..tag.len]);
    lowerAscii(@constCast(parsed.language));
    if (parsed.script.len != 0) titleAscii(@constCast(parsed.script));
    if (parsed.region.len != 0) upperAscii(@constCast(parsed.region));
    for (parsed.variants[0..parsed.variant_count]) |variant| {
        lowerAscii(@constCast(variant));
    }

    applyAliases(&parsed);

    var ordered: [max_variants][]const u8 = undefined;
    @memcpy(ordered[0..parsed.variant_count], parsed.variants[0..parsed.variant_count]);
    std.mem.sort([]const u8, ordered[0..parsed.variant_count], {}, struct {
        fn lessThan(_: void, first: []const u8, second: []const u8) bool {
            return std.mem.lessThan(u8, first, second);
        }
    }.lessThan);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try appendLowered(allocator, &output, parsed.language);
    if (parsed.script.len != 0) {
        if (output.items.len != 0) try output.append(allocator, '-');
        try output.appendSlice(allocator, parsed.script);
    }
    if (parsed.region.len != 0) {
        if (output.items.len != 0) try output.append(allocator, '-');
        try output.appendSlice(allocator, parsed.region);
    }
    for (ordered[0..parsed.variant_count]) |variant| {
        try appendLowered(allocator, &output, variant);
    }
    try appendLowered(allocator, &output, parsed.tail);
    return output.toOwnedSlice(allocator);
}

/// Parsed BCP 47 language tag. Every slice borrows from the input tag.
pub const Locale = struct {
    language: []const u8 = "",
    script: []const u8 = "",
    region: []const u8 = "",
    variants: [max_variants][]const u8 = undefined,
    variant_count: usize = 0,
    /// Extension and private-use subtags starting at the first singleton.
    tail: []const u8 = "",

    pub fn parse(text: []const u8) Error!Locale {
        const tag = try parseTag(text);
        return .{
            .language = tag.language,
            .script = tag.script,
            .region = tag.region,
            .variants = tag.variants,
            .variant_count = tag.variant_count,
            .tail = tag.tail,
        };
    }

    pub fn variantCount(self: Locale) usize {
        return self.variant_count;
    }

    pub fn variantAt(self: Locale, index: usize) []const u8 {
        return self.variants[index];
    }

    /// Value of a Unicode extension keyword, for example `nu` in
    /// `en-US-u-nu-thai`. Only the `-u-` extension is searched.
    pub fn keywordValue(self: Locale, key: []const u8) ?[]const u8 {
        if (key.len != 2) return null;
        const tail = self.tail;
        var index: usize = 0;
        while (index < tail.len) {
            const start = index;
            while (index < tail.len and tail[index] != '-') index += 1;
            const singleton = tail[start..index];
            if (index < tail.len) index += 1;
            if (singleton.len != 1) continue;
            const body_start = index;
            var body_end = tail.len;
            var probe = index;
            while (probe < tail.len) {
                const sub_start = probe;
                while (probe < tail.len and tail[probe] != '-') probe += 1;
                const subtag = tail[sub_start..probe];
                if (probe < tail.len) probe += 1;
                if (subtag.len == 1) {
                    body_end = sub_start;
                    break;
                }
            }
            if (singleton[0] == 'u' or singleton[0] == 'U') {
                var cursor = body_start;
                while (cursor < body_end) {
                    const key_start = cursor;
                    while (cursor < body_end and tail[cursor] != '-') {
                        cursor += 1;
                    }
                    const candidate = tail[key_start..cursor];
                    if (cursor < body_end) cursor += 1;
                    // Three-to-eight character subtags are attributes.
                    if (candidate.len != 2) continue;
                    const value_start = cursor;
                    while (cursor < body_end and tail[cursor] != '-') {
                        cursor += 1;
                    }
                    if (std.ascii.eqlIgnoreCase(candidate, key)) {
                        return tail[value_start..cursor];
                    }
                }
            }
            index = body_end;
        }
        return null;
    }
};

test "locale tag parsing" {
    const testing = @import("std").testing;

    const tag = try Locale.parse("zh-Hant-TW-u-nu-thai-ca-gregory");
    try testing.expectEqualStrings("zh", tag.language);
    try testing.expectEqualStrings("Hant", tag.script);
    try testing.expectEqualStrings("TW", tag.region);
    try testing.expectEqual(@as(usize, 0), tag.variantCount());
    try testing.expectEqualStrings("thai", tag.keywordValue("nu").?);
    try testing.expectEqualStrings("gregory", tag.keywordValue("ca").?);
    try testing.expect(tag.keywordValue("co") == null);
    try testing.expect(tag.keywordValue("number") == null);

    const variant = try Locale.parse("de-DE-1996");
    try testing.expectEqualStrings("DE", variant.region);
    try testing.expectEqual(@as(usize, 1), variant.variantCount());
    try testing.expectEqualStrings("1996", variant.variantAt(0));

    const private_use = try Locale.parse("en-x-private");
    try testing.expectEqualStrings("en", private_use.language);
    try testing.expectEqualStrings("x-private", private_use.tail);
    try testing.expect(private_use.keywordValue("nu") == null);

    const simple = try Locale.parse("en");
    try testing.expectEqualStrings("en", simple.language);
    try testing.expectEqualStrings("", simple.script);
    try testing.expectEqualStrings("", simple.region);

    try testing.expectError(error.InvalidLocale, Locale.parse(""));
    try testing.expectError(error.InvalidLocale, Locale.parse("123"));
}

test "locale canonicalization" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "en-us", .expected = "en-US" },
        .{ .input = "EN_us", .expected = "en-US" },
        .{ .input = "iw", .expected = "he" },
        .{ .input = "in-ID", .expected = "id-ID" },
        .{ .input = "ji", .expected = "yi" },
        .{ .input = "sh", .expected = "sr-Latn" },
        .{ .input = "sh-RS", .expected = "sr-Latn-RS" },
        .{ .input = "mo", .expected = "ro" },
        .{ .input = "art-lojban", .expected = "jbo" },
        .{ .input = "en-BU", .expected = "en-MM" },
        .{ .input = "en-DD", .expected = "en-DE" },
        .{ .input = "en-TP", .expected = "en-TL" },
        .{ .input = "und-Qaai", .expected = "und-Zinh" },
        .{ .input = "zh-hant-tw", .expected = "zh-Hant-TW" },
        .{ .input = "en-u-ca-GREGORY", .expected = "en-u-ca-gregory" },
        .{ .input = "en-x-PRIVATE", .expected = "en-x-private" },
        .{ .input = "cnr", .expected = "sr-ME" },
        .{ .input = "prs", .expected = "fa-AF" },
        .{ .input = "swc", .expected = "sw-CD" },
        .{ .input = "sgn-PT", .expected = "psr" },
        .{ .input = "sgn-620", .expected = "psr" },
        .{ .input = "en-aaland", .expected = "en-AX" },
        .{ .input = "en-US-aaland", .expected = "en-US" },
        .{ .input = "zh-guoyu-hakka-xiang", .expected = "hak" },
        .{ .input = "no-bokmal-nynorsk", .expected = "nb" },
        .{ .input = "aaa-Adlm-AC-fonipa-hepburn-heploc", .expected = "aaa-Adlm-AC-alalc97-fonipa" },
        .{ .input = "sr", .expected = "sr" },
        .{ .input = "nb", .expected = "nb" },
    };
    for (cases) |case| {
        const value = try canonicalizeAlloc(allocator, case.input);
        defer allocator.free(value);
        try testing.expectEqualStrings(case.expected, value);
    }

    try testing.expectError(
        error.InvalidLocale,
        canonicalizeAlloc(allocator, ""),
    );
    try testing.expectError(
        error.InvalidLocale,
        canonicalizeAlloc(allocator, "123"),
    );
}

test "CLDR locale canonicalization conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const case_count = readU32(conformance_blob, 8);
    var offset: usize = 12;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const source_len = conformance_blob[offset];
        const expected_len = conformance_blob[offset + 1];
        const source = conformance_blob[offset + 2 ..][0..source_len];
        const expected = conformance_blob[offset + 2 + source_len ..][0..expected_len];
        offset += 2 + source_len + expected_len;
        const value = try canonicalizeAlloc(allocator, source);
        defer allocator.free(value);
        if (!std.mem.eql(u8, expected, value)) {
            std.debug.print(
                "canonicalization case {d}: {s} -> {s}, expected {s}\n",
                .{ case_index, source, value, expected },
            );
        }
        try testing.expectEqualStrings(expected, value);
    }
    try testing.expectEqual(conformance_blob.len, offset);
}
