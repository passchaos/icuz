const std = @import("std");
const scalar_value = @import("../scalar/root.zig");

const data = @embedFile("data.bin");
const test_data = @embedFile("conformance.bin");

pub const unicode_version = [3]u8{ 17, 0, 0 };

pub const Cluster = struct {
    byte_start: usize,
    byte_len: usize,
};

pub const Error = error{InvalidUtf8};

pub const BoundaryAdvance = struct {
    offset: usize,
    cluster_count: usize,
};

/// A validated, borrowed view for editor-style random-access boundary queries.
///
/// Offsets are UTF-8 byte offsets. Zero and `text.len` are always boundaries.
/// Directional queries are strict: `nextBoundary` returns the first boundary
/// after the requested offset, while `previousBoundary` returns the last one
/// before it. Out-of-range offsets are clamped to `text.len`.
pub const BoundaryView = struct {
    text: []const u8,
    tailoring: ScalarBreaker.Tailoring = .unicode_default,

    pub fn init(text: []const u8) Error!BoundaryView {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return BoundaryView.assumeValid(text);
    }

    pub fn initForTailoring(
        text: []const u8,
        tailoring: ScalarBreaker.Tailoring,
    ) Error!BoundaryView {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return BoundaryView.assumeValidForTailoring(text, tailoring);
    }

    pub fn assumeValid(text: []const u8) BoundaryView {
        scalar_value.assertValidUtf8(text);
        return .{ .text = text };
    }

    pub fn assumeValidForTailoring(
        text: []const u8,
        tailoring: ScalarBreaker.Tailoring,
    ) BoundaryView {
        scalar_value.assertValidUtf8(text);
        return .{ .text = text, .tailoring = tailoring };
    }

    pub fn isBoundary(self: BoundaryView, offset: usize) bool {
        if (offset > self.text.len) return false;
        if (offset == 0 or offset == self.text.len) return true;
        if ((self.text[offset] & 0xc0) == 0x80) return false;

        var iterator = graphemeIteratorWithTailoring(self.text, self.tailoring);
        while (iterator.next()) |cluster| {
            const end = cluster.byte_start + cluster.byte_len;
            if (end == offset) return true;
            if (end > offset) return false;
        }
        return false;
    }

    pub fn nextBoundary(self: BoundaryView, offset: usize) usize {
        const target = @min(offset, self.text.len);
        if (target == self.text.len) return self.text.len;

        var iterator = graphemeIteratorWithTailoring(self.text, self.tailoring);
        while (iterator.next()) |cluster| {
            const end = cluster.byte_start + cluster.byte_len;
            if (end > target) return end;
        }
        return self.text.len;
    }

    pub fn previousBoundary(self: BoundaryView, offset: usize) usize {
        const target = @min(offset, self.text.len);
        if (target == 0) return 0;

        var iterator = graphemeIteratorWithTailoring(self.text, self.tailoring);
        while (iterator.next()) |cluster| {
            const end = cluster.byte_start + cluster.byte_len;
            if (end >= target) return cluster.byte_start;
        }
        return 0;
    }

    /// Return the closest boundary, preferring the preceding boundary on ties.
    pub fn nearestBoundary(self: BoundaryView, offset: usize) usize {
        const target = @min(offset, self.text.len);
        if (target == 0 or target == self.text.len) return target;

        var iterator = graphemeIteratorWithTailoring(self.text, self.tailoring);
        while (iterator.next()) |cluster| {
            const start = cluster.byte_start;
            const end = start + cluster.byte_len;
            if (target == start or target == end) return target;
            if (target < end) {
                return if (end - target < target - start) end else start;
            }
        }
        return self.text.len;
    }

    /// Move forward by at most `count` grapheme clusters.
    ///
    /// A zero count preserves the clamped input offset. For a non-boundary
    /// input, the first step moves to the end of the containing cluster.
    pub fn advanceBoundary(
        self: BoundaryView,
        offset: usize,
        count: usize,
    ) usize {
        const target = @min(offset, self.text.len);
        if (count == 0 or target == self.text.len) return target;

        var remaining = count;
        var iterator = graphemeIteratorWithTailoring(self.text, self.tailoring);
        while (iterator.next()) |cluster| {
            const end = cluster.byte_start + cluster.byte_len;
            if (end <= target) continue;
            remaining -= 1;
            if (remaining == 0) return end;
        }
        return self.text.len;
    }

    /// Move forward from an offset the caller already knows is a grapheme
    /// boundary. Unlike `advanceBoundary`, this does not rescan the prefix
    /// before `offset`, so repeated forward traversal remains linear.
    ///
    /// The caller must supply a UTF-8 and grapheme boundary. The returned count
    /// can be smaller than requested when the end of the view is reached.
    pub fn advanceFromBoundary(
        self: BoundaryView,
        offset: usize,
        count: usize,
    ) BoundaryAdvance {
        const start = @min(offset, self.text.len);
        std.debug.assert(start == self.text.len or (self.text[start] & 0xc0) != 0x80);
        if (count == 0 or start == self.text.len) return .{
            .offset = start,
            .cluster_count = 0,
        };

        var iterator = graphemeIterator(self.text[start..]);
        var boundary = start;
        var advanced: usize = 0;
        while (advanced < count) {
            const cluster = iterator.next() orelse break;
            boundary = start + cluster.byte_start + cluster.byte_len;
            advanced += 1;
        }
        return .{ .offset = boundary, .cluster_count = advanced };
    }

    /// Count grapheme clusters intersecting the clamped half-open range.
    ///
    /// Editor callers normally supply boundaries. If either endpoint is
    /// interior to a cluster, that intersecting cluster is counted once.
    pub fn countClusters(
        self: BoundaryView,
        start: usize,
        end: usize,
    ) usize {
        const limit = @min(end, self.text.len);
        const target = @min(start, limit);
        if (target == limit) return 0;

        var count: usize = 0;
        var iterator = graphemeIteratorWithTailoring(self.text, self.tailoring);
        while (iterator.next()) |cluster| {
            const cluster_end = cluster.byte_start + cluster.byte_len;
            if (cluster_end <= target) continue;
            count += 1;
            if (cluster_end >= limit) break;
        }
        return count;
    }
};

const Class = enum(u4) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
};

const InCb = enum(u2) {
    none,
    consonant,
    extend,
    linker,
};

const Properties = packed struct(u8) {
    class: Class,
    incb: InCb,
    extended_pictographic: bool,
    emoji_presentation: bool,
};

/// Allocation-free Unicode 17 extended-grapheme state for scalar streams.
///
/// `push` returns whether a grapheme boundary occurs immediately before the
/// supplied scalar. The first scalar after initialization or `reset` always
/// starts a grapheme. Callers must supply Unicode scalar values in logical
/// order; no UTF-8 buffering or allocation is performed. `init` selects the
/// Unicode default rules. Pre-Unicode-17 virama compatibility is available
/// only through the explicitly named tailoring.
pub const ScalarBreaker = struct {
    pub const Tailoring = enum {
        unicode_default,
        legacy_virama_linker,
    };

    tailoring: Tailoring = .unicode_default,
    initialized: bool = false,
    previous: Properties = empty_properties,
    regional_indicator_odd: bool = false,
    saw_extended_pictographic: bool = false,
    zwj_after_extended_pictographic: bool = false,
    incb_consonant: bool = false,
    incb_linker: bool = false,

    const empty_properties: Properties = .{
        .class = .other,
        .incb = .none,
        .extended_pictographic = false,
        .emoji_presentation = false,
    };

    pub fn init() ScalarBreaker {
        return .{};
    }

    /// Initialize with an explicit segmentation policy.
    ///
    /// `.legacy_virama_linker` additionally treats five historical viramas as
    /// InCB=Linker. It is a compatibility tailoring, not Unicode default
    /// extended-grapheme segmentation.
    pub fn initWithTailoring(tailoring: Tailoring) ScalarBreaker {
        return .{ .tailoring = tailoring };
    }

    pub fn reset(self: *ScalarBreaker) void {
        self.* = initWithTailoring(self.tailoring);
    }

    pub inline fn push(self: *ScalarBreaker, codepoint: u21) bool {
        return switch (self.tailoring) {
            .unicode_default => self.pushWithTailoring(codepoint, .unicode_default),
            .legacy_virama_linker => self.pushWithTailoring(codepoint, .legacy_virama_linker),
        };
    }

    inline fn pushWithTailoring(
        self: *ScalarBreaker,
        codepoint: u21,
        comptime tailoring: Tailoring,
    ) bool {
        std.debug.assert(scalar_value.isValid(codepoint));
        if (!self.initialized) {
            self.startCodepoint(codepoint, tailoring);
            return true;
        }
        return self.pushAfterFirst(codepoint, tailoring);
    }

    inline fn startCodepoint(
        self: *ScalarBreaker,
        codepoint: u21,
        comptime tailoring: Tailoring,
    ) void {
        const current = properties(codepoint);
        self.start(current, effectiveInCb(codepoint, current, tailoring));
    }

    inline fn pushAfterFirst(
        self: *ScalarBreaker,
        codepoint: u21,
        comptime tailoring: Tailoring,
    ) bool {
        const current = properties(codepoint);
        const current_incb = effectiveInCb(codepoint, current, tailoring);

        const boundary = breaksBetween(
            self.previous,
            current,
            current_incb,
            if (self.regional_indicator_odd) 1 else 0,
            self.zwj_after_extended_pictographic,
            self.incb_consonant,
            self.incb_linker,
        );
        if (boundary) {
            self.start(current, current_incb);
            return true;
        }
        self.continueWith(current, current_incb);
        return false;
    }

    inline fn start(self: *ScalarBreaker, current: Properties, current_incb: InCb) void {
        self.initialized = true;
        self.previous = current;
        self.regional_indicator_odd = current.class == .regional_indicator;
        self.saw_extended_pictographic = current.extended_pictographic;
        self.zwj_after_extended_pictographic = false;
        self.incb_consonant = current_incb == .consonant;
        self.incb_linker = false;
    }

    inline fn continueWith(self: *ScalarBreaker, current: Properties, current_incb: InCb) void {
        const completes_incb_chain = self.incb_consonant and
            self.incb_linker and current_incb == .consonant;
        const continuing_incb_chain = self.incb_consonant and
            (current_incb == .extend or current_incb == .linker or
                current_incb == .consonant);

        if (current.class == .zwj) {
            self.zwj_after_extended_pictographic = self.saw_extended_pictographic;
            // GB11 requires exactly `Extended_Pictographic Extend* ZWJ` on
            // the left. A second ZWJ must not inherit the earlier EP context.
            self.saw_extended_pictographic = false;
        } else if (current.class != .extend) {
            self.zwj_after_extended_pictographic = false;
            self.saw_extended_pictographic = current.extended_pictographic;
        } else if (current.extended_pictographic) {
            self.saw_extended_pictographic = true;
        }

        if (completes_incb_chain) {
            self.incb_consonant = true;
            self.incb_linker = false;
        } else if (continuing_incb_chain) {
            if (current_incb == .linker) self.incb_linker = true;
        } else {
            self.incb_consonant = current_incb == .consonant;
            self.incb_linker = false;
        }

        if (current.class == .regional_indicator) {
            self.regional_indicator_odd = !self.regional_indicator_odd;
        } else {
            self.regional_indicator_odd = false;
        }
        self.previous = current;
    }
};

const Header = struct {
    index_count: usize,
    page_count: usize,
    index_offset: usize,
    pages_offset: usize,
};

const header = parseHeader();

pub const Iterator = struct {
    text: []const u8,
    cursor: usize = 0,
    pending: ?Decoded = null,
    tailoring: ScalarBreaker.Tailoring = .unicode_default,

    pub fn next(self: *Iterator) ?Cluster {
        if (self.cursor >= self.text.len) return null;
        const start = self.cursor;
        const first = self.pending orelse decode(self.text, self.cursor) orelse unreachable;
        self.pending = null;
        self.cursor = first.next;

        // GB3 is the sole multi-byte ASCII cluster.
        if (first.codepoint < 0x80 and self.cursor < self.text.len and
            self.text[self.cursor] < 0x80 and
            !(first.codepoint == '\r' and self.text[self.cursor] == '\n'))
        {
            return .{ .byte_start = start, .byte_len = self.cursor - start };
        }

        var previous = properties(first.codepoint);
        var regional_indicator_count: usize =
            if (previous.class == .regional_indicator) 1 else 0;
        var saw_extended_pictographic = previous.extended_pictographic;
        var zwj_after_extended_pictographic = false;
        var incb_consonant = previous.incb == .consonant;
        var incb_linker = false;

        while (self.cursor < self.text.len) {
            const current = decode(self.text, self.cursor) orelse unreachable;
            const current_properties = properties(current.codepoint);
            const current_incb = if (current_properties.incb == .linker or
                (self.tailoring == .legacy_virama_linker and
                    legacyInCbLinker(current.codepoint)))
                InCb.linker
            else
                current_properties.incb;
            if (breaksBetween(
                previous,
                current_properties,
                current_incb,
                regional_indicator_count,
                zwj_after_extended_pictographic,
                incb_consonant,
                incb_linker,
            )) {
                self.pending = current;
                break;
            }
            self.cursor = current.next;

            const current_completes_incb_chain = incb_consonant and
                incb_linker and current_incb == .consonant;
            const continuing_incb_chain = incb_consonant and
                (current_incb == .extend or current_incb == .linker or
                    current_incb == .consonant);
            if (current_properties.class == .zwj) {
                zwj_after_extended_pictographic = saw_extended_pictographic;
                // A second ZWJ must not inherit the earlier EP context.
                saw_extended_pictographic = false;
            } else if (current_properties.class != .extend) {
                zwj_after_extended_pictographic = false;
                saw_extended_pictographic = current_properties.extended_pictographic;
            } else if (current_properties.extended_pictographic) {
                saw_extended_pictographic = true;
            }

            if (current_completes_incb_chain) {
                // GB9c consumed the following consonant. A later linker starts
                // a new chain only if this consonant itself is a valid anchor.
                incb_consonant = true;
                incb_linker = false;
            } else if (continuing_incb_chain) {
                if (current_incb == .linker) incb_linker = true;
            } else {
                incb_consonant = current_incb == .consonant;
                incb_linker = false;
            }

            if (current_properties.class == .regional_indicator) {
                regional_indicator_count += 1;
            } else {
                regional_indicator_count = 0;
            }
            previous = current_properties;
        }
        return .{ .byte_start = start, .byte_len = self.cursor - start };
    }
};

pub fn clusters(text: []const u8) Error!Iterator {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return assumeValid(text);
}

/// Validate UTF-8 and return an iterator with an explicit segmentation policy.
pub fn clustersWithTailoring(
    text: []const u8,
    tailoring: ScalarBreaker.Tailoring,
) Error!Iterator {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return assumeValidWithTailoring(text, tailoring);
}

pub fn assumeValid(text: []const u8) Iterator {
    scalar_value.assertValidUtf8(text);
    return graphemeIterator(text);
}

pub fn assumeValidWithTailoring(
    text: []const u8,
    tailoring: ScalarBreaker.Tailoring,
) Iterator {
    scalar_value.assertValidUtf8(text);
    return .{ .text = text, .tailoring = tailoring };
}

fn graphemeIterator(text: []const u8) Iterator {
    return .{ .text = text };
}

fn graphemeIteratorWithTailoring(
    text: []const u8,
    tailoring: ScalarBreaker.Tailoring,
) Iterator {
    return .{ .text = text, .tailoring = tailoring };
}

fn breaksBetween(
    previous: Properties,
    current: Properties,
    current_incb: InCb,
    regional_indicator_count: usize,
    zwj_after_extended_pictographic: bool,
    incb_consonant: bool,
    incb_linker: bool,
) bool {
    // GB3.
    if (previous.class == .cr and current.class == .lf) return false;
    // GB4 / GB5.
    if (isControl(previous.class) or isControl(current.class)) return true;
    // GB6..GB8.
    if (previous.class == .l and
        (current.class == .l or current.class == .v or current.class == .lv or
            current.class == .lvt)) return false;
    if ((previous.class == .lv or previous.class == .v) and
        (current.class == .v or current.class == .t)) return false;
    if ((previous.class == .lvt or previous.class == .t) and
        current.class == .t) return false;
    // GB9, GB9a, GB9b.
    if (current.class == .extend or current.class == .zwj) return false;
    if (current.class == .spacing_mark) return false;
    if (previous.class == .prepend) return false;
    // GB9c.
    if (incb_consonant and incb_linker and current_incb == .consonant) return false;
    // GB11.
    if (previous.class == .zwj and zwj_after_extended_pictographic and
        current.extended_pictographic) return false;
    // GB12 / GB13.
    if (previous.class == .regional_indicator and
        current.class == .regional_indicator and
        regional_indicator_count % 2 == 1) return false;
    return true;
}

fn isControl(class: Class) bool {
    return class == .control or class == .cr or class == .lf;
}

fn legacyInCbLinker(codepoint: u21) bool {
    // Unicode 17's InCB table intentionally narrows Linker to scripts covered
    // by the default GB9c derivation. Cangjie's existing script/fallback
    // contract also treats these canonical viramas as conjunct linkers. Keeping
    // them here preserves established caret atoms while still sourcing every
    // scalar property from generated data.
    return switch (codepoint) {
        0x0a4d, 0x0ccd, 0x11046, 0x110b9, 0x11442 => true,
        else => false,
    };
}

inline fn effectiveInCb(
    codepoint: u21,
    value: Properties,
    tailoring: ScalarBreaker.Tailoring,
) InCb {
    return if (value.incb == .linker or
        (tailoring == .legacy_virama_linker and legacyInCbLinker(codepoint)))
        .linker
    else
        value.incb;
}

fn properties(codepoint: u21) Properties {
    if (!scalar_value.isValid(codepoint)) return .{
        .class = .other,
        .incb = .none,
        .extended_pictographic = false,
        .emoji_presentation = false,
    };
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(header.index_offset + page * 2);
    const value = data[
        header.pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ];
    return @bitCast(value);
}

pub inline fn isExtendedPictographic(codepoint: u21) bool {
    return properties(codepoint).extended_pictographic;
}

pub inline fn isEmojiPresentation(codepoint: u21) bool {
    return properties(codepoint).emoji_presentation;
}

test "Unicode emoji presentation stays distinct from extended pictographic" {
    try std.testing.expect(isExtendedPictographic(0x00a9));
    try std.testing.expect(!isEmojiPresentation(0x00a9));
    try std.testing.expect(isExtendedPictographic(0x1f600));
    try std.testing.expect(isEmojiPresentation(0x1f600));
    try std.testing.expect(!isExtendedPictographic('A'));
    try std.testing.expect(!isEmojiPresentation('A'));
}

const Decoded = scalar_value.Decoded;

fn decode(text: []const u8, offset: usize) ?Decoded {
    return scalar_value.decodeValid(text, offset);
}

fn parseHeader() Header {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "CJGB") or
        data[4] != 2 or data[5] != unicode_version[0] or
        data[6] != unicode_version[1] or data[7] != unicode_version[2])
    {
        @compileError("invalid grapheme data");
    }
    const index_count = readU16(8);
    const page_count = readU16(10);
    const index_offset = 12;
    const pages_offset = index_offset + index_count * 2;
    if (index_count != 0x1100 or
        pages_offset + page_count * 256 != data.len)
    {
        @compileError("invalid grapheme data lengths");
    }
    return .{
        .index_count = index_count,
        .page_count = page_count,
        .index_offset = index_offset,
        .pages_offset = pages_offset,
    };
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

test "Unicode 17 grapheme conformance" {
    if (test_data.len < 12 or !std.mem.eql(u8, test_data[0..4], "CJGT") or
        test_data[4] != 1 or test_data[5] != unicode_version[0] or
        test_data[6] != unicode_version[1] or test_data[7] != unicode_version[2])
    {
        return error.InvalidFixture;
    }
    const case_count = std.mem.readInt(u32, test_data[8..12], .little);
    try std.testing.expectEqual(@as(u32, 766), case_count);
    var offset: usize = 12;
    for (0..case_count) |case_index| {
        const count = test_data[offset];
        offset += 1;
        const expected = test_data[offset..][0 .. @as(usize, count) + 1];
        offset += @as(usize, count) + 1;
        const codepoint_bytes = test_data[offset..][0 .. @as(usize, count) * 4];
        offset += @as(usize, count) * 4;

        var utf8: [1024]u8 = undefined;
        var utf8_len: usize = 0;
        var expected_offsets: [256]usize = undefined;
        var expected_count: usize = 0;
        var scalar_breaker = ScalarBreaker.init();
        if (expected[0] != 0) {
            expected_offsets[expected_count] = 0;
            expected_count += 1;
        }
        for (0..count) |index| {
            const cp: u21 = @intCast(std.mem.readInt(
                u32,
                codepoint_bytes[index * 4 ..][0..4],
                .little,
            ));
            try std.testing.expectEqual(expected[index] != 0, scalar_breaker.push(cp));
            utf8_len += try std.unicode.utf8Encode(cp, utf8[utf8_len..]);
            if (expected[index + 1] != 0) {
                expected_offsets[expected_count] = utf8_len;
                expected_count += 1;
            }
        }

        var iterator = assumeValid(utf8[0..utf8_len]);
        var actual_count: usize = 1;
        var actual_end: usize = 0;
        while (iterator.next()) |cluster| {
            actual_end = cluster.byte_start + cluster.byte_len;
            if (expected_offsets[actual_count] != actual_end) {
                std.debug.print(
                    "grapheme case={d} boundary={d} expected={d} actual={d}\n",
                    .{
                        case_index,
                        actual_count,
                        expected_offsets[actual_count],
                        actual_end,
                    },
                );
                return error.GraphemeConformanceMismatch;
            }
            actual_count += 1;
        }
        try std.testing.expectEqual(expected_count, actual_count);

        const view = BoundaryView.assumeValid(utf8[0..utf8_len]);
        for (expected_offsets[0..expected_count], 0..) |boundary, boundary_index| {
            const remaining_clusters = expected_count - boundary_index - 1;
            const requested = @min(@as(usize, 3), remaining_clusters);
            const expected_boundary = expected_offsets[boundary_index + requested];
            try std.testing.expectEqual(
                BoundaryAdvance{
                    .offset = expected_boundary,
                    .cluster_count = requested,
                },
                view.advanceFromBoundary(boundary, requested),
            );
            try std.testing.expectEqual(
                view.advanceBoundary(boundary, requested),
                expected_boundary,
            );
        }
    }
    try std.testing.expectEqual(test_data.len, offset);
}

test "scalar grapheme breaker is incremental and resettable" {
    var breaker = ScalarBreaker.init();
    try std.testing.expect(breaker.push('a'));
    try std.testing.expect(!breaker.push(0x0301));
    try std.testing.expect(breaker.push('b'));

    breaker.reset();
    try std.testing.expect(breaker.push(0x1f1fa));
    try std.testing.expect(!breaker.push(0x1f1f8));
    try std.testing.expect(breaker.push(0x1f1e8));
}

test "GB11 context does not cross a second ZWJ" {
    const input = [_]u21{ 0x1f600, 0x200d, 0x200d, 0x1f600 };
    const expected = [_]bool{ true, false, false, true };

    var breaker = ScalarBreaker.init();
    for (input, expected) |codepoint, boundary| {
        try std.testing.expectEqual(boundary, breaker.push(codepoint));
    }

    const text = "😀‍‍😀";
    var iterator = assumeValid(text);
    const first = iterator.next().?;
    try std.testing.expectEqual(@as(usize, 0), first.byte_start);
    try std.testing.expectEqual(text.len - 4, first.byte_len);
    const second = iterator.next().?;
    try std.testing.expectEqual(text.len - 4, second.byte_start);
    try std.testing.expectEqual(@as(usize, 4), second.byte_len);
    try std.testing.expect(iterator.next() == null);
}

test "legacy virama handling is an explicit tailoring" {
    // The compatibility rule intentionally covers historical cross-script
    // caret atoms: Unicode-default InCB consonants around a legacy linker.
    const strict_expected = [_]bool{ true, false, true };
    const tailored_expected = [_]bool{ true, false, false };
    const legacy_linkers = [_]u21{ 0x0a4d, 0x0ccd, 0x11046, 0x110b9, 0x11442 };
    for (legacy_linkers) |linker| {
        const input = [_]u21{ 0x0915, linker, 0x0915 };
        var strict = ScalarBreaker.init();
        var tailored = ScalarBreaker.initWithTailoring(.legacy_virama_linker);
        for (input, strict_expected, tailored_expected) |codepoint, strict_boundary, tailored_boundary| {
            try std.testing.expectEqual(strict_boundary, strict.push(codepoint));
            try std.testing.expectEqual(tailored_boundary, tailored.push(codepoint));
        }

        tailored.reset();
        for (input, tailored_expected) |codepoint, boundary| {
            try std.testing.expectEqual(boundary, tailored.push(codepoint));
        }
    }

    // The long-standing UTF-8 iterator retains the compatibility tailoring
    // only when the caller explicitly selects it.
    const text = "क੍क";
    var default_iterator = assumeValid(text);
    var default_count: usize = 0;
    while (default_iterator.next()) |_| default_count += 1;
    try std.testing.expectEqual(@as(usize, 2), default_count);

    var iterator = assumeValidWithTailoring(text, .legacy_virama_linker);
    try std.testing.expectEqual(text.len, iterator.next().?.byte_len);
    try std.testing.expect(iterator.next() == null);
}

test "standard InCB linker is independent of tailoring" {
    const input = [_]u21{ 0x0915, 0x094d, 0x0915 };
    const expected = [_]bool{ true, false, false };

    var strict = ScalarBreaker.init();
    var tailored = ScalarBreaker.initWithTailoring(.legacy_virama_linker);
    for (input, expected) |codepoint, boundary| {
        try std.testing.expectEqual(boundary, strict.push(codepoint));
        try std.testing.expectEqual(boundary, tailored.push(codepoint));
    }
}

test "known-boundary forward traversal does not require a prefix scan" {
    const text = "a👩‍💻🇺🇸कुb";
    const view = BoundaryView.assumeValid(text);
    var iterator = assumeValid(text);
    var boundary: usize = 0;
    while (iterator.next()) |cluster| {
        const expected = cluster.byte_start + cluster.byte_len;
        const one = view.advanceFromBoundary(boundary, 1);
        try std.testing.expectEqual(expected, one.offset);
        try std.testing.expectEqual(@as(usize, 1), one.cluster_count);
        boundary = expected;
    }

    const all = view.advanceFromBoundary(0, 100);
    try std.testing.expectEqual(text.len, all.offset);
    try std.testing.expectEqual(@as(usize, 5), all.cluster_count);
    try std.testing.expectEqual(BoundaryAdvance{ .offset = text.len, .cluster_count = 0 }, view.advanceFromBoundary(text.len, 3));
}
