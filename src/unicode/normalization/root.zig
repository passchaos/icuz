//! Unicode 17 normalization for UTF-8 text.
//!
//! This module implements the four UAX #15 forms: NFC, NFD, NFKC, and NFKD.
//! Canonical forms use recursive canonical decomposition and canonical
//! combining-class ordering; compatibility forms additionally apply
//! compatibility mappings. NFC and NFKC then perform canonical composition,
//! including algorithmic Hangul handling. The module deliberately does not
//! perform display-specific or language-specific reordering.

const std = @import("std");
const scalar = @import("../scalar/root.zig");
const combining_class = @import("../canonical/combining_class.zig");
const decomposition = @import("../canonical/decomposition.zig");
const data = @import("data.zig");
const inert = @import("inert.zig");
const utf16 = @import("../utf16.zig");

const conformance = @embedFile("conformance.bin");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{ InvalidUtf8, OutOfMemory };
pub const QuickCheck = data.QuickCheck;
pub const Form = data.Form;
pub const nfkcCasefoldAlloc = @import("casefold.zig").nfkcCasefoldAlloc;
pub const nfkcSimpleCasefoldAlloc = @import("casefold.zig").nfkcSimpleCasefoldAlloc;

/// Canonical decomposition mapping for one scalar, or null when it has none.
/// Hangul syllables decompose algorithmically; use `decomposeInto` for those.
pub fn decompositionFor(codepoint: u21) ?[]const u21 {
    return decomposition.forCodepoint(codepoint);
}

/// Compatibility decomposition mapping for one scalar, or null.
pub fn compatibilityDecompositionFor(codepoint: u21) ?[]const u21 {
    return decomposition.compatibilityForCodepoint(codepoint);
}

/// Canonical combining class for one scalar.
pub fn combiningClass(codepoint: u21) u8 {
    return combining_class.forCodepoint(codepoint);
}

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

/// Validate UTF-8, copy stable spans verbatim, and normalize only the spans
/// that can change, all in one pass. Returns whether any edit was applied.
/// Output is untouched when the text is already normalized.
/// True when every scalar in U+4000..U+9FFF is on a simple page in both
/// canonical and compatibility normalization. Canonical composition pairs do
/// not start in this range, so the scans can skip decoding these CJK scalars
/// and treat them as starters.
const cjk_lead_simple = blk: {
    @setEvalBranchQuota(100_000);
    for (0x40..0xa0) |page| {
        const codepoint: u21 = @intCast(page * 256);
        if (!data.isSimplePage(codepoint, false)) break :blk false;
        if (!data.isSimplePage(codepoint, true)) break :blk false;
    }
    break :blk true;
};

fn normalizeFusedInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!bool {
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) return false;

    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    var engine = SegmentEngine(Utf8Sink){
        .allocator = allocator,
        .sink = .{ .list = output, .allocator = allocator },
        .form = form,
        .compatibility = compatibility,
        .compose = compose,
    };
    defer engine.deinit();
    var stable_start: usize = 0;
    var changed = false;
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var starter_offset: usize = if (ascii_end > 0) ascii_end - 1 else 0;
    var previous_input_class: u8 = 0;
    var index: usize = ascii_end;
    while (index < text.len) {
        if (text[index] < 0x80) {
            var end = index;
            while (end < text.len and text[end] < 0x80) end += 1;
            starter = text[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            index = end;
            continue;
        }
        const start = index;
        if (cjk_lead_simple and text[index] >= 0xe4 and
            text[index] <= 0xe9)
        {
            if (index + 3 > text.len) return error.InvalidUtf8;
            if (text[index + 1] & 0xc0 != 0x80 or
                text[index + 2] & 0xc0 != 0x80)
            {
                return error.InvalidUtf8;
            }
            starter = null;
            starter_offset = start;
            previous_input_class = 0;
            index += 3;
            continue;
        }
        const decoded = scalar.decodeValidating(text, index) orelse
            return error.InvalidUtf8;
        const codepoint = decoded.codepoint;
        index = decoded.next;

        // Compose L+V+T jamo directly: the syllable index is arithmetic, so
        // the generic segment machinery (decompose, order, compose, encode)
        // has nothing to add. A preceding mark keeps the generic path, which
        // tracks ordering against the earlier starter.
        if (compose and previous_input_class == 0 and
            codepoint >= hangul_l_base and
            codepoint < hangul_l_base + hangul_l_count)
        {
            if (hangulSyllableAt(text, codepoint, index)) |syllable| {
                if (!changed) {
                    try output.ensureUnusedCapacity(allocator, text.len + 16);
                    changed = true;
                }
                if (start > stable_start) {
                    try output.appendSlice(
                        allocator,
                        text[stable_start..start],
                    );
                }
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(
                    syllable.composed,
                    &encoded,
                ) catch unreachable;
                try output.appendSlice(allocator, encoded[0..encoded_len]);
                index = syllable.end;
                stable_start = index;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
        }

        if (codepoint >= 0x80 and inert.isInert(codepoint, form)) {
            starter = codepoint;
            starter_offset = start;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        const current_class = combining_class.forCodepoint(codepoint);
        const edit = quick_check == .no or
            (current_class != 0 and previous_input_class > current_class) or
            (quick_check == .maybe and starter != null and
                (previous_input_class == 0 or
                    previous_input_class < current_class) and
                pairChangesUnderForm(starter.?, codepoint, form));
        if (edit) {
            if (!changed) {
                try output.ensureUnusedCapacity(allocator, text.len + 16);
                changed = true;
            }
            if (starter_offset > stable_start) {
                try output.appendSlice(
                    allocator,
                    text[stable_start..starter_offset],
                );
            }
            const end = (try normalizeSegmentFastAt(
                allocator,
                text,
                starter_offset,
                form,
                output,
            )) orelse blk: {
                const fallback_end = segmentEnd(text, starter_offset);
                try normalizeSegmentInto(
                    &engine,
                    text[starter_offset..fallback_end],
                );
                break :blk fallback_end;
            };
            stable_start = end;
            index = end;
            starter = null;
            starter_offset = end;
            previous_input_class = 0;
            continue;
        }
        if (current_class == 0) {
            starter = codepoint;
            starter_offset = start;
        }
        previous_input_class = current_class;
    }
    if (!changed) return false;
    try output.appendSlice(allocator, text[stable_start..]);
    return true;
}

/// Return an allocator-owned string in `form` when `text` must change, or
/// `null` when it is already normalized. Invalid UTF-8 is rejected before any
/// allocation.
pub fn normalizeFormAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
) Error!?[]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    if (!try normalizeFusedInto(allocator, text, form, &output)) {
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
    const before = output.items.len;
    const changed = normalizeFusedInto(allocator, text, form, output) catch |err| {
        output.shrinkRetainingCapacity(before);
        return err;
    };
    if (!changed) try output.appendSlice(allocator, text);
    return changed;
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

/// Outcome of `normalizeCodepointsTryInto`.
pub const CodepointNormalization = union(enum) {
    /// The input is already in the requested form.
    unchanged,
    /// The normalized form was written into the caller's buffer.
    written: []const u21,
    /// The buffer was too small; callers should fall back to the allocating
    /// API.
    overflow,
};

/// Normalize already decoded code points into a caller-owned buffer without
/// heap allocation when the result fits. Short sort keys and search
/// candidates use this to avoid a per-call allocation.
pub fn normalizeCodepointsTryInto(
    buffer: []u21,
    codepoints: []const u21,
    form: Form,
) CodepointNormalization {
    if (isNormalizedCodepoints(codepoints, form)) return .unchanged;
    return normalizeCodepointsTryIntoChanged(buffer, codepoints, form);
}

/// `normalizeCodepointsTryInto` for input already known to need changes,
/// so callers that checked quick-check status do not scan it twice.
pub fn normalizeCodepointsTryIntoChanged(
    buffer: []u21,
    codepoints: []const u21,
    form: Form,
) CodepointNormalization {
    var fixed = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(buffer));
    var output = std.ArrayList(u21).empty;
    normalizeCodepointsInto(fixed.allocator(), codepoints, form, &output) catch
        return .overflow;
    return .{ .written = output.items };
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

/// Decompose one code point into `buffer` and return the component count.
pub fn decomposeInto(
    buffer: *[64]u21,
    codepoint: u21,
    compatibility: bool,
) usize {
    if (codepoint < 0x80) {
        buffer[0] = codepoint;
        return 1;
    }
    if (decomposeHangul(codepoint)) |parts| {
        const slice = parts.slice();
        @memcpy(buffer[0..slice.len], slice);
        return slice.len;
    }
    const mapping = if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    if (mapping) |components| {
        @memcpy(buffer[0..components.len], components);
        return components.len;
    }
    buffer[0] = codepoint;
    return 1;
}

/// Incremental starter-segment normalizer. Canonical ordering and
/// composition run per starter segment instead of over the whole string, and
/// one-code-point segments (ASCII prose, CJK, and so on) skip both passes.
/// Output sink for the segment engine: code points or UTF-8 bytes.
const CodepointSink = struct {
    list: *std.ArrayList(u21),
    allocator: std.mem.Allocator,

    fn appendCodepoints(
        self: *CodepointSink,
        codepoints: []const u21,
    ) error{OutOfMemory}!void {
        try self.list.appendSlice(self.allocator, codepoints);
    }

    fn appendOne(
        self: *CodepointSink,
        codepoint: u21,
    ) error{OutOfMemory}!void {
        try self.list.append(self.allocator, codepoint);
    }
};

const Utf8Sink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn appendCodepoints(
        self: *Utf8Sink,
        codepoints: []const u21,
    ) error{OutOfMemory}!void {
        try self.list.ensureUnusedCapacity(self.allocator, codepoints.len * 4);
        var encoded: [4]u8 = undefined;
        for (codepoints) |codepoint| {
            const length = std.unicode.utf8Encode(codepoint, &encoded) catch
                unreachable;
            self.list.appendSliceAssumeCapacity(encoded[0..length]);
        }
    }

    fn appendOne(
        self: *Utf8Sink,
        codepoint: u21,
    ) error{OutOfMemory}!void {
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch
            unreachable;
        try self.list.appendSlice(self.allocator, encoded[0..length]);
    }

    fn appendAsciiBytes(
        self: *Utf8Sink,
        bytes: []const u8,
    ) error{OutOfMemory}!void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

/// Incremental starter-segment normalizer. Canonical ordering and
/// composition run per starter segment instead of over the whole string, and
/// one-code-point segments (ASCII prose, CJK, and so on) skip both passes.
fn SegmentEngine(comptime Sink: type) type {
    return struct {
        allocator: std.mem.Allocator,
        sink: Sink,
        segment: std.ArrayList(u21) = .empty,
        /// Starter that may still receive combining marks; written to the
        /// output only once the next starter proves that it has none.
        pending: ?u21 = null,
        form: Form,
        compatibility: bool,
        compose: bool,

        const Self = @This();

        fn deinit(self: *Self) void {
            self.segment.deinit(self.allocator);
        }

        fn feed(self: *Self, codepoint: u21) error{OutOfMemory}!void {
            // Inert scalars have no decomposition, combining class 0, and
            // cannot compose with a previous starter.
            if (codepoint >= 0x80 and inert.isInert(codepoint, self.form)) {
                try self.settle();
                self.pending = codepoint;
                return;
            }
            // Unicode 17's longest recursive compatibility decomposition has
            // 18 components; 64 leaves generous headroom.
            var parts: [64]u21 = undefined;
            const count = decomposeInto(&parts, codepoint, self.compatibility);
            for (parts[0..count]) |part| {
                // A segment ends at a starter that cannot compose with the
                // previous character. Spacing marks such as U+0DCF have
                // combining class 0 but are composition seconds, so they stay
                // inside the segment.
                const starter = part < 0x80 or inert.isInert(part, self.form);
                if (starter) {
                    try self.settle();
                    self.pending = part;
                } else {
                    if (self.pending) |pending| {
                        try self.segment.append(self.allocator, pending);
                        self.pending = null;
                    }
                    try self.segment.append(self.allocator, part);
                }
            }
        }

        /// Emit the pending starter or the accumulated mark segment.
        fn settle(self: *Self) error{OutOfMemory}!void {
            const items = self.segment.items;
            if (items.len > 0) {
                canonicalOrder(items);
                const len = if (self.compose) composeSlice(items) else items.len;
                try self.sink.appendCodepoints(items[0..len]);
                self.segment.clearRetainingCapacity();
                return;
            }
            if (self.pending) |pending| {
                try self.sink.appendOne(pending);
                self.pending = null;
            }
        }

        fn flush(self: *Self) error{OutOfMemory}!void {
            try self.settle();
        }
    };
}

/// Append the normalized form of a code-point slice to `output`.
pub fn normalizeCodepointsInto(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    form: Form,
    output: *std.ArrayList(u21),
) error{OutOfMemory}!void {
    // Decomposition rarely grows text beyond the input; reserve once so the
    // per-code-point append does not trigger repeated reallocation.
    try output.ensureUnusedCapacity(allocator, codepoints.len);
    var engine = SegmentEngine(CodepointSink){
        .allocator = allocator,
        .sink = .{ .list = output, .allocator = allocator },
        .form = form,
        .compatibility = form == .nfkc or form == .nfkd,
        .compose = form == .nfc or form == .nfkc,
    };
    defer engine.deinit();
    var index: usize = 0;
    while (index < codepoints.len) {
        // Bulk-copy inert starters; only the final one may still receive
        // combining marks, so it stays pending.
        const run_start = index;
        while (index < codepoints.len and
            (codepoints[index] < 0x80 or
                inert.isInert(codepoints[index], form)))
        {
            index += 1;
        }
        if (index > run_start) {
            try engine.settle();
            const run = codepoints[run_start..index];
            if (run.len > 1) {
                try engine.sink.appendCodepoints(run[0 .. run.len - 1]);
            }
            engine.pending = run[run.len - 1];
            continue;
        }
        try engine.feed(codepoints[index]);
        index += 1;
    }
    try engine.flush();
}

/// Report whether a code-point slice is in `form` without allocating.
pub fn isNormalizedCodepoints(
    codepoints: []const u21,
    form: Form,
) bool {
    const compatibility = form == .nfkc or form == .nfkd;
    var starter: ?u21 = null;
    var previous_input_class: u8 = 0;
    for (codepoints) |codepoint| {
        if (codepoint < 0x80) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
        if (data.isSimplePage(codepoint, compatibility)) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
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
        if (codepoint < 0x80) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
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

fn normalizeSegmentInto(
    engine: *SegmentEngine(Utf8Sink),
    text: []const u8,
) Error!void {
    var index: usize = 0;
    while (index < text.len) {
        // Bulk-copy ASCII runs; the final byte stays pending in case a
        // combining mark follows.
        const run_start = index;
        while (index < text.len and text[index] < 0x80) index += 1;
        if (index > run_start) {
            try engine.settle();
            const run = text[run_start..index];
            if (run.len > 1) {
                try engine.sink.appendAsciiBytes(run[0 .. run.len - 1]);
            }
            engine.pending = run[run.len - 1];
            continue;
        }
        const decoded = scalar.decodeValidating(text, index) orelse
            return error.InvalidUtf8;
        index = decoded.next;
        try engine.feed(decoded.codepoint);
    }
    try engine.flush();
}

/// Normalize one starter segment using stack storage. Returns false when the
/// decomposed segment exceeds the stack buffer, so the caller can fall back to
/// the incremental engine.
/// Normalize the starter segment beginning at `start` using stack storage,
/// decoding the segment once. Returns the byte offset just past the segment,
/// or null when the decomposed segment exceeds the stack buffer.
fn normalizeSegmentFastAt(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
    form: Form,
    output: *std.ArrayList(u8),
) Error!?usize {
    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    var storage: [64]u21 = undefined;
    var classes: [64]u8 = undefined;
    var length: usize = 0;
    var index = start;
    var first = true;
    while (index < text.len) {
        const decoded = scalar.decodeValidating(text, index) orelse
            return error.InvalidUtf8;
        const codepoint = decoded.codepoint;
        const sequence_len = decoded.next - index;
        if (!first) {
            const class = combining_class.forCodepoint(codepoint);
            if (class == 0 and !data.isCompositionSecond(codepoint) and
                !isHangulVOrT(codepoint))
            {
                break;
            }
        }
        first = false;
        index += sequence_len;
        if (codepoint < 0x80) {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = 0;
            length += 1;
            continue;
        }
        if (data.isSimplePage(codepoint, compatibility)) {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = 0;
            length += 1;
            continue;
        }
        var parts: [64]u21 = undefined;
        const count = decomposeInto(&parts, codepoint, compatibility);
        if (length + count > storage.len) return null;
        for (parts[0..count]) |part| {
            storage[length] = part;
            classes[length] = combining_class.forCodepoint(part);
            length += 1;
        }
    }
    canonicalOrderWithClasses(storage[0..length], classes[0..length]);
    const final_len = if (compose)
        composeSliceWithClasses(storage[0..length], classes[0..length])
    else
        length;
    // Encode straight into the list's spare capacity instead of appending
    // one scalar at a time.
    try output.ensureUnusedCapacity(allocator, final_len * 4);
    const dest = output.unusedCapacitySlice();
    var written: usize = 0;
    for (storage[0..final_len]) |codepoint| {
        written += std.unicode.utf8Encode(
            codepoint,
            dest[written..],
        ) catch unreachable;
    }
    output.items.len += written;
    return index;
}

fn normalizeChangedFormInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!void {
    // Reserve the input size once; decomposition may grow the output but
    // rarely reallocates more than once.
    try output.ensureUnusedCapacity(allocator, text.len + 16);
    var engine = SegmentEngine(Utf8Sink){
        .allocator = allocator,
        .sink = .{ .list = output, .allocator = allocator },
        .form = form,
        .compatibility = form == .nfkc or form == .nfkd,
        .compose = form == .nfc or form == .nfkc,
    };
    defer engine.deinit();
    try normalizeSegmentInto(&engine, text);
}

/// Normalize `text`, copying stable spans verbatim and running the segment
/// engine only on the spans that can change. `text` must be valid UTF-8.
fn normalizeWithEditsInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!void {
    // Reserve once for the common case so the per-segment reservations do
    // not each grow the list.
    try output.ensureUnusedCapacity(allocator, text.len + 16);
    var position: usize = 0;
    while (position < text.len) {
        const span = spanQuickCheckYesUnchecked(text[position..], form);
        if (span > 0) {
            try output.appendSlice(
                allocator,
                text[position..][0..span],
            );
            position += span;
            if (position == text.len) break;
        }
        const end = segmentEnd(text, position);
        try normalizeChangedFormInto(
            allocator,
            text[position..end],
            form,
            output,
        );
        position = end;
    }
}

/// Validate UTF-8 and report whether `text` is in NFC without allocating.
pub fn isNormalized(text: []const u8) error{InvalidUtf8}!bool {
    return isNormalizedForm(text, .nfc);
}

/// Validate UTF-8 and report whether `text` is in `form` without allocating.
pub fn isNormalizedForm(text: []const u8, form: Form) error{InvalidUtf8}!bool {
    // The scan validates every scalar it visits. A true result therefore
    // proves the whole string is valid and no second pass is needed. A false
    // result may short-circuit before later invalid bytes, so validate only
    // the unscanned suffix before reporting "not normalized".
    const result = isNormalizedFormScan(text, form);
    if (result.normalized) return true;
    if (!std.unicode.utf8ValidateSlice(text[result.valid_until..])) {
        return error.InvalidUtf8;
    }
    return false;
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

const ScanResult = struct {
    normalized: bool,
    /// Byte offset through which the scan validated UTF-8. Bytes before this
    /// offset are valid even when `normalized` is false.
    valid_until: usize,
};

fn isNormalizedFormScan(text: []const u8, form: Form) ScanResult {
    // ASCII is Quick_Check=Yes with Canonical_Combining_Class=0 in every
    // normalization form, so a pure-ASCII prefix cannot affect the state
    // machine. Skipping it turns the common prose case into a byte scan.
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) {
        return .{ .normalized = true, .valid_until = text.len };
    }

    const compatibility = form == .nfkc or form == .nfkd;
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var previous_input_class: u8 = 0;
    var index: usize = ascii_end;
    while (index < text.len) {
        if (text[index] < 0x80) {
            var end = index;
            while (end < text.len and text[end] < 0x80) end += 1;
            starter = text[end - 1];
            previous_input_class = 0;
            index = end;
            continue;
        }
        const start = index;
        if (cjk_lead_simple and text[index] >= 0xe4 and
            text[index] <= 0xe9)
        {
            if (index + 3 > text.len) {
                return .{ .normalized = false, .valid_until = start };
            }
            if (text[index + 1] & 0xc0 != 0x80 or
                text[index + 2] & 0xc0 != 0x80)
            {
                return .{ .normalized = false, .valid_until = start };
            }
            starter = null;
            previous_input_class = 0;
            index += 3;
            continue;
        }
        const decoded = scalar.decodeValidating(text, index) orelse
            return .{ .normalized = false, .valid_until = start };
        const codepoint = decoded.codepoint;
        index = decoded.next;
        if (data.isSimplePage(codepoint, compatibility)) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) {
            return .{ .normalized = false, .valid_until = start };
        }
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and previous_input_class > current_class) {
            return .{ .normalized = false, .valid_until = start };
        }
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return .{ .normalized = false, .valid_until = start };
        }
        if (current_class == 0) starter = codepoint;
        previous_input_class = current_class;
    }
    return .{ .normalized = true, .valid_until = text.len };
}

fn isNormalizedFormUnchecked(text: []const u8, form: Form) bool {
    return isNormalizedFormScan(text, form).normalized;
}

/// Return the length of the longest prefix that is definitely normalized.
///
/// The result is a safe byte offset at or before the first scalar that can
/// change under `form`, or `text.len` when the whole string is normalized.
/// When a combining mark could compose with or reorder against the preceding
/// starter, the offset of that starter is returned so the caller can
/// normalize the suffix independently.
pub fn spanQuickCheckYes(
    text: []const u8,
    form: Form,
) error{InvalidUtf8}!usize {
    const span = try spanQuickCheckYesImpl(true, text, form);
    // A full-length span proves the scan visited every scalar. Otherwise the
    // scan stopped at the first change and the suffix is still unvalidated.
    if (span == text.len) return span;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return span;
}

fn spanQuickCheckYesUnchecked(text: []const u8, form: Form) usize {
    return spanQuickCheckYesImpl(false, text, form);
}

fn spanQuickCheckYesImpl(
    comptime validating: bool,
    text: []const u8,
    form: Form,
) if (validating) error{InvalidUtf8}!usize else usize {
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) return text.len;

    var starter_offset: usize = if (ascii_end > 0) ascii_end - 1 else 0;
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var previous_input_class: u8 = 0;
    var index: usize = ascii_end;
    while (index < text.len) {
        if (text[index] < 0x80) {
            var end = index;
            while (end < text.len and text[end] < 0x80) end += 1;
            starter = text[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            index = end;
            continue;
        }
        const start = index;
        if (cjk_lead_simple and text[index] >= 0xe4 and
            text[index] <= 0xe9)
        {
            if (index + 3 > text.len) {
                if (validating) return error.InvalidUtf8;
                return text.len;
            }
            if (text[index + 1] & 0xc0 != 0x80 or
                text[index + 2] & 0xc0 != 0x80)
            {
                if (validating) return error.InvalidUtf8;
                return text.len;
            }
            starter = null;
            starter_offset = start;
            previous_input_class = 0;
            index += 3;
            continue;
        }
        const decoded = scalar.decodeValidating(text, index) orelse {
            if (validating) return error.InvalidUtf8;
            return text.len;
        };
        const codepoint = decoded.codepoint;
        index = decoded.next;
        if (codepoint >= 0x80 and inert.isInert(codepoint, form)) {
            starter = codepoint;
            starter_offset = start;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) return starter_offset;
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            previous_input_class > current_class) return starter_offset;
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

/// Return the byte offset of the next segment start at or after `index`.
/// A segment starts at a starter that cannot compose with or reorder
/// against the preceding character; normalizing `[index, result)` in
/// isolation is safe.
fn segmentEnd(text: []const u8, index: usize) usize {
    var cursor = index;
    var first = true;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidating(text, cursor) orelse return text.len;
        const codepoint = decoded.codepoint;
        const length = decoded.next - cursor;
        if (!first and combining_class.forCodepoint(codepoint) == 0 and
            !data.isCompositionSecond(codepoint) and
            !isHangulVOrT(codepoint))
        {
            return cursor;
        }
        first = false;
        cursor += length;
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
    if (codepoint < 0x80) {
        try output.append(allocator, codepoint);
        return;
    }
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

/// Canonical ordering with precomputed combining classes.
fn canonicalOrderWithClasses(codepoints: []u21, classes: []u8) void {
    std.debug.assert(codepoints.len == classes.len);
    var sequence_start: usize = 0;
    for (classes, 0..) |class, index| {
        if (class == 0) {
            sortMarksWithClasses(
                codepoints[sequence_start..index],
                classes[sequence_start..index],
            );
            sequence_start = index + 1;
        }
    }
    sortMarksWithClasses(
        codepoints[sequence_start..],
        classes[sequence_start..],
    );
}

fn sortMarksWithClasses(codepoints: []u21, classes: []u8) void {
    var index: usize = 1;
    while (index < codepoints.len) : (index += 1) {
        const codepoint = codepoints[index];
        const class = classes[index];
        var move = index;
        while (move > 0 and classes[move - 1] > class) : (move -= 1) {
            codepoints[move] = codepoints[move - 1];
            classes[move] = classes[move - 1];
        }
        codepoints[move] = codepoint;
        classes[move] = class;
    }
}

/// Composition using precomputed combining classes.
fn composeSliceWithClasses(items: []u21, classes: []const u8) usize {
    std.debug.assert(items.len == classes.len);
    if (items.len < 2) return items.len;
    var output_len: usize = 1;
    var starter_index: usize = 0;
    var starter = items[0];
    var previous_class: u8 = 0;
    for (items[1..], classes[1..]) |codepoint, class| {
        const composite = if ((data.isCompositionSecond(codepoint) or
            isHangulVOrT(codepoint)) and
            (previous_class == 0 or previous_class < class))
            composePair(starter, codepoint)
        else
            null;
        if (composite) |value| {
            items[starter_index] = value;
            starter = value;
            continue;
        }
        items[output_len] = codepoint;
        if (class == 0) {
            starter_index = output_len;
            starter = codepoint;
        }
        previous_class = class;
        output_len += 1;
    }
    return output_len;
}

/// Sort the marks of every starter segment into canonical order.
pub fn canonicalOrder(codepoints: []u21) void {
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
        // A starter only composes with a following non-starter mark or a
        // Hangul V/T jamo. Skipping the table lookup for ordinary starters
        // keeps ASCII prose on a linear scan.
        const composite = if ((data.isCompositionSecond(codepoint) or
            isHangulVOrT(codepoint)) and
            (previous_class == 0 or previous_class < current_class))
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
    // A direct composition always changes the pair; this avoids the general
    // decompose-order-compose path for the common composing-mark case.
    if ((form == .nfc or form == .nfkc) and
        composePair(starter, current) != null) return true;
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

fn isHangulVOrT(codepoint: u21) bool {
    return (codepoint >= 0x1161 and codepoint <= 0x1175) or
        (codepoint >= 0x11a8 and codepoint <= 0x11c2);
}

/// Direct composition results for Latin-1 starters, which dominate
/// precomposed Latin text. Every canonical pair with a starter below U+0100
/// uses a combining mark in U+0300..U+0342, so a small table replaces the
/// generated page-indexed binary search in the hottest composition path.
const latin_compose_first_mark: u21 = 0x300;
const latin_compose_mark_count: usize = 0x43;

const latin_compose: [0x100][latin_compose_mark_count]u16 = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [0x100][latin_compose_mark_count]u16 =
        [_][latin_compose_mark_count]u16{
            [_]u16{0} ** latin_compose_mark_count,
        } ** 0x100;
    for (0..0x100) |starter| {
        for (0..latin_compose_mark_count) |mark_index| {
            const combining = latin_compose_first_mark + mark_index;
            if (data.composePair(@intCast(starter), @intCast(combining))) |composed| {
                table[starter][mark_index] = @intCast(composed);
            }
        }
    }
    break :blk table;
};

pub fn composePair(starter: u21, combining: u21) ?u21 {
    if (starter < 0x100 and combining >= latin_compose_first_mark and
        combining < latin_compose_first_mark + latin_compose_mark_count)
    {
        const composed = latin_compose[starter][combining - latin_compose_first_mark];
        return if (composed == 0) null else composed;
    }
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

const HangulSyllable = struct {
    composed: u21,
    end: usize,
};

/// Compose the L jamo `l` with the scalars after `after_l`. Returns null
/// when the next scalar is not a V jamo.
fn hangulSyllableAt(text: []const u8, l: u21, after_l: usize) ?HangulSyllable {
    const v = scalar.decodeValidating(text, after_l) orelse return null;
    const lv = composeHangul(l, v.codepoint) orelse return null;
    const t = scalar.decodeValidating(text, v.next) orelse
        return .{ .composed = lv, .end = v.next };
    if (composeHangul(lv, t.codepoint)) |lvt| {
        return .{ .composed = lvt, .end = t.next };
    }
    return .{ .composed = lv, .end = v.next };
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

test "normalizer scalar helpers" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(?u21, 0x00e9), composePair('e', 0x0301));
    try testing.expectEqual(@as(?u21, 0xac00), composePair(0x1100, 0x1161));
    try testing.expectEqual(@as(?u21, null), composePair(0x0915, 0x093c));
    const mapping = decompositionFor(0x00e9).?;
    try testing.expectEqualSlices(u21, &.{ 'e', 0x0301 }, mapping);
    try testing.expectEqual(@as(?[]const u21, null), decompositionFor('a'));
    try testing.expectEqual(@as(u8, 230), combiningClass(0x0301));
    try testing.expectEqual(@as(u8, 0), combiningClass('a'));
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

test "Hangul jamo runs compose directly" {
    // LV and LVT, with trailing text and marks that must stay intact.
    try expectNormalized("\u{1100}\u{1161}", "\u{ac00}");
    try expectNormalized("\u{1100}\u{1161}\u{11a8}", "\u{ac01}");
    try expectNormalized(
        "\u{1100}\u{1161}\u{11a8} x",
        "\u{ac01} x",
    );
    try expectNormalized(
        "\u{1100}\u{1161}\u{0301}",
        "\u{ac00}\u{0301}",
    );
    try expectNormalized(
        "\u{1100}\u{1161}\u{11a8}\u{0301}",
        "\u{ac01}\u{0301}",
    );
    // A lone L jamo and an L followed by another V start fresh.
    try expectNormalized("\u{1100}", "\u{1100}");
    try expectNormalized("\u{1100}\u{1161}\u{1161}", "\u{ac00}\u{1161}");
    // NFD still decomposes syllables back to jamo.
    try expectFormNormalized(
        "\u{ac01}",
        "\u{1100}\u{1161}\u{11a8}",
        .nfd,
    );
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
    // U+0340 is Quick_Check=No with ccc 230, so the preceding starter must
    // stay inside the suffix that gets normalized.
    try std.testing.expectEqual(
        @as(usize, 2),
        try spanQuickCheckYes("abc\u{0340}", .nfc),
    );
    // Invalid bytes after an early stop still surface as InvalidUtf8.
    try std.testing.expectError(
        error.InvalidUtf8,
        spanQuickCheckYes("a\u{0301}\xff", .nfc),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        spanQuickCheckYes("\xff", .nfc),
    );
}

test "normalization copies stable prefixes" {
    const allocator = std.testing.allocator;
    const input = "abcde\u{0301}xyz";
    const expected = "abcd\xc3\xa9xyz";

    const result = (try normalizeAlloc(allocator, input)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try std.testing.expect(try normalizeFormInto(
        allocator,
        input,
        .nfc,
        &output,
    ));
    try std.testing.expectEqualStrings(expected, output.items);
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

test "span editing matches whole-string normalization" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const inputs = [_][]const u8{
        "a\u{0301}b\u{0323}c",
        "e\u{0301}\u{0323}",
        "A\u{030a}\u{0301}",
        "\u{1100}\u{1161}\u{11a8}",
        "\u{ac00}\u{11a8}",
        "\u{ac01}",
        "\u{0301}abc",
        "a\u{0340}b",
        "x\u{0dcf}y",
        "\u{0d15}\u{094d}\u{0937}\u{093f}",
        "aa\u{0301}\u{0323}\u{0302}bb",
        "\u{fb01}\u{212b}",
        "\u{1e9b}\u{0323}",
        "a\u{0301}bcdef\u{0323}g",
        "plain ASCII",
        "",
    };
    const forms = [_]Form{ .nfc, .nfd, .nfkc, .nfkd };
    for (forms) |form| {
        for (inputs) |input| {
            var reference = std.ArrayList(u8).empty;
            defer reference.deinit(allocator);
            try normalizeChangedFormInto(allocator, input, form, &reference);

            var edited = std.ArrayList(u8).empty;
            defer edited.deinit(allocator);
            try normalizeWithEditsInto(allocator, input, form, &edited);

            try testing.expectEqualStrings(reference.items, edited.items);
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

test "isNormalized validates the unscanned suffix" {
    const testing = @import("std").testing;
    try testing.expect(!(try isNormalized("a\u{0301}b")));
    try testing.expectError(
        error.InvalidUtf8,
        isNormalized("a\u{0301}\xff"),
    );
    try testing.expectError(error.InvalidUtf8, isNormalized("\xff"));
}
