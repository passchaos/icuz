//! CLDR 48 transliteration tables.
//!
//! The table-driven transforms are generated from the CLDR transform rules by
//! tools/unicode/transliterate/generate_data.py. Latin-ASCII runs the CLDR
//! pipeline (NFD, remove nonspacing marks after Latin letters and digits, NFC,
//! then map); Fullwidth-Halfwidth and its inverse use longest-match mapping.

const std = @import("std");
const normalization = @import("normalization/root.zig");
const properties = @import("properties.zig");
const script = @import("script/root.zig");
const case_mapping = @import("case/root.zig");
const unicode_name = @import("name.zig");
const word_rules = @import("word/rules.zig");

/// CLDR release the compiled transform tables come from.
pub const cldr_version = "48";

pub const Transform = enum {
    latin_ascii,
    fullwidth_halfwidth,
    halfwidth_fullwidth,
    georgian_latin,
    georgian_latin_bgn,
    latin_georgian,
    lao_latin,
    kazakh_fonipa,
    uyghur_fonipa,
    hebrew_latin_bgn,
    russian_latin_bgn,
    greek_latin_bgn,
    katakana_latin_bgn,
    nfd,
    nfc,
    nfkd,
    nfkc,
};

pub const Error = error{ InvalidUtf8, OutOfMemory, UnknownTransform };

const data = @embedFile("transliterate/data.bin");

const header_len = 44;
const transform_count = readU16(8);
const entry_count = readU32(10);
const source_count = readU32(14);
const target_count = readU32(18);
const set_count = readU32(22);
const range_count = readU32(26);
const context_count = readU32(30);
const context_element_count = readU32(34);
const step_count = readU32(40);
const transform_offset = header_len;
const step_offset = transform_offset + @as(usize, transform_count) * 36;
const entry_offset = step_offset + @as(usize, step_count) * 8;
const set_offset = entry_offset + @as(usize, entry_count) * 34;
const range_offset = set_offset + @as(usize, set_count) * 8;
const context_offset = range_offset + @as(usize, range_count) * 8;
const context_element_offset = context_offset + @as(usize, context_count) * 8;
const names_offset = context_element_offset +
    @as(usize, context_element_count) * 8;

const names_length = blk: {
    @setEvalBranchQuota(100_000);
    var maximum: usize = 0;
    for (0..transform_count) |index| {
        const record = transformAt(index);
        maximum = @max(maximum, @as(usize, record.name_offset) + record.name_len);
    }
    break :blk maximum;
};

const sources_offset = names_offset + names_length;
const targets_offset = sources_offset + @as(usize, source_count) * 4;

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJTR") or
        data[4] != 16 or data[5] != 48 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid transliteration data");
    }
    if (targets_offset + @as(usize, target_count) * 4 != data.len) {
        @compileError("invalid transliteration data lengths");
    }
}

const TransformRecord = struct {
    name_offset: u16,
    name_len: u8,
    pass_count: u8,
    entry_start: u32,
    entry_count: u32,
    pre_normalization: u8,
    post_normalization: u8,
    filter_set: u32,
    final_case: u8,
    filtered_normalization: bool,
    next_transform: u32,
    pre_transform: u32,
    step_start: u32,
    step_count: u16,
};

const Entry = struct {
    source_offset: u32,
    source_len: u8,
    target_offset: u32,
    target_len: u8,
    before_context: u32,
    after_context: u32,
    pass: u8,
    flags: u8,
    priority: u16,
    source2_offset: u32,
    source2_len: u8,
    repeat_set: u32,
    repeat_min: u8,
    repeat_start: u32,
    repeat_len: u32,
    kind: u8,
};

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn transformAt(index: usize) TransformRecord {
    const base = transform_offset + index * 36;
    return .{
        .name_offset = readU16(base),
        .name_len = data[base + 2],
        .pass_count = data[base + 3],
        .entry_start = readU32(base + 4),
        .entry_count = readU32(base + 8),
        .pre_normalization = data[base + 12],
        .post_normalization = data[base + 13],
        .filter_set = readU32(base + 14),
        .final_case = data[base + 18],
        .filtered_normalization = data[base + 19] != 0,
        .next_transform = readU32(base + 20),
        .pre_transform = readU32(base + 24),
        .step_start = readU32(base + 28),
        .step_count = readU16(base + 32),
    };
}

const named_transform_names = [_][]const u8{
    "NFC",       "NFD",       "NFKC",      "NFKD",     "Any-Lower",
    "Any-Upper", "Any-Title", "nl-Title",  "Any-Null", "Hex-Any",
    "Any-Hex",   "Name-Any",  "Any-Name",  "Latin-NumericPinyin",
    "NumericPinyin-Latin",
};

/// Number of transforms available by name, including named engines.
pub fn transformCount() usize {
    return transform_count + named_transform_names.len;
}

/// Name of the transform at `index`, or null when out of range.
pub fn transformNameAt(index: usize) ?[]const u8 {
    if (index < transform_count) {
        const record = transformAt(index);
        return data[names_offset + record.name_offset ..][0..record.name_len];
    }
    const named_index = index - transform_count;
    if (named_index >= named_transform_names.len) return null;
    return named_transform_names[named_index];
}

const TransformAlias = struct { icu: []const u8, clrd: []const u8 };
const transform_aliases = [_]TransformAlias{
    .{ .icu = "ru-ru_Latn/BGN", .clrd = "Russian-Latin-BGN" },
    .{ .icu = "el-el_Latn/BGN", .clrd = "Greek-Latin-BGN" },
    .{ .icu = "he-he_Latn/BGN", .clrd = "Hebrew-Latin-BGN" },
    .{ .icu = "ka-ka_Latn/BGN_1981", .clrd = "Georgian-Latin-BGN_1981" },
    .{ .icu = "mn-mn_Latn/BGN", .clrd = "Mongolian-Latin-BGN" },
    .{ .icu = "bg-bg_Latn/BGN", .clrd = "Bulgarian-Latin-BGN" },
    .{ .icu = "mk-mk_Latn/BGN", .clrd = "Macedonian-Latin-BGN" },
    .{ .icu = "Any-sr_Latn/BGN", .clrd = "Serbian-Latin-BGN" },
    .{ .icu = "uk-uk_Latn/BGN", .clrd = "Ukrainian-Latin-BGN" },
    .{ .icu = "be-be_Latn/BGN", .clrd = "Belarusian-Latin-BGN" },
    .{ .icu = "kk-kk_Latn/BGN", .clrd = "Kazakh-Latin-BGN" },
    .{ .icu = "ky-ky_Latn/BGN", .clrd = "Kirghiz-Latin-BGN" },
    .{ .icu = "hy-hy_Latn/BGN", .clrd = "Armenian-Latin-BGN" },
    .{ .icu = "fa-fa_Latn/BGN", .clrd = "Persian-Latin-BGN" },
    .{ .icu = "ar-ar_Latn/BGN", .clrd = "Arabic-Latin-BGN" },
    .{ .icu = "ps-ps_Latn/BGN", .clrd = "Pashto-Latin-BGN" },
    .{ .icu = "ko-ko_Latn/BGN", .clrd = "Korean-Latin-BGN" },
    .{ .icu = "az_Cyrl-az/BGN", .clrd = "Azerbaijani-Latin-BGN" },
};

fn aliasTransform(name: []const u8) ?[]const u8 {
    for (transform_aliases) |alias| {
        if (std.mem.eql(u8, name, alias.icu)) return alias.clrd;
    }
    return null;
}

fn isNamedTransform(name: []const u8) bool {
    const names = [_][]const u8{
        "Latin-ASCII", "NFC",       "NFD",       "NFKC",      "NFKD",
        "Any-Lower",   "Any-Upper", "Any-Title", "nl-Title",  "Any-Null",
        "Null",        "Hex-Any",   "Any-Hex",   "Name-Any",  "Any-Name",
        "Latin-NumericPinyin", "NumericPinyin-Latin",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Index of a compiled table transform, or null for named engines.
/// ICU aliases resolve to their canonical transform index.
pub fn transformIndex(name: []const u8) ?usize {
    if (aliasTransform(name)) |clrd| return findTransformByName(clrd);
    return findTransformByName(name);
}

/// Whether `name` resolves through the table blob or a named engine.
pub fn hasTransform(name: []const u8) bool {
    if (aliasTransform(name)) |clrd| return findTransformByName(clrd) != null;
    return isNamedTransform(name) or findTransformByName(name) != null;
}

fn findTransformByName(name: []const u8) ?usize {
    for (0..transform_count) |index| {
        const record = transformAt(index);
        const record_name = data[names_offset + record.name_offset ..][0..record.name_len];
        if (std.mem.eql(u8, record_name, name)) return index;
    }
    return null;
}

fn entryAt(index: usize) Entry {
    const base = entry_offset + index * 34;
    return .{
        .source_offset = readU32(base),
        .source_len = data[base + 4],
        .target_offset = readU32(base + 5),
        .target_len = data[base + 9],
        .before_context = readU32(base + 10),
        .after_context = readU32(base + 14),
        .pass = data[base + 18],
        .flags = data[base + 19],
        .priority = readU16(base + 20),
        .source2_offset = readU32(base + 22),
        .source2_len = data[base + 26],
        .repeat_min = data[base + 27],
        .repeat_set = readU32(base + 28),
        .repeat_start = 0,
        .repeat_len = 0,
        .kind = data[base + 32],
    };
}

/// First source codepoint of an entry without materializing the whole record;
/// used by the binary search in the literal range.
fn entryFirstCodepoint(index: usize) u21 {
    const base = entry_offset + index * 34;
    return @intCast(readU32(sources_offset + readU32(base) * 4));
}

fn sourceCodepoint(entry: Entry, index: usize) u21 {
    return @intCast(readU32(sources_offset +
        (@as(usize, entry.source_offset) + index) * 4));
}

fn sourceCodepoint2(entry: Entry, index: usize) u21 {
    return @intCast(readU32(sources_offset +
        (@as(usize, entry.source2_offset) + index) * 4));
}

fn targetCodepoint(entry: Entry, index: usize) u21 {
    return @intCast(readU32(targets_offset +
        (@as(usize, entry.target_offset) + index) * 4));
}

fn setContains(set_index: u32, codepoint: u21) bool {
    if (set_index == 0) return false;
    const record = set_offset + @as(usize, set_index) * 8;
    const offset = readU32(record);
    const count = readU32(record + 4);
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = range_offset + (@as(usize, offset) + middle) * 8;
        const start = readU32(base);
        const end = readU32(base + 4);
        if (codepoint < start) {
            high = middle;
        } else if (codepoint > end) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

const ContextElement = struct {
    set_index: u32,
    flags: u32,
};

fn contextElementAt(index: usize) ContextElement {
    const base = context_element_offset + index * 8;
    return .{
        .set_index = readU32(base),
        .flags = readU32(base + 4),
    };
}

fn contextMatches(
    context_index: u32,
    codepoints: []const u21,
    position: usize,
    forward: bool,
) bool {
    if (context_index == 0) return true;
    const record = context_offset + @as(usize, context_index) * 8;
    const offset = readU32(record);
    const count = readU32(record + 4);
    if (forward) {
        var cursor = position;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const element = contextElementAt(@as(usize, offset) + index);
            const optional = element.flags & 2 != 0;
            const repeat = element.flags & 8 != 0;
            const require_one = element.flags & 16 != 0;
            if (element.flags & 32 != 0) {
                if (element.flags & 1 != 0) {
                    // Negated class containing the end anchor: the boundary
                    // itself is excluded, normal positions use the set.
                    if (cursor >= codepoints.len) return false;
                } else if (cursor == codepoints.len) {
                    // A class union with the end anchor matches the boundary
                    // without consuming a character.
                    continue;
                }
            }
            if (repeat) {
                var consumed: usize = 0;
                while (cursor < codepoints.len) {
                    const contains = setContains(
                        element.set_index,
                        codepoints[cursor],
                    );
                    const matched = if (element.flags & 1 != 0)
                        !contains
                    else
                        contains;
                    if (!matched) break;
                    cursor += 1;
                    consumed += 1;
                }
                if (require_one and consumed == 0) return false;
                continue;
            }
            if (cursor >= codepoints.len) {
                if (element.flags & 4 != 0 or optional) continue;
                // ICU lets a negated class match the empty position at the
                // end of the text (CLDR's word-final inherent-vowel rules).
                if (element.flags & 1 != 0) continue;
                return false;
            }
            const contains = setContains(element.set_index, codepoints[cursor]);
            const matched = if (element.flags & 1 != 0) !contains else contains;
            if (!matched) {
                if (optional) continue;
                return false;
            }
            cursor += 1;
        }
        return true;
    }
    var cursor = position;
    var index: usize = count;
    while (index > 0) {
        index -= 1;
        const element = contextElementAt(@as(usize, offset) + index);
        const optional = element.flags & 2 != 0;
        const repeat = element.flags & 8 != 0;
        const require_one = element.flags & 16 != 0;
        if (element.flags & 32 != 0) {
            if (element.flags & 1 != 0) {
                if (cursor == 0) return false;
            } else if (cursor == 0) {
                continue;
            }
        }
        if (repeat) {
            var consumed: usize = 0;
            while (cursor > 0) {
                const contains = setContains(
                    element.set_index,
                    codepoints[cursor - 1],
                );
                const matched = if (element.flags & 1 != 0)
                    !contains
                else
                    contains;
                if (!matched) break;
                cursor -= 1;
                consumed += 1;
            }
            if (require_one and consumed == 0) return false;
            continue;
        }
        if (cursor == 0) {
            if (element.flags & 4 != 0 or optional) continue;
            // ICU lets a negated class match the empty position at the start
            // of the text (CLDR's word-initial inherent-vowel rules).
            if (element.flags & 1 != 0) continue;
            return false;
        }
        cursor -= 1;
        const contains = setContains(element.set_index, codepoints[cursor]);
        const matched = if (element.flags & 1 != 0) !contains else contains;
        if (!matched) {
            if (optional) {
                cursor += 1;
                continue;
            }
            return false;
        }
    }
    return true;
}

const EntryRange = struct {
    start: usize,
    end: usize,
};

/// Entries of one transform are sorted by pass, so each pass is a contiguous
/// slice of the transform's entry range.
fn transformPassRange(transform_index: usize, pass_index: u8) EntryRange {
    const transform = transformAt(transform_index);
    const range_start = @as(usize, transform.entry_start);
    const range_end = range_start + @as(usize, transform.entry_count);
    var low = range_start;
    var high = range_end;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entryAt(middle).pass < pass_index) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    const start = low;
    high = range_end;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entryAt(middle).pass <= pass_index) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return .{ .start = start, .end = low };
}

/// Entries with an empty or repeated source are stored at the front of a
/// pass, before the sorted literal-source entries.
/// Negated-source entries are stored at the end of a pass, after the sorted
/// literal entries.
fn negatedStart(range: EntryRange) usize {
    var end = range.end;
    while (end > range.start and entryAt(end - 1).flags & 64 != 0) : (end -= 1) {}
    return end;
}

fn mappingStart(range: EntryRange) usize {
    var start = range.start;
    while (start < range.end and entryAt(start).flags & 205 != 0) : (start += 1) {}
    return start;
}

fn hasInsertions(range: EntryRange) bool {
    var index = range.start;
    while (index < range.end) : (index += 1) {
        const flags = entryAt(index).flags;
        if (flags & 1 != 0) return true;
        if (flags & 205 == 0) break;
    }
    return false;
}

/// Apply the pass's empty-source rules before its mapping rules. The inserted
/// text is visible to later rules through the growing output buffer.
fn applyInsertions(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    range: EntryRange,
) Error!std.ArrayList(u21) {
    var output = std.ArrayList(u21).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index <= codepoints.len) {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var matched = false;
            var entry_index = range.start;
            while (entry_index < range.end) : (entry_index += 1) {
                const entry = entryAt(entry_index);
                if (entry.flags & 205 == 0) break;
                if (entry.flags & 1 == 0) continue;
                if (!contextMatches(
                    entry.before_context,
                    output.items,
                    output.items.len,
                    false,
                )) {
                    continue;
                }
                if (!contextMatches(
                    entry.after_context,
                    codepoints,
                    index,
                    true,
                )) {
                    continue;
                }
                var offset: usize = 0;
                while (offset < entry.target_len) : (offset += 1) {
                    try output.append(
                        allocator,
                        targetCodepoint(entry, offset),
                    );
                }
                matched = true;
                break;
            }
            if (!matched) break;
        }
        if (index == codepoints.len) break;
        try output.append(allocator, codepoints[index]);
        index += 1;
    }
    return output;
}

fn findMatchInRange(
    range: EntryRange,
    codepoints: []const u21,
    index: usize,
    before: []const u21,
    filter_set: u32,
) ?Entry {
    const first = codepoints[index];
    // ICU's :: [set] ; filter restricts which input characters may start a
    // match; everything else passes through unchanged.
    if (filter_set != 0 and !setContains(filter_set, first)) return null;
    const literals_start = mappingStart(range);
    const literals_end = negatedStart(range);
    var best: ?Entry = null;

    var lead = range.start;
    while (lead < literals_start) : (lead += 1) {
        const entry = entryAt(lead);
        var candidate: ?Entry = null;
        if (entry.flags & 128 != 0) {
            // Repeated negated class in the middle of a source sequence.
            const prefix_len = @as(usize, entry.source_len);
            const suffix_len = @as(usize, entry.source2_len);
            if (index + prefix_len > codepoints.len) continue;
            var prefix_ok = true;
            for (0..prefix_len) |offset| {
                if (sourceCodepoint(entry, offset) !=
                    codepoints[index + offset])
                {
                    prefix_ok = false;
                    break;
                }
            }
            if (!prefix_ok) continue;
            const run_start = index + prefix_len;
            var consumed: usize = 0;
            while (run_start + consumed < codepoints.len and
                consumed < 255 and
                !setContains(entry.repeat_set, codepoints[run_start + consumed]))
            {
                consumed += 1;
            }
            if (consumed < entry.repeat_min) continue;
            const suffix_start = run_start + consumed;
            if (suffix_start + suffix_len > codepoints.len) continue;
            var suffix_ok = true;
            for (0..suffix_len) |offset| {
                if (sourceCodepoint2(entry, offset) !=
                    codepoints[suffix_start + offset])
                {
                    suffix_ok = false;
                    break;
                }
            }
            if (!suffix_ok) continue;
            if (!contextMatches(entry.before_context, before, before.len, false)) {
                continue;
            }
            if (!contextMatches(
                entry.after_context,
                codepoints,
                suffix_start + suffix_len,
                true,
            )) {
                continue;
            }
            var matched = entry;
            matched.source_len = @intCast(prefix_len + consumed + suffix_len);
            matched.repeat_start = @intCast(prefix_len);
            matched.repeat_len = @intCast(consumed);
            candidate = matched;
        } else if (entry.flags & 1 != 0) {
            // Empty-source insertion rule: contexts see the current output
            // prefix and the remaining input.
            if (!contextMatches(entry.before_context, before, before.len, false)) {
                continue;
            }
            if (!contextMatches(
                entry.after_context,
                codepoints,
                index,
                true,
            )) {
                continue;
            }
            candidate = entry;
        } else if (entry.flags & 8 != 0) {
            // A collapse entry matches one unit (base plus trailing marks)
            // and consumes any immediately following units, emitting only
            // the first one.
            if (!setContains(entry.source_offset, first)) continue;
            var consumed: usize = 1;
            while (index + consumed < codepoints.len and
                properties.isMark(codepoints[index + consumed]))
            {
                consumed += 1;
            }
            const unit_length = @min(consumed, 255);
            while (index + consumed < codepoints.len and
                setContains(entry.source_offset, codepoints[index + consumed]))
            {
                consumed += 1;
                while (index + consumed < codepoints.len and
                    properties.isMark(codepoints[index + consumed]))
                {
                    consumed += 1;
                }
            }
            if (!contextMatches(
                entry.before_context,
                before,
                before.len,
                false,
            )) {
                continue;
            }
            if (!contextMatches(
                entry.after_context,
                codepoints,
                index + consumed,
                true,
            )) {
                continue;
            }
            var matched = entry;
            matched.source_len = @intCast(consumed);
            matched.target_len = @intCast(unit_length);
            candidate = matched;
        } else if (entry.flags & 4 != 0) {
            // A repeated class source consumes the longest run in the set.
            var consumed: usize = 0;
            while (index + consumed < codepoints.len and consumed < 255 and
                setContains(entry.source_offset, codepoints[index + consumed]))
            {
                consumed += 1;
            }
            if (consumed < entry.source_len) continue;
            if (!contextMatches(
                entry.before_context,
                before,
                before.len,
                false,
            )) {
                continue;
            }
            if (!contextMatches(
                entry.after_context,
                codepoints,
                index + consumed,
                true,
            )) {
                continue;
            }
            var matched = entry;
            matched.source_len = @intCast(consumed);
            candidate = matched;
        }
        if (candidate) |value| {
            if (best == null or value.priority < best.?.priority) {
                best = value;
            }
        }
    }

    var low = literals_start;
    var high = literals_end;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entryFirstCodepoint(middle) < first) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    var entry_index = low;
    while (entry_index < literals_end) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (sourceCodepoint(entry, 0) != first) break;
        const length = @as(usize, entry.source_len);
        if (length > codepoints.len - index) continue;
        var matched = true;
        var offset: usize = 1;
        while (offset < length) : (offset += 1) {
            if (sourceCodepoint(entry, offset) != codepoints[index + offset]) {
                matched = false;
                break;
            }
        }
        if (!matched) continue;
        if (!contextMatches(entry.before_context, before, before.len, false)) {
            continue;
        }
        if (!contextMatches(
            entry.after_context,
            codepoints,
            index + length,
            true,
        )) {
            continue;
        }
        if (best == null or entry.priority < best.?.priority) best = entry;
        break;
    }

    entry_index = literals_end;
    while (entry_index < range.end) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.flags & 64 == 0) continue;
        // Negated source class: the first codepoint must be outside the set.
        if (setContains(entry.source_offset, first)) continue;
        if (!contextMatches(entry.before_context, before, before.len, false)) {
            continue;
        }
        if (!contextMatches(
            entry.after_context,
            codepoints,
            index + 1,
            true,
        )) {
            continue;
        }
        if (best == null or entry.priority < best.?.priority) best = entry;
        break;
    }
    return best;
}

fn decodeAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!std.ArrayList(u21) {
    var codepoints = std.ArrayList(u21).empty;
    errdefer codepoints.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        if (index + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
            return error.InvalidUtf8;
        try codepoints.append(allocator, codepoint);
        index += length;
    }
    return codepoints;
}

fn appendCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u21,
) Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        return error.InvalidUtf8;
    try output.appendSlice(allocator, buffer[0..length]);
}

fn appendTarget(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    entry: Entry,
) Error!void {
    var index: usize = 0;
    while (index < entry.target_len) : (index += 1) {
        try appendCodepoint(allocator, output, targetCodepoint(entry, index));
    }
}

fn halfwidthKatakanaAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    var codepoints = try decodeAlloc(allocator, text);
    defer codepoints.deinit(allocator);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const range = transformPassRange(transform_index, 0);
    var index: usize = 0;
    while (index < codepoints.items.len) {
        const codepoint = codepoints.items[index];
        if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
            if (findMatchInRange(range, codepoints.items, index, codepoints.items[0..index], 0)) |entry| {
                try appendTarget(allocator, &output, entry);
                index += entry.source_len;
                continue;
            }
        }
        try appendCodepoint(allocator, &output, codepoint);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn applyPassAlloc(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    range: EntryRange,
    filter_set: u32,
) Error!std.ArrayList(u21) {
    // Apply the pass in place so a rule whose output cursor is at the start
    // of the replacement (`|` in ICU rule syntax) rescans that replacement.
    var work = std.ArrayList(u21).empty;
    errdefer work.deinit(allocator);
    try work.appendSlice(allocator, codepoints);
    var index: usize = 0;
    var target_buffer: [256]u21 = undefined;
    var steps: usize = 0;
    const max_steps = codepoints.len * 16 + 1024;
    while (index < work.items.len) {
        steps += 1;
        if (steps > max_steps) break;
        if (findMatchInRange(range, work.items, index, work.items[0..index], filter_set)) |entry| {
            if (entry.kind == 1) {
                // The target's sentinel is replaced by the captured
                // ante-context codepoint immediately before the key.
                var mapped = std.ArrayList(u21).empty;
                defer mapped.deinit(allocator);
                const captured = if (index > 0) work.items[index - 1] else 0;
                for (0..@as(usize, entry.target_len)) |offset| {
                    const codepoint = targetCodepoint(entry, offset);
                    try mapped.append(
                        allocator,
                        if (codepoint == 0x110001) captured else codepoint,
                    );
                }
                try work.replaceRange(
                    allocator,
                    index,
                    entry.source_len,
                    mapped.items,
                );
                index += mapped.items.len;
                continue;
            }
            if (entry.flags & 128 != 0) {
                var mapped = std.ArrayList(u21).empty;
                defer mapped.deinit(allocator);
                for (0..@as(usize, entry.target_len)) |offset| {
                    const codepoint = targetCodepoint(entry, offset);
                    if (codepoint == 0x110000) {
                        for (0..@as(usize, entry.repeat_len)) |run_index| {
                            try mapped.append(
                                allocator,
                                work.items[
                                    index + entry.repeat_start + run_index
                                ],
                            );
                        }
                    } else {
                        try mapped.append(allocator, codepoint);
                    }
                }
                try work.replaceRange(
                    allocator,
                    index,
                    entry.source_len,
                    mapped.items,
                );
                index += mapped.items.len;
                continue;
            }
            if (entry.flags & 1 != 0) {
                const target_len: usize = entry.target_len;
                for (0..target_len) |offset| {
                    target_buffer[offset] = targetCodepoint(entry, offset);
                }
                try work.replaceRange(
                    allocator,
                    index,
                    0,
                    target_buffer[0..target_len],
                );
                index += target_len;
                continue;
            }
            if (entry.flags & 16 != 0) {
                // Embedded case call: &Any-Lower($1) or &Any-Upper($1).
                var matched = std.ArrayList(u8).empty;
                defer matched.deinit(allocator);
                for (work.items[index .. index + entry.source_len]) |codepoint| {
                    try appendCodepoint(allocator, &matched, codepoint);
                }
                const mapped = if (entry.flags & 32 != 0)
                    try case_mapping.fullUpperAlloc(allocator, matched.items, .{})
                else
                    try case_mapping.fullLowerAlloc(allocator, matched.items, .{});
                defer allocator.free(mapped);
                var mapped_codepoints = try decodeAlloc(allocator, mapped);
                defer mapped_codepoints.deinit(allocator);
                try work.replaceRange(
                    allocator,
                    index,
                    entry.source_len,
                    mapped_codepoints.items,
                );
                index += mapped_codepoints.items.len;
                continue;
            }
            const target_len: usize = entry.target_len;
            if (entry.flags & 8 != 0) {
                for (0..target_len) |offset| {
                    target_buffer[offset] = work.items[index + offset];
                }
            } else {
                for (0..target_len) |offset| {
                    target_buffer[offset] = targetCodepoint(entry, offset);
                }
            }
            try work.replaceRange(
                allocator,
                index,
                entry.source_len,
                target_buffer[0..target_len],
            );
            if (entry.flags & 2 == 0) index += target_len;
        } else {
            index += 1;
        }
    }
    return work;
}

fn transformName(index: usize) []const u8 {
    const record = transformAt(index);
    return data[names_offset + record.name_offset ..][0..record.name_len];
}

fn runComponentAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    index: usize,
) Error![]u8 {
    if (std.mem.eql(u8, transformName(index), "Latin-ASCII")) {
        return latinAsciiAlloc(allocator, text);
    }
    return tableAlloc(allocator, text, index);
}

const Step = struct {
    kind: u8,
    value: u32,
};

fn stepAt(index: usize) Step {
    const base = step_offset + index * 8;
    return .{ .kind = data[base], .value = readU32(base + 4) };
}

fn runStepProgramAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    record: TransformRecord,
) Error![]u8 {
    var current = try allocator.dupe(u8, text);
    errdefer allocator.free(current);
    var index: usize = record.step_start;
    const end = index + record.step_count;
    while (index < end) : (index += 1) {
        const step = stepAt(index);
        const next: []u8 = switch (step.kind) {
            0 => try runComponentAlloc(allocator, current, step.value),
            1 => blk: {
                const form: normalization.Form = switch (step.value) {
                    1 => .nfd,
                    2 => .nfc,
                    3 => .nfkd,
                    4 => .nfkc,
                    else => .nfc,
                };
                const normalized = try normalization.normalizeFormAlloc(
                    allocator,
                    current,
                    form,
                );
                break :blk normalized orelse try allocator.dupe(u8, current);
            },
            2 => try case_mapping.fullLowerAlloc(allocator, current, .{}),
            3 => try case_mapping.fullUpperAlloc(allocator, current, .{}),
            else => try allocator.dupe(u8, current),
        };
        allocator.free(current);
        current = next;
    }
    return current;
}

fn runFilteredProgramAlloc(
    allocator: std.mem.Allocator,
    run: []const u21,
    record: TransformRecord,
) Error![]u8 {
    const run_text = try encodeCodepointsAlloc(allocator, run);
    defer allocator.free(run_text);
    return runStepProgramAlloc(allocator, run_text, record);
}

/// Execute an ordered pipeline program. A global filter restricts the
/// program to input runs, matching ICU's compound-filter behavior.
fn runStepsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    const record = transformAt(transform_index);
    if (record.filter_set == 0) {
        return runStepProgramAlloc(allocator, text, record);
    }
    var codepoints = try decodeAlloc(allocator, text);
    defer codepoints.deinit(allocator);
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < codepoints.items.len) {
        const contained = setContains(
            record.filter_set,
            codepoints.items[index],
        );
        const start = index;
        while (index < codepoints.items.len and
            setContains(record.filter_set, codepoints.items[index]) ==
                contained)
        {
            index += 1;
        }
        const run = codepoints.items[start..index];
        if (!contained) {
            for (run) |codepoint| {
                try appendCodepoint(allocator, &output, codepoint);
            }
            continue;
        }
        const converted = try runFilteredProgramAlloc(
            allocator,
            run,
            record,
        );
        defer allocator.free(converted);
        try output.appendSlice(allocator, converted);
    }
    return output.toOwnedSlice(allocator);
}

fn tableAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    const record = transformAt(transform_index);
    if (record.step_count != 0) {
        return runStepsAlloc(allocator, text, transform_index);
    }
    var owned: ?[]u8 = null;
    defer if (owned) |value| allocator.free(value);
    var input = text;
    if (record.pre_transform != 0xffff_ffff) {
        owned = try runComponentAlloc(allocator, text, record.pre_transform);
        input = owned.?;
    }
    const result = try tableCoreAlloc(allocator, input, transform_index);
    if (record.next_transform == 0xffff_ffff) return result;
    const chained = try runComponentAlloc(
        allocator,
        result,
        record.next_transform,
    );
    allocator.free(result);
    return chained;
}

fn normalizationFormFromId(value: u8) normalization.Form {
    return switch (value) {
        1 => .nfd,
        2 => .nfc,
        3 => .nfkd,
        4 => .nfkc,
        else => .nfc,
    };
}

/// Run every pass of a transform over `codepoints`, returning the final
/// codepoint sequence. `filter_set` restricts which codepoints may start a
/// match; only the first pass consults it.
fn runPassesAlloc(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    transform_index: usize,
    filter_set: u32,
) Error!std.ArrayList(u21) {
    const record = transformAt(transform_index);
    const pass_count: usize = @max(record.pass_count, 1);
    // Leading normalization directives can leave empty passes; the global
    // filter belongs to the first pass that actually contains rules.
    const first_pass: usize = blk: {
        for (0..pass_count) |pass| {
            const range = transformPassRange(transform_index, @intCast(pass));
            if (range.end > range.start) break :blk pass;
        }
        break :blk 0;
    };
    var current: []const u21 = codepoints;
    var pass_output: ?std.ArrayList(u21) = null;
    defer if (pass_output) |*value| value.deinit(allocator);

    // Each pass applies its empty-source insertion rules, then its mapping
    // rules. Empty passes (for example around normalization directives) are
    // skipped without scanning the text.
    var pass: usize = 0;
    while (pass < pass_count) : (pass += 1) {
        const range = transformPassRange(transform_index, @intCast(pass));
        if (range.end == range.start) continue;
        const next = try applyPassAlloc(
            allocator,
            current,
            range,
            if (pass == first_pass) filter_set else 0,
        );
        if (pass_output) |*value| value.deinit(allocator);
        pass_output = next;
        current = next.items;
    }
    if (pass_output) |value| {
        pass_output = null;
        return value;
    }
    var output = std.ArrayList(u21).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, codepoints);
    return output;
}

fn encodeCodepointsAlloc(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (codepoints) |codepoint| {
        try appendCodepoint(allocator, &output, codepoint);
    }
    return output.toOwnedSlice(allocator);
}

/// Apply the trailing case transform and output normalization. Takes ownership
/// of `raw` and returns a newly owned slice.
fn applyFinalCaseAndNormalization(
    allocator: std.mem.Allocator,
    raw: []u8,
    record: TransformRecord,
) Error![]u8 {
    var value = raw;
    if (record.final_case != 0) {
        const cased = if (record.final_case == 1)
            try case_mapping.fullLowerAlloc(allocator, value, .{})
        else
            try case_mapping.fullUpperAlloc(allocator, value, .{});
        allocator.free(value);
        value = cased;
    }
    if (record.post_normalization == 0) return value;
    const post_normalized = try normalization.normalizeFormAlloc(
        allocator,
        value,
        normalizationFormFromId(record.post_normalization),
    );
    if (post_normalized) |normalized| {
        allocator.free(value);
        return normalized;
    }
    return value;
}

/// Reverse transforms use an input-side global filter. ICU splits the input
/// into maximal filtered runs and runs the whole compound (including its
/// normalization steps) on each run, so unfiltered characters such as Arabic
/// marks are never reordered by the final normalization.
fn filteredRunAlloc(
    allocator: std.mem.Allocator,
    run: []const u21,
    record: TransformRecord,
    transform_index: usize,
) Error![]u8 {
    const run_text = try encodeCodepointsAlloc(allocator, run);
    defer allocator.free(run_text);
    var normalized: ?[]u8 = null;
    defer if (normalized) |value| allocator.free(value);
    var input: []const u8 = run_text;
    if (record.pre_normalization != 0) {
        normalized = try normalization.normalizeFormAlloc(
            allocator,
            run_text,
            normalizationFormFromId(record.pre_normalization),
        );
        if (normalized) |value| input = value;
    }
    var run_codepoints = try decodeAlloc(allocator, input);
    defer run_codepoints.deinit(allocator);
    var final = try runPassesAlloc(
        allocator,
        run_codepoints.items,
        transform_index,
        0,
    );
    defer final.deinit(allocator);
    const raw = try encodeCodepointsAlloc(allocator, final.items);
    return applyFinalCaseAndNormalization(allocator, raw, record);
}

fn filteredTableCoreAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    const record = transformAt(transform_index);
    var codepoints = try decodeAlloc(allocator, text);
    defer codepoints.deinit(allocator);
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < codepoints.items.len) {
        const contained = setContains(
            record.filter_set,
            codepoints.items[index],
        );
        const start = index;
        while (index < codepoints.items.len and
            setContains(record.filter_set, codepoints.items[index]) ==
                contained)
        {
            index += 1;
        }
        const run = codepoints.items[start..index];
        if (!contained) {
            for (run) |codepoint| {
                try appendCodepoint(allocator, &output, codepoint);
            }
            continue;
        }
        const converted = try filteredRunAlloc(
            allocator,
            run,
            record,
            transform_index,
        );
        defer allocator.free(converted);
        try output.appendSlice(allocator, converted);
    }
    return output.toOwnedSlice(allocator);
}

fn tableCoreAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    const record = transformAt(transform_index);
    if (record.filtered_normalization) {
        return filteredTableCoreAlloc(allocator, text, transform_index);
    }
    var normalized: ?[]u8 = null;
    var source = text;
    if (record.pre_normalization == 5) {
        const halfwidth_index = findTransformByName("Halfwidth-Fullwidth") orelse
            return error.UnknownTransform;
        const converted = try halfwidthKatakanaAlloc(
            allocator,
            text,
            halfwidth_index,
        );
        const nfc = try normalization.normalizeFormAlloc(
            allocator,
            converted,
            .nfc,
        );
        if (nfc) |value| {
            allocator.free(converted);
            normalized = value;
        } else {
            normalized = converted;
        }
        source = normalized.?;
    } else if (record.pre_normalization != 0) {
        normalized = try normalization.normalizeFormAlloc(
            allocator,
            text,
            normalizationFormFromId(record.pre_normalization),
        );
        if (normalized) |value| source = value;
    }
    defer if (normalized) |value| allocator.free(value);

    var codepoints = try decodeAlloc(allocator, source);
    defer codepoints.deinit(allocator);
    var final = try runPassesAlloc(
        allocator,
        codepoints.items,
        transform_index,
        record.filter_set,
    );
    defer final.deinit(allocator);
    const raw = try encodeCodepointsAlloc(allocator, final.items);
    return applyFinalCaseAndNormalization(allocator, raw, record);
}

fn namedTableAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    name: []const u8,
) Error![]u8 {
    const transform_index = findTransformByName(name) orelse
        return error.UnknownTransform;
    return tableAlloc(allocator, text, transform_index);
}

fn isAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn removableBase(codepoint: u21) bool {
    if (codepoint >= '0' and codepoint <= '9') return true;
    return script.forCodepoint(codepoint) == .latin;
}

fn latinAsciiAlloc(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    const nfd_owned = try normalization.normalizeFormAlloc(allocator, text, .nfd);
    defer if (nfd_owned) |owned| allocator.free(owned);
    const nfd_text = nfd_owned orelse text;

    var codepoints = try decodeAlloc(allocator, nfd_text);
    defer codepoints.deinit(allocator);

    var stripped = std.ArrayList(u21).empty;
    defer stripped.deinit(allocator);
    var base: ?u21 = null;
    for (codepoints.items) |codepoint| {
        const mark = properties.category(codepoint) == .Mn;
        if (mark and base != null and removableBase(base.?)) continue;
        if (!mark) base = codepoint;
        try stripped.append(allocator, codepoint);
    }

    const nfc_owned = try normalization.normalizeCodepointsAlloc(
        allocator,
        stripped.items,
        .nfc,
    );
    defer if (nfc_owned) |owned| allocator.free(owned);
    const nfc_codepoints = nfc_owned orelse stripped.items;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const range = transformPassRange(0, 0);
    var index: usize = 0;
    while (index < nfc_codepoints.len) {
        if (findMatchInRange(range, nfc_codepoints, index, nfc_codepoints[0..index], 0)) |entry| {
            try appendTarget(allocator, &output, entry);
            index += entry.source_len;
        } else {
            try appendCodepoint(allocator, &output, nfc_codepoints[index]);
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Transliterate UTF-8 `text` with the requested CLDR transform.
pub fn transliterateAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform: Transform,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const ascii_identity = switch (transform) {
        .halfwidth_fullwidth, .latin_georgian => false,
        else => true,
    };
    if (ascii_identity and isAscii(text)) return allocator.dupe(u8, text);
    return switch (transform) {
        .latin_ascii => latinAsciiAlloc(allocator, text),
        .fullwidth_halfwidth => tableAlloc(allocator, text, 1),
        .halfwidth_fullwidth => tableAlloc(allocator, text, 2),
        .georgian_latin => namedTableAlloc(allocator, text, "Georgian-Latin"),
        .georgian_latin_bgn => namedTableAlloc(
            allocator,
            text,
            "Georgian-Latin-BGN_1981",
        ),
        .lao_latin => namedTableAlloc(allocator, text, "Lao-Latin"),
        .latin_georgian => namedTableAlloc(allocator, text, "Latin-Georgian"),
        .kazakh_fonipa => namedTableAlloc(allocator, text, "kk-kk_FONIPA"),
        .uyghur_fonipa => namedTableAlloc(allocator, text, "ug-ug_FONIPA"),
        .hebrew_latin_bgn => namedTableAlloc(
            allocator,
            text,
            "Hebrew-Latin-BGN",
        ),
        .russian_latin_bgn => namedTableAlloc(
            allocator,
            text,
            "Russian-Latin-BGN",
        ),
        .greek_latin_bgn => namedTableAlloc(
            allocator,
            text,
            "Greek-Latin-BGN",
        ),
        .katakana_latin_bgn => namedTableAlloc(
            allocator,
            text,
            "Katakana-Latin-BGN",
        ),
        .nfd, .nfc, .nfkd, .nfkc => blk: {
            const form: normalization.Form = switch (transform) {
                .nfd => .nfd,
                .nfc => .nfc,
                .nfkd => .nfkd,
                .nfkc => .nfkc,
                else => unreachable,
            };
            const normalized = try normalization.normalizeFormAlloc(
                allocator,
                text,
                form,
            );
            break :blk normalized orelse try allocator.dupe(u8, text);
        },
    };
}

/// Transliterate UTF-8 `text` with a compiled CLDR transform selected by its
/// CLDR name, for example `"Russian-Latin-BGN"` or `"Amharic-Latin-BGN"`.
fn hexAnyAlloc(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 2 < text.len and
            text[index + 1] == 'x' and text[index + 2] == '{')
        {
            if (std.mem.indexOfScalarPos(u8, text, index + 3, '}')) |close| {
                const digits = text[index + 3 .. close];
                if (digits.len >= 1 and digits.len <= 6) {
                    if (std.fmt.parseInt(u21, digits, 16)) |value| {
                        var buffer: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(value, &buffer)) |length| {
                            try output.appendSlice(allocator, buffer[0..length]);
                            index = close + 1;
                            continue;
                        } else |_| {}
                    } else |_| {}
                }
            }
        }
        if (text[index] == '\\' and index + 1 < text.len) {
            const kind = text[index + 1];
            const digits: usize = if (kind == 'u') 4 else if (kind == 'U') 8 else 0;
            if (digits != 0 and index + 2 + digits <= text.len) {
                const value = std.fmt.parseInt(
                    u21,
                    text[index + 2 ..][0..digits],
                    16,
                ) catch {
                    try output.append(allocator, text[index]);
                    index += 1;
                    continue;
                };
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(value, &buffer) catch {
                    try output.append(allocator, text[index]);
                    index += 1;
                    continue;
                };
                try output.appendSlice(allocator, buffer[0..length]);
                index += 2 + digits;
                continue;
            }
        }
        try output.append(allocator, text[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn nameAnyAlloc(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 2 < text.len and
            text[index + 1] == 'N' and text[index + 2] == '{')
        {
            if (std.mem.indexOfScalarPos(u8, text, index + 3, '}')) |close| {
                if (unicode_name.findByName(text[index + 3 .. close])) |codepoint| {
                    var buffer: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(codepoint, &buffer)) |length| {
                        try output.appendSlice(allocator, buffer[0..length]);
                        index = close + 1;
                        continue;
                    } else |_| {}
                }
            }
        }
        try output.append(allocator, text[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn anyNameAlloc(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        if (index + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
            return error.InvalidUtf8;
        if (unicode_name.name(codepoint)) |entry| {
            try output.appendSlice(allocator, "\\N{");
            try output.appendSlice(allocator, entry);
            try output.append(allocator, '}');
        } else if (codepoint <= 0x1f or
            (codepoint >= 0x7f and codepoint <= 0x9f))
        {
            var buffer: [24]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\N{{<control-{X:0>4}>}}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        } else if ((codepoint >= 0xe000 and codepoint <= 0xf8ff) or
            (codepoint >= 0xf0000 and codepoint <= 0xffffd) or
            (codepoint >= 0x100000 and codepoint <= 0x10fffd))
        {
            var buffer: [32]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\N{{<private use area-{X}>}}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        } else if (properties.category(codepoint) == .Cn) {
            var buffer: [24]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\N{{<unassigned-{X:0>4}>}}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        } else if (codepoint <= 0xffff) {
            var buffer: [6]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\u{X:0>4}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        } else {
            var buffer: [10]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\U{X:0>8}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        }
        index += length;
    }
    return output.toOwnedSlice(allocator);
}

fn anyHexAlloc(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        if (index + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
            return error.InvalidUtf8;
        if (codepoint <= 0xffff) {
            var buffer: [6]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\u{X:0>4}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        } else {
            var buffer: [10]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\U{X:0>8}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        }
        index += length;
    }
    return output.toOwnedSlice(allocator);
}

fn pinyinToneIndex(codepoint: u21) ?u8 {
    return switch (codepoint) {
        0x0304 => 0,
        0x0301 => 1,
        0x030C => 2,
        0x0300 => 3,
        0x0306 => 4,
        else => null,
    };
}

fn pinyinToneMark(index: u8) u21 {
    return switch (index) {
        0 => 0x0304,
        1 => 0x0301,
        2 => 0x030C,
        3 => 0x0300,
        else => 0x0306,
    };
}

fn isPinyinLetter(codepoint: u21) bool {
    return (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 'A' and codepoint <= 'Z') or
        codepoint == 0x00FC;
}

fn isPinyinVowel(codepoint: u21) bool {
    return switch (codepoint) {
        'a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U', 0x00FC => true,
        else => false,
    };
}

fn pinyinPrecomposed(vowel: u21, tone: u8) ?u21 {
    const table = switch (vowel) {
        'a', 'A' => [_]u21{ 0x0101, 0x00E1, 0x01CE, 0x00E0, 0x0103 },
        'e', 'E' => [_]u21{ 0x0113, 0x00E9, 0x011B, 0x00E8, 0x0115 },
        'i', 'I' => [_]u21{ 0x012B, 0x00ED, 0x01D0, 0x00EC, 0x012D },
        'o', 'O' => [_]u21{ 0x014D, 0x00F3, 0x01D2, 0x00F2, 0x014F },
        'u', 'U' => [_]u21{ 0x016B, 0x00FA, 0x01D4, 0x00F9, 0x016D },
        0x00FC => [_]u21{ 0x01D6, 0x01D8, 0x01DA, 0x01DC, 0x00FC },
        else => return null,
    };
    return table[tone];
}

/// Move Pinyin tone marks to a trailing tone digit.
fn latinNumericPinyinAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    const nfd = try normalization.normalizeFormAlloc(allocator, text, .nfd);
    defer if (nfd) |value| allocator.free(value);
    var codepoints = try decodeAlloc(allocator, nfd orelse text);
    defer codepoints.deinit(allocator);
    var output = std.ArrayList(u21).empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    var pending_digit: u8 = 0;
    var skip_remaining: usize = 0;
    while (index < codepoints.items.len) {
        const codepoint = codepoints.items[index];
        if (pending_digit != 0) {
            try output.append(allocator, codepoint);
            if (skip_remaining > 0) skip_remaining -= 1;
            if (skip_remaining == 0) {
                try output.append(allocator, '0' + pending_digit);
                pending_digit = 0;
            }
            index += 1;
            continue;
        }
        if (pinyinToneIndex(codepoint)) |tone| {
            // The base may be separated from the tone mark by another
            // combining mark (for example u + diaeresis + grave).
            var base_index = output.items.len;
            while (base_index > 0 and
                !isPinyinLetter(output.items[base_index - 1]))
            {
                base_index -= 1;
            }
            if (base_index == 0) {
                try output.append(allocator, codepoint);
                index += 1;
                continue;
            }
            const base = output.items[base_index - 1];
            var skip: usize = 0;
            if (index + 1 < codepoints.items.len) {
                const next = codepoints.items[index + 1];
                if (base == 'e' and next == 'r') {
                    skip = 1;
                } else if (index + 2 < codepoints.items.len and
                    ((next == 'n' and codepoints.items[index + 2] == 'g') or
                        (next == 'o' and codepoints.items[index + 2] == 'n')))
                {
                    skip = 2;
                } else if (next == 'i' or next == 'o' or next == 'n' or
                    next == 'u')
                {
                    skip = 1;
                }
            }
            pending_digit = tone + 1;
            skip_remaining = skip;
            if (skip == 0) {
                try output.append(allocator, '0' + pending_digit);
                pending_digit = 0;
            }
            index += 1;
            continue;
        }
        try output.append(allocator, codepoint);
        index += 1;
    }
    if (pending_digit != 0) {
        try output.append(allocator, '0' + pending_digit);
    }
    var encoded = std.ArrayList(u8).empty;
    errdefer encoded.deinit(allocator);
    for (output.items) |codepoint| {
        try appendCodepoint(allocator, &encoded, codepoint);
    }
    const raw = try encoded.toOwnedSlice(allocator);
    const nfc = try normalization.normalizeFormAlloc(allocator, raw, .nfc);
    if (nfc) |value| {
        allocator.free(raw);
        return value;
    }
    return raw;
}

/// Place a trailing Pinyin tone digit on the correct vowel.
fn numericPinyinLatinAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    var codepoints = try decodeAlloc(allocator, text);
    defer codepoints.deinit(allocator);
    var output = std.ArrayList(u21).empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < codepoints.items.len) {
        const codepoint = codepoints.items[index];
        if (codepoint >= '1' and codepoint <= '5' and
            output.items.len > 0 and
            isPinyinLetter(output.items[output.items.len - 1]))
        {
            var start = output.items.len;
            while (start > 0 and isPinyinLetter(output.items[start - 1])) {
                start -= 1;
            }
            var tone_position: ?usize = null;
            const priorities = [_]u21{ 'a', 'A', 'o', 'O', 'e', 'E' };
            for (priorities) |vowel| {
                for (output.items[start..], start..) |value, position| {
                    if (value == vowel) {
                        tone_position = position;
                        break;
                    }
                }
                if (tone_position != null) break;
            }
            if (tone_position == null) {
                for (output.items[start..], start..) |value, position| {
                    if (isPinyinVowel(value)) tone_position = position;
                }
            }
            if (tone_position == null) {
                tone_position = output.items.len - 1;
            }
            const digit: u8 = @intCast(codepoint - '1');
            if (digit != 4) {
                const vowel = output.items[tone_position.?];
                if (pinyinPrecomposed(vowel, digit)) |composed| {
                    output.items[tone_position.?] = composed;
                } else {
                    try output.insert(
                        allocator,
                        tone_position.? + 1,
                        pinyinToneMark(digit),
                    );
                }
            }
            index += 1;
            continue;
        }
        try output.append(allocator, codepoint);
        index += 1;
    }
    var encoded = std.ArrayList(u8).empty;
    errdefer encoded.deinit(allocator);
    for (output.items) |codepoint| {
        try appendCodepoint(allocator, &encoded, codepoint);
    }
    const raw = try encoded.toOwnedSlice(allocator);
    const nfc = try normalization.normalizeFormAlloc(allocator, raw, .nfc);
    if (nfc) |value| {
        allocator.free(raw);
        return value;
    }
    return raw;
}

/// Dutch title casing: Any-Title followed by the `Ij` -> `IJ` digraph fix
/// at word starts.
fn nlTitleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    const titled = try case_mapping.fullTitleAlloc(allocator, text, .{});
    defer allocator.free(titled);
    var codepoints = try decodeAlloc(allocator, titled);
    defer codepoints.deinit(allocator);
    const items = codepoints.items;
    var index: usize = 0;
    while (index + 1 < items.len) : (index += 1) {
        if (items[index] != 'I' or items[index + 1] != 'j') continue;
        var cursor = index;
        var boundary = cursor == 0;
        if (!boundary) {
            const mid = word_rules.properties(items[cursor - 1]).class;
            if (mid == .mid_letter or mid == .mid_num_let) cursor -= 1;
            while (cursor > 0 and
                word_rules.properties(items[cursor - 1]).class == .extend)
            {
                cursor -= 1;
            }
            if (cursor == 0) {
                boundary = true;
            } else {
                const before = word_rules.properties(items[cursor - 1]).class;
                boundary = before != .a_letter and before != .hebrew_letter;
            }
        }
        if (!boundary) continue;
        items[index + 1] = 'J';
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (items) |codepoint| {
        try appendCodepoint(allocator, &output, codepoint);
    }
    return output.toOwnedSlice(allocator);
}

fn namedFormAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: normalization.Form,
) Error![]u8 {
    if (try normalization.normalizeFormAlloc(allocator, text, form)) |value| {
        return value;
    }
    return allocator.dupe(u8, text);
}

pub fn transliterateByNameAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    name: []const u8,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (std.mem.eql(u8, name, "Latin-ASCII")) {
        if (isAscii(text)) return allocator.dupe(u8, text);
        return latinAsciiAlloc(allocator, text);
    }
    if (std.mem.eql(u8, name, "NFC")) return namedFormAlloc(allocator, text, .nfc);
    if (std.mem.eql(u8, name, "NFD")) return namedFormAlloc(allocator, text, .nfd);
    if (std.mem.eql(u8, name, "NFKC")) return namedFormAlloc(allocator, text, .nfkc);
    if (std.mem.eql(u8, name, "NFKD")) return namedFormAlloc(allocator, text, .nfkd);
    if (std.mem.eql(u8, name, "Any-Lower")) {
        return case_mapping.fullLowerAlloc(allocator, text, .{});
    }
    if (std.mem.eql(u8, name, "Any-Upper")) {
        return case_mapping.fullUpperAlloc(allocator, text, .{});
    }
    if (std.mem.eql(u8, name, "Any-Title")) {
        return case_mapping.fullTitleAlloc(allocator, text, .{});
    }
    if (std.mem.eql(u8, name, "nl-Title")) {
        return nlTitleAlloc(allocator, text);
    }
    if (std.mem.eql(u8, name, "Latin-NumericPinyin")) {
        return latinNumericPinyinAlloc(allocator, text);
    }
    if (std.mem.eql(u8, name, "NumericPinyin-Latin")) {
        return numericPinyinLatinAlloc(allocator, text);
    }
    if (std.mem.eql(u8, name, "Any-Null") or std.mem.eql(u8, name, "Null")) {
        return allocator.dupe(u8, text);
    }
    if (std.mem.eql(u8, name, "Name-Any")) return nameAnyAlloc(allocator, text);
    if (std.mem.eql(u8, name, "Any-Name")) return anyNameAlloc(allocator, text);
    if (std.mem.eql(u8, name, "Hex-Any")) return hexAnyAlloc(allocator, text);
    if (std.mem.eql(u8, name, "Any-Hex")) return anyHexAlloc(allocator, text);
    if (aliasTransform(name)) |clrd| {
        return transliterateByNameAlloc(allocator, text, clrd);
    }
    const transform_index = findTransformByName(name) orelse
        return error.UnknownTransform;
    return tableAlloc(allocator, text, transform_index);
}

test "Latin-ASCII transliteration" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "\u{FF34}\u{FF25}\u{FF33}\u{FF34}", .expected = "TEST" },
        .{ .input = "m\u{0331}a\u{0331}c\u{0331}r\u{0331}o\u{0331}n\u{0331} below", .expected = "macron below" },
        .{ .input = "cldrbug:1\u{0331}0\u{0331}1\u{0331}2\u{0331}3\u{0331}", .expected = "cldrbug:10123" },
        .{ .input = "\u{00C6} \u{00D8} \u{00DE} \u{00DF} \u{00A9}", .expected = "AE O TH ss (C)" },
        .{ .input = "\u{0141}\u{00F3}d\u{017A}", .expected = "Lodz" },
        .{ .input = "na\u{00EF}ve", .expected = "naive" },
        .{ .input = "\u{0130}stanbul", .expected = "Istanbul" },
        .{ .input = "\u{0149}", .expected = "'n" },
    };
    for (cases) |case| {
        const result = try transliterateAlloc(allocator, case.input, .latin_ascii);
        defer allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }

    const cjk = try transliterateAlloc(allocator, "\u{4F60}\u{597D}", .latin_ascii);
    defer allocator.free(cjk);
    try testing.expectEqualStrings("\u{4F60}\u{597D}", cjk);
}

test "fullwidth and halfwidth transliteration" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const halfwidth = try transliterateAlloc(
        allocator,
        "\u{FF21}\u{FF22}\u{FF23}\u{FF11}\u{FF12}\u{FF13}",
        .fullwidth_halfwidth,
    );
    defer allocator.free(halfwidth);
    try testing.expectEqualStrings("ABC123", halfwidth);

    const fullwidth = try transliterateAlloc(
        allocator,
        "ABC123",
        .halfwidth_fullwidth,
    );
    defer allocator.free(fullwidth);
    try testing.expectEqualStrings(
        "\u{FF21}\u{FF22}\u{FF23}\u{FF11}\u{FF12}\u{FF13}",
        fullwidth,
    );

    const katakana = try transliterateAlloc(
        allocator,
        "\u{30AC}\u{30AE}\u{30B0}",
        .fullwidth_halfwidth,
    );
    defer allocator.free(katakana);
    try testing.expectEqualStrings("\u{FF76}\u{FF9E}\u{FF77}\u{FF9E}\u{FF78}\u{FF9E}", katakana);

    const katakana_back = try transliterateAlloc(
        allocator,
        "\u{FF76}\u{FF9E}\u{FF77}\u{FF9E}\u{FF78}\u{FF9E}",
        .halfwidth_fullwidth,
    );
    defer allocator.free(katakana_back);
    try testing.expectEqualStrings("\u{30AC}\u{30AE}\u{30B0}", katakana_back);

    const apostrophe = try transliterateAlloc(
        allocator,
        "\u{FF07}",
        .fullwidth_halfwidth,
    );
    defer allocator.free(apostrophe);
    try testing.expectEqualStrings("'", apostrophe);

    const fullwidth_apostrophe = try transliterateAlloc(
        allocator,
        "'",
        .halfwidth_fullwidth,
    );
    defer allocator.free(fullwidth_apostrophe);
    try testing.expectEqualStrings("\u{FF07}", fullwidth_apostrophe);
}

test "normalization transliterators" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const decomposed = try transliterateAlloc(allocator, "\u{00E9}", .nfd);
    defer allocator.free(decomposed);
    try testing.expectEqualStrings("e\u{0301}", decomposed);

    const composed = try transliterateAlloc(allocator, "e\u{0301}", .nfc);
    defer allocator.free(composed);
    try testing.expectEqualStrings("\u{00E9}", composed);

    const compatibility = try transliterateAlloc(allocator, "\u{FB01}", .nfkc);
    defer allocator.free(compatibility);
    try testing.expectEqualStrings("fi", compatibility);
}

test "Georgian and Lao transliteration" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const georgian = try transliterateAlloc(
        allocator,
        "\u{10E1}\u{10D0}\u{10E5}\u{10D0}\u{10E0}\u{10D7}\u{10D5}\u{10D4}\u{10DA}\u{10DD}",
        .georgian_latin,
    );
    defer allocator.free(georgian);
    try testing.expectEqualStrings("sakartvelo", georgian);

    const bgn = try transliterateAlloc(
        allocator,
        "\u{10E1}\u{10D0}\u{10E5}\u{10D0}\u{10E0}\u{10D7}\u{10D5}\u{10D4}\u{10DA}\u{10DD}",
        .georgian_latin_bgn,
    );
    defer allocator.free(bgn);
    try testing.expectEqualStrings("sak\u{2019}art\u{2019}velo", bgn);

    const lao = try transliterateAlloc(
        allocator,
        "\u{0EC0}\u{0EB1}\u{0EBD}\u{0EB0}",
        .lao_latin,
    );
    defer allocator.free(lao);
    try testing.expectEqualStrings("ia", lao);
}

test "Latin-Georgian, Kazakh, and Uyghur transliteration" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const latin_georgian = try transliterateAlloc(
        allocator,
        "sakartvelo",
        .latin_georgian,
    );
    defer allocator.free(latin_georgian);
    try testing.expectEqualStrings(
        "\u{10E1}\u{10D0}\u{10E5}\u{10D0}\u{10E0}\u{10D7}\u{10D5}\u{10D4}\u{10DA}\u{10DD}",
        latin_georgian,
    );

    const kazakh = try transliterateAlloc(
        allocator,
        "\u{049B}\u{0430}\u{0437}\u{0430}\u{049B}",
        .kazakh_fonipa,
    );
    defer allocator.free(kazakh);
    try testing.expectEqualStrings("q\u{0251}z\u{0251}q", kazakh);

    const uyghur = try transliterateAlloc(
        allocator,
        "\u{0642}\u{0627}\u{0632}\u{0627}\u{0642}",
        .uyghur_fonipa,
    );
    defer allocator.free(uyghur);
    try testing.expectEqualStrings("qazaq", uyghur);

    const hebrew = try transliterateAlloc(
        allocator,
        "\u{05D0}\u{05B8}\u{05DC}\u{05B6}\u{05E3}",
        .hebrew_latin_bgn,
    );
    defer allocator.free(hebrew);
    try testing.expectEqualStrings("\u{2019}olef", hebrew);

    const russian = try transliterateAlloc(
        allocator,
        "\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}",
        .russian_latin_bgn,
    );
    defer allocator.free(russian);
    try testing.expectEqualStrings("Moskva", russian);
}

const conformance_fixtures = [_]struct {
    bytes: []const u8,
    magic: [4]u8,
    name: []const u8,
}{
    .{
        .bytes = @embedFile("transliterate/georgian_bgn_conformance.bin"),
        .magic = "CJTG".*,
        .name = "Georgian-Latin-BGN_1981",
    },
    .{
        .bytes = @embedFile("transliterate/hebrew_bgn_conformance.bin"),
        .magic = "CJTH".*,
        .name = "Hebrew-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/russian_bgn_conformance.bin"),
        .magic = "CJRU".*,
        .name = "Russian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/greek_bgn_conformance.bin"),
        .magic = "CJGR".*,
        .name = "Greek-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/katakana_bgn_conformance.bin"),
        .magic = "CJKA".*,
        .name = "Katakana-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/amharic_bgn_conformance.bin"),
        .magic = "CJAM".*,
        .name = "Amharic-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/kazakh_bgn_conformance.bin"),
        .magic = "CJKZ".*,
        .name = "Kazakh-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/turkmen_bgn_conformance.bin"),
        .magic = "CJTM".*,
        .name = "Turkmen-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/ukrainian_bgn_conformance.bin"),
        .magic = "CJUA".*,
        .name = "Ukrainian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/belarusian_bgn_conformance.bin"),
        .magic = "CJBY".*,
        .name = "Belarusian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/mongolian_bgn_conformance.bin"),
        .magic = "CJMO".*,
        .name = "Mongolian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/bulgarian_bgn_conformance.bin"),
        .magic = "CJBU".*,
        .name = "Bulgarian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/macedonian_bgn_conformance.bin"),
        .magic = "CJMC".*,
        .name = "Macedonian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/serbian_bgn_conformance.bin"),
        .magic = "CJRS".*,
        .name = "Serbian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/sgw_ethi_conformance.bin"),
        .magic = "CJSG".*,
        .name = "sgw-Ethi-t-und-ethi",
    },
    .{
        .bytes = @embedFile("transliterate/amharic_geminate_conformance.bin"),
        .magic = "CJGE".*,
        .name = "am-Ethi-t-am-ethi-m0-geminate",
    },
    .{
        .bytes = @embedFile("transliterate/ethi_aethiopi_conformance.bin"),
        .magic = "CJE3".*,
        .name = "und-Ethi-t-und-latn-m0-aethiopi",
    },
    .{
        .bytes = @embedFile("transliterate/ethi_beta_conformance.bin"),
        .magic = "CJE4".*,
        .name = "und-Ethi-t-und-latn-m0-beta_metsehaf",
    },
    .{
        .bytes = @embedFile("transliterate/ethi_ies_conformance.bin"),
        .magic = "CJE5".*,
        .name = "und-Ethi-t-und-latn-m0-ies-jes-1964",
    },
    .{
        .bytes = @embedFile("transliterate/byn_tekie_conformance.bin"),
        .magic = "CJBK".*,
        .name = "byn-Ethi-t-byn-latn-m0-tekie-alibekit",
    },
    .{
        .bytes = @embedFile("transliterate/ethi_lambdin_conformance.bin"),
        .magic = "CJE7".*,
        .name = "und-Ethi-t-und-latn-m0-lambdin",
    },
    .{
        .bytes = @embedFile("transliterate/si_latn_conformance.bin"),
        .magic = "CJSL".*,
        .name = "si-si_Latn",
    },
    .{
        .bytes = @embedFile("transliterate/my_fonipa_conformance.bin"),
        .magic = "CJMF".*,
        .name = "my-my_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/byn_xaleget_conformance.bin"),
        .magic = "CJB2".*,
        .name = "byn-Ethi-t-byn-latn-m0-xaleget",
    },
    .{
        .bytes = @embedFile("transliterate/cyrillic_latin_conformance.bin"),
        .magic = "CJYL".*,
        .name = "Cyrillic-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/arabic_latin_icu_conformance.bin"),
        .magic = "CJAL".*,
        .name = "Arabic-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_arabic_conformance.bin"),
        .magic = "CJIA".*,
        .name = "InterIndic-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_deva_conformance.bin"),
        .magic = "CJDE".*,
        .name = "InterIndic-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_beng_conformance.bin"),
        .magic = "CJIB".*,
        .name = "InterIndic-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_guru_conformance.bin"),
        .magic = "CJIG".*,
        .name = "InterIndic-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_gujr_conformance.bin"),
        .magic = "CJIU".*,
        .name = "InterIndic-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_orya_conformance.bin"),
        .magic = "CJIO".*,
        .name = "InterIndic-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_telu_conformance.bin"),
        .magic = "CJIE".*,
        .name = "InterIndic-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_knda_conformance.bin"),
        .magic = "CJIK".*,
        .name = "InterIndic-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_mlym_conformance.bin"),
        .magic = "CJIM".*,
        .name = "InterIndic-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_latn_conformance.bin"),
        .magic = "CJIX".*,
        .name = "InterIndic-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/chr_fonipa_conformance.bin"),
        .magic = "CJCH".*,
        .name = "chr-chr_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/zu_fonipa_conformance.bin"),
        .magic = "CJZU".*,
        .name = "zu-zu_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/kk_fonipa_conformance.bin"),
        .magic = "CJKK".*,
        .name = "kk-kk_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_taml_conformance.bin"),
        .magic = "CJTA".*,
        .name = "InterIndic-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/hiragana_katakana_conformance.bin"),
        .magic = "CJHK".*,
        .name = "Hiragana-Katakana",
    },
    .{
        .bytes = @embedFile("transliterate/persian_bgn_conformance.bin"),
        .magic = "CJPE".*,
        .name = "Persian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/nv_fonipa_conformance.bin"),
        .magic = "CJN2".*,
        .name = "nv-nv_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/si_fonipa_conformance.bin"),
        .magic = "CJSF".*,
        .name = "si-si_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/es_fonipa_conformance.bin"),
        .magic = "CJEF".*,
        .name = "es-es_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/xh_fonipa_conformance.bin"),
        .magic = "CJHF".*,
        .name = "xh-xh_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/vec_fonipa_conformance.bin"),
        .magic = "CJVF".*,
        .name = "vec-vec_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/ro_fonipa_conformance.bin"),
        .magic = "CJOF".*,
        .name = "ro-ro_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/arabic_bgn_conformance.bin"),
        .magic = "CJAB".*,
        .name = "Arabic-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/armenian_bgn_conformance.bin"),
        .magic = "CJHA".*,
        .name = "Armenian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/thaana_latin_conformance.bin"),
        .magic = "CJTN".*,
        .name = "Thaana-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/syriac_latin_conformance.bin"),
        .magic = "CJSY".*,
        .name = "Syriac-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/canadian_latin_conformance.bin"),
        .magic = "CJCA".*,
        .name = "CanadianAboriginal-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/tr_lower_conformance.bin"),
        .magic = "CJT2".*,
        .name = "tr-Lower",
    },
    .{
        .bytes = @embedFile("transliterate/az_lower_conformance.bin"),
        .magic = "CJAZ".*,
        .name = "az-Lower",
    },
    .{
        .bytes = @embedFile("transliterate/el_lower_conformance.bin"),
        .magic = "CJEL".*,
        .name = "el-Lower",
    },
    .{
        .bytes = @embedFile("transliterate/el_upper_conformance.bin"),
        .magic = "CJEU".*,
        .name = "el-Upper",
    },
    .{
        .bytes = @embedFile("transliterate/lt_lower_conformance.bin"),
        .magic = "CJLL".*,
        .name = "lt-Lower",
    },
    .{
        .bytes = @embedFile("transliterate/lt_upper_conformance.bin"),
        .magic = "CJLU".*,
        .name = "lt-Upper",
    },
    .{
        .bytes = @embedFile("transliterate/korean_bgn_conformance.bin"),
        .magic = "CJKO".*,
        .name = "Korean-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/kirghiz_bgn_conformance.bin"),
        .magic = "CJKI".*,
        .name = "Kirghiz-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/latin_armenian_conformance.bin"),
        .magic = "CJLA".*,
        .name = "Latin-Armenian",
    },
    .{
        .bytes = @embedFile("transliterate/azerbaijani_bgn_conformance.bin"),
        .magic = "CJA2".*,
        .name = "Azerbaijani-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/latin_cyrillic_conformance.bin"),
        .magic = "CJLC".*,
        .name = "Latin-Cyrillic",
    },
    .{
        .bytes = @embedFile("transliterate/latin_thaana_conformance.bin"),
        .magic = "CJTT".*,
        .name = "Latin-Thaana",
    },
    .{
        .bytes = @embedFile("transliterate/latin_canadian_conformance.bin"),
        .magic = "CJC2".*,
        .name = "Latin-CanadianAboriginal",
    },
    .{
        .bytes = @embedFile("transliterate/georgian_latin_conformance.bin"),
        .magic = "CJGG".*,
        .name = "Georgian-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/latin_georgian_conformance.bin"),
        .magic = "CJG3".*,
        .name = "Latin-Georgian",
    },
    .{
        .bytes = @embedFile("transliterate/halfwidth_conformance.bin"),
        .magic = "CJHW".*,
        .name = "Halfwidth-Fullwidth",
    },
    .{
        .bytes = @embedFile("transliterate/fullwidth_conformance.bin"),
        .magic = "CJFW".*,
        .name = "Fullwidth-Halfwidth",
    },
    .{
        .bytes = @embedFile("transliterate/latin_ascii_conformance.bin"),
        .magic = "CJAS".*,
        .name = "Latin-ASCII",
    },
    .{
        .bytes = @embedFile("transliterate/kirghiz_official_conformance.bin"),
        .magic = "CJK3".*,
        .name = "Kirghiz-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/armenian_official_conformance.bin"),
        .magic = "CJH3".*,
        .name = "Armenian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/persian_official_conformance.bin"),
        .magic = "CJP3".*,
        .name = "Persian-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/tr_upper_conformance.bin"),
        .magic = "CJTU".*,
        .name = "tr-Upper",
    },
    .{
        .bytes = @embedFile("transliterate/az_upper_conformance.bin"),
        .magic = "CJAU".*,
        .name = "az-Upper",
    },
    .{
        .bytes = @embedFile("transliterate/de_ascii_conformance.bin"),
        .magic = "CJD2".*,
        .name = "de-ASCII",
    },
    .{
        .bytes = @embedFile("transliterate/de_ascii_official_conformance.bin"),
        .magic = "CJD3".*,
        .name = "de-ASCII",
    },
    .{
        .bytes = @embedFile("transliterate/any_publishing_conformance.bin"),
        .magic = "CJAP".*,
        .name = "Any-Publishing",
    },
    .{
        .bytes = @embedFile("transliterate/katakana_hiragana_conformance.bin"),
        .magic = "CJKH".*,
        .name = "Katakana-Hiragana",
    },
    .{
        .bytes = @embedFile("transliterate/pashto_bgn_conformance.bin"),
        .magic = "CJPB".*,
        .name = "Pashto-Latin-BGN",
    },
    .{
        .bytes = @embedFile("transliterate/simp_trad_conformance.bin"),
        .magic = "CJZ1".*,
        .name = "Simplified-Traditional",
    },
    .{
        .bytes = @embedFile("transliterate/trad_simp_conformance.bin"),
        .magic = "CJZ2".*,
        .name = "Traditional-Simplified",
    },
    .{
        .bytes = @embedFile("transliterate/hans_hant_conformance.bin"),
        .magic = "CJZ3".*,
        .name = "Hans-Hant",
    },
    .{
        .bytes = @embedFile("transliterate/hant_hans_conformance.bin"),
        .magic = "CJZ4".*,
        .name = "Hant-Hans",
    },
    .{
        .bytes = @embedFile("transliterate/eth_gem_aeth_conformance.bin"),
        .magic = "CJEG".*,
        .name = "Ethiopic-Latin/Aethiopica_Geminate",
    },
    .{
        .bytes = @embedFile("transliterate/eth_gem_ies_conformance.bin"),
        .magic = "CJE6".*,
        .name = "Ethiopic-Latin/IES_JES_1964_Geminate",
    },
    .{
        .bytes = @embedFile("transliterate/my_fonipa_official.bin"),
        .magic = "CJM3".*,
        .name = "my-my_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/am_fonipa_conformance.bin"),
        .magic = "CJAF".*,
        .name = "am-am_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/am_fonipa_rev_conformance.bin"),
        .magic = "CJFA".*,
        .name = "am_FONIPA-am",
    },
    .{
        .bytes = @embedFile("transliterate/kk_am_conformance.bin"),
        .magic = "CJPA".*,
        .name = "kk-am",
    },
    .{
        .bytes = @embedFile("transliterate/my_am_conformance.bin"),
        .magic = "CJPM".*,
        .name = "my-am",
    },
    .{
        .bytes = @embedFile("transliterate/ro_am_conformance.bin"),
        .magic = "CJPR".*,
        .name = "ro-am",
    },
    .{
        .bytes = @embedFile("transliterate/si_am_conformance.bin"),
        .magic = "CJPS".*,
        .name = "si-am",
    },
    .{
        .bytes = @embedFile("transliterate/xh_am_conformance.bin"),
        .magic = "CJPX".*,
        .name = "xh-am",
    },
    .{
        .bytes = @embedFile("transliterate/zu_am_conformance.bin"),
        .magic = "CJPZ".*,
        .name = "zu-am",
    },
    .{
        .bytes = @embedFile("transliterate/latin_arabic_conformance.bin"),
        .magic = "CJLQ".*,
        .name = "Latin-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/latin_syriac_conformance.bin"),
        .magic = "CJLS".*,
        .name = "Latin-Syriac",
    },
    .{
        .bytes = @embedFile("transliterate/armenian_latin_conformance.bin"),
        .magic = "CJAR".*,
        .name = "Armenian-Latin",
    },    .{
        .bytes = @embedFile("transliterate/bengali_interindic_conformance.bin"),
        .magic = "CJBI".*,
        .name = "Bengali-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_interindic_conformance.bin"),
        .magic = "CJDI".*,
        .name = "Devanagari-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_interindic_conformance.bin"),
        .magic = "CJGI".*,
        .name = "Gujarati-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_interindic_conformance.bin"),
        .magic = "CJUI".*,
        .name = "Gurmukhi-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_interindic_conformance.bin"),
        .magic = "CJNK".*,
        .name = "Kannada-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_interindic_conformance.bin"),
        .magic = "CJMI".*,
        .name = "Malayalam-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_interindic_conformance.bin"),
        .magic = "CJRI".*,
        .name = "Oriya-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_interindic_conformance.bin"),
        .magic = "CJTI".*,
        .name = "Tamil-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_interindic_conformance.bin"),
        .magic = "CJEI".*,
        .name = "Telugu-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/latin_interindic_conformance.bin"),
        .magic = "CJLI".*,
        .name = "Latin-InterIndic",
    },
    .{
        .bytes = @embedFile("transliterate/latin_numeric_pinyin_conformance.bin"),
        .magic = "CJPN".*,
        .name = "Latin-NumericPinyin",
    },
    .{
        .bytes = @embedFile("transliterate/numeric_pinyin_latin_conformance.bin"),
        .magic = "CJNP".*,
        .name = "NumericPinyin-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/ja_latn_ko_conformance.bin"),
        .magic = "CJF8".*,
        .name = "ja_Latn-ko",
    },
    .{
        .bytes = @embedFile("transliterate/ru_zh_conformance.bin"),
        .magic = "CJF9".*,
        .name = "ru-zh",
    },
    .{
        .bytes = @embedFile("transliterate/ch_am_conformance.bin"),
        .magic = "CJF6".*,
        .name = "ch-am",
    },
    .{
        .bytes = @embedFile("transliterate/sk_am_conformance.bin"),
        .magic = "CJF7".*,
        .name = "sk-am",
    },
    .{
        .bytes = @embedFile("transliterate/pl_ja_conformance.bin"),
        .magic = "CJF1".*,
        .name = "pl-ja",
    },
    .{
        .bytes = @embedFile("transliterate/ro_ja_conformance.bin"),
        .magic = "CJF3".*,
        .name = "ro-ja",
    },
    .{
        .bytes = @embedFile("transliterate/sk_ja_conformance.bin"),
        .magic = "CJF5".*,
        .name = "sk-ja",
    },
    .{
        .bytes = @embedFile("transliterate/pl_fonipa_ja_conformance.bin"),
        .magic = "CJFS".*,
        .name = "pl_FONIPA-ja",
    },
    .{
        .bytes = @embedFile("transliterate/ro_fonipa_ja_conformance.bin"),
        .magic = "CJFX".*,
        .name = "ro_FONIPA-ja",
    },
    .{
        .bytes = @embedFile("transliterate/sk_fonipa_ja_conformance.bin"),
        .magic = "CJFY".*,
        .name = "sk_FONIPA-ja",
    },
    .{
        .bytes = @embedFile("transliterate/am_chr_conformance.bin"),
        .magic = "CJEY".*,
        .name = "am-chr",
    },
    .{
        .bytes = @embedFile("transliterate/ch_chr_conformance.bin"),
        .magic = "CJFI".*,
        .name = "ch-chr",
    },
    .{
        .bytes = @embedFile("transliterate/cs_chr_conformance.bin"),
        .magic = "CJFJ".*,
        .name = "cs-chr",
    },
    .{
        .bytes = @embedFile("transliterate/eo_chr_conformance.bin"),
        .magic = "CJFL".*,
        .name = "eo-chr",
    },
    .{
        .bytes = @embedFile("transliterate/es_am_conformance.bin"),
        .magic = "CJFN".*,
        .name = "es-am",
    },
    .{
        .bytes = @embedFile("transliterate/es_chr_conformance.bin"),
        .magic = "CJFO".*,
        .name = "es-chr",
    },
    .{
        .bytes = @embedFile("transliterate/es_419_chr_conformance.bin"),
        .magic = "CJFQ".*,
        .name = "es_419-chr",
    },
    .{
        .bytes = @embedFile("transliterate/hy_chr_conformance.bin"),
        .magic = "CJFR".*,
        .name = "hy-chr",
    },
    .{
        .bytes = @embedFile("transliterate/ia_chr_conformance.bin"),
        .magic = "CJFT".*,
        .name = "ia-chr",
    },
    .{
        .bytes = @embedFile("transliterate/kk_chr_conformance.bin"),
        .magic = "CJFU".*,
        .name = "kk-chr",
    },
    .{
        .bytes = @embedFile("transliterate/ky_chr_conformance.bin"),
        .magic = "CJFV".*,
        .name = "ky-chr",
    },
    .{
        .bytes = @embedFile("transliterate/rm_sursilv_chr_conformance.bin"),
        .magic = "CJFZ".*,
        .name = "rm_SURSILV-chr",
    },
    .{
        .bytes = @embedFile("transliterate/ro_chr_conformance.bin"),
        .magic = "CJF0".*,
        .name = "ro-chr",
    },
    .{
        .bytes = @embedFile("transliterate/si_chr_conformance.bin"),
        .magic = "CJF2".*,
        .name = "si-chr",
    },
    .{
        .bytes = @embedFile("transliterate/tlh_chr_conformance.bin"),
        .magic = "CJF4".*,
        .name = "tlh-chr",
    },
    .{
        .bytes = @embedFile("transliterate/han_spacedhan_conformance.bin"),
        .magic = "CJFP".*,
        .name = "Han-Spacedhan",
    },
    .{
        .bytes = @embedFile("transliterate/ipa_xsampa_conformance.bin"),
        .magic = "CJFK".*,
        .name = "IPA-XSampa",
    },
    .{
        .bytes = @embedFile("transliterate/latin_katakana_conformance.bin"),
        .magic = "CJFM".*,
        .name = "Latin-Katakana",
    },
    .{
        .bytes = @embedFile("transliterate/es_fonipa_am_conformance.bin"),
        .magic = "CJEQ".*,
        .name = "es_FONIPA-am",
    },
    .{
        .bytes = @embedFile("transliterate/und_fonipa_chr_conformance.bin"),
        .magic = "CJFH".*,
        .name = "und_FONIPA-chr",
    },
    .{
        .bytes = @embedFile("transliterate/fa_fa_fonipa_conformance.bin"),
        .magic = "CJEP".*,
        .name = "fa-fa_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/cs_fonipa_ja_conformance.bin"),
        .magic = "CJFE".*,
        .name = "cs_FONIPA-ja",
    },
    .{
        .bytes = @embedFile("transliterate/es_fonipa_es_419_fonipa_conformance.bin"),
        .magic = "CJFD".*,
        .name = "es_FONIPA-es_419_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/es_fonipa_ja_conformance.bin"),
        .magic = "CJFG".*,
        .name = "es_FONIPA-ja",
    },
    .{
        .bytes = @embedFile("transliterate/it_am_conformance.bin"),
        .magic = "CJEE".*,
        .name = "it-am",
    },
    .{
        .bytes = @embedFile("transliterate/it_ja_conformance.bin"),
        .magic = "CJEP".*,
        .name = "it-ja",
    },
    .{
        .bytes = @embedFile("transliterate/ja_latn_ru_conformance.bin"),
        .magic = "CJES".*,
        .name = "ja_Latn-ru",
    },
    .{
        .bytes = @embedFile("transliterate/ru_ja_conformance.bin"),
        .magic = "CJET".*,
        .name = "ru-ja",
    },
    .{
        .bytes = @embedFile("transliterate/dsb_dsb_fonipa_conformance.bin"),
        .magic = "CJEH".*,
        .name = "dsb-dsb_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/latin_hebrew_conformance.bin"),
        .magic = "CJLH".*,
        .name = "Latin-Hebrew",
    },
    .{
        .bytes = @embedFile("transliterate/thailogical_latin_conformance.bin"),
        .magic = "CJEO".*,
        .name = "ThaiLogical-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/sat_am_conformance.bin"),
        .magic = "CJER".*,
        .name = "sat-am",
    },
    .{
        .bytes = @embedFile("transliterate/sat_olck_sat_fonipa_conformance.bin"),
        .magic = "CJEM".*,
        .name = "sat_Olck-sat_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/uz_cyrl_uz_latn_conformance.bin"),
        .magic = "CJEN".*,
        .name = "uz_Cyrl-uz_Latn",
    },
    .{
        .bytes = @embedFile("transliterate/nl_title_conformance.bin"),
        .magic = "CJD0".*,
        .name = "nl-Title",
    },
    .{
        .bytes = @embedFile("transliterate/ug_fonipa_conformance.bin"),
        .magic = "CJUG".*,
        .name = "ug-ug_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/greek_latin_conformance.bin"),
        .magic = "CJGK".*,
        .name = "Greek-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/latin_greek_conformance.bin"),
        .magic = "CJGL".*,
        .name = "Latin-Greek",
    },
    .{
        .bytes = @embedFile("transliterate/hebrew_latin_conformance.bin"),
        .magic = "CJHL".*,
        .name = "Hebrew-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/az_title_conformance.bin"),
        .magic = "CJDS".*,
        .name = "az-Title",
    },
    .{
        .bytes = @embedFile("transliterate/el_title_conformance.bin"),
        .magic = "CJDU".*,
        .name = "el-Title",
    },
    .{
        .bytes = @embedFile("transliterate/lt_title_conformance.bin"),
        .magic = "CJDY".*,
        .name = "lt-Title",
    },
    .{
        .bytes = @embedFile("transliterate/tr_title_conformance.bin"),
        .magic = "CJEA".*,
        .name = "tr-Title",
    },
    .{
        .bytes = @embedFile("transliterate/interindic_ur_conformance.bin"),
        .magic = "CJDT".*,
        .name = "InterIndic-ur",
    },
    .{
        .bytes = @embedFile("transliterate/latin_russian_bgn_conformance.bin"),
        .magic = "CJEV".*,
        .name = "Latin-Russian/BGN",
    },
    .{
        .bytes = @embedFile("transliterate/maldivian_latin_bgn_conformance.bin"),
        .magic = "CJEX".*,
        .name = "Maldivian-Latin/BGN",
    },
    .{
        .bytes = @embedFile("transliterate/uzbek_latin_bgn_conformance.bin"),
        .magic = "CJEW".*,
        .name = "Uzbek-Latin/BGN",
    },
    .{
        .bytes = @embedFile("transliterate/ch_ch_fonipa_conformance.bin"),
        .magic = "CJDV".*,
        .name = "ch-ch_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/cs_am_conformance.bin"),
        .magic = "CJEZ".*,
        .name = "cs-am",
    },
    .{
        .bytes = @embedFile("transliterate/cs_cs_fonipa_conformance.bin"),
        .magic = "CJDX".*,
        .name = "cs-cs_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/eo_am_conformance.bin"),
        .magic = "CJE0".*,
        .name = "eo-am",
    },
    .{
        .bytes = @embedFile("transliterate/eo_eo_fonipa_conformance.bin"),
        .magic = "CJDZ".*,
        .name = "eo-eo_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/ha_ha_ne_conformance.bin"),
        .magic = "CJEJ".*,
        .name = "ha-ha_NE",
    },
    .{
        .bytes = @embedFile("transliterate/hy_am_conformance.bin"),
        .magic = "CJE1".*,
        .name = "hy-am",
    },
    .{
        .bytes = @embedFile("transliterate/hy_hy_fonipa_conformance.bin"),
        .magic = "CJD1".*,
        .name = "hy-hy_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/hy_arevmda_am_conformance.bin"),
        .magic = "CJE2".*,
        .name = "hy_AREVMDA-am",
    },
    .{
        .bytes = @embedFile("transliterate/hy_arevmda_hy_arevmda_fonipa_conformance.bin"),
        .magic = "CJD4".*,
        .name = "hy_AREVMDA-hy_AREVMDA_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/ia_am_conformance.bin"),
        .magic = "CJE8".*,
        .name = "ia-am",
    },
    .{
        .bytes = @embedFile("transliterate/ia_ia_fonipa_conformance.bin"),
        .magic = "CJD5".*,
        .name = "ia-ia_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/ky_am_conformance.bin"),
        .magic = "CJE9".*,
        .name = "ky-am",
    },
    .{
        .bytes = @embedFile("transliterate/ky_ky_fonipa_conformance.bin"),
        .magic = "CJD6".*,
        .name = "ky-ky_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/la_la_fonipa_conformance.bin"),
        .magic = "CJD7".*,
        .name = "la-la_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/pl_am_conformance.bin"),
        .magic = "CJFB".*,
        .name = "pl-am",
    },
    .{
        .bytes = @embedFile("transliterate/pl_pl_fonipa_conformance.bin"),
        .magic = "CJD8".*,
        .name = "pl-pl_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/rm_sursilv_am_conformance.bin"),
        .magic = "CJFC".*,
        .name = "rm_SURSILV-am",
    },
    .{
        .bytes = @embedFile("transliterate/rm_sursilv_rm_fonipa_sursilv_conformance.bin"),
        .magic = "CJD9".*,
        .name = "rm_SURSILV-rm_FONIPA_SURSILV",
    },
    .{
        .bytes = @embedFile("transliterate/sk_sk_fonipa_conformance.bin"),
        .magic = "CJEB".*,
        .name = "sk-sk_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/ta_ta_fonipa_conformance.bin"),
        .magic = "CJEC".*,
        .name = "ta-ta_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/tlh_am_conformance.bin"),
        .magic = "CJFF".*,
        .name = "tlh-am",
    },
    .{
        .bytes = @embedFile("transliterate/tlh_tlh_fonipa_conformance.bin"),
        .magic = "CJED".*,
        .name = "tlh-tlh_FONIPA",
    },
    .{
        .bytes = @embedFile("transliterate/yo_yo_bj_conformance.bin"),
        .magic = "CJEK".*,
        .name = "yo-yo_BJ",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_arabic_conformance.bin"),
        .magic = "CJAA".*,
        .name = "Bengali-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_ur_conformance.bin"),
        .magic = "CJAO".*,
        .name = "Bengali-ur",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_arabic_conformance.bin"),
        .magic = "CJAQ".*,
        .name = "Devanagari-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_ur_conformance.bin"),
        .magic = "CJA5".*,
        .name = "Devanagari-ur",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_arabic_conformance.bin"),
        .magic = "CJA6".*,
        .name = "Gujarati-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_ur_conformance.bin"),
        .magic = "CJBG".*,
        .name = "Gujarati-ur",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_arabic_conformance.bin"),
        .magic = "CJBH".*,
        .name = "Gurmukhi-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_ur_conformance.bin"),
        .magic = "CJBV".*,
        .name = "Gurmukhi-ur",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_arabic_conformance.bin"),
        .magic = "CJBW".*,
        .name = "Kannada-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_ur_conformance.bin"),
        .magic = "CJB9".*,
        .name = "Kannada-ur",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_arabic_conformance.bin"),
        .magic = "CJCB".*,
        .name = "Malayalam-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_ur_conformance.bin"),
        .magic = "CJCN".*,
        .name = "Malayalam-ur",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_arabic_conformance.bin"),
        .magic = "CJCO".*,
        .name = "Oriya-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_ur_conformance.bin"),
        .magic = "CJC0".*,
        .name = "Oriya-ur",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_arabic_conformance.bin"),
        .magic = "CJC3".*,
        .name = "Tamil-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_ur_conformance.bin"),
        .magic = "CJDF".*,
        .name = "Tamil-ur",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_arabic_conformance.bin"),
        .magic = "CJDG".*,
        .name = "Telugu-Arabic",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_ur_conformance.bin"),
        .magic = "CJDR".*,
        .name = "Telugu-ur",
    },
    .{
        .bytes = @embedFile("transliterate/latin_bengali_conformance.bin"),
        .magic = "CJAA".*,
        .name = "Latin-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/latin_devanagari_conformance.bin"),
        .magic = "CJAO".*,
        .name = "Latin-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/latin_gujarati_conformance.bin"),
        .magic = "CJAQ".*,
        .name = "Latin-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/latin_gurmukhi_conformance.bin"),
        .magic = "CJA5".*,
        .name = "Latin-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/latin_kannada_conformance.bin"),
        .magic = "CJA6".*,
        .name = "Latin-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/latin_malayalam_conformance.bin"),
        .magic = "CJBG".*,
        .name = "Latin-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/latin_oriya_conformance.bin"),
        .magic = "CJBH".*,
        .name = "Latin-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/latin_tamil_conformance.bin"),
        .magic = "CJBV".*,
        .name = "Latin-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/latin_telugu_conformance.bin"),
        .magic = "CJBW".*,
        .name = "Latin-Telugu",
    },    .{
        .bytes = @embedFile("transliterate/bengali_devanagari_conformance.bin"),
        .magic = "CJAC".*,
        .name = "Bengali-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_gujarati_conformance.bin"),
        .magic = "CJAD".*,
        .name = "Bengali-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_gurmukhi_conformance.bin"),
        .magic = "CJAE".*,
        .name = "Bengali-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_kannada_conformance.bin"),
        .magic = "CJAG".*,
        .name = "Bengali-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_latin_conformance.bin"),
        .magic = "CJAH".*,
        .name = "Bengali-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_malayalam_conformance.bin"),
        .magic = "CJAI".*,
        .name = "Bengali-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_oriya_conformance.bin"),
        .magic = "CJAJ".*,
        .name = "Bengali-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_tamil_conformance.bin"),
        .magic = "CJAK".*,
        .name = "Bengali-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/bengali_telugu_conformance.bin"),
        .magic = "CJAN".*,
        .name = "Bengali-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_bengali_conformance.bin"),
        .magic = "CJAT".*,
        .name = "Devanagari-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_gujarati_conformance.bin"),
        .magic = "CJAV".*,
        .name = "Devanagari-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_gurmukhi_conformance.bin"),
        .magic = "CJAW".*,
        .name = "Devanagari-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_kannada_conformance.bin"),
        .magic = "CJAX".*,
        .name = "Devanagari-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_latin_conformance.bin"),
        .magic = "CJAY".*,
        .name = "Devanagari-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_malayalam_conformance.bin"),
        .magic = "CJA0".*,
        .name = "Devanagari-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_oriya_conformance.bin"),
        .magic = "CJA1".*,
        .name = "Devanagari-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_tamil_conformance.bin"),
        .magic = "CJA3".*,
        .name = "Devanagari-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/devanagari_telugu_conformance.bin"),
        .magic = "CJA4".*,
        .name = "Devanagari-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_bengali_conformance.bin"),
        .magic = "CJA7".*,
        .name = "Gujarati-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_devanagari_conformance.bin"),
        .magic = "CJA8".*,
        .name = "Gujarati-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_gurmukhi_conformance.bin"),
        .magic = "CJA9".*,
        .name = "Gujarati-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_kannada_conformance.bin"),
        .magic = "CJBA".*,
        .name = "Gujarati-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_latin_conformance.bin"),
        .magic = "CJBB".*,
        .name = "Gujarati-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_malayalam_conformance.bin"),
        .magic = "CJBC".*,
        .name = "Gujarati-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_oriya_conformance.bin"),
        .magic = "CJBD".*,
        .name = "Gujarati-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_tamil_conformance.bin"),
        .magic = "CJBE".*,
        .name = "Gujarati-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/gujarati_telugu_conformance.bin"),
        .magic = "CJBF".*,
        .name = "Gujarati-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_bengali_conformance.bin"),
        .magic = "CJBJ".*,
        .name = "Gurmukhi-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_devanagari_conformance.bin"),
        .magic = "CJBL".*,
        .name = "Gurmukhi-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_gujarati_conformance.bin"),
        .magic = "CJBM".*,
        .name = "Gurmukhi-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_kannada_conformance.bin"),
        .magic = "CJBN".*,
        .name = "Gurmukhi-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_latin_conformance.bin"),
        .magic = "CJBO".*,
        .name = "Gurmukhi-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_malayalam_conformance.bin"),
        .magic = "CJBP".*,
        .name = "Gurmukhi-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_oriya_conformance.bin"),
        .magic = "CJBQ".*,
        .name = "Gurmukhi-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_tamil_conformance.bin"),
        .magic = "CJBR".*,
        .name = "Gurmukhi-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/gurmukhi_telugu_conformance.bin"),
        .magic = "CJBS".*,
        .name = "Gurmukhi-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_bengali_conformance.bin"),
        .magic = "CJBX".*,
        .name = "Kannada-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_devanagari_conformance.bin"),
        .magic = "CJBZ".*,
        .name = "Kannada-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_gujarati_conformance.bin"),
        .magic = "CJB0".*,
        .name = "Kannada-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_gurmukhi_conformance.bin"),
        .magic = "CJB3".*,
        .name = "Kannada-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_latin_conformance.bin"),
        .magic = "CJB4".*,
        .name = "Kannada-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_malayalam_conformance.bin"),
        .magic = "CJB5".*,
        .name = "Kannada-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_oriya_conformance.bin"),
        .magic = "CJB6".*,
        .name = "Kannada-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_tamil_conformance.bin"),
        .magic = "CJB7".*,
        .name = "Kannada-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/kannada_telugu_conformance.bin"),
        .magic = "CJB8".*,
        .name = "Kannada-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_bengali_conformance.bin"),
        .magic = "CJCC".*,
        .name = "Malayalam-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_devanagari_conformance.bin"),
        .magic = "CJCD".*,
        .name = "Malayalam-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_gujarati_conformance.bin"),
        .magic = "CJCE".*,
        .name = "Malayalam-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_gurmukhi_conformance.bin"),
        .magic = "CJCF".*,
        .name = "Malayalam-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_kannada_conformance.bin"),
        .magic = "CJCG".*,
        .name = "Malayalam-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_latin_conformance.bin"),
        .magic = "CJCI".*,
        .name = "Malayalam-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_oriya_conformance.bin"),
        .magic = "CJCJ".*,
        .name = "Malayalam-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_tamil_conformance.bin"),
        .magic = "CJCK".*,
        .name = "Malayalam-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/malayalam_telugu_conformance.bin"),
        .magic = "CJCM".*,
        .name = "Malayalam-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_bengali_conformance.bin"),
        .magic = "CJCP".*,
        .name = "Oriya-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_devanagari_conformance.bin"),
        .magic = "CJCQ".*,
        .name = "Oriya-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_gujarati_conformance.bin"),
        .magic = "CJCR".*,
        .name = "Oriya-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_gurmukhi_conformance.bin"),
        .magic = "CJCU".*,
        .name = "Oriya-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_kannada_conformance.bin"),
        .magic = "CJCV".*,
        .name = "Oriya-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_latin_conformance.bin"),
        .magic = "CJCW".*,
        .name = "Oriya-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_malayalam_conformance.bin"),
        .magic = "CJCX".*,
        .name = "Oriya-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_tamil_conformance.bin"),
        .magic = "CJCY".*,
        .name = "Oriya-Tamil",
    },
    .{
        .bytes = @embedFile("transliterate/oriya_telugu_conformance.bin"),
        .magic = "CJCZ".*,
        .name = "Oriya-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_bengali_conformance.bin"),
        .magic = "CJC4".*,
        .name = "Tamil-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_devanagari_conformance.bin"),
        .magic = "CJC5".*,
        .name = "Tamil-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_gujarati_conformance.bin"),
        .magic = "CJC6".*,
        .name = "Tamil-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_gurmukhi_conformance.bin"),
        .magic = "CJC7".*,
        .name = "Tamil-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_kannada_conformance.bin"),
        .magic = "CJC8".*,
        .name = "Tamil-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_latin_conformance.bin"),
        .magic = "CJC9".*,
        .name = "Tamil-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_malayalam_conformance.bin"),
        .magic = "CJDA".*,
        .name = "Tamil-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_oriya_conformance.bin"),
        .magic = "CJDC".*,
        .name = "Tamil-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/tamil_telugu_conformance.bin"),
        .magic = "CJDD".*,
        .name = "Tamil-Telugu",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_bengali_conformance.bin"),
        .magic = "CJDH".*,
        .name = "Telugu-Bengali",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_devanagari_conformance.bin"),
        .magic = "CJDJ".*,
        .name = "Telugu-Devanagari",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_gujarati_conformance.bin"),
        .magic = "CJDK".*,
        .name = "Telugu-Gujarati",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_gurmukhi_conformance.bin"),
        .magic = "CJDL".*,
        .name = "Telugu-Gurmukhi",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_kannada_conformance.bin"),
        .magic = "CJDM".*,
        .name = "Telugu-Kannada",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_latin_conformance.bin"),
        .magic = "CJDN".*,
        .name = "Telugu-Latin",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_malayalam_conformance.bin"),
        .magic = "CJDO".*,
        .name = "Telugu-Malayalam",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_oriya_conformance.bin"),
        .magic = "CJDP".*,
        .name = "Telugu-Oriya",
    },
    .{
        .bytes = @embedFile("transliterate/telugu_tamil_conformance.bin"),
        .magic = "CJDQ".*,
        .name = "Telugu-Tamil",
    },
};

test "transliterate by CLDR name" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const russian = try transliterateByNameAlloc(
        allocator,
        "\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}",
        "Russian-Latin-BGN",
    );
    defer allocator.free(russian);
    try testing.expectEqualStrings("Moskva", russian);

    try testing.expectError(
        error.UnknownTransform,
        transliterateByNameAlloc(allocator, "x", "No-Such-Transform"),
    );
    try testing.expectError(
        error.InvalidUtf8,
        transliterateByNameAlloc(allocator, "\xff", "Russian-Latin-BGN"),
    );
}

test "CLDR transform conformance" {
    var failures: usize = 0;
    for (conformance_fixtures) |fixture| {
        const fixture_failures = try checkTransformConformance(
            fixture.bytes,
            fixture.magic,
            fixture.name,
        );
        if (fixture_failures != 0) {
            std.debug.print(
                "FAILURES {s}: {d}\n",
                .{ fixture.name, fixture_failures },
            );
        }
        failures += fixture_failures;
    }
    if (failures != 0) {
        std.debug.print(
            "transliteration conformance failures: {d}\n",
            .{failures},
        );
        return error.TestUnexpectedResult;
    }
}

fn checkTransformConformance(
    fixture: []const u8,
    magic: [4]u8,
    transform_name: []const u8,
) !usize {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    if (fixture.len < 12 or !std.mem.eql(u8, fixture[0..4], &magic) or
        fixture[4] != 1 or fixture[5] != 48 or
        fixture[6] != 0 or fixture[7] != 0)
    {
        return error.InvalidFixture;
    }
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var offset: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |case_index| {
        if (offset + 4 > fixture.len) return error.InvalidFixture;
        const source_len = std.mem.readInt(
            u16,
            fixture[offset..][0..2],
            .little,
        );
        const target_len = std.mem.readInt(
            u16,
            fixture[offset + 2 ..][0..2],
            .little,
        );
        offset += 4;
        if (offset + source_len + target_len > fixture.len) {
            return error.InvalidFixture;
        }
        const source = fixture[offset..][0..source_len];
        offset += source_len;
        const target = fixture[offset..][0..target_len];
        offset += target_len;

        const converted = try transliterateByNameAlloc(
            allocator,
            source,
            transform_name,
        );
        const actual = converted;
        if (!std.mem.eql(u8, actual, target)) {
            if (std.mem.eql(u8, transform_name, "my-my_FONIPA") and
                case_index == 0)
            {
                std.debug.print("expected:", .{});
                for (target) |byte| std.debug.print(" {x:0>2}", .{byte});
                std.debug.print("\nactual:  ", .{});
                for (actual) |byte| std.debug.print(" {x:0>2}", .{byte});
                std.debug.print("\n", .{});
            }
            if (failures < 20) {
                std.debug.print(
                    "{s} conformance case {d}: expected {s}, got {s}\n",
                    .{ transform_name, case_index, target, actual },
                );
            }
            failures += 1;
            allocator.free(converted);
            continue;
        }
        allocator.free(converted);
    }
    if (offset != fixture.len) return error.InvalidFixture;
    return failures;
}

test "named normalization and case transforms" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const nfd = try transliterateByNameAlloc(allocator, "\u{00e9}", "NFD");
    defer allocator.free(nfd);
    try testing.expectEqualStrings("e\u{0301}", nfd);

    const nfc = try transliterateByNameAlloc(allocator, "e\u{0301}", "NFC");
    defer allocator.free(nfc);
    try testing.expectEqualStrings("\u{00e9}", nfc);

    const upper = try transliterateByNameAlloc(allocator, "stra\u{00df}e", "Any-Upper");
    defer allocator.free(upper);
    try testing.expectEqualStrings("STRASSE", upper);

    const lower = try transliterateByNameAlloc(allocator, "\u{0130}", "Any-Lower");
    defer allocator.free(lower);
    try testing.expectEqualStrings("i\u{0307}", lower);

    const title = try transliterateByNameAlloc(
        allocator,
        "hello world",
        "Any-Title",
    );
    defer allocator.free(title);
    try testing.expectEqualStrings("Hello World", title);
}

test "transform discovery" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    try testing.expect(transformCount() >= 80);
    try testing.expectEqual(
        @as(usize, transform_count) + named_transform_names.len,
        transformCount(),
    );
    try testing.expect(hasTransform("Latin-ASCII"));
    try testing.expect(hasTransform("Russian-Latin-BGN"));
    try testing.expect(hasTransform("NFC"));
    try testing.expect(hasTransform("Any-Title"));
    try testing.expect(transformIndex("Latin-ASCII") != null);
    try testing.expect(transformIndex("NFC") == null);
    try testing.expect(transformIndex("No-Such-Transform") == null);
    try testing.expect(!hasTransform(""));
    try testing.expectError(
        error.UnknownTransform,
        transliterateByNameAlloc(allocator, "abc", ""),
    );
    try testing.expect(transformIndex("ru-ru_Latn/BGN") != null);
    try testing.expect(!hasTransform("No-Such-Transform"));
    var found = false;
    var found_named = false;
    for (0..transformCount()) |index| {
        const name = transformNameAt(index) orelse return error.TestUnexpectedResult;
        if (std.mem.eql(u8, name, "Simplified-Traditional")) found = true;
        if (std.mem.eql(u8, name, "Any-Lower")) found_named = true;
    }
    try testing.expect(found);
    try testing.expect(found_named);
    try testing.expect(transformNameAt(transformCount()) == null);

    const icu_named = try transliterateByNameAlloc(
        allocator,
        "\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}",
        "ru-ru_Latn/BGN",
    );
    defer allocator.free(icu_named);
    try testing.expectEqualStrings("Moskva", icu_named);
    try testing.expect(hasTransform("ru-ru_Latn/BGN"));

    const decoded = try transliterateByNameAlloc(
        allocator,
        "a\\u0042",
        "Hex-Any",
    );
    defer allocator.free(decoded);
    try testing.expectEqualStrings("aB", decoded);
    const braced = try transliterateByNameAlloc(
        allocator,
        "\\x{1F600}",
        "Hex-Any",
    );
    defer allocator.free(braced);
    try testing.expectEqualStrings("\u{1F600}", braced);
    const bare_hex = try transliterateByNameAlloc(allocator, "\\x41", "Hex-Any");
    defer allocator.free(bare_hex);
    try testing.expectEqualStrings("\\x41", bare_hex);
    const encoded = try transliterateByNameAlloc(allocator, "\u{00e9}", "Any-Hex");
    defer allocator.free(encoded);
    try testing.expectEqualStrings("\\u00E9", encoded);
    const ascii_hex = try transliterateByNameAlloc(allocator, "A ", "Any-Hex");
    defer allocator.free(ascii_hex);
    try testing.expectEqualStrings("\\u0041\\u0020", ascii_hex);

    const named = try transliterateByNameAlloc(
        allocator,
        "\\N{LATIN CAPITAL LETTER A}",
        "Name-Any",
    );
    defer allocator.free(named);
    try testing.expectEqualStrings("A", named);
    const unknown_name = try transliterateByNameAlloc(
        allocator,
        "\\N{NO SUCH NAME}",
        "Name-Any",
    );
    defer allocator.free(unknown_name);
    try testing.expectEqualStrings("\\N{NO SUCH NAME}", unknown_name);

    const encoded_name = try transliterateByNameAlloc(allocator, "A", "Any-Name");
    defer allocator.free(encoded_name);
    try testing.expectEqualStrings(
        "\\N{LATIN CAPITAL LETTER A}",
        encoded_name,
    );
    const pua_name = try transliterateByNameAlloc(allocator, "\u{E000}", "Any-Name");
    defer allocator.free(pua_name);
    try testing.expectEqualStrings(
        "\\N{<private use area-E000>}",
        pua_name,
    );
    const unassigned_name = try transliterateByNameAlloc(
        allocator,
        "\u{0378}",
        "Any-Name",
    );
    defer allocator.free(unassigned_name);
    try testing.expectEqualStrings("\\N{<unassigned-0378>}", unassigned_name);

    const identity = try transliterateByNameAlloc(allocator, "abc", "Any-Null");
    defer allocator.free(identity);
    try testing.expectEqualStrings("abc", identity);
}

test "transform aliases resolve" {
    const testing = @import("std").testing;
    for (transform_aliases) |alias| {
        try testing.expect(findTransformByName(alias.clrd) != null);
        try testing.expect(hasTransform(alias.icu));
    }
}

test "discovered names resolve" {
    const testing = @import("std").testing;
    for (0..transformCount()) |index| {
        const name = transformNameAt(index) orelse
            return error.TestUnexpectedResult;
        try testing.expect(hasTransform(name));
    }
}

test "Hex-Any keeps malformed escapes" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const out = try transliterateByNameAlloc(allocator, "\\uZZZZ", "Hex-Any");
    defer allocator.free(out);
    try testing.expectEqualStrings("\\uZZZZ", out);
}

test "transliteration data version" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("48", cldr_version);
}

test "transform aliases execute" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    for (transform_aliases) |alias| {
        const out = try transliterateByNameAlloc(allocator, "abc", alias.icu);
        defer allocator.free(out);
    }
}
