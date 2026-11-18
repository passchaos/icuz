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

const header_len = 40;
const transform_count = data[8];
const entry_count = readU32(10);
const source_count = readU32(14);
const target_count = readU32(18);
const set_count = readU32(22);
const range_count = readU32(26);
const context_count = readU32(30);
const context_element_count = readU32(34);
const transform_offset = header_len;
const entry_offset = transform_offset + @as(usize, transform_count) * 24;
const set_offset = entry_offset + @as(usize, entry_count) * 20;
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
        data[4] != 10 or data[5] != 48 or data[6] != 0 or data[7] != 0)
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
    next_transform: u32,
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
};

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn transformAt(index: usize) TransformRecord {
    const base = transform_offset + index * 24;
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
        .next_transform = readU32(base + 20),
    };
}

/// Number of compiled table transforms available by name.
pub fn transformCount() usize {
    return transform_count;
}

/// Name of the transform at `index`, or null when out of range.
pub fn transformNameAt(index: usize) ?[]const u8 {
    if (index >= transform_count) return null;
    const record = transformAt(index);
    return data[names_offset + record.name_offset ..][0..record.name_len];
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
        "Latin-ASCII", "NFC",     "NFD",       "NFKC",      "NFKD",
        "Any-Lower",   "Any-Upper", "Any-Title", "Any-Null", "Null",
        "Hex-Any",     "Any-Hex",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
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
    const base = entry_offset + index * 20;
    return .{
        .source_offset = readU32(base),
        .source_len = data[base + 4],
        .target_offset = readU32(base + 5),
        .target_len = data[base + 9],
        .before_context = readU32(base + 10),
        .after_context = readU32(base + 14),
        .pass = data[base + 18],
        .flags = data[base + 19],
    };
}

fn sourceCodepoint(entry: Entry, index: usize) u21 {
    return @intCast(readU32(sources_offset +
        (@as(usize, entry.source_offset) + index) * 4));
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
fn mappingStart(range: EntryRange) usize {
    var start = range.start;
    while (start < range.end and entryAt(start).flags & 5 != 0) : (start += 1) {}
    return start;
}

fn hasInsertions(range: EntryRange) bool {
    var index = range.start;
    while (index < range.end) : (index += 1) {
        const flags = entryAt(index).flags;
        if (flags & 1 != 0) return true;
        if (flags & 5 == 0) break;
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
                if (entry.flags & 5 == 0) break;
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
    var lead = range.start;
    while (lead < literals_start) : (lead += 1) {
        const entry = entryAt(lead);
        if (entry.flags & 4 == 0) continue;
        // A repeated class source consumes the longest run in the set.
        var consumed: usize = 0;
        while (index + consumed < codepoints.len and consumed < 255 and
            setContains(entry.source_offset, codepoints[index + consumed]))
        {
            consumed += 1;
        }
        if (consumed < entry.source_len) continue;
        if (!contextMatches(entry.before_context, before, before.len, false)) {
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
        return matched;
    }
    var low = literals_start;
    var high = range.end;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sourceCodepoint(entryAt(middle), 0) < first) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    var entry_index = low;
    while (entry_index < range.end) : (entry_index += 1) {
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
        return entry;
    }
    return null;
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
            const target_len: usize = entry.target_len;
            for (0..target_len) |offset| {
                target_buffer[offset] = targetCodepoint(entry, offset);
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

fn tableAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    const result = try tableCoreAlloc(allocator, text, transform_index);
    const record = transformAt(transform_index);
    if (record.next_transform == 0xffff_ffff) return result;
    const next = record.next_transform;
    const chained = if (std.mem.eql(u8, transformName(next), "Latin-ASCII"))
        try latinAsciiAlloc(allocator, result)
    else
        try tableCoreAlloc(allocator, result, next);
    allocator.free(result);
    return chained;
}

fn tableCoreAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    transform_index: usize,
) Error![]u8 {
    const record = transformAt(transform_index);
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
        const form: normalization.Form = switch (record.pre_normalization) {
            1 => .nfd,
            2 => .nfc,
            3 => .nfkd,
            4 => .nfkc,
            else => .nfc,
        };
        normalized = try normalization.normalizeFormAlloc(allocator, text, form);
        if (normalized) |value| source = value;
    }
    defer if (normalized) |value| allocator.free(value);

    var codepoints = try decodeAlloc(allocator, source);
    defer codepoints.deinit(allocator);

    const pass_count: usize = @max(record.pass_count, 1);
    var current: []const u21 = codepoints.items;
    var pass_output: ?std.ArrayList(u21) = null;
    defer if (pass_output) |*value| value.deinit(allocator);

    // Each pass applies its empty-source insertion rules, then its mapping
    // rules. Every pass except the last writes intermediate codepoints; the
    // final pass emits UTF-8 directly.
    var pass: usize = 0;
    while (pass < pass_count) : (pass += 1) {
        const range = transformPassRange(transform_index, @intCast(pass));
        var pass_input: []const u21 = current;
        var inserted: ?std.ArrayList(u21) = null;
        defer if (inserted) |*value| value.deinit(allocator);
        if (hasInsertions(range)) {
            inserted = try applyInsertions(allocator, current, range);
            pass_input = inserted.?.items;
        }
        var next = try applyPassAlloc(
            allocator,
            pass_input,
            range,
            if (pass == 0) record.filter_set else 0,
        );
        if (pass + 1 == pass_count) {
            defer next.deinit(allocator);
            var output = std.ArrayList(u8).empty;
            errdefer output.deinit(allocator);
            for (next.items) |codepoint| {
                try appendCodepoint(allocator, &output, codepoint);
            }
            var raw = try output.toOwnedSlice(allocator);
            if (record.final_case != 0) {
                const cased = if (record.final_case == 1)
                    try case_mapping.fullLowerAlloc(allocator, raw, .{})
                else
                    try case_mapping.fullUpperAlloc(allocator, raw, .{});
                allocator.free(raw);
                raw = cased;
            }
            if (record.post_normalization == 0) return raw;
            const form: normalization.Form = switch (
                record.post_normalization
            ) {
                1 => .nfd,
                2 => .nfc,
                3 => .nfkd,
                4 => .nfkc,
                else => .nfc,
            };
            const post_normalized = try normalization.normalizeFormAlloc(
                allocator,
                raw,
                form,
            );
            if (post_normalized) |value| {
                allocator.free(raw);
                return value;
            }
            return raw;
        }
        if (pass_output) |*value| value.deinit(allocator);
        pass_output = next;
        current = next.items;
    }
    unreachable;
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
        if (codepoint >= 0x20 and codepoint <= 0x7e) {
            try output.append(allocator, text[index]);
        } else if (codepoint <= 0xffff) {
            var buffer: [6]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\u{x:0>4}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        } else {
            var buffer: [10]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buffer,
                "\\U{x:0>8}",
                .{codepoint},
            ) catch unreachable;
            try output.appendSlice(allocator, formatted);
        }
        index += length;
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
    if (std.mem.eql(u8, name, "Any-Null") or std.mem.eql(u8, name, "Null")) {
        return allocator.dupe(u8, text);
    }
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
    for (conformance_fixtures) |fixture| {
        try checkTransformConformance(
            fixture.bytes,
            fixture.magic,
            fixture.name,
        );
    }
}

fn checkTransformConformance(
    fixture: []const u8,
    magic: [4]u8,
    transform_name: []const u8,
) !void {
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
    if (failures != 0) return error.TestUnexpectedResult;
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
    try testing.expect(hasTransform("Latin-ASCII"));
    try testing.expect(hasTransform("Russian-Latin-BGN"));
    try testing.expect(hasTransform("NFC"));
    try testing.expect(hasTransform("Any-Title"));
    try testing.expect(!hasTransform("No-Such-Transform"));
    var found = false;
    for (0..transformCount()) |index| {
        const name = transformNameAt(index) orelse return error.TestUnexpectedResult;
        if (std.mem.eql(u8, name, "Simplified-Traditional")) found = true;
    }
    try testing.expect(found);
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
    const encoded = try transliterateByNameAlloc(allocator, "\u{00e9}", "Any-Hex");
    defer allocator.free(encoded);
    try testing.expectEqualStrings("\\u00e9", encoded);

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
