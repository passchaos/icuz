//! Standard Unicode Character Database algorithms for Zig.
//!
//! This aggregate contains only Unicode-standard properties and UAX
//! algorithms. Cangjie-specific shaping, editor, display, and OpenType policy
//! lives in the consuming library.

const std = @import("std");
const line_break = @import("./line_break/iterator.zig");
const grapheme_boundary = @import("./grapheme/iterator.zig");
const word_boundary = @import("./word/iterator.zig");
const sentence_boundary = @import("./sentence/iterator.zig");
const joining = @import("./joining.zig");
const script_mod = @import("./script/root.zig");
const script_extensions = @import("./script_extensions/root.zig");
const vertical = @import("./vertical/root.zig");
const bidi_paragraph = @import("./bidi/paragraph.zig");
const canonical_combining_class = @import("./canonical/combining_class.zig");
const canonical_decomposition = @import("./canonical/decomposition.zig");
const normalization = @import("./normalization/root.zig");
const case_mod = @import("./case/root.zig");
const properties = @import("./properties.zig");
const scalar_value = @import("./scalar/root.zig");
const scalar_cursor = @import("./scalar/cursor.zig");
const word_cursor = @import("./word/cursor.zig");
const sentence_cursor = @import("./sentence/cursor.zig");

pub const Script = script_mod.Script;
pub const isScalarValue = scalar_value.isValid;
pub const scriptExtensionsContain = script_extensions.contains;
pub const hasExplicitScriptExtensions = script_extensions.hasExplicit;
pub const scriptExtensionsCount = script_extensions.count;
pub const ScriptExtensions = script_extensions.Set;
pub const scriptExtensionsForCodepoint = script_extensions.forCodepoint;
pub const scriptForCodepoint = script_mod.forCodepoint;

pub const ScriptRun = struct {
    script: Script,
    byte_start: usize,
    byte_len: usize,
};

/// Allocation-free UAX #24-style script-run traversal.
pub const ScriptRunIterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn next(self: *ScriptRunIterator) error{InvalidUtf8}!?ScriptRun {
        if (self.cursor >= self.text.len) return null;

        const run_start = self.cursor;
        var run_end = self.cursor;
        var current_script: ?Script = null;
        while (self.cursor < self.text.len) {
            const cluster = self.cursor;
            const decoded = decodeCodepointAt(self.text, self.cursor) orelse
                return error.InvalidUtf8;
            const script = scriptForCodepoint(decoded.codepoint);
            if (current_script == null) {
                current_script = if (script == .common or script == .inherited)
                    .common
                else
                    script;
                self.cursor = decoded.next;
                run_end = decoded.next;
                continue;
            }
            if (scriptBelongsToRun(
                decoded.codepoint,
                script,
                current_script.?,
            )) {
                if (current_script.? == .common and
                    script != .common and script != .inherited)
                {
                    current_script = script;
                }
                self.cursor = decoded.next;
                run_end = decoded.next;
                continue;
            }

            self.cursor = cluster;
            break;
        }

        return .{
            .script = current_script.?,
            .byte_start = run_start,
            .byte_len = run_end - run_start,
        };
    }
};

pub fn scriptRuns(text: []const u8) ScriptRunIterator {
    return .{ .text = text };
}

pub const ExactBidiClass = bidi_paragraph.Class;
pub const BidiBaseDirection = bidi_paragraph.BaseDirection;
pub const BidiParagraph = bidi_paragraph.Paragraph;
pub const BidiRangeMode = bidi_paragraph.RangeMode;
pub const BidiRange = bidi_paragraph.Range;
pub const bidi_unicode_version = bidi_paragraph.unicode_version;

pub const JoiningType = joining.Type;
pub const JoiningForm = joining.Form;

pub const VerticalOrientation = vertical.Orientation;
pub const vertical_orientation_unicode_version = vertical.unicode_version;

/// Complete Unicode 17 UAX #50 classifier.
pub fn verticalOrientationForCodepoint(codepoint: u21) VerticalOrientation {
    return vertical.orientation(codepoint);
}

pub fn verticalPresentationCodepoint(codepoint: u21) ?u21 {
    return vertical.presentationCodepoint(codepoint);
}

pub const joiningTypeForCodepoint = joining.typeForCodepoint;

pub fn canonicalCombiningClass(codepoint: u21) u8 {
    return canonical_combining_class.forCodepoint(codepoint);
}

pub fn canonicalDecomposition(codepoint: u21) ?[]const u21 {
    if (!scalar_value.isValid(codepoint)) return null;
    return canonical_decomposition.markLeadingForCodepoint(codepoint);
}

pub fn canonicalDecompositionAll(codepoint: u21) ?[]const u21 {
    if (!scalar_value.isValid(codepoint)) return null;
    return canonical_decomposition.forCodepoint(codepoint);
}

pub fn canonicalDecompositionDirect(codepoint: u21) ?[]const u21 {
    if (!scalar_value.isValid(codepoint)) return null;
    return canonical_decomposition.directForCodepoint(codepoint);
}

pub const NormalizationQuickCheck = normalization.QuickCheck;
pub const normalization_unicode_version = normalization.unicode_version;
pub const nfcQuickCheckCodepoint = normalization.quickCheckCodepoint;
pub const normalizeNfcAlloc = normalization.normalizeAlloc;
pub const normalizeNfdAlloc = normalization.normalizeNfdAlloc;
pub const normalizeNfkcAlloc = normalization.normalizeNfkcAlloc;
pub const normalizeNfkdAlloc = normalization.normalizeNfkdAlloc;
pub const isNormalizedNfc = normalization.isNormalized;
pub const isNormalizedNfcAssumeValid = normalization.isNormalizedAssumeValid;

pub const simpleLower = case_mod.simpleLower;
pub const simpleUpper = case_mod.simpleUpper;
pub const simpleTitle = case_mod.simpleTitle;
pub const simpleCaseFold = case_mod.simpleFold;
pub const fullCaseFold = case_mod.fullFold;
pub const lowerAlloc = case_mod.lowerAlloc;
pub const upperAlloc = case_mod.upperAlloc;
pub const caseFoldAlloc = case_mod.foldAlloc;

pub const GraphemeCluster = grapheme_boundary.Cluster;
pub const GraphemeClusterIterator = grapheme_boundary.Iterator;
pub const ScalarGraphemeBreaker = grapheme_boundary.ScalarBreaker;
pub const GraphemeBoundaryView = grapheme_boundary.BoundaryView;
pub const GraphemeBoundaryAdvance = grapheme_boundary.BoundaryAdvance;
pub const grapheme_unicode_version = grapheme_boundary.unicode_version;

pub fn graphemeClusters(text: []const u8) error{InvalidUtf8}!GraphemeClusterIterator {
    return grapheme_boundary.clusters(text);
}

pub fn graphemeClustersAssumeValid(text: []const u8) GraphemeClusterIterator {
    return grapheme_boundary.assumeValid(text);
}

pub fn graphemeBoundaries(text: []const u8) error{InvalidUtf8}!GraphemeBoundaryView {
    return GraphemeBoundaryView.init(text);
}

pub fn graphemeBoundariesAssumeValid(text: []const u8) GraphemeBoundaryView {
    return GraphemeBoundaryView.assumeValid(text);
}

pub const WordBoundarySegment = word_boundary.Segment;
pub const WordBoundaryIterator = word_boundary.Iterator;
pub const Scalar = scalar_cursor.Scalar;
pub const WordCursorIterator = word_cursor.WordCursorIterator;
pub const word_unicode_version = word_boundary.unicode_version;

pub fn wordSegments(text: []const u8) word_boundary.Error!WordBoundaryIterator {
    return word_boundary.segments(text);
}

pub fn wordSegmentsAssumeValid(text: []const u8) WordBoundaryIterator {
    return word_boundary.assumeValid(text);
}

pub const SentenceSegment = sentence_boundary.Segment;
pub const SentenceBoundaryIterator = sentence_boundary.Iterator;
pub const SentenceCursorIterator = sentence_cursor.SentenceCursorIterator;
pub const sentence_unicode_version = sentence_boundary.unicode_version;

pub fn sentenceSegments(
    text: []const u8,
) sentence_boundary.Error!SentenceBoundaryIterator {
    return sentence_boundary.segments(text);
}

pub const LineBreakKind = line_break.BreakKind;
pub const LineBreak = line_break.Break;
pub const LineBreakIterator = line_break.Iterator;
pub const LineBreakClass = line_break.BreakClass;
pub const line_break_unicode_version = line_break.unicode_version;

pub fn lineBreaks(text: []const u8) line_break.Error!LineBreakIterator {
    return line_break.breaks(text);
}

pub fn lineBreaksAssumeValid(text: []const u8) LineBreakIterator {
    return line_break.breaksAssumeValid(text);
}

pub fn lineBreakClassForCodepoint(codepoint: u21) LineBreakClass {
    return line_break.classForCodepoint(codepoint);
}

pub const isExtendedPictographic =
    grapheme_boundary.isExtendedPictographic;
pub const isEmojiPresentation = grapheme_boundary.isEmojiPresentation;

pub const isVariationSelector = script_mod.isVariationSelector;

pub fn isMongolianFreeVariationSelector(codepoint: u21) bool {
    return (codepoint >= 0x180b and codepoint <= 0x180d) or codepoint == 0x180f;
}

pub fn isEmojiModifierCodepoint(codepoint: u21) bool {
    return codepoint >= 0x1f3fb and codepoint <= 0x1f3ff;
}

pub fn isRegionalIndicatorCodepoint(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

/// Return whether Unicode assigns General_Category=Nonspacing_Mark (Mn).
pub const isNonspacingMarkCodepoint = properties.isNonspacingMark;

pub fn isEmojiTagCodepoint(codepoint: u21) bool {
    return codepoint >= 0xe0020 and codepoint <= 0xe007f;
}

pub fn exactBidiClassForCodepoint(codepoint: u21) ExactBidiClass {
    return bidi_paragraph.classForCodepoint(codepoint);
}

/// Whether an LTR run may require UAX #9 visual reordering because of this
/// scalar. Keep this predicate shared by source scanning and fallback bidi
/// scans so their trigger sets cannot drift.
pub fn mayNeedBidiVisualReorder(codepoint: u21) bool {
    return switch (exactBidiClassForCodepoint(codepoint)) {
        .r,
        .al,
        .rle,
        .rlo,
        .rli,
        .lre,
        .lro,
        .lri,
        .fsi,
        .pdf,
        .pdi,
        => true,
        else => false,
    };
}

pub fn resolveBidiParagraph(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_direction: BidiBaseDirection,
) !BidiParagraph {
    return bidi_paragraph.resolve(allocator, text, base_direction);
}

pub fn resolveBidiParagraphWithRanges(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_direction: BidiBaseDirection,
    ranges: []const BidiRange,
) !BidiParagraph {
    return bidi_paragraph.resolveWithRanges(
        allocator,
        text,
        base_direction,
        ranges,
    );
}

pub fn itemizeGraphemeClusters(allocator: std.mem.Allocator, text: []const u8) ![]GraphemeCluster {
    var clusters = std.ArrayList(GraphemeCluster).empty;
    errdefer clusters.deinit(allocator);

    var iterator = try graphemeClusters(text);
    while (iterator.next()) |cluster| try clusters.append(allocator, cluster);
    return try clusters.toOwnedSlice(allocator);
}

pub fn itemizeLineBreaks(allocator: std.mem.Allocator, text: []const u8) ![]LineBreak {
    var breaks = std.ArrayList(LineBreak).empty;
    errdefer breaks.deinit(allocator);

    var iterator = try lineBreaks(text);
    while (iterator.next()) |opportunity| {
        try breaks.append(allocator, opportunity);
    }

    return try breaks.toOwnedSlice(allocator);
}

pub fn itemizeScriptRuns(allocator: std.mem.Allocator, text: []const u8) ![]ScriptRun {
    var runs = std.ArrayList(ScriptRun).empty;
    errdefer runs.deinit(allocator);
    var iterator = scriptRuns(text);
    while (try iterator.next()) |run| try runs.append(allocator, run);
    return try runs.toOwnedSlice(allocator);
}

pub fn mirroredCodepoint(codepoint: u21) u21 {
    return bidi_paragraph.mirroredCodepoint(codepoint);
}

const DecodedCodepoint = struct {
    codepoint: u21,
    next: usize,
};

fn decodeCodepointAt(text: []const u8, cursor: usize) ?DecodedCodepoint {
    if (cursor >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return null;
    const end = cursor + @as(usize, len);
    if (end > text.len) return null;
    const codepoint = std.unicode.utf8Decode(text[cursor..end]) catch return null;
    return .{ .codepoint = codepoint, .next = end };
}

fn scriptBelongsToRun(codepoint: u21, script: Script, current: Script) bool {
    if (script == current) return true;
    if (script == .common or script == .inherited) {
        return !script_extensions.hasExplicit(codepoint) or
            script_extensions.contains(codepoint, current);
    }
    if (current == .common) return true;
    return false;
}

test {
    _ = word_cursor;
    _ = sentence_cursor;
    _ = normalization;
    _ = case_mod;
    _ = properties;
}
