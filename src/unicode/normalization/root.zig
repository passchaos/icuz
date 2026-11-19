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
const utf16 = @import("../utf16.zig");

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
    if (isNormalizedFormUnchecked(text, form)) return null;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try normalizeChangedFormInto(allocator, text, form, &output);
    if (std.mem.eql(u8, output.items, text)) {
        output.deinit(allocator);
        return null;
    }
    return try output.toOwnedSlice(allocator);
}

/// Append the normalized form of `text` to `output`.
///
/// Returns whether the normalized text differs from the input. The output
/// receives the normalized text in both cases, so callers can reuse one buffer
/// across calls.
pub fn normalizeFormInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!bool {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (isNormalizedFormUnchecked(text, form)) {
        try output.appendSlice(allocator, text);
        return false;
    }

    const before = output.items.len;
    try normalizeChangedFormInto(allocator, text, form, output);
    return !std.mem.eql(u8, output.items[before..], text);
}

/// Normalize a code-point slice. Returns null when the slice is unchanged.
pub fn normalizeCodepointsAlloc(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    form: Form,
) error{OutOfMemory}!?[]u21 {
    if (isNormalizedCodepoints(codepoints, form)) return null;

    var output = std.ArrayList(u21).empty;
    errdefer output.deinit(allocator);
    try normalizeCodepointsInto(allocator, codepoints, form, &output);
    const result = try output.toOwnedSlice(allocator);
    if (std.mem.eql(u21, result, codepoints)) {
        allocator.free(result);
        return null;
    }
    return result;
}

/// Append the recursive canonical decomposition of a single code point to
/// `output` without reordering it against surrounding text. ICU's identical
/// collation strength compares this per-code-point decomposition.
pub fn appendCanonicalDecompositionInto(
    allocator: std.mem.Allocator,
    codepoint: u21,
    output: *std.ArrayList(u21),
) error{OutOfMemory}!void {
    try appendDecomposition(allocator, output, codepoint, false);
}

/// Append the normalized form of a code-point slice to `output`.
pub fn normalizeCodepointsInto(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    form: Form,
    output: *std.ArrayList(u21),
) error{OutOfMemory}!void {
    const start = output.items.len;
    // Decomposition rarely grows text beyond the input; reserve once so the
    // per-code-point append does not trigger repeated reallocation.
    try output.ensureUnusedCapacity(allocator, codepoints.len);
    const compatibility = form == .nfkc or form == .nfkd;
    for (codepoints) |codepoint| {
        try appendDecomposition(allocator, output, codepoint, compatibility);
    }

    const slice = output.items[start..];
    canonicalOrder(slice);
    if (form == .nfc or form == .nfkc) {
        const len = composeSlice(slice);
        output.shrinkRetainingCapacity(start + len);
    }
}

/// Report whether a code-point slice is in `form` without allocating.
pub fn isNormalizedCodepoints(
    codepoints: []const u21,
    form: Form,
) bool {
    var starter: ?u21 = null;
    var previous_input_class: u8 = 0;
    for (codepoints) |codepoint| {
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

/// Normalize a UTF-16 slice. Returns null when it is already normalized.
pub fn normalizeUtf16Alloc(
    allocator: std.mem.Allocator,
    units: []const u16,
    form: Form,
) error{ InvalidUtf16, OutOfMemory }!?[]u16 {
    const codepoints = utf16.decodeAlloc(allocator, units) catch |err| switch (err) {
        error.InvalidUtf16 => return error.InvalidUtf16,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => unreachable,
    };
    defer allocator.free(codepoints);

    const normalized = try normalizeCodepointsAlloc(allocator, codepoints, form);
    const result = normalized orelse return null;
    defer allocator.free(result);

    return utf16.encodeAlloc(allocator, result) catch |err| switch (err) {
        error.InvalidUtf16 => return error.InvalidUtf16,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => unreachable,
    };
}

/// Report whether a UTF-16 slice is in `form` without allocating.
pub fn isNormalizedUtf16(
    units: []const u16,
    form: Form,
) error{InvalidUtf16}!bool {
    if (!utf16.validate(units)) return error.InvalidUtf16;

    var starter: ?u21 = null;
    var previous_input_class: u8 = 0;
    var iterator = utf16.Iterator{ .units = units };
    while (iterator.next()) |codepoint| {
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

/// Incremental normalizer for chunked UTF-8 input.
///
/// Each `feed` chunk must be valid UTF-8 and end on a code-point boundary. The
/// normalizer holds only the unstable suffix (one starter, its marks, and any
/// Hangul composition chain), so memory does not grow with the total input.
pub const Normalizer = struct {
    allocator: std.mem.Allocator,
    form: Form,
    pending: std.ArrayList(u21),
    normalized: std.ArrayList(u21),

    pub fn init(allocator: std.mem.Allocator, form: Form) Normalizer {
        return .{
            .allocator = allocator,
            .form = form,
            .pending = .empty,
            .normalized = .empty,
        };
    }

    pub fn deinit(self: *Normalizer) void {
        self.pending.deinit(self.allocator);
        self.normalized.deinit(self.allocator);
    }

    pub fn feed(
        self: *Normalizer,
        text: []const u8,
        output: *std.ArrayList(u8),
    ) Error!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            try self.process(codepoint, output);
        }
    }

    pub fn finish(self: *Normalizer, output: *std.ArrayList(u8)) Error!void {
        try self.flush(output);
    }

    fn process(
        self: *Normalizer,
        codepoint: u21,
        output: *std.ArrayList(u8),
    ) Error!void {
        if (self.pending.items.len == 0 or
            combining_class.forCodepoint(codepoint) != 0)
        {
            try self.pending.append(self.allocator, codepoint);
            return;
        }

        if ((self.form == .nfd or self.form == .nfkd) or
            !self.pendingCanComposeWith(codepoint))
        {
            try self.flush(output);
        }
        try self.pending.append(self.allocator, codepoint);
    }

    fn pendingCanComposeWith(self: *Normalizer, codepoint: u21) bool {
        if (self.form == .nfd or self.form == .nfkd) return false;

        var base: ?u21 = null;
        for (self.pending.items) |item| {
            if (combining_class.forCodepoint(item) != 0) continue;
            if (base == null) {
                base = item;
            } else if (composeHangul(base.?, item)) |composed| {
                base = composed;
            } else {
                base = item;
            }
        }
        if (base == null) return false;
        return composeHangul(base.?, codepoint) != null;
    }

    fn flush(
        self: *Normalizer,
        output: *std.ArrayList(u8),
    ) Error!void {
        if (self.pending.items.len == 0) return;

        self.normalized.clearRetainingCapacity();
        try normalizeCodepointsInto(
            self.allocator,
            self.pending.items,
            self.form,
            &self.normalized,
        );

        var encoded: [4]u8 = undefined;
        try output.ensureUnusedCapacity(
            self.allocator,
            self.normalized.items.len * 4,
        );
        for (self.normalized.items) |codepoint| {
            const len = std.unicode.utf8Encode(codepoint, &encoded) catch
                unreachable;
            try output.appendSlice(self.allocator, encoded[0..len]);
        }
        self.pending.clearRetainingCapacity();
    }
};

fn normalizeChangedFormInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!void {
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
    try output.ensureUnusedCapacity(allocator, utf8_len);
    var encoded: [4]u8 = undefined;
    for (codepoints.items) |codepoint| {
        const len = std.unicode.utf8Encode(codepoint, &encoded) catch
            unreachable;
        try output.appendSlice(allocator, encoded[0..len]);
    }
}

/// Validate UTF-8 and report whether `text` is in NFC without allocating.
pub fn isNormalized(text: []const u8) error{InvalidUtf8}!bool {
    return isNormalizedForm(text, .nfc);
}

/// Validate UTF-8 and report whether `text` is in `form` without allocating.
pub fn isNormalizedForm(text: []const u8, form: Form) error{InvalidUtf8}!bool {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return isNormalizedFormUnchecked(text, form);
}

/// Report whether prevalidated UTF-8 is in NFC without allocating.
pub fn isNormalizedAssumeValid(text: []const u8) bool {
    return isNormalizedFormAssumeValid(text, .nfc);
}

/// Report whether prevalidated UTF-8 is in `form` without allocating.
pub fn isNormalizedFormAssumeValid(text: []const u8, form: Form) bool {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    return isNormalizedFormUnchecked(text, form);
}

fn isNormalizedFormUnchecked(text: []const u8, form: Form) bool {
    // ASCII is Quick_Check=Yes with Canonical_Combining_Class=0 in every
    // normalization form, so a pure-ASCII prefix cannot affect the state
    // machine. Skipping it turns the common prose case into a byte scan.
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) return true;

    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var previous_input_class: u8 = 0;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = ascii_end };
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

/// Return the length of the longest prefix that is definitely normalized.
///
/// The result is the byte offset of the first scalar that can change under
/// `form`, or `text.len` when the whole string is normalized. A `MAYBE` scalar
/// returns the offset of the preceding starter, matching ICU's
/// `spanQuickCheckYes` contract.
pub fn spanQuickCheckYes(
    text: []const u8,
    form: Form,
) error{InvalidUtf8}!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) return text.len;

    var starter_offset: usize = if (ascii_end > 0) ascii_end - 1 else 0;
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var previous_input_class: u8 = 0;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = ascii_end };
    while (true) {
        const start = iterator.i;
        const codepoint = iterator.nextCodepoint() orelse break;
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) return start;
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            previous_input_class > current_class) return start;
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return starter_offset;
        }
        if (current_class == 0) {
            starter = codepoint;
            starter_offset = start;
        }
        previous_input_class = current_class;
    }
    return text.len;
}

fn asciiPrefixLen(text: []const u8) usize {
    const high_bits: u64 = 0x8080_8080_8080_8080;
    var index: usize = 0;
    while (index + 8 <= text.len) : (index += 8) {
        const word = std.mem.readInt(u64, text[index..][0..8], .little);
        if (word & high_bits != 0) break;
    }
    while (index < text.len and text[index] < 0x80) : (index += 1) {}
    return index;
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

test "normalization appends into a caller-owned buffer" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try std.testing.expect(try normalizeFormInto(
        allocator,
        "cafe\u{0301}",
        .nfc,
        &output,
    ));
    try std.testing.expectEqualStrings("caf\xc3\xa9", output.items);

    try std.testing.expect(!(try normalizeFormInto(
        allocator,
        "abc",
        .nfc,
        &output,
    )));
    try std.testing.expectEqualStrings("caf\xc3\xa9abc", output.items);

    try std.testing.expectError(
        error.InvalidUtf8,
        normalizeFormInto(allocator, "\xff", .nfc, &output),
    );
}

test "spanQuickCheckYes reports the first unstable offset" {
    try std.testing.expectEqual(
        @as(usize, 3),
        try spanQuickCheckYes("abc", .nfc),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try spanQuickCheckYes("a\u{0301}", .nfc),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try spanQuickCheckYes("abc\u{0301}", .nfc),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try spanQuickCheckYes("\u{0340}", .nfc),
    );
}

test "UTF-16 normalization" {
    const allocator = std.testing.allocator;
    const source = try utf16.utf8ToUtf16Alloc(allocator, "cafe\u{0301}");
    defer allocator.free(source);
    try std.testing.expect(!(try isNormalizedUtf16(source, .nfc)));

    const normalized = (try normalizeUtf16Alloc(allocator, source, .nfc)).?;
    defer allocator.free(normalized);
    try std.testing.expect(try isNormalizedUtf16(normalized, .nfc));

    const text = try utf16.utf16ToUtf8Alloc(allocator, normalized);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("caf\xc3\xa9", text);
}

test "streaming normalizer matches one-shot normalization" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        "cafe\u{0301}",
        "A\u{0301}B",
        "\u{1100}\u{1161}\u{11A8}",
        "\u{0301}A",
        "plain ASCII",
        "a\u{0323}\u{0301}b",
    };
    const forms = [_]Form{ .nfc, .nfd, .nfkc, .nfkd };

    for (forms) |form| {
        for (inputs) |input| {
            var normalizer = Normalizer.init(allocator, form);
            defer normalizer.deinit();
            var output = std.ArrayList(u8).empty;
            defer output.deinit(allocator);

            var iterator = std.unicode.Utf8Iterator{ .bytes = input, .i = 0 };
            while (iterator.nextCodepoint()) |codepoint| {
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &encoded) catch
                    unreachable;
                try normalizer.feed(encoded[0..len], &output);
            }
            try normalizer.finish(&output);

            const expected = try normalizeFormAlloc(allocator, input, form);
            defer if (expected) |owned| allocator.free(owned);
            try std.testing.expectEqualStrings(
                expected orelse input,
                output.items,
            );
        }
    }
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
