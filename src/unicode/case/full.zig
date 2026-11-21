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

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);

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
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (edits) |value| value.clearRetainingCapacity();

    var decoded = try decodeAlloc(allocator, text);
    defer decoded.deinit(allocator);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);

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
                sourceSlice(text, &decoded, emitted),
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
                    sourceSlice(text, &decoded, index),
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
                    sourceSlice(text, &decoded, index),
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
            sourceSlice(text, &decoded, emitted),
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
) error{OutOfMemory}!DecodedText {
    var codepoints = std.ArrayList(u21).empty;
    errdefer codepoints.deinit(allocator);
    var offsets = std.ArrayList(usize).empty;
    errdefer offsets.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, text.len);
    try offsets.ensureTotalCapacity(allocator, text.len);

    var cursor: usize = 0;
    while (scalar.decodeValid(text, cursor)) |decoded| {
        try codepoints.append(allocator, decoded.codepoint);
        try offsets.append(allocator, cursor);
        cursor = decoded.next;
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
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (edits) |value| value.clearRetainingCapacity();

    var decoded = try decodeAlloc(allocator, text);
    defer decoded.deinit(allocator);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);

    for (decoded.codepoints.items, 0..) |codepoint, index| {
        const before = output.items.len;
        if (lookup(codepoint, kind, options.locale, decoded.codepoints.items, index)) |mapping| {
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
            sourceSlice(text, &decoded, index),
            decoded.offsets.items[index],
            output.items[before..],
        );
    }
    return output.toOwnedSlice(allocator);
}

fn sourceSlice(text: []const u8, decoded: *const DecodedText, index: usize) []const u8 {
    const start = decoded.offsets.items[index];
    const end = if (index + 1 < decoded.offsets.items.len)
        decoded.offsets.items[index + 1]
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

fn lookup(
    codepoint: u21,
    kind: full_data.Kind,
    locale: Locale,
    codepoints: []const u21,
    index: usize,
) ?[]const u21 {
    const records = full_data.recordsFor(codepoint);
    if (records.len == 0) return null;

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

fn appendMapping(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    mapping: []const u21,
) error{OutOfMemory}!void {
    var encoded: [4]u8 = undefined;
    for (mapping) |codepoint| {
        const len = scalar.encodeUtf8(&encoded, codepoint);
        try output.appendSlice(allocator, encoded[0..len]);
    }
}

fn appendCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u21,
) error{OutOfMemory}!void {
    var encoded: [4]u8 = undefined;
    const len = scalar.encodeUtf8(&encoded, codepoint);
    try output.appendSlice(allocator, encoded[0..len]);
}

inline fn simpleLowerFast(codepoint: u21) u21 {
    if (codepoint < 0x80) {
        return if (codepoint >= 'A' and codepoint <= 'Z')
            codepoint + ('a' - 'A')
        else
            codepoint;
    }
    return data.simpleLower(codepoint);
}

inline fn simpleUpperFast(codepoint: u21) u21 {
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
