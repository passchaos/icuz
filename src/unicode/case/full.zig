//! Full Unicode case mapping (SpecialCasing.txt) with context and locale rules.
//!
//! The simple mapping APIs in `root.zig` stay one-to-one. These functions apply
//! the full mappings, including multi-scalar expansions such as `ß -> SS`, and
//! evaluate the context conditions used by Greek final sigma, Turkic dotted
//! letters, and Lithuanian dot-above insertion.

const std = @import("std");
const data = @import("data.zig");
const full_data = @import("full_data.zig");
const properties = @import("../properties/general_category.zig");
const combining_class = @import("../canonical/combining_class.zig");
const scalar = @import("../scalar/root.zig");
const word = @import("../word/iterator.zig");
const edits_mod = @import("edits.zig");

pub const Edits = edits_mod.Edits;

pub const Error = error{ InvalidUtf8, OutOfMemory };

/// Locale family for case mappings.
///
/// `turkic` covers Turkish (`tr`) and Azerbaijani (`az`); `lithuanian` covers
/// `lt`. Every other locale uses `.root`.
pub const Locale = enum { root, turkic, lithuanian };

pub const Options = struct {
    locale: Locale = .root,
};

const locale_root: u3 = 1;
const locale_turkic: u3 = 2;
const locale_lithuanian: u3 = 4;

const condition_final_sigma: u6 = 1;
const condition_after_soft_dotted: u6 = 2;
const condition_more_above: u6 = 4;
const condition_before_dot: u6 = 8;
const condition_not_before_dot: u6 = 16;
const condition_after_i: u6 = 32;

/// Lowercase UTF-8 text using full mappings.
pub fn fullLowerAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) Error![]u8 {
    return mapAlloc(allocator, text, options, .lower, null);
}

/// Lowercase with edit tracking, like ICU's `CaseMap.toLower` with `Edits`.
pub fn fullLowerWithEditsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: *Edits,
    options: Options,
) Error![]u8 {
    return mapAlloc(allocator, text, options, .lower, edits);
}

/// Uppercase UTF-8 text using full mappings.
pub fn fullUpperAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) Error![]u8 {
    return mapAlloc(allocator, text, options, .upper, null);
}

/// Uppercase with edit tracking, like ICU's `CaseMap.toUpper` with `Edits`.
pub fn fullUpperWithEditsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: *Edits,
    options: Options,
) Error![]u8 {
    return mapAlloc(allocator, text, options, .upper, edits);
}

/// Titlecase UTF-8 text using UAX #29 word boundaries and full mappings.
///
/// The first cased scalar of each word receives the title mapping; the rest of
/// the word receives the lowercase mapping. Non-word separators are copied
/// unchanged.
pub fn fullTitleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) Error![]u8 {
    return titleAlloc(allocator, text, options, null);
}

/// Titlecase with edit tracking, like ICU's `CaseMap.toTitle` with `Edits`.
pub fn fullTitleWithEditsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: *Edits,
    options: Options,
) Error![]u8 {
    return titleAlloc(allocator, text, options, edits);
}

/// Case-fold UTF-8 text with edit tracking, like ICU's `CaseMap.fold`.
pub fn foldWithEditsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: *Edits,
) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    edits.clearRetainingCapacity();

    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);

    var encoded: [4]u8 = undefined;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = scalar.decodeValid(text, index) orelse unreachable;
        const before = output.items.len;
        if (data.fullFold(decoded.codepoint)) |components| {
            for (components) |component| {
                const length = scalar.encodeUtf8(&encoded, component);
                try output.appendSlice(allocator, encoded[0..length]);
            }
        } else {
            const length = scalar.encodeUtf8(&encoded, decoded.codepoint);
            try output.appendSlice(allocator, encoded[0..length]);
        }
        try recordEdit(
            edits,
            text[index..decoded.next],
            index,
            output.items[before..],
        );
        index = decoded.next;
    }
    return output.toOwnedSlice(allocator);
}

fn titleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
    edits: ?*Edits,
) Error![]u8 {
    if (edits) |value| value.clearRetainingCapacity();

    var decoded = try decodeAlloc(allocator, text, true);
    defer decoded.deinit(allocator);

    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);

    var segments = word.segments(text) catch unreachable;
    var emitted: usize = 0;
    while (segments.next()) |segment| {
        const start = indexForByte(decoded.offsets.items, segment.byte_start);
        const end = indexForByte(
            decoded.offsets.items,
            segment.byte_start + segment.byte_len,
        );
        while (emitted < start) : (emitted += 1) {
            const before = output.items.len;
            try appendCodepoint(allocator, &output, decoded.codepoints.items[emitted]);
            try recordEdit(
                edits,
                sourceSlice(text, decoded.offsets.items, emitted),
                decoded.offsets.items[emitted],
                output.items[before..],
            );
        }

        if (segment.is_word) {
            var first_cased: ?usize = null;
            for (start..end) |index| {
                if (properties.isCased(decoded.codepoints.items[index])) {
                    first_cased = index;
                    break;
                }
            }
            for (start..end) |index| {
                const codepoint = decoded.codepoints.items[index];
                const before = output.items.len;
                if (first_cased != null and index == first_cased.?) {
                    if (lookup(
                        codepoint,
                        .title,
                        options.locale,
                        decoded.codepoints.items,
                        index,
                    )) |mapping| {
                        try appendMapping(allocator, &output, mapping);
                    } else {
                        try appendCodepoint(
                            allocator,
                            &output,
                            simpleTitleFast(codepoint),
                        );
                    }
                } else {
                    if (lookup(
                        codepoint,
                        .lower,
                        options.locale,
                        decoded.codepoints.items,
                        index,
                    )) |mapping| {
                        try appendMapping(allocator, &output, mapping);
                    } else {
                        try appendCodepoint(
                            allocator,
                            &output,
                            simpleLowerFast(codepoint),
                        );
                    }
                }
                try recordEdit(
                    edits,
                    sourceSlice(text, decoded.offsets.items, index),
                    decoded.offsets.items[index],
                    output.items[before..],
                );
            }
        } else {
            for (start..end) |index| {
                const before = output.items.len;
                try appendCodepoint(
                    allocator,
                    &output,
                    decoded.codepoints.items[index],
                );
                try recordEdit(
                    edits,
                    sourceSlice(text, decoded.offsets.items, index),
                    decoded.offsets.items[index],
                    output.items[before..],
                );
            }
        }
        emitted = end;
    }
    while (emitted < decoded.codepoints.items.len) : (emitted += 1) {
        const before = output.items.len;
        try appendCodepoint(allocator, &output, decoded.codepoints.items[emitted]);
        try recordEdit(
            edits,
            sourceSlice(text, decoded.offsets.items, emitted),
            decoded.offsets.items[emitted],
            output.items[before..],
        );
    }
    return output.toOwnedSlice(allocator);
}

const DecodedText = struct {
    codepoints: std.ArrayList(u21),
    offsets: std.ArrayList(usize),

    fn deinit(self: *DecodedText, allocator: std.mem.Allocator) void {
        self.codepoints.deinit(allocator);
        self.offsets.deinit(allocator);
    }
};

fn decodeAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    need_offsets: bool,
) Error!DecodedText {
    var codepoints = std.ArrayList(u21).empty;
    errdefer codepoints.deinit(allocator);
    var offsets = std.ArrayList(usize).empty;
    errdefer offsets.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, text.len);
    if (need_offsets) {
        try offsets.ensureTotalCapacity(allocator, text.len);
    }

    var cursor: usize = 0;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidatingPacked(text, cursor);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        codepoints.appendAssumeCapacity(scalar.packedCodepoint(decoded));
        if (need_offsets) offsets.appendAssumeCapacity(cursor);
        cursor += scalar.packedLength(decoded);
    }
    return .{ .codepoints = codepoints, .offsets = offsets };
}

fn indexForByte(offsets: []const usize, byte_offset: usize) usize {
    var low: usize = 0;
    var high = offsets.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (offsets[mid] < byte_offset) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn mapAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
    comptime kind: full_data.Kind,
    edits: ?*Edits,
) Error![]u8 {
    if (edits) |value| value.clearRetainingCapacity();
    if (edits == null) return mapStreaming(allocator, text, options, kind);
    return mapWithEdits(allocator, text, options, kind, edits.?);
}

/// Decode, map, and encode in one pass.
///
/// Context conditions are resolved from the UTF-8 bytes directly: backward
/// scans decode the previous scalar on demand, and forward scans walk ahead of
/// the cursor. The common case never touches either scan, so no intermediate
/// code-point array is built.
const MapMode = enum { full, simple, fold };

fn mapStreaming(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
    comptime kind: full_data.Kind,
) Error![]u8 {
    if (options.locale == .root) {
        return mapStreamingInner(allocator, text, .root, kind, true, .full);
    }
    return mapStreamingInner(allocator, text, options.locale, kind, false, .full);
}

/// One-to-one mapping entry point for the simple case API.
///
/// The identity skip masks are conservative supersets of the simple mappings,
/// so they are shared with the full-mapping path; only the record lookup is
/// compiled out.
pub fn simpleMapAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime kind: full_data.Kind,
) Error![]u8 {
    return mapStreamingInner(allocator, text, .root, kind, true, .simple);
}

/// Full case folding entry point; ASCII folds like lowercase.
pub fn foldStreamingAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    return mapStreamingInner(allocator, text, .root, .lower, true, .fold);
}

/// Append the simple lowercase mapping to a caller-owned buffer.
pub fn simpleLowerInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u8),
) Error!void {
    return mapStreamingInto(
        allocator,
        text,
        .root,
        .lower,
        true,
        .simple,
        output,
    );
}

/// Append the simple uppercase mapping to a caller-owned buffer.
pub fn simpleUpperInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u8),
) Error!void {
    return mapStreamingInto(
        allocator,
        text,
        .root,
        .upper,
        true,
        .simple,
        output,
    );
}

/// Append the full case folding to a caller-owned buffer.
pub fn foldStreamingInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u8),
) Error!void {
    return mapStreamingInto(
        allocator,
        text,
        .root,
        .lower,
        true,
        .fold,
        output,
    );
}

fn mapStreamingInner(
    allocator: std.mem.Allocator,
    text: []const u8,
    locale: Locale,
    comptime kind: full_data.Kind,
    comptime root: bool,
    comptime mode: MapMode,
) Error![]u8 {
    // Most mappings keep the byte length, so sizing the first allocation
    // exactly lets toOwnedSlice return it without a remap or copy. Every
    // write either checks spare capacity or proves four bytes fit: identity
    // copies only write a quad when `cursor + 4 <= text.len`.
    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);
    try mapStreamingInto(
        allocator,
        text,
        locale,
        kind,
        root,
        mode,
        &output,
    );
    return output.toOwnedSlice(allocator);
}

fn mapStreamingInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    locale: Locale,
    comptime kind: full_data.Kind,
    comptime root: bool,
    comptime mode: MapMode,
    output: *std.ArrayList(u8),
) Error!void {
    output.clearRetainingCapacity();
    var cursor: usize = 0;
    while (cursor < text.len) {
        const first = text[cursor];
        // Root-locale ASCII can never hit a SpecialCasing record, so an ASCII
        // run maps byte-for-byte without decoding or table lookups.
        if (root and first < 0x80) {
            const ascii_chunk = 16;
            while (cursor + ascii_chunk <= text.len) {
                const chunk: @Vector(ascii_chunk, u8) =
                    text[cursor..][0..ascii_chunk].*;
                // Reduce over two 64-bit lanes: a 16-lane byte reduction
                // lowers to a long shuffle chain on x86-64.
                const quads: @Vector(2, u64) = @bitCast(chunk);
                if (@reduce(.Or, quads) & 0x8080_8080_8080_8080 != 0) break;
                if (output.unusedCapacitySlice().len < ascii_chunk) {
                    try output.ensureUnusedCapacity(allocator, ascii_chunk);
                }
                output.unusedCapacitySlice()[0..ascii_chunk].* =
                    asciiMapVector(chunk, kind);
                output.items.len += ascii_chunk;
                cursor += ascii_chunk;
            }
            // Mixed prose has ASCII runs shorter than the vector width. Map
            // the leading ASCII bytes of the failed chunk in one store
            // instead of walking them one at a time.
            if (cursor + ascii_chunk <= text.len) {
                const chunk: @Vector(ascii_chunk, u8) =
                    text[cursor..][0..ascii_chunk].*;
                const quads: @Vector(2, u64) = @bitCast(chunk);
                const mask = 0x8080_8080_8080_8080;
                const low = quads[0] & mask;
                const count: usize = if (low != 0)
                    @ctz(low) / 8
                else
                    8 + @ctz(quads[1] & mask) / 8;
                if (count != 0) {
                    if (output.unusedCapacitySlice().len < ascii_chunk) {
                        try output.ensureUnusedCapacity(
                            allocator,
                            ascii_chunk,
                        );
                    }
                    output.unusedCapacitySlice()[0..ascii_chunk].* =
                        asciiMapVector(chunk, kind);
                    output.items.len += count;
                    cursor += count;
                    continue;
                }
            }
            const spare = output.unusedCapacitySlice();
            const limit = @min(spare.len, text.len - cursor);
            var count: usize = 0;
            while (count < limit) : (count += 1) {
                const byte = text[cursor + count];
                if (byte >= 0x80) break;
                spare[count] = switch (kind) {
                    .lower => if (byte >= 'A' and byte <= 'Z')
                        byte + ('a' - 'A')
                    else
                        byte,
                    .upper, .title => if (byte >= 'a' and byte <= 'z')
                        byte - ('a' - 'A')
                    else
                        byte,
                };
            }
            if (count == 0) {
                try output.ensureUnusedCapacity(allocator, 4);
                continue;
            }
            output.items.len += count;
            cursor += count;
            continue;
        }

        // A lead byte whose whole scalar range is identity needs no decoding:
        // validate the sequence in place and copy it. One metadata load packs
        // the skip flag, the second-byte bounds and the sequence length.
        if (root and first >= 0x80) {
            const meta = switch (mode) {
                .fold => full_data.fold_lead_meta[first],
                .full, .simple => switch (kind) {
                    .lower => full_data.lower_lead_meta[first],
                    .upper, .title => full_data.upper_lead_meta[first],
                },
            };
            if (meta & full_data.lead_skip_bit != 0) {
                const length: usize = (meta >> 16) & 7;
                if (cursor + length > text.len) return error.InvalidUtf8;
                // When the source quad and the output spare both exist, one
                // 32-bit load validates and copies the whole sequence: the
                // output position never exceeds the source position, so
                // `cursor + 4 <= text.len` proves four spare bytes.
                if (output.items.len <= cursor and cursor + 4 <= text.len) {
                    const quad = std.mem.readInt(
                        u32,
                        text[cursor..][0..4],
                        .little,
                    );
                    const second: u8 = @truncate(quad >> 8);
                    if (second < @as(u8, @truncate(meta)) or
                        second > @as(u8, @truncate(meta >> 8)))
                    {
                        return error.InvalidUtf8;
                    }
                    if (length >= 3 and
                        @as(u8, @truncate(quad >> 16)) & 0xc0 != 0x80)
                    {
                        return error.InvalidUtf8;
                    }
                    if (length == 4 and
                        @as(u8, @truncate(quad >> 24)) & 0xc0 != 0x80)
                    {
                        return error.InvalidUtf8;
                    }
                    std.mem.writeInt(
                        u32,
                        output.unusedCapacitySlice()[0..4],
                        quad,
                        .little,
                    );
                    output.items.len += length;
                    cursor += length;
                    continue;
                }
                const second = text[cursor + 1];
                if (second < @as(u8, @truncate(meta)) or
                    second > @as(u8, @truncate(meta >> 8)))
                {
                    return error.InvalidUtf8;
                }
                if (length >= 3 and text[cursor + 2] & 0xc0 != 0x80) {
                    return error.InvalidUtf8;
                }
                if (length == 4 and text[cursor + 3] & 0xc0 != 0x80) {
                    return error.InvalidUtf8;
                }
                try copyIdentityBytes(
                    allocator,
                    output,
                    text,
                    cursor,
                    length,
                );
                cursor += length;
                continue;
            }
        }

        // Latin-1 uppercase letters map with a byte offset, so accented
        // prose can skip the decoder and the encoder entirely. Their full
        // mappings equal the simple ones; only sharp s folds to two scalars.
        if (root and first == 0xc3 and kind == .lower and
            cursor + 2 <= text.len)
        {
            const second = text[cursor + 1];
            if (second & 0xc0 != 0x80) return error.InvalidUtf8;
            // Sharp s is the only Latin-1 scalar with a multi-scalar fold.
            if (mode != .fold or second != 0x9f) {
                // U+00C0..U+00DE minus U+00D7 (multiplication sign).
                const mapped = if (second >= 0x80 and second <= 0x9e and
                    second != 0x97)
                    second + 0x20
                else
                    second;
                try output.ensureUnusedCapacity(allocator, 2);
                const spare = output.unusedCapacitySlice();
                spare[0] = 0xc3;
                spare[1] = mapped;
                output.items.len += 2;
                cursor += 2;
                continue;
            }
        }

        const decoded = scalar.decodeValidatingPacked(text, cursor);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar.packedCodepoint(decoded);
        const next = cursor + scalar.packedLength(decoded);
        const may_map = switch (mode) {
            // Folding only changes scalars that also have a simple case
            // mapping, so the union of the lower and upper filters is exact
            // enough and never skips a folding scalar.
            .fold => full_data.interesting(codepoint, .lower, root) or
                full_data.interesting(codepoint, .upper, root),
            .full, .simple => full_data.interesting(codepoint, kind, root),
        };
        if (!may_map) {
            // The mapping is the identity, so the source bytes are the result.
            try copyIdentityBytes(
                allocator,
                output,
                text,
                cursor,
                next - cursor,
            );
            cursor = next;
            continue;
        }
        if (mode == .fold) {
            if (data.fullFold(codepoint)) |components| {
                try appendMapping(allocator, output, components);
                cursor = next;
                continue;
            }
            // The scalar folds to itself; copy the source bytes.
            try copyIdentityBytes(
                allocator,
                output,
                text,
                cursor,
                next - cursor,
            );
            cursor = next;
            continue;
        }
        if (mode == .full) {
            const mapping = if (root)
                lookupRootStreaming(codepoint, kind, text, cursor, next)
            else
                lookupStreaming(codepoint, kind, locale, text, cursor, next);
            if (mapping) |components| {
                try appendMapping(allocator, output, components);
                cursor = next;
                continue;
            }
        }
        const mapped = switch (kind) {
            .lower => simpleLowerFast(codepoint),
            .upper => simpleUpperFast(codepoint),
            .title => simpleTitleFast(codepoint),
        };
        try appendCodepoint(allocator, output, mapped);
        cursor = next;
    }
}

fn mapWithEdits(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
    comptime kind: full_data.Kind,
    edits: *Edits,
) Error![]u8 {
    var decoded = try decodeAlloc(allocator, text, true);
    defer decoded.deinit(allocator);

    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);

    const codepoints = decoded.codepoints.items;
    const offsets = decoded.offsets.items;
    for (codepoints, 0..) |codepoint, index| {
        const before = output.items.len;
        if (lookup(codepoint, kind, options.locale, codepoints, index)) |mapping| {
            try appendMapping(allocator, &output, mapping);
        } else {
            const mapped = switch (kind) {
                .lower => simpleLowerFast(codepoint),
                .upper => simpleUpperFast(codepoint),
                .title => simpleTitleFast(codepoint),
            };
            try appendCodepoint(allocator, &output, mapped);
        }
        try recordEdit(
            edits,
            sourceSlice(text, offsets, index),
            offsets[index],
            output.items[before..],
        );
    }
    return output.toOwnedSlice(allocator);
}

fn sourceSlice(
    text: []const u8,
    offsets: []const usize,
    index: usize,
) []const u8 {
    const start = offsets[index];
    const end = if (index + 1 < offsets.len)
        offsets[index + 1]
    else
        text.len;
    return text[start..end];
}

fn recordEdit(
    edits: ?*Edits,
    source: []const u8,
    source_index: usize,
    destination: []const u8,
) error{OutOfMemory}!void {
    const value = edits orelse return;
    if (destination.len == source.len and
        std.mem.eql(u8, source, destination))
    {
        try value.addUnchanged(source_index, source.len);
    } else {
        try value.addReplace(source.len, destination.len);
    }
}

inline fn lookup(
    codepoint: u21,
    kind: full_data.Kind,
    locale: Locale,
    codepoints: []const u21,
    index: usize,
) ?[]const u21 {
    if (!full_data.hasRecords(codepoint, locale == .root)) return null;
    const records = full_data.recordsFor(codepoint);

    if (locale != .root) {
        const locale_bit: u3 = switch (locale) {
            .root => locale_root,
            .turkic => locale_turkic,
            .lithuanian => locale_lithuanian,
        };
        for (records) |record| {
            if (record.locale != locale_bit) continue;
            if (!conditionsMatch(record.conditions, codepoints, index)) continue;
            const mapping = full_data.componentsFor(record, kind);
            return if (mapping.len == 0) null else mapping;
        }
    }

    for (records) |record| {
        if (record.locale != locale_root) continue;
        if (!conditionsMatch(record.conditions, codepoints, index)) continue;
        const mapping = full_data.componentsFor(record, kind);
        return if (mapping.len == 0) null else mapping;
    }
    return null;
}

inline fn lookupRootStreaming(
    codepoint: u21,
    kind: full_data.Kind,
    text: []const u8,
    cursor: usize,
    next: usize,
) ?[]const u21 {
    if (!full_data.hasRecords(codepoint, true)) return null;
    for (full_data.recordsFor(codepoint)) |record| {
        if (record.locale != locale_root) continue;
        if (record.conditions != 0 and
            !conditionsMatchAt(record.conditions, text, cursor, next)) continue;
        const mapping = full_data.componentsFor(record, kind);
        return if (mapping.len == 0) null else mapping;
    }
    return null;
}

inline fn lookupStreaming(
    codepoint: u21,
    kind: full_data.Kind,
    locale: Locale,
    text: []const u8,
    cursor: usize,
    next: usize,
) ?[]const u21 {
    if (!full_data.hasRecords(codepoint, locale == .root)) return null;
    const records = full_data.recordsFor(codepoint);

    if (locale != .root) {
        const locale_bit: u3 = switch (locale) {
            .root => locale_root,
            .turkic => locale_turkic,
            .lithuanian => locale_lithuanian,
        };
        for (records) |record| {
            if (record.locale != locale_bit) continue;
            if (!conditionsMatchAt(record.conditions, text, cursor, next)) continue;
            const mapping = full_data.componentsFor(record, kind);
            return if (mapping.len == 0) null else mapping;
        }
    }

    for (records) |record| {
        if (record.locale != locale_root) continue;
        if (!conditionsMatchAt(record.conditions, text, cursor, next)) continue;
        const mapping = full_data.componentsFor(record, kind);
        return if (mapping.len == 0) null else mapping;
    }
    return null;
}

fn conditionsMatch(
    mask: u6,
    codepoints: []const u21,
    index: usize,
) bool {
    if (mask & condition_final_sigma != 0 and
        !finalSigma(codepoints, index)) return false;
    if (mask & condition_after_soft_dotted != 0 and
        !afterSoftDotted(codepoints, index)) return false;
    if (mask & condition_more_above != 0 and
        !moreAbove(codepoints, index)) return false;
    if (mask & condition_before_dot != 0 and
        !beforeDot(codepoints, index)) return false;
    if (mask & condition_not_before_dot != 0 and
        beforeDot(codepoints, index)) return false;
    if (mask & condition_after_i != 0 and
        !afterI(codepoints, index)) return false;
    return true;
}

fn finalSigma(codepoints: []const u21, index: usize) bool {
    var cursor = index;
    var preceded_by_cased = false;
    while (cursor > 0) {
        cursor -= 1;
        const codepoint = codepoints[cursor];
        if (properties.isCaseIgnorable(codepoint)) continue;
        preceded_by_cased = properties.isCased(codepoint);
        break;
    }
    if (!preceded_by_cased) return false;

    cursor = index + 1;
    while (cursor < codepoints.len) : (cursor += 1) {
        const codepoint = codepoints[cursor];
        if (properties.isCaseIgnorable(codepoint)) continue;
        return !properties.isCased(codepoint);
    }
    return true;
}

fn afterSoftDotted(codepoints: []const u21, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        const codepoint = codepoints[cursor];
        if (properties.isCaseIgnorable(codepoint)) continue;
        return properties.isSoftDotted(codepoint);
    }
    return false;
}

fn moreAbove(codepoints: []const u21, index: usize) bool {
    var cursor = index + 1;
    while (cursor < codepoints.len) : (cursor += 1) {
        const combining = combining_class.forCodepoint(codepoints[cursor]);
        if (combining == 0) return false;
        if (combining >= 230) return true;
    }
    return false;
}

fn beforeDot(codepoints: []const u21, index: usize) bool {
    var cursor = index + 1;
    while (cursor < codepoints.len) : (cursor += 1) {
        const codepoint = codepoints[cursor];
        if (codepoint == 0x0307) return true;
        if (combining_class.forCodepoint(codepoint) == 0) return false;
    }
    return false;
}

fn afterI(codepoints: []const u21, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        const codepoint = codepoints[cursor];
        if (properties.isCaseIgnorable(codepoint)) continue;
        return codepoint == 'I';
    }
    return false;
}

fn conditionsMatchAt(
    mask: u6,
    text: []const u8,
    cursor: usize,
    next: usize,
) bool {
    if (mask & condition_final_sigma != 0 and
        !finalSigmaAt(text, cursor, next)) return false;
    if (mask & condition_after_soft_dotted != 0 and
        !afterSoftDottedAt(text, cursor)) return false;
    if (mask & condition_more_above != 0 and
        !moreAboveAt(text, next)) return false;
    if (mask & condition_before_dot != 0 and
        !beforeDotAt(text, next)) return false;
    if (mask & condition_not_before_dot != 0 and
        beforeDotAt(text, next)) return false;
    if (mask & condition_after_i != 0 and
        !afterIAt(text, cursor)) return false;
    return true;
}

/// Start offset of the scalar that ends at or before `offset`, or null when
/// the text starts with a stray continuation byte.
fn previousStart(text: []const u8, offset: usize) ?usize {
    if (offset == 0) return null;
    var start = offset - 1;
    while (text[start] & 0xc0 == 0x80) {
        if (start == 0) return null;
        start -= 1;
    }
    return start;
}

inline fn isAsciiLetter(byte: u8) bool {
    return (byte | 0x20) >= 'a' and (byte | 0x20) <= 'z';
}

/// Decode the scalar at `start`, which the forward scan already validated.
inline fn decodePreviousScalar(text: []const u8, start: usize) u21 {
    const first = text[start];
    if (first < 0xe0) {
        return (@as(u21, first & 0x1f) << 6) | (text[start + 1] & 0x3f);
    }
    if (first < 0xf0) {
        return (@as(u21, first & 0x0f) << 12) |
            (@as(u21, text[start + 1] & 0x3f) << 6) |
            (text[start + 2] & 0x3f);
    }
    return (@as(u21, first & 0x07) << 18) |
        (@as(u21, text[start + 1] & 0x3f) << 12) |
        (@as(u21, text[start + 2] & 0x3f) << 6) |
        (text[start + 3] & 0x3f);
}

/// True when the scalar before `cursor` is cased with no case-ignorable
/// scalars in between.
fn precededByCased(text: []const u8, cursor: usize) bool {
    var end = cursor;
    while (end > 0) {
        var start = end - 1;
        while (text[start] & 0xc0 == 0x80) {
            if (start == 0) return false;
            start -= 1;
        }
        end = start;
        const first = text[start];
        if (first < 0x80) {
            // Letters are cased, and spaces and digits are neither cased
            // nor case-ignorable, so the common neighbors need no lookup.
            if (isAsciiLetter(first)) return true;
            if (first == ' ' or (first >= '0' and first <= '9')) return false;
        }
        const codepoint: u21 = if (first < 0x80)
            first
        else
            decodePreviousScalar(text, start);
        if (properties.isCaseIgnorable(codepoint)) continue;
        return properties.isCased(codepoint);
    }
    return false;
}

/// True when the scalar after `next` is cased with no case-ignorable scalars
/// in between.
fn followedByCased(text: []const u8, next: usize) bool {
    var at = next;
    while (at < text.len) {
        const first = text[at];
        if (first < 0x80) {
            if (isAsciiLetter(first)) return true;
            if (first == ' ' or (first >= '0' and first <= '9')) return false;
        }
        const decoded = scalar.decodeValid(text, at) orelse return false;
        at = decoded.next;
        if (properties.isCaseIgnorable(decoded.codepoint)) continue;
        return properties.isCased(decoded.codepoint);
    }
    return false;
}

fn finalSigmaAt(text: []const u8, cursor: usize, next: usize) bool {
    return precededByCased(text, cursor) and !followedByCased(text, next);
}

fn afterSoftDottedAt(text: []const u8, cursor: usize) bool {
    var at = cursor;
    while (previousStart(text, at)) |start| {
        at = start;
        const decoded = scalar.decodeValid(text, start) orelse return false;
        if (properties.isCaseIgnorable(decoded.codepoint)) continue;
        return properties.isSoftDotted(decoded.codepoint);
    }
    return false;
}

fn afterIAt(text: []const u8, cursor: usize) bool {
    var at = cursor;
    while (previousStart(text, at)) |start| {
        at = start;
        const decoded = scalar.decodeValid(text, start) orelse return false;
        if (properties.isCaseIgnorable(decoded.codepoint)) continue;
        return decoded.codepoint == 'I';
    }
    return false;
}

fn moreAboveAt(text: []const u8, next: usize) bool {
    var at = next;
    while (at < text.len) {
        const decoded = scalar.decodeValid(text, at) orelse break;
        const combining = combining_class.forCodepoint(decoded.codepoint);
        if (combining == 0) return false;
        if (combining >= 230) return true;
        at = decoded.next;
    }
    return false;
}

fn beforeDotAt(text: []const u8, next: usize) bool {
    var at = next;
    while (at < text.len) {
        const decoded = scalar.decodeValid(text, at) orelse break;
        if (decoded.codepoint == 0x0307) return true;
        if (combining_class.forCodepoint(decoded.codepoint) == 0) return false;
        at = decoded.next;
    }
    return false;
}

inline fn appendMapping(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    mapping: []const u21,
) error{OutOfMemory}!void {
    const needed = mapping.len * 4;
    if (output.unusedCapacitySlice().len >= needed) {
        const dest = output.unusedCapacitySlice();
        var written: usize = 0;
        for (mapping) |codepoint| {
            written += scalar.encodeUtf8(dest[written..][0..4], codepoint);
        }
        output.items.len += written;
        return;
    }
    // The spare capacity cannot hold the worst-case write. Encode into a
    // stack buffer and reserve the exact length: asking for four bytes per
    // scalar at the end of a full buffer grows the list and forces a shrink
    // copy in toOwnedSlice.
    var encoded: [16]u8 = undefined;
    var written: usize = 0;
    for (mapping) |codepoint| {
        written += scalar.encodeUtf8(encoded[written..][0..4], codepoint);
    }
    try output.ensureTotalCapacityPrecise(
        allocator,
        output.items.len + written,
    );
    @memcpy(output.unusedCapacitySlice()[0..written], encoded[0..written]);
    output.items.len += written;
}

inline fn appendCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u21,
) error{OutOfMemory}!void {
    if (output.unusedCapacitySlice().len >= 4) {
        const dest = output.unusedCapacitySlice();
        output.items.len += scalar.encodeUtf8(dest[0..4], codepoint);
        return;
    }
    var encoded: [4]u8 = undefined;
    const len = scalar.encodeUtf8(&encoded, codepoint);
    try output.ensureTotalCapacityPrecise(
        allocator,
        output.items.len + len,
    );
    @memcpy(output.unusedCapacitySlice()[0..len], encoded[0..len]);
    output.items.len += len;
}

inline fn asciiMapVector(
    chunk: @Vector(16, u8),
    comptime kind: full_data.Kind,
) @Vector(16, u8) {
    const Vector = @Vector(16, u8);
    const delta: Vector = @splat(0x20);
    const zero: Vector = @splat(0);
    return switch (kind) {
        .lower => chunk +% @select(
            u8,
            (chunk >= @as(Vector, @splat('A'))) &
                (chunk <= @as(Vector, @splat('Z'))),
            delta,
            zero,
        ),
        .upper, .title => chunk -% @select(
            u8,
            (chunk >= @as(Vector, @splat('a'))) &
                (chunk <= @as(Vector, @splat('z'))),
            delta,
            zero,
        ),
    };
}

/// Copy an identity sequence of `length` (2-4) bytes.
///
/// While the output has not outgrown the input position, the reserved
/// capacity covers the whole input and a single word load and store copies
/// the sequence plus one byte that a later write overwrites.
inline fn copyIdentityBytes(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
    cursor: usize,
    length: usize,
) error{OutOfMemory}!void {
    if (output.items.len <= cursor and cursor + 4 <= text.len) {
        const quad = std.mem.readInt(u32, text[cursor..][0..4], .little);
        std.mem.writeInt(
            u32,
            output.unusedCapacitySlice()[0..4],
            quad,
            .little,
        );
    } else {
        if (output.unusedCapacitySlice().len < length) {
            try output.ensureUnusedCapacity(allocator, length);
        }
        copySourceBytes(
            output.unusedCapacitySlice(),
            text[cursor..][0..length],
        );
    }
    output.items.len += length;
}

inline fn copySourceBytes(dest: []u8, source: []const u8) void {
    switch (source.len) {
        1 => dest[0] = source[0],
        2 => {
            dest[0] = source[0];
            dest[1] = source[1];
        },
        3 => {
            dest[0] = source[0];
            dest[1] = source[1];
            dest[2] = source[2];
        },
        else => {
            dest[0] = source[0];
            dest[1] = source[1];
            dest[2] = source[2];
            dest[3] = source[3];
        },
    }
}

pub inline fn simpleLowerFast(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'A' and codepoint <= 'Z')
            codepoint + ('a' - 'A')
        else
            codepoint;
    }
    return data.simpleLower(codepoint);
}

pub inline fn simpleUpperFast(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'a' and codepoint <= 'z')
            codepoint - ('a' - 'A')
        else
            codepoint;
    }
    return data.simpleUpper(codepoint);
}

inline fn simpleTitleFast(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'a' and codepoint <= 'z')
            codepoint - ('a' - 'A')
        else
            codepoint;
    }
    return data.simpleTitle(codepoint);
}

test "full uppercase expands sharp s and ligatures" {
    const allocator = std.testing.allocator;
    const output = try fullUpperAlloc(allocator, "stra\u{00df}e \u{fb01}", .{});
    defer allocator.free(output);
    try std.testing.expectEqualStrings("STRASSE FI", output);
}

test "full lowercase preserves canonical equivalence for dotted I" {
    const allocator = std.testing.allocator;
    const output = try fullLowerAlloc(allocator, "\u{0130}", .{});
    defer allocator.free(output);
    try std.testing.expectEqualStrings("i\u{0307}", output);
}

test "Turkic locale overrides dotted and dotless I" {
    const allocator = std.testing.allocator;
    const lower = try fullLowerAlloc(allocator, "I", .{ .locale = .turkic });
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("\u{0131}", lower);

    const upper = try fullUpperAlloc(allocator, "i", .{ .locale = .turkic });
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("\u{0130}", upper);
}

test "Final_Sigma uses final form at word end" {
    const allocator = std.testing.allocator;
    const final = try fullLowerAlloc(allocator, "\u{039f}\u{03a3}", .{});
    defer allocator.free(final);
    try std.testing.expectEqualStrings("\u{03bf}\u{03c2}", final);

    const medial = try fullLowerAlloc(allocator, "\u{039f}\u{03a3}\u{0391}", .{});
    defer allocator.free(medial);
    try std.testing.expectEqualStrings("\u{03bf}\u{03c3}\u{03b1}", medial);
}

test "Lithuanian More_Above inserts dot above" {
    const allocator = std.testing.allocator;
    const output = try fullLowerAlloc(
        allocator,
        "I\u{0300}",
        .{ .locale = .lithuanian },
    );
    defer allocator.free(output);
    try std.testing.expectEqualStrings("i\u{0307}\u{0300}", output);
}

test "title casing uses word boundaries" {
    const allocator = std.testing.allocator;
    const output = try fullTitleAlloc(allocator, "hello world", .{});
    defer allocator.free(output);
    try std.testing.expectEqualStrings("Hello World", output);

    const digraph = try fullTitleAlloc(allocator, "\u{01c6}ungla", .{});
    defer allocator.free(digraph);
    try std.testing.expectEqualStrings("\u{01c5}ungla", digraph);
}

test "full case mapping rejects invalid UTF-8" {
    try std.testing.expectError(
        error.InvalidUtf8,
        fullUpperAlloc(std.testing.allocator, "\xff", .{}),
    );
}

test "streaming fold matches the folding table" {
    const allocator = std.testing.allocator;
    var text_buffer: [4]u8 = undefined;
    var expected_buffer: [16]u8 = undefined;
    var codepoint: u21 = 0;
    while (codepoint <= 0xFFFF) : (codepoint += 1) {
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) continue;
        if (!full_data.interesting(codepoint, .lower, false) and
            !full_data.interesting(codepoint, .upper, false)) continue;
        try expectFoldMatches(allocator, &text_buffer, &expected_buffer, codepoint);
    }
    for ([_]u21{ 0x10400, 0x10428, 0x10570, 0x118a0, 0x16e40, 0x1e900 }) |sample| {
        try expectFoldMatches(allocator, &text_buffer, &expected_buffer, sample);
    }
}

fn expectFoldMatches(
    allocator: std.mem.Allocator,
    text_buffer: *[4]u8,
    expected_buffer: *[16]u8,
    codepoint: u21,
) !void {
    const length = scalar.encodeUtf8(text_buffer, codepoint);
    var expected_len: usize = 0;
    if (data.fullFold(codepoint)) |components| {
        for (components) |component| {
            expected_len += scalar.encodeUtf8(expected_buffer[expected_len..], component);
        }
    } else {
        expected_len = scalar.encodeUtf8(expected_buffer[0..], codepoint);
    }
    const folded = try foldStreamingAlloc(allocator, text_buffer[0..length]);
    defer allocator.free(folded);
    try std.testing.expectEqualStrings(
        expected_buffer[0..expected_len],
        folded,
    );
}

test "identity skip path validates UTF-8 like std" {
    const allocator = std.testing.allocator;
    var text: [4]u8 = undefined;
    for (0x80..0x100) |lead| {
        text[0] = @intCast(lead);
        for (0..0x100) |second| {
            text[1] = @intCast(second);
            for ([_]u8{ 0x7f, 0x80, 0xbf, 0xc0 }) |tail| {
                text[2] = tail;
                text[3] = 0x80;
                try expectValidityMatches(allocator, text[0..2]);
                try expectValidityMatches(allocator, text[0..3]);
                try expectValidityMatches(allocator, text[0..4]);
            }
        }
    }
}

fn expectValidityMatches(
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const valid = std.unicode.utf8ValidateSlice(text);
    inline for ([_]bool{ false, true }) |upper| {
        const mapped = if (upper)
            fullUpperAlloc(allocator, text, .{})
        else
            fullLowerAlloc(allocator, text, .{});
        if (mapped) |output| {
            defer allocator.free(output);
            try std.testing.expect(valid);
        } else |err| {
            try std.testing.expectEqual(error.InvalidUtf8, err);
            try std.testing.expect(!valid);
        }
    }
}

test "streaming and edit-tracking mappings agree" {
    const allocator = std.testing.allocator;
    var edits = Edits.init(allocator);
    defer edits.deinit();
    var buffer: [8]u8 = undefined;
    var codepoint: u21 = 0;
    // Astral code points always take the table path; sample them instead of
    // paying for allocations on each of the million plane 1-16 scalars.
    // U+0307 has locale-only records and is not root-interesting.
    const extra_samples = [_]u21{
        0x0307,  0x10400, 0x10428, 0x104b0, 0x10570, 0x10d50, 0x118a0,
        0x16e40, 0x1e900, 0x1e921, 0x1f600,
    };
    while (true) : (codepoint += 1) {
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) continue;
        if (codepoint == 0x10000) {
            for (extra_samples) |sample| {
                try expectSameMapping(allocator, &edits, &buffer, sample);
            }
            break;
        }
        if (!full_data.interesting(codepoint, .lower, true) and
            !full_data.interesting(codepoint, .upper, true)) continue;
        try expectSameMapping(allocator, &edits, &buffer, codepoint);
    }
}

fn expectSameMapping(
    allocator: std.mem.Allocator,
    edits: *Edits,
    buffer: *[8]u8,
    codepoint: u21,
) !void {
    const length = scalar.encodeUtf8(buffer, codepoint);
    const text = buffer[0..length];
    for ([_]Locale{ .root, .turkic, .lithuanian }) |locale| {
        const options = Options{ .locale = locale };
        inline for ([_]full_data.Kind{ .lower, .upper }) |kind| {
            const mapped = if (kind == .lower)
                try fullLowerAlloc(allocator, text, options)
            else
                try fullUpperAlloc(allocator, text, options);
            defer allocator.free(mapped);
            const tracked = if (kind == .lower)
                try fullLowerWithEditsAlloc(allocator, text, edits, options)
            else
                try fullUpperWithEditsAlloc(allocator, text, edits, options);
            defer allocator.free(tracked);
            try std.testing.expectEqualStrings(mapped, tracked);
        }
    }
}

test "Final_Sigma ignores case-ignorable marks" {
    const allocator = std.testing.allocator;
    const final = try fullLowerAlloc(
        allocator,
        "\u{039f}\u{03a3}\u{0301}",
        .{},
    );
    defer allocator.free(final);
    try std.testing.expectEqualStrings("\u{03bf}\u{03c2}\u{0301}", final);

    const medial = try fullLowerAlloc(
        allocator,
        "\u{039f}\u{03a3}\u{0301}\u{0391}",
        .{},
    );
    defer allocator.free(medial);
    try std.testing.expectEqualStrings("\u{03bf}\u{03c3}\u{0301}\u{03b1}", medial);
}

test "Turkic Not_Before_Dot falls back to the root mapping" {
    const allocator = std.testing.allocator;
    const output = try fullLowerAlloc(
        allocator,
        "I\u{0307}",
        .{ .locale = .turkic },
    );
    defer allocator.free(output);
    try std.testing.expectEqualStrings("i\u{0307}", output);
}

test "title casing lowercases the rest of each word with context" {
    const allocator = std.testing.allocator;
    const sigma = try fullTitleAlloc(allocator, "\u{039f}\u{03a3}", .{});
    defer allocator.free(sigma);
    try std.testing.expectEqualStrings("\u{039f}\u{03c2}", sigma);

    const leading = try fullTitleAlloc(allocator, "  hello", .{});
    defer allocator.free(leading);
    try std.testing.expectEqualStrings("  Hello", leading);
}

test "case mapping with edits" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var edits = Edits.init(allocator);
    defer edits.deinit();
    const source = "Stra\u{00df}e ABC";
    const mapped = try fullLowerWithEditsAlloc(allocator, source, &edits, .{});
    defer allocator.free(mapped);
    try testing.expectEqualStrings("stra\u{00df}e abc", mapped);
    try testing.expect(edits.hasChanges());
    try testing.expectEqual(@as(usize, 4), edits.changeCount());
    try testing.expectEqual(source.len, edits.sourceLength());
    try testing.expectEqual(mapped.len, edits.destinationLength());
    try testing.expectEqual(@as(usize, 4), edits.mapIndex(4));
    try testing.expectEqual(@as(usize, 8), edits.mapIndex(8));

    // A one-code-point to two-code-point mapping shifts later indices.
    var dotted = Edits.init(allocator);
    defer dotted.deinit();
    const lower = try fullLowerWithEditsAlloc(allocator, "\u{0130}x", &dotted, .{});
    defer allocator.free(lower);
    try testing.expectEqualStrings("i\u{0307}x", lower);
    try testing.expectEqual(@as(usize, 1), dotted.changeCount());
    try testing.expectEqual(@as(usize, 0), dotted.mapIndex(0));
    try testing.expectEqual(@as(usize, 3), dotted.mapIndex(2));
    try testing.expectEqual(@as(usize, 4), dotted.mapIndex(3));

    var upper_edits = Edits.init(allocator);
    defer upper_edits.deinit();
    const upper = try fullUpperWithEditsAlloc(
        allocator,
        "stra\u{00df}e",
        &upper_edits,
        .{},
    );
    defer allocator.free(upper);
    try testing.expectEqualStrings("STRASSE", upper);
    try testing.expect(upper_edits.hasChanges());

    var title_edits = Edits.init(allocator);
    defer title_edits.deinit();
    const title = try fullTitleWithEditsAlloc(
        allocator,
        "hello world",
        &title_edits,
        .{},
    );
    defer allocator.free(title);
    try testing.expectEqualStrings("Hello World", title);
    try testing.expectEqual(@as(usize, 2), title_edits.changeCount());

    var fold_edits = Edits.init(allocator);
    defer fold_edits.deinit();
    const folded = try foldWithEditsAlloc(
        allocator,
        "Stra\u{00df}e \u{0130}",
        &fold_edits,
    );
    defer allocator.free(folded);
    try testing.expectEqualStrings("strasse i\u{0307}", folded);
    try testing.expect(fold_edits.hasChanges());
    try testing.expectEqual(@as(usize, 3), fold_edits.changeCount());
    try testing.expectEqual(@as(usize, 4), fold_edits.mapIndex(4));
    try testing.expectEqual(@as(usize, 6), fold_edits.mapIndex(6));
    try testing.expectEqual(@as(usize, 8), fold_edits.mapIndex(8));
    try testing.expectEqual(@as(usize, 8), fold_edits.mapIndex(9));
    try testing.expectEqual(@as(usize, 11), fold_edits.mapIndex(10));
}
