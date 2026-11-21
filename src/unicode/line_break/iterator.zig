//! Unicode 17.0 default line breaking (UAX #14, LB1–LB31).
//!
//! Generated scalar properties include the General_Category, East_Asian_Width,
//! and Extended_Pictographic bits required by context-sensitive rules. The
//! iterator resolves LB1 and LB9 while streaming and retains bounded state for
//! numeric expressions, Brahmic orthographic syllables, and RI pairing.

const std = @import("std");

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

pub const Iterator = struct {
    text: []const u8,
    cursor: usize = 0,
    state: rules.StreamState = .{},
    emitted_end: bool = false,
    simple_ascii: bool = true,
    suppress_break_at_cursor: bool = false,

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
                    continue;
                }
            } else {
                // A Hangul run never starts with a word class, so skip the
                // word-run scanner when the previous scalar is already
                // inside one.
                if (!rules.isHangulBlock(self.state.last.class) and
                    self.consumeUnicodeWordRun()) continue;
                if (self.consumeHangulRun()) continue;
            }

            const decoded = rules.decodeValid(self.text, self.cursor);
            // A pending opportunity intentionally routes the first scalar of
            // the next ASCII word through the complete rule engine. Preserve
            // prose scanning after that scalar; punctuation or non-ASCII input
            // permanently leaves this narrow fast path for the current run.
            if (decoded.codepoint >= 0x80 or
                rules.asciiWordClass(@intCast(decoded.codepoint)) == null)
            {
                self.simple_ascii = false;
            }
            const raw_properties = properties(decoded.codepoint);
            const effective = rules.effectiveSignificant(
                decoded,
                raw_properties,
                self.state.lb9_base,
            );
            const break_kind = if (self.suppress_break_at_cursor) suppress: {
                self.suppress_break_at_cursor = false;
                break :suppress null;
            } else rules.decide(
                self.text,
                self.state,
                decoded,
                raw_properties,
                effective,
            );
            self.state.consume(raw_properties.class, effective);
            self.cursor = decoded.next;
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
                return .{ .byte_offset = decoded.start, .kind = kind };
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
        var consumed = false;
        if (!rules.isHangulBlock(last_class)) {
            // Start a run at an L jamo only when the boundary before it is
            // already settled: start of text or an emitted break. The L-to-V
            // boundary is then an internal LB26 pair. L jamo encode with a
            // 0xE1 lead byte, so other scripts skip the decode entirely.
            if (!(self.state.count == 0 or self.suppress_break_at_cursor)) {
                return false;
            }
            if (self.text[self.cursor] != 0xe1) return false;
            const decoded = rules.decodeValid(self.text, cursor);
            const raw = properties(decoded.codepoint);
            if (raw.class != .hangul_l_jamo) return false;
            self.state.consume(raw.class, .{
                .codepoint = decoded.codepoint,
                .properties = raw,
                .class = raw.class,
                .start = cursor,
                .next = decoded.next,
            });
            self.suppress_break_at_cursor = false;
            cursor = decoded.next;
            last_class = raw.class;
            consumed = true;
        }
        while (cursor < self.text.len and self.text[cursor] >= 0x80) {
            const decoded = rules.decodeValid(self.text, cursor);
            const raw = properties(decoded.codepoint);
            if (!rules.hangulNoBreak(last_class, raw.class)) break;
            self.state.consume(raw.class, .{
                .codepoint = decoded.codepoint,
                .properties = raw,
                .class = raw.class,
                .start = cursor,
                .next = decoded.next,
            });
            cursor = decoded.next;
            consumed = true;
            last_class = raw.class;
        }
        if (!consumed) return false;
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
            self.simple_ascii = false;
            return null;
        }

        self.state.consumeAsciiWordRun(self.text[start..word_end]);
        self.state.consumeAsciiSpaceRun(next_word - word_end);
        self.cursor = next_word;
        self.suppress_break_at_cursor = true;
        return .{ .byte_offset = next_word, .kind = .soft };
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
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return breaksAssumeValid(text);
}

pub fn breaksAssumeValid(text: []const u8) Iterator {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    return .{ .text = text };
}

pub inline fn classForCodepoint(codepoint: u21) BreakClass {
    return property_data.lookup(codepoint).class;
}

inline fn properties(codepoint: u21) property_data.Properties {
    return property_data.lookup(codepoint);
}

test {
    try @import("conformance_test.zig").run(@This());
}
