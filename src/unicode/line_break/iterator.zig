//! Unicode 17.0 default line breaking (UAX #14, LB1–LB31).
//!
//! Generated scalar properties include the General_Category, East_Asian_Width,
//! and Extended_Pictographic bits required by context-sensitive rules. The
//! iterator resolves LB1 and LB9 while streaming and retains bounded state for
//! numeric expressions, Brahmic orthographic syllables, and RI pairing.

const std = @import("std");

const scalar = @import("../scalar/root.zig");
const property_data = @import("properties.zig");
const rules = @import("rules.zig");

pub const unicode_version = property_data.unicode_version;
pub const BreakClass = property_data.BreakClass;
pub const BreakKind = rules.BreakKind;

pub const Break = struct {
    byte_offset: usize,
    kind: BreakKind,
};

pub const Error = error{InvalidUtf8};

/// Properties shared by every scalar in U+4000..U+9FFF outside the Yijing
/// block: ideographic, East Asian wide, not extended pictographic.
const cjk_ideograph_properties = property_data.Properties{
    .class = .ideographic,
    .category = .other,
    .east_asian = true,
    .extended_pictographic = false,
    .reserved = 0,
};

/// Return one past the last scalar of the ideographic run starting at
/// `start`. The caller guarantees valid UTF-8, and U+4DC0..U+4DFF (Yijing)
/// are alphabetic, so a three-byte lead test identifies the run.
/// True when `codepoint` belongs to the contiguous ideographic range the run
/// scanner accepts (CJK Ext A and CJK Unified, excluding the Yijing block).
inline fn isIdeographicCodepoint(codepoint: u21) bool {
    return codepoint >= 0x4000 and codepoint <= 0x9fff and
        (codepoint < 0x4dc0 or codepoint > 0x4dff);
}

/// True when the pair (last effective class, ideographic) is decided as a
/// soft break by the rule engine's fast path and no earlier rule can
/// override it.
fn breakBeforeIdeograph(state: *const rules.StreamState) bool {
    if (state.previous_raw == .mandatory or
        state.previous_raw == .carriage_return or
        state.previous_raw == .line_feed or
        state.previous_raw == .next_line or
        state.previous_raw == .zero_width_joiner)
    {
        return false;
    }
    return switch (state.last.class) {
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
        => true,
        else => false,
    };
}

fn scanIdeographicRunEnd(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor + 3 <= text.len) {
        const lead = text[cursor];
        if (lead < 0xe4 or lead > 0xe9) break;
        if (lead == 0xe4 and text[cursor + 1] == 0xb7) break;
        cursor += 3;
    }
    return cursor;
}

/// Decode a three-byte sequence at `offset`. Callers have already checked
/// the lead byte range and that three bytes are readable.
inline fn decodeThree(text: []const u8, offset: usize) u21 {
    return (@as(u21, text[offset] & 0x0f) << 12) |
        (@as(u21, text[offset + 1] & 0x3f) << 6) |
        @as(u21, text[offset + 2] & 0x3f);
}

/// True when the scalar at `offset` is one whose LB18 break after spaces
/// needs no rule evaluation: word classes, ideographs, emoji, and Hangul.
/// Joining and prohibited classes (WJ, GL, IS, CL/CP/EX/SY, hard breaks)
/// fall back to the rule engine.
fn spaceRunSoftFollower(text: []const u8, offset: usize) bool {
    if (text[offset] < 0x80) return rules.isAsciiWordByte(text[offset]);
    const decoded = scalar.decodeValidPacked(text, offset);
    if (decoded == scalar.packed_invalid) return false;
    return switch (properties(scalar.packedCodepoint(decoded)).class) {
        .alphabetic,
        .hebrew_letter,
        .numeric,
        .ideographic,
        .emoji_base,
        .emoji_modifier,
        .hangul_l_jamo,
        .hangul_v_jamo,
        .hangul_t_jamo,
        .hangul_lv_syllable,
        .hangul_lvt_syllable,
        .regional_indicator,
        => true,
        else => false,
    };
}

pub const Iterator = struct {
    text: []const u8,
    cursor: usize = 0,
    state: rules.StreamState = .{},
    emitted_end: bool = false,
    simple_ascii: bool = true,
    suppress_break_at_cursor: bool = false,
    /// Byte offset one past the ideographic run being replayed; interior
    /// boundaries are all LB31 soft.
    id_run_end: usize = 0,

    pub fn next(self: *Iterator) ?Break {
        while (!self.emitted_end) {
            if (self.cursor >= self.text.len) {
                self.emitted_end = true;
                if (self.text.len == 0) return null;
                return .{ .byte_offset = self.text.len, .kind = .hard };
            }

            // Dispatch on the lead byte: the ASCII prose scanners can only
            // act on ASCII and the run scanners reject ASCII with one
            // comparison, so a single branch replaces the cross-checks.
            if (self.text[self.cursor] < 0x80) {
                if (self.nextSimpleAscii()) |opportunity| return opportunity;
                if (self.consumeAsciiWordRun()) continue;
                // LB7 forbids a break before a space, so an ASCII space run
                // can be consumed without consulting the rule engine. A
                // pending break was already returned at this cursor, and a
                // hard break (LB4/LB5) is emitted before the run, so those
                // two cases take the generic path.
                if (!self.suppress_break_at_cursor and
                    self.text[self.cursor] == ' ' and
                    self.state.previous_raw != .mandatory and
                    self.state.previous_raw != .carriage_return and
                    self.state.previous_raw != .line_feed and
                    self.state.previous_raw != .next_line)
                {
                    var end = self.cursor + 1;
                    while (end < self.text.len and self.text[end] == ' ') {
                        end += 1;
                    }
                    self.state.consumeAsciiSpaceRun(end - self.cursor);
                    self.cursor = end;
                    const needs_rules = self.state.spaceRunNeedsRules();
                    // `space → JL` is LB31 soft unless the run follows
                    // opening punctuation or a quotation. Consume the L jamo
                    // and return the boundary without the general rule
                    // engine; the next call resumes at its V jamo.
                    if (!needs_rules and end + 3 <= self.text.len and
                        self.text[end] == 0xe1)
                    {
                        const decoded = scalar.decodeValidPacked(
                            self.text,
                            end,
                        );
                        const codepoint = scalar.packedCodepoint(decoded);
                        if (codepoint >= 0x1100 and codepoint <= 0x1112) {
                            const next_index =
                                end + scalar.packedLength(decoded);
                            const raw = property_data.lookupHangul(codepoint);
                            self.state.consume(raw.class, .{
                                .codepoint = codepoint,
                                .properties = raw,
                                .class = raw.class,
                                .start = end,
                                .next = next_index,
                            });
                            self.cursor = next_index;
                            self.simple_ascii = false;
                            return .{ .byte_offset = end, .kind = .soft };
                        }
                    }
                    // LB18 ends the line after a space run. Emit that
                    // boundary here so the word it precedes is consumed by a
                    // run scanner instead of the rule engine.
                    if (!needs_rules and end < self.text.len and
                        spaceRunSoftFollower(self.text, end))
                    {
                        self.simple_ascii = self.text[end] < 0x80;
                        self.suppress_break_at_cursor = true;
                        return .{ .byte_offset = end, .kind = .soft };
                    }
                    continue;
                }
            } else {
                // Start of an ideographic run: the boundary is soft for every
                // left class without a prohibition, and the run interior is
                // replayed, so settle the first scalar without the rule
                // engine.
                if (self.text[self.cursor] >= 0xe4 and
                    self.text[self.cursor] <= 0xe9 and
                    self.cursor + 3 <= self.text.len and
                    self.cursor >= self.id_run_end and
                    self.cursor != 0 and
                    !self.suppress_break_at_cursor)
                {
                    const start = self.cursor;
                    // The lead range guarantees a three-byte sequence.
                    const codepoint = decodeThree(self.text, start);
                    if (isIdeographicCodepoint(codepoint) and
                        breakBeforeIdeograph(&self.state))
                    {
                        const next_index = start + 3;
                        self.id_run_end =
                            scanIdeographicRunEnd(self.text, next_index);
                        const effective = rules.effectiveSignificant(
                            codepoint,
                            start,
                            next_index,
                            cjk_ideograph_properties,
                            self.state.lb9_base,
                        );
                        self.state.consume(.ideographic, effective);
                        self.simple_ascii = false;
                        self.cursor = next_index;
                        return .{ .byte_offset = start, .kind = .soft };
                    }
                }
                // Interior boundaries of an ideographic run are all LB31
                // soft, so replay them without a property lookup or rule
                // evaluation.
                if (self.cursor < self.id_run_end) {
                    const start = self.cursor;
                    // The run scanner only advances over three-byte leads.
                    // Every scalar in the run is ideographic, so the raw
                    // class, LB9 base, numeric flags, and regional-indicator
                    // count already hold the values `consume` would set for
                    // the run's first scalar.
                    self.state.previous_previous = self.state.previous;
                    self.state.previous = self.state.last;
                    self.state.last = .{
                        .codepoint = decodeThree(self.text, start),
                        .properties = cjk_ideograph_properties,
                        .class = .ideographic,
                    };
                    self.state.count += 1;
                    self.cursor = start + 3;
                    return .{
                        .byte_offset = start,
                        .kind = .soft,
                    };
                }
                // Jamo encode with a 0xE1 lead, which the word-run scanner
                // would decode once only to reject. Try the Hangul run first;
                // it rejects other leads with one comparison. A Hangul run
                // never starts with a word class, so the word scanner cannot
                // apply when the previous scalar is already inside one.
                // Every Hangul jamo encodes with an 0xE1 lead, so other
                // scripts skip the run scanner's call entirely.
                if (self.text[self.cursor] == 0xe1 and
                    self.consumeHangulRun()) continue;
                if (self.text[self.cursor] < 0xf0 and
                    !rules.isHangulBlock(self.state.last.class) and
                    self.consumeUnicodeWordRun()) continue;
            }

            const start = self.cursor;
            const decoded = scalar.decodeValidPacked(self.text, start);
            const codepoint = scalar.packedCodepoint(decoded);
            const next_index = start + scalar.packedLength(decoded);
            // A pending opportunity intentionally routes the first scalar of
            // the next ASCII word through the complete rule engine. Preserve
            // prose scanning after that scalar; punctuation or non-ASCII input
            // permanently leaves this narrow fast path for the current run.
            if (codepoint >= 0x80 or
                rules.asciiWordClass(@intCast(codepoint)) == null)
            {
                self.simple_ascii = false;
            }
            const raw_properties = properties(codepoint);
            const effective = rules.effectiveSignificant(
                codepoint,
                start,
                next_index,
                raw_properties,
                self.state.lb9_base,
            );
            // An LB9-folded mark cannot start a line, so only a pending
            // suppressed break can hide the decision.
            const break_kind = if (self.suppress_break_at_cursor) suppress: {
                self.suppress_break_at_cursor = false;
                break :suppress null;
            } else if (effective == null)
                null
            else
                rules.decide(
                    self.text,
                    &self.state,
                    start,
                    next_index,
                    raw_properties,
                    &effective.?,
                );
            // Every interior boundary of an ideographic run is LB31 soft, so
            // once a soft decision lands before an ideograph, find the run
            // end and replay the interior breaks cheaply.
            if (break_kind == .soft and
                raw_properties.class == .ideographic)
            {
                self.id_run_end = scanIdeographicRunEnd(self.text, next_index);
            }
            self.state.consume(raw_properties.class, effective);
            self.cursor = next_index;
            // Punctuation or non-ASCII input disables the prose scanner, but
            // after a word scalar the scanner's committed history is again
            // consistent with the shape it models: the boundary before the
            // next word byte is a word pair (never a break), and the scanner
            // only emits the boundary after the following space run. A space
            // is not resumable because the scanner would skip the pending
            // space-to-word break.
            if (effective) |significant| {
                if (!self.simple_ascii and
                    rules.isWordClass(significant.class) and
                    self.cursor < self.text.len and
                    self.text[self.cursor] < 0x80 and
                    rules.isAsciiWordByte(self.text[self.cursor]))
                {
                    self.simple_ascii = true;
                }
            }
            if (break_kind) |kind| {
                return .{ .byte_offset = start, .kind = kind };
            }
        }
        return null;
    }

    /// Consume a run of Hangul scalars whose adjacent pairs are all
    /// prohibited by LB26. The internal boundaries never break, so only the
    /// final state must be recorded before the next full decision.
    fn consumeHangulRun(self: *Iterator) bool {
        if (self.cursor >= self.text.len) return false;
        if (self.text[self.cursor] < 0x80) return false;
        var last_class = self.state.last.class;
        var cursor = self.cursor;
        var significant_count: usize = 0;
        var tail: [3]rules.HistoryEntry = undefined;
        if (!rules.isHangulBlock(last_class)) {
            // Start a run at an L jamo only when the boundary before it is
            // already settled: start of text or an emitted break. The L-to-V
            // boundary is then an internal LB26 pair. L jamo encode with a
            // 0xE1 lead byte, so other scripts skip the decode entirely.
            if (!(self.state.count == 0 or self.suppress_break_at_cursor)) {
                return false;
            }
            if (self.text[self.cursor] != 0xe1 or
                cursor + 3 > self.text.len)
            {
                return false;
            }
            const codepoint = decodeThree(self.text, cursor);
            const next_index = cursor + 3;
            const raw = if (codepoint >= 0x1100 and codepoint <= 0x11ff)
                property_data.lookupHangul(codepoint)
            else
                properties(codepoint);
            if (raw.class != .hangul_l_jamo) return false;
            tail[0] = .{
                .codepoint = codepoint,
                .properties = raw,
                .class = raw.class,
            };
            significant_count = 1;
            self.suppress_break_at_cursor = false;
            cursor = next_index;
            last_class = raw.class;
        }
        while (cursor < self.text.len and self.text[cursor] >= 0x80) {
            var codepoint: u21 = undefined;
            var next_index: usize = undefined;
            // Jamo are three-byte scalars with a 0xE1 lead; other scripts
            // take the general decoder.
            if (self.text[cursor] == 0xe1 and cursor + 3 <= self.text.len) {
                codepoint = decodeThree(self.text, cursor);
                next_index = cursor + 3;
            } else {
                const decoded = scalar.decodeValidPacked(self.text, cursor);
                codepoint = scalar.packedCodepoint(decoded);
                next_index = cursor + scalar.packedLength(decoded);
            }
            const raw = if (codepoint >= 0x1100 and codepoint <= 0x11ff)
                property_data.lookupHangul(codepoint)
            else
                properties(codepoint);
            if (!rules.hangulNoBreak(last_class, raw.class)) break;
            tail[significant_count % tail.len] = .{
                .codepoint = codepoint,
                .properties = raw,
                .class = raw.class,
            };
            significant_count += 1;
            cursor = next_index;
            last_class = raw.class;
        }
        if (significant_count == 0) return false;
        // Every interior pair is prohibited, so the run needs the same
        // bounded-history update as a word run rather than a full state
        // transition per scalar.
        self.state.consumeWordRun(last_class, significant_count, &tail);
        self.cursor = cursor;
        self.simple_ascii = false;
        return true;
    }

    fn nextSimpleAscii(self: *Iterator) ?Break {
        if (self.cursor >= self.text.len or
            self.suppress_break_at_cursor) return null;

        const start = self.cursor;
        // This scanner commits state only after recognizing a complete
        // `word SP+ word`, hard-break, or end-of-text shape. Punctuation
        // commits the word run and hands the punctuation boundary to the
        // generic path, so no partial shape is ever decided here.
        if (!self.simple_ascii) {
            if (rules.isAsciiHardBreak(self.text[start])) {
                const previous = self.state.previous_raw;
                if (previous != .mandatory and previous != .carriage_return and
                    previous != .line_feed and previous != .next_line)
                {
                    return self.consumeSimpleAsciiHardBreak(start);
                }
            }
            return null;
        }
        if (!rules.isAsciiWordByte(self.text[start])) {
            if (rules.isAsciiHardBreak(self.text[start])) {
                return self.consumeSimpleAsciiHardBreak(start);
            }
            self.simple_ascii = false;
            return null;
        }

        var word_end = start + 1;
        while (word_end < self.text.len and
            rules.isAsciiWordByte(self.text[word_end]))
        {
            word_end += 1;
        }
        if (word_end == self.text.len) {
            self.cursor = word_end;
            self.emitted_end = true;
            return .{ .byte_offset = word_end, .kind = .hard };
        }
        if (self.text[word_end] != ' ') {
            if (rules.isAsciiHardBreak(self.text[word_end])) {
                self.state.consumeAsciiWordRun(self.text[start..word_end]);
                return self.consumeSimpleAsciiHardBreak(word_end);
            }
            if (rules.isAsciiProsePunctuation(self.text[word_end])) {
                @branchHint(.unlikely);
                switch (self.consumeAsciiWordPunctuation(start, word_end)) {
                    .unhandled => {},
                    .handoff => return null,
                    .emitted => |break_| return break_,
                }
            }
            // The word cannot complete a `word SP+ word` shape, but the
            // boundary before it is already settled, so commit the run and
            // let the generic path decide the punctuation boundary.
            self.state.consumeAsciiWordRun(self.text[start..word_end]);
            self.cursor = word_end;
            self.simple_ascii = false;
            return null;
        }

        var next_word = word_end + 1;
        while (next_word < self.text.len and self.text[next_word] == ' ') {
            next_word += 1;
        }
        if (next_word == self.text.len) {
            self.cursor = next_word;
            self.emitted_end = true;
            return .{ .byte_offset = next_word, .kind = .hard };
        }
        if (rules.isAsciiHardBreak(self.text[next_word])) {
            self.state.consumeAsciiWordRun(self.text[start..word_end]);
            self.state.consumeAsciiSpaceRun(next_word - word_end);
            return self.consumeSimpleAsciiHardBreak(next_word);
        }
        if (!rules.isAsciiWordByte(self.text[next_word])) {
            // The word and space boundaries are settled even when the next
            // scalar is not an ASCII word; commit them and let the generic
            // path decide the next boundary.
            self.state.consumeAsciiWordRun(self.text[start..word_end]);
            self.state.consumeAsciiSpaceRun(next_word - word_end);
            self.cursor = next_word;
            self.simple_ascii = false;
            return null;
        }

        self.state.consumeAsciiWordRun(self.text[start..word_end]);
        self.state.consumeAsciiSpaceRun(next_word - word_end);
        self.cursor = next_word;
        self.suppress_break_at_cursor = true;
        return .{ .byte_offset = next_word, .kind = .soft };
    }

    const PunctuationOutcome = union(enum) {
        /// The shape did not match; nothing was committed.
        unhandled,
        /// The punctuation and spaces were committed; the generic path
        /// decides the next boundary.
        handoff,
        /// A break at the end of the committed shape.
        emitted: Break,
    };

    /// Commit `word PUNCT+ SP+` in one step. LB13 and LB15d prohibit a break
    /// inside the punctuation run and LB7 prohibits one before the spaces.
    /// When an ASCII word follows, the space-to-word boundary is LB31 soft
    /// and the break is returned here; otherwise the generic path decides it.
    fn consumeAsciiWordPunctuation(
        self: *Iterator,
        start: usize,
        word_end: usize,
    ) PunctuationOutcome {
        var punct_end = word_end;
        while (punct_end < self.text.len and
            rules.isAsciiProsePunctuation(self.text[punct_end]))
        {
            punct_end += 1;
        }
        if (punct_end == self.text.len) {
            @branchHint(.unlikely);
            self.commitAsciiWordPunctuation(start, word_end, punct_end);
            self.emitted_end = true;
            return .{ .emitted = .{
                .byte_offset = punct_end,
                .kind = .hard,
            } };
        }
        if (rules.isAsciiHardBreak(self.text[punct_end])) {
            @branchHint(.unlikely);
            self.commitAsciiWordPunctuation(start, word_end, punct_end);
            return .{ .emitted = self.consumeSimpleAsciiHardBreak(punct_end) };
        }
        if (self.text[punct_end] != ' ') return .unhandled;
        var next_word = punct_end + 1;
        while (next_word < self.text.len and self.text[next_word] == ' ') {
            next_word += 1;
        }

        self.commitAsciiWordPunctuation(start, word_end, punct_end);
        self.state.consumeAsciiSpaceRun(next_word - punct_end);
        self.cursor = next_word;
        self.simple_ascii = false;
        if (next_word == self.text.len) {
            self.emitted_end = true;
            return .{ .emitted = .{
                .byte_offset = next_word,
                .kind = .hard,
            } };
        }
        if (!rules.isAsciiWordByte(self.text[next_word])) return .handoff;
        self.suppress_break_at_cursor = true;
        return .{ .emitted = .{
            .byte_offset = next_word,
            .kind = .soft,
        } };
    }

    fn commitAsciiWordPunctuation(
        self: *Iterator,
        start: usize,
        word_end: usize,
        punct_end: usize,
    ) void {
        self.state.consumeAsciiWordRun(self.text[start..word_end]);
        for (self.text[word_end..punct_end], word_end..) |byte, offset| {
            self.consumeAsciiPunctuation(byte, offset);
        }
    }

    fn consumeAsciiPunctuation(
        self: *Iterator,
        byte: u8,
        offset: usize,
    ) void {
        const raw = properties(byte);
        self.state.consume(raw.class, .{
            .codepoint = byte,
            .properties = raw,
            .class = raw.class,
            .start = offset,
            .next = offset + 1,
        });
    }

    fn consumeSimpleAsciiHardBreak(
        self: *Iterator,
        break_start: usize,
    ) Break {
        var end = break_start + 1;
        if (self.text[break_start] == '\r' and end < self.text.len and
            self.text[end] == '\n')
        {
            end += 1;
        }
        self.cursor = end;
        const final_class: BreakClass = switch (self.text[end - 1]) {
            '\r' => .carriage_return,
            '\n' => .line_feed,
            else => .mandatory,
        };
        const final = rules.Significant{
            .codepoint = self.text[end - 1],
            .properties = properties(self.text[end - 1]),
            .class = final_class,
            .start = end - 1,
            .next = end,
        };
        self.state.consume(final_class, final);
        self.suppress_break_at_cursor = true;
        if (end == self.text.len) self.emitted_end = true;
        return .{ .byte_offset = end, .kind = .hard };
    }

    fn consumeAsciiWordRun(self: *Iterator) bool {
        if (self.cursor >= self.text.len) return false;
        const follows_emitted_space_break =
            self.suppress_break_at_cursor and self.state.last.class == .space;
        if (self.cursor != 0 and !rules.isWordClass(self.state.last.class) and
            !follows_emitted_space_break) return false;
        if (!rules.isAsciiWordByte(self.text[self.cursor])) return false;

        var end = self.cursor + 1;
        while (end < self.text.len and rules.isAsciiWordByte(self.text[end])) {
            end += 1;
        }
        self.state.consumeAsciiWordRun(self.text[self.cursor..end]);
        self.cursor = end;
        // The scanner already emitted the boundary before this word. Batching
        // the word crosses no legal internal boundary, so the pending marker
        // has now fulfilled the same role as one complete scalar step.
        if (follows_emitted_space_break) self.suppress_break_at_cursor = false;
        return true;
    }

    fn consumeUnicodeWordRun(self: *Iterator) bool {
        if (self.cursor >= self.text.len) return false;
        const first = self.text[self.cursor];
        if (first < 0xc2 or first >= 0xf0) return false;

        // The first boundary must either be LB2, have already been returned by
        // the scanner, or follow AL/HL/NU. Thereafter every significant pair
        // in this run is prohibited by LB23, LB25, or LB28. LB9-ignored CM/ZWJ
        // scalars cannot introduce an internal boundary. This class proof is
        // deliberately script-independent, so Arabic/Hebrew (two-byte UTF-8)
        // and Indic (three-byte) word runs benefit without a fragile script
        // whitelist.
        if (self.cursor != 0 and !self.suppress_break_at_cursor and
            !rules.isWordClass(self.state.last.class))
        {
            return false;
        }

        if (first < 0xe0) return self.consumeTwoByteWordRun();
        return self.consumeThreeByteWordRun();
    }

    /// Two-byte UTF-8 word run: Arabic, Hebrew, Syriac, Greek, Cyrillic, and
    /// every other U+0080..U+07FF script. Kept separate from the three-byte
    /// loop so each scanner carries one bounds and one range test per scalar.
    fn consumeTwoByteWordRun(self: *Iterator) bool {
        var cursor = self.cursor;
        var lb9_base = self.state.lb9_base;
        var final_raw = self.state.previous_raw;
        var significant_count: usize = 0;
        var tail: [3]rules.HistoryEntry = undefined;

        while (cursor + 1 < self.text.len and self.text[cursor] >= 0xc2 and
            self.text[cursor] < 0xe0)
        {
            const first = self.text[cursor];
            const second = self.text[cursor + 1];
            const raw = property_data.lookupDouble(first, second);
            const class = property_data.resolveClass(raw);

            if (class == .combining_mark or raw.class == .zero_width_joiner) {
                // LB9 folds these scalars into an existing ordinary word base.
                // At run start, or after SP/BK/ZW, LB10 would instead turn the
                // scalar into AL and the generic path must preserve that state.
                const base = lb9_base orelse break;
                if (base == .mandatory or base == .carriage_return or
                    base == .line_feed or base == .next_line or
                    base == .space or base == .zero_width_space)
                {
                    break;
                }
                final_raw = raw.class;
                cursor += 2;
                continue;
            }
            if (!rules.isWordClass(class)) break;

            const codepoint = (@as(u21, first & 0x1f) << 6) |
                @as(u21, second & 0x3f);
            appendHistoryTail(
                &tail,
                &significant_count,
                .{
                    .codepoint = codepoint,
                    .properties = raw,
                    .class = class,
                },
            );
            lb9_base = class;
            final_raw = raw.class;
            cursor += 2;
        }
        if (cursor == self.cursor) return false;

        self.state.consumeWordRun(
            final_raw,
            significant_count,
            &tail,
        );
        self.cursor = cursor;
        self.simple_ascii = false;
        self.suppress_break_at_cursor = false;
        return true;
    }

    fn consumeThreeByteWordRun(self: *Iterator) bool {
        var cursor = self.cursor;
        var lb9_base = self.state.lb9_base;
        var final_raw = self.state.previous_raw;
        var significant_count: usize = 0;
        var tail: [3]rules.HistoryEntry = undefined;

        while (cursor + 2 < self.text.len and self.text[cursor] >= 0xe0 and
            self.text[cursor] < 0xf0)
        {
            const first = self.text[cursor];
            const second = self.text[cursor + 1];
            const third = self.text[cursor + 2];
            const raw = property_data.lookupTriple(first, second, third);
            const class = property_data.resolveClass(raw);

            if (class == .combining_mark or raw.class == .zero_width_joiner) {
                // LB9 folds these scalars into an existing ordinary word base.
                // At run start, or after SP/BK/ZW, LB10 would instead turn the
                // scalar into AL and the generic path must preserve that state.
                const base = lb9_base orelse break;
                if (base == .mandatory or base == .carriage_return or
                    base == .line_feed or base == .next_line or
                    base == .space or base == .zero_width_space)
                {
                    break;
                }
                final_raw = raw.class;
                cursor += 3;
                continue;
            }
            if (!rules.isWordClass(class)) break;

            const codepoint = (@as(u21, first & 0x0f) << 12) |
                (@as(u21, second & 0x3f) << 6) |
                @as(u21, third & 0x3f);
            appendHistoryTail(
                &tail,
                &significant_count,
                .{
                    .codepoint = codepoint,
                    .properties = raw,
                    .class = class,
                },
            );
            lb9_base = class;
            final_raw = raw.class;
            cursor += 3;
        }
        if (cursor == self.cursor) return false;

        self.state.consumeWordRun(
            final_raw,
            significant_count,
            &tail,
        );
        self.cursor = cursor;
        self.simple_ascii = false;
        self.suppress_break_at_cursor = false;
        return true;
    }
};

inline fn appendHistoryTail(
    tail: *[3]rules.HistoryEntry,
    count: *usize,
    entry: anytype,
) void {
    const history = rules.HistoryEntry{
        .codepoint = entry.codepoint,
        .properties = entry.properties,
        .class = entry.class,
    };
    tail[count.* % tail.len] = history;
    count.* += 1;
}

pub fn breaks(text: []const u8) Error!Iterator {
    if (!scalar.validate.isValid(text)) return error.InvalidUtf8;
    return breaksAssumeValid(text);
}

pub fn breaksAssumeValid(text: []const u8) Iterator {
    scalar.assertValidUtf8(text);
    return .{ .text = text };
}

pub inline fn classForCodepoint(codepoint: u21) BreakClass {
    return property_data.class(codepoint);
}

inline fn properties(codepoint: u21) property_data.Properties {
    return property_data.lookup(codepoint);
}

test {
    try @import("conformance_test.zig").run(@This());
}
