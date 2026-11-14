//! Unicode 17 normalization for UTF-8 text.
//!
//! This module implements the four UAX #15 forms: NFC, NFD, NFKC, and NFKD.
//! Canonical forms use recursive canonical decomposition and canonical
//! combining-class ordering; compatibility forms additionally apply
//! compatibility mappings. NFC and NFKC then perform canonical composition,
//! including algorithmic Hangul handling. The module deliberately does not
//! perform display-specific or language-specific reordering.

const std = @import("std");
const combining_class = @import("../canonical/combining_class.zig");
const decomposition = @import("../canonical/decomposition.zig");
const data = @import("data.zig");

const conformance = @embedFile("conformance.bin");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{ InvalidUtf8, OutOfMemory };
pub const QuickCheck = data.QuickCheck;
pub const Form = data.Form;

/// Return Unicode's per-scalar NFC_Quick_Check value.
pub const quickCheckCodepoint = data.nfcQuickCheck;

/// Return Unicode's per-scalar quick-check value for one normalization form.
pub fn quickCheckFormCodepoint(codepoint: u21, form: Form) QuickCheck {
    return data.quickCheck(codepoint, form);
}

/// Return an allocator-owned NFC string when `text` must change, or `null`
/// when it is already NFC. ASCII and all other normalized input allocate
/// nothing. Invalid UTF-8 is rejected before any allocation.
pub fn normalizeAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfc);
}

pub fn normalizeNfdAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfd);
}

pub fn normalizeNfkcAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfkc);
}

pub fn normalizeNfkdAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfkd);
}

/// Return an allocator-owned string in `form` when `text` must change, or
/// `null` when it is already normalized. Invalid UTF-8 is rejected before any
/// allocation.
pub fn normalizeFormAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
) Error!?[]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (isNormalizedFormAssumeValid(text, form)) return null;

    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, text.len);

    const compatibility = form == .nfkc or form == .nfkd;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        try appendDecomposition(allocator, &codepoints, codepoint, compatibility);
    }
    canonicalOrder(codepoints.items);
    if (form == .nfc or form == .nfkc) {
        codepoints.shrinkRetainingCapacity(composeSlice(codepoints.items));
    }

    var utf8_len: usize = 0;
    for (codepoints.items) |codepoint| {
        utf8_len = std.math.add(
            usize,
            utf8_len,
            std.unicode.utf8CodepointSequenceLength(codepoint) catch
                unreachable,
        ) catch return error.OutOfMemory;
    }
    const output = try allocator.alloc(u8, utf8_len);
    errdefer allocator.free(output);
    var offset: usize = 0;
    for (codepoints.items) |codepoint| {
        offset += std.unicode.utf8Encode(codepoint, output[offset..]) catch
            unreachable;
    }
    std.debug.assert(offset == output.len);
    if (std.mem.eql(u8, output, text)) {
        allocator.free(output);
        return null;
    }
    return output;
}

/// Validate UTF-8 and report whether `text` is in NFC without allocating.
pub fn isNormalized(text: []const u8) error{InvalidUtf8}!bool {
    return isNormalizedForm(text, .nfc);
}

/// Validate UTF-8 and report whether `text` is in `form` without allocating.
pub fn isNormalizedForm(text: []const u8, form: Form) error{InvalidUtf8}!bool {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return isNormalizedFormAssumeValid(text, form);
}

/// Report whether prevalidated UTF-8 is in NFC without allocating.
pub fn isNormalizedAssumeValid(text: []const u8) bool {
    return isNormalizedFormAssumeValid(text, .nfc);
}

/// Report whether prevalidated UTF-8 is in `form` without allocating.
pub fn isNormalizedFormAssumeValid(text: []const u8, form: Form) bool {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    var starter: ?u21 = null;
    var previous_input_class: u8 = 0;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) return false;
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            previous_input_class > current_class) return false;
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return false;
        }
        if (current_class == 0) starter = codepoint;
        previous_input_class = current_class;
    }
    return true;
}

fn appendDecomposition(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u21),
    codepoint: u21,
    compatibility: bool,
) error{OutOfMemory}!void {
    if (decomposeHangul(codepoint)) |parts| {
        try output.appendSlice(allocator, parts.slice());
        return;
    }
    const mapping = if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    if (mapping) |components| {
        try output.appendSlice(allocator, components);
        return;
    }
    try output.append(allocator, codepoint);
}

fn canonicalOrder(codepoints: []u21) void {
    var sequence_start: usize = 0;
    for (codepoints, 0..) |codepoint, index| {
        if (combining_class.forCodepoint(codepoint) == 0) {
            stableSortMarks(codepoints[sequence_start..index]);
            sequence_start = index + 1;
        }
    }
    stableSortMarks(codepoints[sequence_start..]);
}

fn stableSortMarks(codepoints: []u21) void {
    std.sort.insertion(u21, codepoints, {}, struct {
        fn lessThan(_: void, lhs: u21, rhs: u21) bool {
            return combining_class.forCodepoint(lhs) <
                combining_class.forCodepoint(rhs);
        }
    }.lessThan);
}

fn composeSlice(items: []u21) usize {
    if (items.len < 2) return items.len;
    var output_len: usize = 1;
    var starter_index: usize = 0;
    var starter = items[0];
    var previous_class: u8 = 0;

    for (items[1..]) |codepoint| {
        const current_class = combining_class.forCodepoint(codepoint);
        const composite = if (previous_class == 0 or
            previous_class < current_class)
            composePair(starter, codepoint)
        else
            null;
        if (composite) |value| {
            items[starter_index] = value;
            starter = value;
            continue;
        }

        items[output_len] = codepoint;
        if (current_class == 0) {
            starter_index = output_len;
            starter = codepoint;
        }
        previous_class = current_class;
        output_len += 1;
    }
    return output_len;
}

fn pairChangesUnderForm(starter: u21, current: u21, form: Form) bool {
    // Unicode 17's longest recursive compatibility decomposition has 18
    // components; 64 leaves room for both the starter and the current scalar.
    // A Maybe scalar only needs the current starter: any intervening input
    // mark either blocks it or has a lower combining class.
    var storage: [64]u21 = undefined;
    var len: usize = 0;
    const compatibility = form == .nfkc or form == .nfkd;
    appendDecompositionFixed(&storage, &len, starter, compatibility);
    appendDecompositionFixed(&storage, &len, current, compatibility);
    canonicalOrder(storage[0..len]);
    const normalized_len = if (form == .nfc or form == .nfkc)
        composeSlice(storage[0..len])
    else
        len;
    return normalized_len != 2 or storage[0] != starter or
        storage[1] != current;
}

fn appendDecompositionFixed(
    output: *[64]u21,
    len: *usize,
    codepoint: u21,
    compatibility: bool,
) void {
    if (decomposeHangul(codepoint)) |parts| {
        std.debug.assert(len.* + parts.len <= output.len);
        for (parts.slice()) |component| {
            output[len.*] = component;
            len.* += 1;
        }
        return;
    }
    const mapping = if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    if (mapping) |components| {
        std.debug.assert(len.* + components.len <= output.len);
        for (components) |component| {
            output[len.*] = component;
            len.* += 1;
        }
        return;
    }
    output[len.*] = codepoint;
    len.* += 1;
}

fn composePair(starter: u21, combining: u21) ?u21 {
    return composeHangul(starter, combining) orelse
        data.composePair(starter, combining);
}

const hangul_s_base: u21 = 0xac00;
const hangul_l_base: u21 = 0x1100;
const hangul_v_base: u21 = 0x1161;
const hangul_t_base: u21 = 0x11a7;
const hangul_l_count: u21 = 19;
const hangul_v_count: u21 = 21;
const hangul_t_count: u21 = 28;
const hangul_n_count: u21 = hangul_v_count * hangul_t_count;
const hangul_s_count: u21 = hangul_l_count * hangul_n_count;

const HangulDecomposition = struct {
    values: [3]u21,
    len: usize,

    fn slice(self: *const HangulDecomposition) []const u21 {
        return self.values[0..self.len];
    }
};

fn decomposeHangul(codepoint: u21) ?HangulDecomposition {
    if (codepoint < hangul_s_base or
        codepoint >= hangul_s_base + hangul_s_count) return null;
    const index = codepoint - hangul_s_base;
    const l = hangul_l_base + index / hangul_n_count;
    const v = hangul_v_base + (index % hangul_n_count) / hangul_t_count;
    const t = index % hangul_t_count;
    return if (t == 0)
        .{ .values = .{ l, v, 0 }, .len = 2 }
    else
        .{ .values = .{ l, v, hangul_t_base + t }, .len = 3 };
}

fn composeHangul(starter: u21, combining: u21) ?u21 {
    const l_index = starter -% hangul_l_base;
    if (l_index < hangul_l_count) {
        const v_index = combining -% hangul_v_base;
        if (v_index < hangul_v_count) {
            return hangul_s_base +
                (l_index * hangul_v_count + v_index) * hangul_t_count;
        }
    }
    const s_index = starter -% hangul_s_base;
    if (s_index < hangul_s_count and s_index % hangul_t_count == 0) {
        const t_index = combining -% hangul_t_base;
        if (t_index > 0 and t_index < hangul_t_count) {
            return starter + t_index;
        }
    }
    return null;
}

fn expectFormNormalized(source: []const u8, expected: []const u8, form: Form) !void {
    const output = try normalizeFormAlloc(std.testing.allocator, source, form);
    defer if (output) |owned| std.testing.allocator.free(owned);
    if (std.mem.eql(u8, source, expected)) {
        if (output != null) {
            std.debug.print("{s} unnecessarily changed: source={x} actual={x}\n", .{ @tagName(form), source, output.? });
            return error.TestUnexpectedResult;
        }
    } else {
        const actual = output orelse {
            std.debug.print("{s} unexpectedly unchanged: source={x} expected={x}\n", .{ @tagName(form), source, expected });
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(expected, actual);
    }
    if (!(try isNormalizedForm(expected, form))) {
        std.debug.print("{s} expected output rejected: expected={x}\n", .{ @tagName(form), expected });
        return error.TestUnexpectedResult;
    }
}

fn expectNormalized(source: []const u8, expected: []const u8) !void {
    try expectFormNormalized(source, expected, .nfc);
}

test "normalization keeps ASCII and normalized UTF-8 allocation free" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expect((try normalizeAlloc(
        failing.allocator(),
        "plain ASCII",
    )) == null);
    try std.testing.expect((try normalizeAlloc(
        failing.allocator(),
        "caf\xc3\xa9 \xe4\xb8\xad",
    )) == null);
}

test "NFC performs canonical ordering composition and Hangul composition" {
    try std.testing.expect(!(try isNormalized("A\u{0301}")));
    try std.testing.expect(!(try isNormalized("\u{1100}\u{1161}")));
    try expectNormalized("cafe\xcc\x81", "caf\xc3\xa9");
    try expectNormalized("A\u{0301}\u{0323}", "\u{1ea0}\u{0301}");
    try expectNormalized("\u{1100}\u{1161}\u{11a8}", "\u{ac01}");
    try expectNormalized("\u{212b}", "\u{00c5}");
    try expectNormalized("\u{0958}", "\u{0915}\u{093c}");
}

test "NFC does not apply display-only Vietnamese mark reordering" {
    try expectNormalized("a\u{0301}\u{0306}", "\u{00e1}\u{0306}");
}

test "NFD decomposes and NFD output is stable" {
    try std.testing.expect(!(try isNormalizedForm("\u{00c5}", .nfd)));
    try expectFormNormalized("\u{00c5}", "A\u{030a}", .nfd);
    try expectFormNormalized("\u{ac01}", "\u{1100}\u{1161}\u{11a8}", .nfd);
    try expectFormNormalized("\u{1ea4}", "A\u{0302}\u{0301}", .nfd);
    try expectFormNormalized("caf\xc3\xa9", "cafe\u{0301}", .nfd);
}

test "NFKC and NFKD apply compatibility mappings" {
    try std.testing.expect(!(try isNormalizedForm("\u{fb01}", .nfkc)));
    try expectFormNormalized("\u{fb01}", "fi", .nfkc);
    try expectFormNormalized("\u{00a8}", " \u{0308}", .nfkc);
    try expectFormNormalized("\u{2163}", "IV", .nfkc);
    try expectFormNormalized("\u{fb01}", "fi", .nfkd);
    try expectFormNormalized("\u{00c5}", "A\u{030a}", .nfkd);
    try expectFormNormalized("\u{1ea4}", "A\u{0302}\u{0301}", .nfkd);
    try expectFormNormalized("\u{ff21}", "A", .nfkc);
}

test "normalization rejects invalid UTF-8 before allocating" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        normalizeAlloc(failing.allocator(), "valid\xfftail"),
    );
    try std.testing.expectError(error.InvalidUtf8, isNormalized("\xff"));
}

test "Unicode 17 NFC normalization conformance" {
    if (conformance.len < 12 or
        !std.mem.eql(u8, conformance[0..4], "CJNF") or
        conformance[4] != 1 or
        !std.mem.eql(u8, conformance[5..8], &unicode_version))
    {
        return error.InvalidFixture;
    }
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    try std.testing.expectEqual(@as(u32, 20_034), case_count);
    var fixture_offset: usize = 12;
    for (0..case_count) |_| {
        const lengths = conformance[fixture_offset..][0..5].*;
        fixture_offset += 5;
        var columns: [5][72]u8 = undefined;
        var column_lengths: [5]usize = undefined;
        for (lengths, 0..) |scalar_count, column_index| {
            var utf8_len: usize = 0;
            for (0..scalar_count) |_| {
                const codepoint: u21 = @intCast(std.mem.readInt(
                    u32,
                    conformance[fixture_offset..][0..4],
                    .little,
                ));
                fixture_offset += 4;
                utf8_len += try std.unicode.utf8Encode(
                    codepoint,
                    columns[column_index][utf8_len..],
                );
            }
            column_lengths[column_index] = utf8_len;
        }
        const c1 = columns[0][0..column_lengths[0]];
        const c2 = columns[1][0..column_lengths[1]];
        const c3 = columns[2][0..column_lengths[2]];
        const c4 = columns[3][0..column_lengths[3]];
        const c5 = columns[4][0..column_lengths[4]];
        try expectNormalized(c1, c2);
        try expectNormalized(c2, c2);
        try expectNormalized(c3, c2);
        try expectNormalized(c4, c4);
        try expectNormalized(c5, c4);
    }
    try std.testing.expectEqual(conformance.len, fixture_offset);
}
