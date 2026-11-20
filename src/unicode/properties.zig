//! Standard Unicode scalar properties.
//!
//! This module exposes only Unicode-defined predicates. Shaping, editor, and
//! display-width policy belongs in the consuming library.

const mark = @import("mark/root.zig");

pub const general_category = @import("properties/general_category.zig");
pub const aliases = @import("properties/aliases.zig");

pub const Category = general_category.Category;
pub const BinaryProperty = general_category.BinaryProperty;
pub const category = general_category.category;
pub const categoryMask = general_category.categoryMask;
pub const matchesCategoryMask = general_category.matchesMask;
pub const has = general_category.has;
pub const hasBinaryProperty = general_category.has;
pub const binaryPropertyFromAlias = aliases.binaryPropertyFromAlias;

pub const isWhiteSpace = general_category.isWhiteSpace;
pub const isAlphabetic = general_category.isAlphabetic;
pub const isUppercase = general_category.isUppercase;
pub const isLowercase = general_category.isLowercase;
pub const isMath = general_category.isMath;
pub const isDefaultIgnorableCodePoint =
    general_category.isDefaultIgnorableCodePoint;

pub const isIdStart = general_category.isIdStart;
pub const isIdContinue = general_category.isIdContinue;
pub const isXidStart = general_category.isXidStart;
pub const isXidContinue = general_category.isXidContinue;
pub const isCaseIgnorable = general_category.isCaseIgnorable;
pub const isCased = general_category.isCased;
pub const isGraphemeBase = general_category.isGraphemeBase;
pub const isGraphemeExtend = general_category.isGraphemeExtend;
pub const isPatternSyntax = general_category.isPatternSyntax;
pub const isPatternWhiteSpace = general_category.isPatternWhiteSpace;
pub const isQuotationMark = general_category.isQuotationMark;
pub const isSoftDotted = general_category.isSoftDotted;
pub const isTerminalPunctuation = general_category.isTerminalPunctuation;
pub const isUnifiedIdeograph = general_category.isUnifiedIdeograph;
pub const isVariationSelector = general_category.isVariationSelector;
pub const isBidiControl = general_category.isBidiControl;
pub const isJoinControl = general_category.isJoinControl;
pub const isEmoji = general_category.isEmoji;
pub const isEmojiComponent = general_category.isEmojiComponent;
pub const isEmojiModifierBase = general_category.isEmojiModifierBase;
pub const isEmojiPresentation = general_category.isEmojiPresentation;
pub const isExtendedPictographic = general_category.isExtendedPictographic;
pub const isNoncharacterCodePoint = general_category.isNoncharacterCodePoint;

pub const isNonspacingMark = mark.isNonspacing;

pub const numeric = @import("properties/numeric.zig");
pub const NumericType = numeric.NumericType;
pub const numericValue = numeric.numericValue;
pub const numericType = numeric.numericType;
pub const digitValue = numeric.digitValue;

/// Exact Unicode 17.0 General_Category=L (Lu, Ll, Lt, Lm, Lo).
/// Numbers, marks, unassigned codepoints and invalid scalar values are false.
pub fn isLetter(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0x1f);
}

/// General_Category=M (Mn, Mc, Me).
pub fn isMark(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0xe0);
}

/// General_Category=N (Nd, Nl, No).
pub fn isNumber(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0x700);
}

/// General_Category=Nd.
pub fn isDecimalNumber(codepoint: u21) bool {
    return category(codepoint) == .Nd;
}

/// General_Category=P (Pc, Pd, Ps, Pe, Pi, Pf, Po).
pub fn isPunctuation(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0x3f800);
}

/// General_Category=S (Sm, Sc, Sk, So).
pub fn isSymbol(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0x3c0000);
}

/// General_Category=Z (Zs, Zl, Zp).
pub fn isSeparator(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0x1c00000);
}

/// General_Category=C (Cc, Cf, Cs, Co, Cn).
pub fn isControl(codepoint: u21) bool {
    return matchesCategoryMask(codepoint, 0x3e000000);
}

pub fn isEmojiModifier(codepoint: u21) bool {
    return codepoint >= 0x1f3fb and codepoint <= 0x1f3ff;
}

pub fn isEmojiTag(codepoint: u21) bool {
    return codepoint >= 0xe0020 and codepoint <= 0xe007f;
}

pub fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

pub fn isZeroWidthJoiner(codepoint: u21) bool {
    return codepoint == 0x200d;
}

pub fn isBidiFormattingControl(codepoint: u21) bool {
    return codepoint == 0x061c or
        (codepoint >= 0x200e and codepoint <= 0x200f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
}

test "standard Unicode properties" {
    const testing = @import("std").testing;
    try testing.expect(isLetter('A'));
    try testing.expect(!isLetter('0'));
    try testing.expect(isMark(0x0301));
    try testing.expect(isNumber('0'));
    try testing.expect(isDecimalNumber('0'));
    try testing.expect(isPunctuation(','));
    try testing.expect(isSymbol('+'));
    try testing.expect(isSeparator(' '));
    try testing.expect(isWhiteSpace(' '));
    try testing.expect(isAlphabetic('A'));
    try testing.expect(isUppercase('A'));
    try testing.expect(isLowercase('a'));
    try testing.expect(isNonspacingMark(0x0301));
    try testing.expect(isVariationSelector(0xfe0f));
    try testing.expect(isEmojiModifier(0x1f3fd));
    try testing.expect(isEmojiTag(0xe0067));
    try testing.expect(isRegionalIndicator(0x1f1e8));
    try testing.expect(isZeroWidthJoiner(0x200d));
    try testing.expect(isBidiFormattingControl(0x2067));
    try testing.expect(!isBidiFormattingControl('A'));
    try testing.expectEqual(Category.Lu, category('A'));
    try testing.expectEqual(Category.Ll, category('a'));
    try testing.expectEqual(Category.Nd, category('0'));
    try testing.expectEqual(Category.Cn, category(0x0378));
}

test {
    _ = general_category;
    _ = aliases;
}
