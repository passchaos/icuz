//! Streaming state and Unicode 17 UAX #14 boundary rules.
//!
//! The public iterator owns byte traversal and opportunities. This module owns
//! only semantic state and LB1–LB31 evaluation, keeping generated data layout
//! and ASCII scanning policy out of the specification-ordered rule engine.

const std = @import("std");

const property_data = @import("properties.zig");

pub const BreakClass = property_data.BreakClass;
pub const Properties = property_data.Properties;

pub const BreakKind = enum {
    soft,
    hard,
};

pub const Significant = struct {
    codepoint: u21,
    properties: Properties,
    class: BreakClass,
    start: usize,
    next: usize,
};

const Lookahead = struct {
    first: ?Significant = null,
    second: ?Significant = null,
};

pub const HistoryEntry = struct {
    codepoint: u21 = 0,
    properties: Properties = @bitCast(@as(u16, 0)),
    class: BreakClass = .unknown,
};

pub const StreamState = struct {
    previous_raw: BreakClass = .unknown,
    lb9_base: ?BreakClass = null,
    count: usize = 0,
    last: HistoryEntry = .{},
    previous: HistoryEntry = .{},
    previous_previous: HistoryEntry = .{},
    before_spaces: HistoryEntry = .{},
    before_spaces_previous: HistoryEntry = .{},
    numeric_chain: bool = false,
    numeric_close_suffix: bool = false,
    regional_indicator_count: usize = 0,

    fn beforeSpaceRun(self: *const StreamState) HistoryEntry {
        return if (self.count != 0 and self.last.class == .space)
            self.before_spaces
        else
            self.last;
    }

    /// True when the class before the current space run forces the general
    /// rules to inspect the next boundary; otherwise a `space → JL` pair is
    /// LB31 soft and the iterator can decide it directly.
    pub fn spaceRunNeedsRules(self: *const StreamState) bool {
        const before = self.beforeSpaceRun();
        return switch (before.class) {
            .open_punctuation,
            .quotation,
            .close_punctuation,
            .close_parenthesis,
            .before_and_after,
            => true,
            else => false,
        };
    }

    fn beforeBeforeSpaceRun(self: *const StreamState) HistoryEntry {
        return if (self.count != 0 and self.last.class == .space)
            self.before_spaces_previous
        else
            self.previous;
    }

    pub fn consume(
        self: *StreamState,
        raw: BreakClass,
        significant: ?Significant,
    ) void {
        self.previous_raw = raw;
        const current = significant orelse return;
        self.lb9_base = current.class;

        if (current.class == .space and
            (self.count == 0 or self.last.class != .space))
        {
            self.before_spaces = self.last;
            self.before_spaces_previous = self.previous;
        }

        const numeric_before = self.numeric_chain;
        self.numeric_close_suffix =
            (current.class == .close_punctuation or
                current.class == .close_parenthesis) and
            numeric_before;
        self.numeric_chain = if (current.class == .numeric)
            true
        else if ((current.class == .symbol or
            current.class == .infix_separator) and numeric_before)
            true
        else
            false;

        self.regional_indicator_count =
            if (current.class == .regional_indicator)
                self.regional_indicator_count + 1
            else
                0;

        self.previous_previous = self.previous;
        self.previous = self.last;
        self.last = .{
            .codepoint = current.codepoint,
            .properties = current.properties,
            .class = current.class,
        };
        self.count += 1;
    }

    pub fn consumeAsciiSpaceRun(self: *StreamState, count: usize) void {
        std.debug.assert(count != 0);
        const old_last = self.last;
        const old_previous = self.previous;
        const space = HistoryEntry{
            .codepoint = ' ',
            .properties = property_data.lookup(' '),
            .class = .space,
        };
        if (self.count == 0 or self.last.class != .space) {
            self.before_spaces = old_last;
            self.before_spaces_previous = old_previous;
        }
        if (count == 1) {
            self.previous_previous = old_previous;
            self.previous = old_last;
        } else if (count == 2) {
            self.previous_previous = old_last;
            self.previous = space;
        } else {
            self.previous_previous = space;
            self.previous = space;
        }
        self.last = space;
        self.previous_raw = .space;
        self.lb9_base = .space;
        self.numeric_chain = false;
        self.numeric_close_suffix = false;
        self.regional_indicator_count = 0;
        self.count += count;
    }

    /// Updates bounded rule history for an ASCII word consumed together with
    /// its following spaces by the prose scanner.
    pub fn consumeAsciiWordRun(self: *StreamState, bytes: []const u8) void {
        std.debug.assert(bytes.len != 0);
        std.debug.assert(self.count == 0 or
            isWordClass(self.last.class) or self.last.class == .space);
        for (bytes) |byte| std.debug.assert(asciiWordClass(byte) != null);

        const old_last = self.last;
        const old_previous = self.previous;
        const final = asciiHistoryEntry(bytes[bytes.len - 1]);
        if (bytes.len == 1) {
            self.previous_previous = old_previous;
            self.previous = old_last;
        } else if (bytes.len == 2) {
            self.previous_previous = old_last;
            self.previous = asciiHistoryEntry(bytes[0]);
        } else {
            self.previous_previous = asciiHistoryEntry(bytes[bytes.len - 3]);
            self.previous = asciiHistoryEntry(bytes[bytes.len - 2]);
        }
        self.last = final;
        self.previous_raw = final.class;
        self.lb9_base = final.class;
        self.numeric_chain = final.class == .numeric;
        self.numeric_close_suffix = false;
        self.regional_indicator_count = 0;
        self.count += bytes.len;
    }

    /// Commits a previously validated AL/HL/NU run in constant work.
    ///
    /// `tail_ring` retains the final one to three significant scalars.
    /// LB9-ignored scalars are reflected only in `final_raw`; every future UAX
    /// #14 rule observes at most three significant history entries, the final
    /// numeric state, and the total RI parity. Updating those fields once avoids
    /// repeating the full state transition for every mark in a complex-script
    /// word.
    pub inline fn consumeWordRun(
        self: *StreamState,
        final_raw: BreakClass,
        significant_count: usize,
        tail_ring: *const [3]HistoryEntry,
    ) void {
        self.previous_raw = final_raw;
        if (significant_count == 0) return;

        const old_last = self.last;
        const old_previous = self.previous;
        switch (@min(significant_count, tail_ring.len)) {
            1 => {
                self.previous_previous = old_previous;
                self.previous = old_last;
                self.last = tail_ring[0];
            },
            2 => {
                self.previous_previous = old_last;
                self.previous = tail_ring[0];
                self.last = tail_ring[1];
            },
            3 => {
                // The ring's next insertion slot contains the oldest retained
                // entry once at least three significant scalars were seen.
                const oldest = significant_count % tail_ring.len;
                self.previous_previous = tail_ring[oldest];
                self.previous = tail_ring[(oldest + 1) % tail_ring.len];
                self.last = tail_ring[(oldest + 2) % tail_ring.len];
            },
            else => unreachable,
        }
        self.lb9_base = self.last.class;
        self.numeric_chain = self.last.class == .numeric;
        self.numeric_close_suffix = false;
        self.regional_indicator_count = 0;
        self.count += significant_count;
    }
};

pub const Decoded = struct {
    codepoint: u21,
    start: usize,
    next: usize,
};

pub inline fn decodeValid(text: []const u8, start: usize) Decoded {
    const first = text[start];
    if (first < 0x80) {
        return .{ .codepoint = first, .start = start, .next = start + 1 };
    }
    const second = text[start + 1];
    if (first < 0xe0) {
        return .{
            .codepoint = (@as(u21, first & 0x1f) << 6) |
                @as(u21, second & 0x3f),
            .start = start,
            .next = start + 2,
        };
    }
    const third = text[start + 2];
    if (first < 0xf0) {
        return .{
            .codepoint = (@as(u21, first & 0x0f) << 12) |
                (@as(u21, second & 0x3f) << 6) |
                @as(u21, third & 0x3f),
            .start = start,
            .next = start + 3,
        };
    }
    const fourth = text[start + 3];
    return .{
        .codepoint = (@as(u21, first & 0x07) << 18) |
            (@as(u21, second & 0x3f) << 12) |
            (@as(u21, third & 0x3f) << 6) |
            @as(u21, fourth & 0x3f),
        .start = start,
        .next = start + 4,
    };
}

pub inline fn effectiveSignificant(
    codepoint: u21,
    start: usize,
    next: usize,
    raw: Properties,
    lb9_base: ?BreakClass,
) ?Significant {
    var class = property_data.resolveClass(raw);
    if (class == .combining_mark or raw.class == .zero_width_joiner) {
        if (lb9_base) |base| {
            if (base != .mandatory and base != .carriage_return and
                base != .line_feed and base != .next_line and
                base != .space and base != .zero_width_space)
            {
                return null;
            }
        }
        class = .alphabetic; // LB10.
    }
    return .{
        .codepoint = codepoint,
        .properties = raw,
        .class = class,
        .start = start,
        .next = next,
    };
}

/// Evaluates one boundary in specification order.
///
/// Lookahead is decoded lazily and cached per boundary because only quotation,
/// numeric-expression, and Brahmic rules need it. Ordinary prose therefore
/// remains a strictly forward, bounded-state stream.
pub fn decide(
    text: []const u8,
    state: *const StreamState,
    current_start: usize,
    current_next: usize,
    raw_properties: Properties,
    effective: ?*const Significant,
) ?BreakKind {
    if (current_start == 0) return null; // LB2.
    if (asciiCommonDecision(state, raw_properties.class)) |fast| {
        return fast.kind;
    }

    // LB4–LB8a use original classes and precede LB9 replacement.
    if (state.previous_raw == .carriage_return and
        raw_properties.class == .line_feed) return null;
    if (state.previous_raw == .mandatory or
        state.previous_raw == .carriage_return or
        state.previous_raw == .line_feed or
        state.previous_raw == .next_line) return .hard;
    if (raw_properties.class == .mandatory or
        raw_properties.class == .carriage_return or
        raw_properties.class == .line_feed or
        raw_properties.class == .next_line or
        raw_properties.class == .space or
        raw_properties.class == .zero_width_space) return null;
    if (state.previous_raw == .zero_width_joiner) return null;
    if (effective == null) return null; // LB9.

    const right = effective.?.*;
    // Hangul-to-Hangul pairs are fully decided by LB26/LB27: either an
    // internal syllable pair or LB31. Every rule between LB4 and LB25 needs
    // a non-Hangul class on one side.
    if (isHangulBlock(state.last.class) and isHangulBlock(right.class)) {
        return if (hangulNoBreak(state.last.class, right.class)) null else .soft;
    }
    var lookahead_cache: ?Lookahead = null;
    const left = state.last;
    const previous = state.previous;
    const before_spaces = state.beforeSpaceRun();
    const before_before_spaces = state.beforeBeforeSpaceRun();
    const right_class = right.class;

    // Pair decisions that no rule above or below can override. Both sides
    // are non-space, non-punctuation classes here, so the space-run and
    // lookahead state does not participate.
    if (right_class == .ideographic or right_class == .emoji_base) {
        // LB31 for CJK and emoji prose: these left classes have no
        // prohibition before an ideograph or emoji base (LB23a only blocks
        // prefix, and LB11/LB12/LB14/LB19 need a joiner, glue, open
        // punctuation, or quotation on the left).
        switch (left.class) {
            .close_punctuation,
            .close_parenthesis,
            .exclamation,
            .symbol,
            .infix_separator,
            .alphabetic,
            .hebrew_letter,
            .numeric,
            .postfix,
            .ideographic,
            .emoji_base,
            .emoji_modifier,
            => return .soft,
            else => {},
        }
    }
    if (left.class == .emoji_base and right_class == .emoji_modifier) {
        return null; // LB30b.
    }
    if (isAlphabetic(left.class) and isAlphabetic(right_class)) {
        return null; // LB28.
    }
    // LB15d: an infix separator never starts a line. The only exceptions are
    // the numeric lookahead form handled at LB15c, which needs a space on
    // the left, and LB8, which allows a break after a zero-width space.
    if (right_class == .infix_separator and left.class != .space and
        left.class != .zero_width_space) return null;
    // LB18: a space run ends the line unless an earlier rule prohibits the
    // break. Exclude the right classes those rules cover and the quotation /
    // opening / closing contexts carried by the space run.
    if (left.class == .space) {
        switch (right_class) {
            .word_joiner,
            .non_breaking_glue,
            .close_punctuation,
            .close_parenthesis,
            .exclamation,
            .symbol,
            .nonstarter,
            .before_and_after,
            .quotation,
            .hyphen,
            .unambiguous_hyphen,
            .after,
            .infix_separator,
            .inseparable,
            .numeric,
            .postfix,
            .prefix,
            => {},
            else => switch (before_spaces.class) {
                .open_punctuation,
                .quotation,
                .close_punctuation,
                .close_parenthesis,
                .before_and_after,
                => {},
                else => return .soft,
            },
        }
    }
    if (isHangulBlock(left.class) and right_class == .postfix) return null;
    if (left.class == .prefix and isHangulBlock(right_class)) return null;
    if (hangulNoBreak(left.class, right_class)) return null;

    // LB8.
    if (before_spaces.class == .zero_width_space) return .soft;
    // LB11–LB14.
    if (right_class == .word_joiner or left.class == .word_joiner) return null;
    if (left.class == .non_breaking_glue) return null;
    if (right_class == .non_breaking_glue and
        left.class != .space and left.class != .after and
        left.class != .hyphen and
        left.class != .unambiguous_hyphen) return null;
    if (right_class == .close_punctuation or
        right_class == .close_parenthesis or
        right_class == .exclamation or
        right_class == .symbol) return null;
    if (before_spaces.class == .open_punctuation) return null;

    // LB15a–LB15d.
    if (before_spaces.class == .quotation and
        before_spaces.properties.category == .initial_punctuation and
        isInitialQuotationContext(before_before_spaces.class))
    {
        return null;
    }
    if (right_class == .quotation and
        right.properties.category == .final_punctuation and
        isFinalQuotationFollower(nextClass(
            text,
            current_next,
            right.class,
            &lookahead_cache,
        )))
    {
        return null;
    }
    if (left.class == .space and right_class == .infix_separator and
        nextClass(
            text,
            current_next,
            right.class,
            &lookahead_cache,
        ) == .numeric) return .soft;
    if (right_class == .infix_separator) return null;

    // LB16–LB18.
    if ((before_spaces.class == .close_punctuation or
        before_spaces.class == .close_parenthesis) and
        right_class == .nonstarter) return null;
    if (before_spaces.class == .before_and_after and
        right_class == .before_and_after) return null;
    if (left.class == .space) return .soft;

    // LB19 / LB19a.
    if (right_class == .quotation and
        right.properties.category != .initial_punctuation) return null;
    if (left.class == .quotation and
        left.properties.category != .final_punctuation) return null;
    if (right_class == .quotation and !left.properties.east_asian) return null;
    if (right_class == .quotation and
        !nextIsEastAsian(
            text,
            current_next,
            right.class,
            &lookahead_cache,
        )) return null;
    if (left.class == .quotation and !right.properties.east_asian) return null;
    if (left.class == .quotation and
        (state.count < 2 or !previous.properties.east_asian)) return null;

    // LB20–LB22.
    if (right_class == .contingent or left.class == .contingent) return .soft;
    if ((left.class == .hyphen or left.class == .unambiguous_hyphen) and
        isAlphabetic(right_class) and
        isWordInitialHyphenContext(previous.class)) return null;
    if (right_class == .after or
        right_class == .unambiguous_hyphen or
        right_class == .hyphen or
        right_class == .nonstarter or left.class == .before) return null;
    if ((left.class == .hyphen or left.class == .unambiguous_hyphen) and
        previous.class == .hebrew_letter and
        right_class != .hebrew_letter) return null;
    if (left.class == .symbol and right_class == .hebrew_letter) return null;
    if (right_class == .inseparable) return null;

    // LB23–LB24.
    if ((isAlphabetic(left.class) and right_class == .numeric) or
        (left.class == .numeric and isAlphabetic(right_class))) return null;
    if (left.class == .prefix and isIdeographic(right_class)) return null;
    if (isIdeographic(left.class) and right_class == .postfix) return null;
    if ((left.class == .prefix or left.class == .postfix) and
        isAlphabetic(right_class)) return null;
    if (isAlphabetic(left.class) and
        (right_class == .prefix or right_class == .postfix)) return null;

    // LB25.
    if ((state.numeric_chain or state.numeric_close_suffix) and
        (right_class == .postfix or right_class == .prefix)) return null;
    if (state.numeric_chain and right_class == .numeric) return null;
    if ((left.class == .postfix or left.class == .prefix) and
        startsNumericExpression(
            right_class,
            ensureLookahead(
                text,
                current_next,
                right.class,
                &lookahead_cache,
            ),
        )) return null;
    if ((left.class == .hyphen or left.class == .infix_separator) and
        right_class == .numeric) return null;

    // LB26–LB27.
    if (hangulNoBreak(left.class, right_class)) return null;
    if (isHangulBlock(left.class) and right_class == .postfix) return null;
    if (left.class == .prefix and isHangulBlock(right_class)) return null;

    // LB28 / LB28a.
    if (isAlphabetic(left.class) and isAlphabetic(right_class)) return null;
    if (left.class == .aksara_prebase and isAksaraBase(right)) return null;
    if (isAksaraBaseEntry(left) and
        (right_class == .virama_final or right_class == .virama)) return null;
    if (isAksaraBaseEntry(previous) and left.class == .virama and
        (right_class == .aksara or right.codepoint == 0x25cc)) return null;
    if (isAksaraBaseEntry(left) and isAksaraBase(right) and
        nextClass(
            text,
            current_next,
            right.class,
            &lookahead_cache,
        ) == .virama_final) return null;

    // LB29–LB30b.
    if (left.class == .infix_separator and isAlphabetic(right_class)) return null;
    if ((isAlphabetic(left.class) or left.class == .numeric) and
        right_class == .open_punctuation and
        !right.properties.east_asian) return null;
    if (left.class == .close_parenthesis and
        !left.properties.east_asian and
        (isAlphabetic(right_class) or right_class == .numeric)) return null;
    if (left.class == .regional_indicator and
        right_class == .regional_indicator and
        state.regional_indicator_count % 2 == 1) return null;
    if (left.class == .emoji_base and right_class == .emoji_modifier) return null;
    if (left.properties.extended_pictographic and
        left.properties.category == .unassigned and
        right_class == .emoji_modifier) return null;

    return .soft; // LB31.
}

const ascii_word_classes = blk: {
    var table = [_]?BreakClass{null} ** 128;
    for ('A'..'Z' + 1) |byte| table[byte] = .alphabetic;
    for ('a'..'z' + 1) |byte| table[byte] = .alphabetic;
    for ('0'..'9' + 1) |byte| table[byte] = .numeric;
    break :blk table;
};

pub inline fn asciiWordClass(byte: u8) ?BreakClass {
    return ascii_word_classes[byte];
}

const ascii_word_bytes: [256]bool = blk: {
    var table: [256]bool = @splat(false);
    for ('A'..'Z' + 1) |byte| table[byte] = true;
    for ('a'..'z' + 1) |byte| table[byte] = true;
    for ('0'..'9' + 1) |byte| table[byte] = true;
    break :blk table;
};

pub inline fn isAsciiWordByte(byte: u8) bool {
    return ascii_word_bytes[byte];
}

pub inline fn isAsciiHardBreak(byte: u8) bool {
    return byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

/// ASCII scalars whose boundary before them is always prohibited (LB13 for
/// closing punctuation, exclamation, and symbols; LB15d for infix separators)
/// and whose following space-to-word boundary is LB31 soft.
const ascii_prose_punctuation = blk: {
    var table = [_]bool{false} ** 256;
    for (0..128) |byte| {
        const class = property_data.lookup(@intCast(byte)).class;
        table[byte] = class == .close_punctuation or
            class == .close_parenthesis or
            class == .exclamation or
            class == .infix_separator or
            class == .symbol;
    }
    break :blk table;
};

pub inline fn isAsciiProsePunctuation(byte: u8) bool {
    return ascii_prose_punctuation[byte];
}

/// True when LB13 or LB15d settles the boundary before an ASCII prose
/// punctuation scalar as prohibited, so the iterator can consume it without
/// the full rule engine. Hard breaks precede LB13, and LB8 allows a break
/// after a zero-width space; both fall back to `decide`.
pub fn asciiPunctuationSettled(
    state: *const StreamState,
    class: BreakClass,
) bool {
    if (state.previous_raw == .mandatory or
        state.previous_raw == .carriage_return or
        state.previous_raw == .line_feed or
        state.previous_raw == .next_line)
    {
        return false;
    }
    // LB15d only prohibits an infix separator directly after a non-space;
    // after spaces LB18 decides, so that boundary keeps the general path.
    if (class == .infix_separator) {
        return state.last.class != .space and
            state.last.class != .zero_width_space;
    }
    return state.beforeSpaceRun().class != .zero_width_space;
}

pub inline fn isWordClass(class: BreakClass) bool {
    return class == .alphabetic or class == .hebrew_letter or
        class == .numeric;
}

/// History entries for ASCII word bytes, materialized at compile time. The
/// run scanners build up to three of these per word, and the class and
/// property lookups cost more than one struct load.
const ascii_history: [128]HistoryEntry = blk: {
    var table: [128]HistoryEntry = undefined;
    for (0..128) |byte| {
        table[byte] = .{
            .codepoint = @intCast(byte),
            .properties = property_data.lookup(@intCast(byte)),
            .class = asciiWordClass(@intCast(byte)) orelse .unknown,
        };
    }
    break :blk table;
};

fn asciiHistoryEntry(byte: u8) HistoryEntry {
    return ascii_history[byte];
}

const FastDecision = struct {
    kind: ?BreakKind,
};

fn asciiCommonDecision(
    state: *const StreamState,
    current: BreakClass,
) ?FastDecision {
    // These branches cover ordinary ASCII prose only. Punctuation, joiners,
    // and any class whose behavior depends on lookaround return null and enter
    // the complete Unicode state machine.
    if (state.previous_raw == .carriage_return and current == .line_feed) {
        return .{ .kind = null };
    }
    if (state.previous_raw == .mandatory or
        state.previous_raw == .carriage_return or
        state.previous_raw == .line_feed or
        state.previous_raw == .next_line)
    {
        return .{ .kind = .hard };
    }
    if (current == .mandatory or current == .carriage_return or
        current == .line_feed or current == .next_line or
        current == .space)
    {
        return .{ .kind = null };
    }
    if (state.previous_raw == .zero_width_joiner) return .{ .kind = null };
    // LB13: no break before close punctuation, close parenthesis, an
    // exclamation, or a symbol, even after spaces. LB8 (a break after a
    // zero-width space) is the only earlier rule that can differ. Infix
    // separators follow LB15d instead, which allows the break after spaces.
    if (state.beforeSpaceRun().class != .zero_width_space and
        (current == .close_punctuation or
            current == .close_parenthesis or
            current == .exclamation or
            current == .symbol))
    {
        return .{ .kind = null };
    }

    if (current == .alphabetic or current == .numeric) {
        if (state.last.class == .alphabetic or
            state.last.class == .hebrew_letter or
            state.last.class == .numeric)
        {
            return .{ .kind = null };
        }
        // LB18 precedes every alphabetic/numeric contextual rule. Once an
        // ASCII word scalar follows SP, no later rule can revoke that break.
        if (state.last.class == .space and
            state.before_spaces.class != .open_punctuation and
            state.before_spaces.class != .quotation and
            state.before_spaces.class != .close_punctuation and
            state.before_spaces.class != .close_parenthesis and
            state.before_spaces.class != .before_and_after)
        {
            return .{ .kind = .soft };
        }
    }
    return null;
}

fn lookaheadSignificant(
    text: []const u8,
    offset: usize,
    initial_lb9_base: BreakClass,
) Lookahead {
    var result = Lookahead{};
    var cursor = offset;
    var lb9_base: ?BreakClass = initial_lb9_base;
    while (cursor < text.len and result.second == null) {
        const decoded = decodeValid(text, cursor);
        const raw = property_data.lookup(decoded.codepoint);
        if (effectiveSignificant(
            decoded.codepoint,
            decoded.start,
            decoded.next,
            raw,
            lb9_base,
        )) |entry| {
            lb9_base = entry.class;
            if (result.first == null) {
                result.first = entry;
            } else {
                result.second = entry;
            }
        }
        cursor = decoded.next;
    }
    return result;
}

fn ensureLookahead(
    text: []const u8,
    offset: usize,
    initial_lb9_base: BreakClass,
    cache: *?Lookahead,
) Lookahead {
    if (cache.* == null) {
        cache.* = lookaheadSignificant(text, offset, initial_lb9_base);
    }
    return cache.*.?;
}

fn nextClass(
    text: []const u8,
    offset: usize,
    initial_lb9_base: BreakClass,
    cache: *?Lookahead,
) ?BreakClass {
    const lookahead = ensureLookahead(text, offset, initial_lb9_base, cache);
    return if (lookahead.first) |entry| entry.class else null;
}

fn nextIsEastAsian(
    text: []const u8,
    offset: usize,
    initial_lb9_base: BreakClass,
    cache: *?Lookahead,
) bool {
    const lookahead = ensureLookahead(text, offset, initial_lb9_base, cache);
    return lookahead.first != null and lookahead.first.?.properties.east_asian;
}

fn isInitialQuotationContext(class: BreakClass) bool {
    return class == .mandatory or class == .carriage_return or
        class == .line_feed or class == .next_line or
        class == .open_punctuation or class == .quotation or
        class == .non_breaking_glue or class == .space or
        class == .zero_width_space or class == .unknown;
}

fn isFinalQuotationFollower(class: ?BreakClass) bool {
    const value = class orelse return true;
    return value == .space or value == .non_breaking_glue or
        value == .word_joiner or value == .close_punctuation or
        value == .quotation or value == .close_parenthesis or
        value == .exclamation or value == .infix_separator or
        value == .symbol or value == .mandatory or
        value == .carriage_return or value == .line_feed or
        value == .next_line or value == .zero_width_space;
}

fn isWordInitialHyphenContext(class: BreakClass) bool {
    return class == .unknown or class == .mandatory or
        class == .carriage_return or class == .line_feed or
        class == .next_line or class == .space or
        class == .zero_width_space or class == .contingent or
        class == .non_breaking_glue;
}

fn isAlphabetic(class: BreakClass) bool {
    return class == .alphabetic or class == .hebrew_letter;
}

fn isIdeographic(class: BreakClass) bool {
    return class == .ideographic or class == .emoji_base or
        class == .emoji_modifier;
}

pub inline fn isHangulBlock(class: BreakClass) bool {
    return class == .hangul_l_jamo or class == .hangul_v_jamo or
        class == .hangul_t_jamo or class == .hangul_lv_syllable or
        class == .hangul_lvt_syllable;
}

/// LB26: no break inside a Hangul syllable sequence.
pub inline fn hangulNoBreak(left: BreakClass, right: BreakClass) bool {
    return (left == .hangul_l_jamo and
        (right == .hangul_l_jamo or
            right == .hangul_v_jamo or
            right == .hangul_lv_syllable or
            right == .hangul_lvt_syllable)) or
        ((left == .hangul_v_jamo or left == .hangul_lv_syllable) and
            (right == .hangul_v_jamo or right == .hangul_t_jamo)) or
        ((left == .hangul_t_jamo or left == .hangul_lvt_syllable) and
            right == .hangul_t_jamo);
}

fn isAksaraBase(entry: Significant) bool {
    return entry.class == .aksara or entry.class == .aksara_start or
        entry.codepoint == 0x25cc;
}

fn isAksaraBaseEntry(entry: HistoryEntry) bool {
    return entry.class == .aksara or entry.class == .aksara_start or
        entry.codepoint == 0x25cc;
}

fn startsNumericExpression(right: BreakClass, lookahead: Lookahead) bool {
    if (right == .numeric) return true;
    if (right != .open_punctuation) return false;
    const first = lookahead.first orelse return false;
    if (first.class == .numeric) return true;
    return first.class == .infix_separator and
        lookahead.second != null and lookahead.second.?.class == .numeric;
}
