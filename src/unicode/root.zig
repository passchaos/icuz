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
const name_mod = @import("./name.zig");
const set_mod = @import("./set.zig");
const break_rules_mod = @import("./break_rules.zig");
const utf16_mod = @import("./utf16.zig");
const collation_mod = @import("./collation/root.zig");
const search_mod = @import("./search.zig");
const spoof_mod = @import("./spoof.zig");
const idna_mod = @import("./idna.zig");
const plural_mod = @import("./format/plurals.zig");
const number_mod = @import("./format/number.zig");
const dates_mod = @import("./format/dates.zig");
const message_mod = @import("./format/message.zig");
const list_mod = @import("./format/list.zig");
const relative_mod = @import("./format/relative.zig");
const units_mod = @import("./format/units.zig");
const charset_mod = @import("./charset.zig");
const transliterate_mod = @import("./transliterate.zig");
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
pub const normalizeInto = normalization.normalizeFormInto;
pub const spanQuickCheckYes = normalization.spanQuickCheckYes;
pub const normalizeCodepointsAlloc = normalization.normalizeCodepointsAlloc;
pub const isNormalizedCodepoints = normalization.isNormalizedCodepoints;
pub const normalizeUtf16Alloc = normalization.normalizeUtf16Alloc;
pub const isNormalizedUtf16 = normalization.isNormalizedUtf16;
pub const Normalizer = normalization.Normalizer;
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
pub const fullLowerAlloc = case_mod.fullLowerAlloc;
pub const fullUpperAlloc = case_mod.fullUpperAlloc;
pub const fullTitleAlloc = case_mod.fullTitleAlloc;
pub const CaseLocale = case_mod.Locale;
pub const CaseOptions = case_mod.CaseOptions;

pub const NameType = name_mod.NameType;
pub const characterName = name_mod.name;
pub const characterNameInto = name_mod.nameInto;
pub const characterNameAlloc = name_mod.nameAlloc;
pub const characterAlias = name_mod.alias;
pub const firstCharacterAlias = name_mod.firstAlias;
pub const findCharacterByName = name_mod.findByName;

pub const UnicodeSet = set_mod.Set;
pub const UnicodeSetRange = set_mod.Range;
pub const parseUnicodeSet = set_mod.parse;
pub const unicodeSetFromProperty = set_mod.fromProperty;
pub const unicodeSetFromCategory = set_mod.fromCategoryMask;
pub const unicodeSetFromScript = set_mod.fromScript;
pub const unicodeSetFromScriptExtensions = set_mod.fromScriptExtensions;

pub const utf16 = utf16_mod;

pub const CollationStrength = collation_mod.Strength;
pub const CollationVariableWeighting = collation_mod.VariableWeighting;
pub const CollationOptions = collation_mod.Options;
pub const CollationCollator = collation_mod.Collator;
pub const collationSortKeyAlloc = collation_mod.sortKeyAlloc;
pub const collationSortKeyInto = collation_mod.sortKeyInto;
pub const collationSortKeyCodepointsInto = collation_mod.sortKeyCodepointsInto;
pub const collationSortKeyUtf16Alloc = collation_mod.sortKeyUtf16Alloc;
pub const collationSortKeyUtf16Into = collation_mod.sortKeyUtf16Into;
pub const collationCompare = collation_mod.compare;
pub const collationCompareUtf16 = collation_mod.compareUtf16;
pub const SearchState = search_mod.Search;
pub const searchIndexOf = search_mod.indexOf;
pub const spoofSkeletonAlloc = spoof_mod.skeletonAlloc;
pub const spoofSkeletonCodepointsInto = spoof_mod.skeletonCodepointsInto;
pub const spoofAreConfusable = spoof_mod.areConfusable;
pub const spoofIdentifierAllowed = spoof_mod.identifierAllowed;
pub const SpoofRestrictionLevel = spoof_mod.RestrictionLevel;
pub const spoofRestrictionLevel = spoof_mod.restrictionLevel;
pub const spoofIsMixedScript = spoof_mod.isMixedScript;
pub const spoofIsAllowedIdentifier = spoof_mod.isAllowedIdentifier;
pub const collation_uca_version = collation_mod.uca_version;
pub const collation_cldr_version = collation_mod.cldr_version;

pub const IdnaOptions = idna_mod.Options;
pub const idnaToAsciiAlloc = idna_mod.toAsciiAlloc;
pub const idnaToUnicodeAlloc = idna_mod.toUnicodeAlloc;
pub const idnaValidate = idna_mod.validate;
pub const idna_version = idna_mod.idna_version;

pub const PluralCategory = plural_mod.Category;
pub const pluralCategory = plural_mod.category;
pub const pluralCategoryForInteger = plural_mod.categoryForInteger;
pub const pluralCategoryForDecimalString = plural_mod.categoryForDecimalString;
pub const ordinalPluralCategory = plural_mod.ordinalCategory;
pub const ordinalPluralCategoryForInteger = plural_mod.ordinalCategoryForInteger;
pub const ordinalPluralCategoryForDecimalString =
    plural_mod.ordinalCategoryForDecimalString;
pub const plural_cldr_version = plural_mod.cldr_version;

pub const NumberStyle = number_mod.Style;
pub const NumberCompactStyle = number_mod.CompactStyle;
pub const NumberCurrencyDisplay = number_mod.CurrencyDisplay;
pub const NumberOptions = number_mod.Options;
pub const NumberParseOptions = number_mod.ParseOptions;
pub const formatNumberAlloc = number_mod.formatAlloc;
pub const formatIntegerAlloc = number_mod.formatIntegerAlloc;
pub const formatNumberSkeletonAlloc = number_mod.formatSkeletonAlloc;
pub const formatNumberSkeletonIntegerAlloc =
    number_mod.formatSkeletonIntegerAlloc;
pub const parseNumberFloat = number_mod.parseFloat;
pub const parseNumberFloatPrefix = number_mod.parseFloatPrefix;
pub const parseNumberInt = number_mod.parseInt;
pub const NumberParseResult = number_mod.ParseResult;
pub const number_cldr_version = number_mod.cldr_version;

const rbnf_mod = @import("./format/rbnf.zig");
const timezone_mod = @import("./timezone/root.zig");
const calendar_mod = @import("./format/calendar.zig");
const intervals_mod = @import("./format/intervals.zig");
const durations_mod = @import("./format/durations.zig");
const display_names_mod = @import("./format/display_names.zig");
const likely_subtags_mod = @import("./format/likely_subtags.zig");
const chinese_calendar_mod = @import("./format/chinese_calendar.zig");
pub const RbnfTag = rbnf_mod.Tag;
pub const formatRbnfAlloc = rbnf_mod.formatAlloc;
pub const rbnf_cldr_version = rbnf_mod.cldr_version;

pub const TimeZone = timezone_mod.Zone;
pub const TimeZoneOffset = timezone_mod.Offset;
pub const findTimeZone = timezone_mod.find;
pub const timeZoneOffsetAt = timezone_mod.offsetAt;
pub const timeZoneLocalSeconds = timezone_mod.localSeconds;
pub const timeZoneUtcSeconds = timezone_mod.utcSeconds;
pub const timeZoneCount = timezone_mod.count;
pub const timeZoneAt = timezone_mod.at;
pub const tzdata_version = timezone_mod.tzdata_version;
pub const timeZoneUsesDaylight = timezone_mod.usesDaylight;
pub const TimeZoneNameWidth = timezone_mod.names.Width;
pub const TimeZoneNameKind = timezone_mod.names.Kind;
pub const timeZoneNameAlloc = timezone_mod.names.zoneNameAlloc;
pub const timeZoneGmtOffsetAlloc = timezone_mod.names.gmtOffsetAlloc;
pub const timeZoneExemplarCityAlloc = timezone_mod.names.exemplarCityAlloc;

pub const DateTime = dates_mod.DateTime;
pub const DateStyle = dates_mod.Style;
pub const DateParseDefaults = dates_mod.ParseDefaults;
pub const CalendarField = dates_mod.CalendarField;
pub const parseDatePattern = dates_mod.parsePattern;
pub const parseDateSkeleton = dates_mod.parseSkeleton;
pub const addCalendarDays = dates_mod.addDays;
pub const addCalendarMonths = dates_mod.addMonths;
pub const addCalendarYears = dates_mod.addYears;
pub const calendarFieldDifference = dates_mod.fieldDifference;
pub const dateSkeletonPattern = dates_mod.skeletonPattern;
pub const formatDateAlloc = dates_mod.formatDateAlloc;
pub const formatTimeAlloc = dates_mod.formatTimeAlloc;
pub const formatTimeWithZoneAlloc = dates_mod.formatTimeWithZoneAlloc;
pub const formatDateTimeAlloc = dates_mod.formatDateTimeAlloc;
pub const formatDatePatternAlloc = dates_mod.formatPatternAlloc;
pub const dateTimeFromUnixSeconds = dates_mod.fromUnixSeconds;
pub const dateTimeFromUnixSecondsInZone =
    dates_mod.dateTimeFromUnixSecondsInZone;
pub const formatUnixTimeInZoneAlloc = dates_mod.formatUnixTimeInZoneAlloc;
pub const formatTimeInZoneAlloc = dates_mod.formatTimeInZoneAlloc;
pub const formatPatternInZoneAlloc = dates_mod.formatPatternInZoneAlloc;
pub const unixSecondsFromDateTime = dates_mod.unixSeconds;
pub const ZoneInfo = dates_mod.ZoneInfo;
pub const CalendarSystem = calendar_mod.Calendar;
pub const CalendarDate = calendar_mod.Date;
pub const calendarDateFromDays = calendar_mod.fromDays;
pub const calendarDaysFromGregorian = calendar_mod.daysFromGregorian;
pub const formatDateInCalendarAlloc = dates_mod.formatDateInCalendarAlloc;
pub const formatDateTimeInCalendarAlloc = dates_mod.formatDateTimeInCalendarAlloc;
pub const formatPatternInCalendarAlloc = dates_mod.formatPatternInCalendarAlloc;
pub const formatDateIntervalAlloc = intervals_mod.formatDateIntervalAlloc;
pub const formatTimeIntervalAlloc = intervals_mod.formatTimeIntervalAlloc;
pub const DurationStyle = durations_mod.Style;
pub const formatDurationAlloc = durations_mod.formatDurationAlloc;
pub const DisplayNameKind = display_names_mod.Kind;
pub const displayName = display_names_mod.name;
pub const formatLocaleDisplayNameAlloc = display_names_mod.localeDisplayNameAlloc;
pub const maximizeLocaleAlloc = likely_subtags_mod.maximizeAlloc;
pub const minimizeLocaleAlloc = likely_subtags_mod.minimizeAlloc;
pub const date_cldr_version = dates_mod.cldr_version;

pub const MessageArgument = message_mod.Argument;
pub const MessageNamedArgument = message_mod.NamedArgument;
pub const MessageArguments = message_mod.Arguments;
pub const formatMessageAlloc = message_mod.formatAlloc;

pub const CharsetEncoding = charset_mod.Encoding;
pub const CharsetErrorMode = charset_mod.ErrorMode;
pub const CharsetOptions = charset_mod.Options;
pub const CharsetDecoder = charset_mod.Decoder;
pub const CharsetEncoder = charset_mod.Encoder;
pub const charsetFromLabel = charset_mod.fromLabel;
pub const decodeCharsetAlloc = charset_mod.decodeAlloc;
pub const encodeCharsetAlloc = charset_mod.encodeAlloc;
pub const convertCharsetAlloc = charset_mod.convertAlloc;
pub const validateCharset = charset_mod.validate;

pub const Transliteration = transliterate_mod.Transform;
pub const transliterateAlloc = transliterate_mod.transliterateAlloc;

pub const ListStyle = list_mod.Style;
pub const ListOptions = list_mod.Options;
pub const formatListAlloc = list_mod.formatAlloc;

pub const RelativeUnit = relative_mod.Unit;
pub const RelativeNumeric = relative_mod.Numeric;
pub const RelativeOptions = relative_mod.Options;
pub const formatRelativeAlloc = relative_mod.formatAlloc;

pub const Unit = units_mod.Unit;
pub const UnitStyle = units_mod.Style;
pub const UnitOptions = units_mod.Options;
pub const formatUnitAlloc = units_mod.formatAlloc;

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

pub const DictionaryWordIterator = word_boundary.DictionaryIterator;

/// Word segmentation that applies ICU break dictionaries to Thai, Lao,
/// Khmer, Burmese, and CJK runs. Other text uses the UAX #29 rules.
pub fn wordSegmentsWithDictionaries(
    text: []const u8,
) word_boundary.Error!DictionaryWordIterator {
    return word_boundary.segmentsWithDictionaries(text);
}

pub fn wordSegmentsWithDictionariesAssumeValid(
    text: []const u8,
) DictionaryWordIterator {
    return word_boundary.assumeValidWithDictionaries(text);
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
    _ = line_break;
    _ = grapheme_boundary;
    _ = word_boundary;
    _ = sentence_boundary;
    _ = joining;
    _ = script_mod;
    _ = script_extensions;
    _ = vertical;
    _ = bidi_paragraph;
    _ = canonical_combining_class;
    _ = canonical_decomposition;
    _ = normalization;
    _ = case_mod;
    _ = name_mod;
    _ = set_mod;
    _ = utf16_mod;
    _ = collation_mod;
    _ = search_mod;
    _ = spoof_mod;
    _ = idna_mod;
    _ = plural_mod;
    _ = number_mod;
    _ = dates_mod;
    _ = rbnf_mod;
    _ = timezone_mod;
    _ = calendar_mod;
    _ = intervals_mod;
    _ = durations_mod;
    _ = display_names_mod;
    _ = likely_subtags_mod;
    _ = chinese_calendar_mod;
    _ = message_mod;
    _ = charset_mod;
    _ = transliterate_mod;
    _ = list_mod;
    _ = relative_mod;
    _ = units_mod;
    _ = properties;
    _ = scalar_value;
    _ = scalar_cursor;
    _ = word_cursor;
    _ = sentence_cursor;
    _ = break_rules_mod;
}
