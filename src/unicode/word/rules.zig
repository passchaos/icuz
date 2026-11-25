//! Shared Unicode 17 word-boundary semantics and generated properties.

const std = @import("std");
const scalar_value = @import("../scalar/root.zig");
const data = @embedFile("data.bin");
pub const unicode_version = [3]u8{ 17, 0, 0 };

pub const Class = enum(u5) {
    other,
    cr,
    lf,
    newline,
    extend,
    format,
    katakana,
    a_letter,
    mid_letter,
    mid_num,
    mid_num_let,
    numeric,
    extend_num_let,
    regional_indicator,
    hebrew_letter,
    single_quote,
    double_quote,
    zwj,
    wseg_space,
};

pub const Properties = packed struct(u8) {
    class: Class,
    extended_pictographic: bool,
    word_anchor: bool,
    /// Exact Unicode 17 General_Category=L, independent from word anchors.
    letter: bool,
};

const Header = struct {
    index_count: usize,
    page_count: usize,
    index_offset: usize,
    pages_offset: usize,
};

const header = parseHeader();

pub fn isNewline(class: Class) bool {
    return class == .newline or class == .cr or class == .lf;
}

pub fn isIgnored(class: Class) bool {
    return class == .extend or class == .format or class == .zwj;
}

pub fn isAhLetter(class: Class) bool {
    return class == .a_letter or class == .hebrew_letter;
}

pub fn isMidNumLetQ(class: Class) bool {
    return class == .mid_num_let or class == .single_quote;
}

pub fn isLetterMid(class: Class) bool {
    return class == .mid_letter or isMidNumLetQ(class);
}

pub fn isNumericMid(class: Class) bool {
    return class == .mid_num or isMidNumLetQ(class);
}

pub fn isExtendNumLetLeft(class: Class) bool {
    return isAhLetter(class) or class == .numeric or class == .katakana or
        class == .extend_num_let;
}

pub fn isExtendNumLetRight(class: Class) bool {
    return isAhLetter(class) or class == .numeric or class == .katakana;
}

pub fn properties(codepoint: u21) Properties {
    if (!scalar_value.isValid(codepoint)) return .{
        .class = .other,
        .extended_pictographic = false,
        .word_anchor = false,
        .letter = false,
    };
    return propertiesAssumeValid(codepoint);
}

/// Property lookup for a scalar the caller's decoder already proved valid.
pub inline fn propertiesAssumeValid(codepoint: u21) Properties {
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(header.index_offset + page * 2);
    const value = data[
        header.pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ];
    return @bitCast(value);
}

fn parseHeader() Header {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "CJWB") or
        data[4] != 2 or data[5] != unicode_version[0] or
        data[6] != unicode_version[1] or data[7] != unicode_version[2])
    {
        @compileError("invalid word-break data");
    }
    const index_count = readU16(8);
    const page_count = readU16(10);
    const index_offset = 12;
    const pages_offset = index_offset + index_count * 2;
    if (index_count != 0x1100 or
        pages_offset + page_count * 256 != data.len)
    {
        @compileError("invalid word-break data lengths");
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

/// Rules WB3-WB4 use adjacent scalars before ignored-class replacement.
pub fn adjacentBreak(previous: Properties, current: Properties) ?bool {
    // WB3.
    if (previous.class == .cr and
        current.class == .lf) return false;
    // WB3a / WB3b. These precede WB4: ignored characters immediately after a
    // newline start their own segment instead of attaching to the control.
    if (isNewline(previous.class) or
        isNewline(current.class)) return true;
    // WB3c is intentionally adjacent. ZWJ followed by Extend then an extended
    // pictograph does not match, because WB4 removes that ZWJ from rule input.
    if (previous.class == .zwj and
        current.extended_pictographic) return false;
    // WB3d is also evaluated before ignore replacement.
    if (previous.class == .wseg_space and
        current.class == .wseg_space) return false;
    // WB4.
    if (isIgnored(current.class)) return false;

    return null;
}

/// WB5-WB999 after ignored-class replacement.
pub fn significantBreak(previous: Class, previous_previous: Class, current: Class, next: Class, regional_indicator_odd: bool) bool {
    if (isNewline(previous)) return true;
    // WB5.
    if (isAhLetter(previous) and
        isAhLetter(current)) return false;
    // WB6 / WB7.
    if (isAhLetter(previous) and
        isLetterMid(current) and
        isAhLetter(next)) return false;
    if (isAhLetter(previous_previous) and
        isLetterMid(previous) and
        isAhLetter(current)) return false;
    // WB7a / WB7b / WB7c.
    if (previous == .hebrew_letter and
        current == .single_quote) return false;
    if (previous == .hebrew_letter and
        current == .double_quote and
        next == .hebrew_letter) return false;
    if (previous_previous == .hebrew_letter and
        previous == .double_quote and
        current == .hebrew_letter) return false;
    // WB8–WB10.
    if (previous == .numeric and
        current == .numeric) return false;
    if (isAhLetter(previous) and
        current == .numeric) return false;
    if (previous == .numeric and
        isAhLetter(current)) return false;
    // WB11 / WB12.
    if (previous_previous == .numeric and
        isNumericMid(previous) and
        current == .numeric) return false;
    if (previous == .numeric and
        isNumericMid(current) and
        next == .numeric) return false;
    // WB13.
    if (previous == .katakana and
        current == .katakana) return false;
    // WB13a / WB13b.
    if (isExtendNumLetLeft(previous) and
        current == .extend_num_let) return false;
    if (previous == .extend_num_let and
        isExtendNumLetRight(current)) return false;
    // WB15 / WB16.
    if (previous == .regional_indicator and
        current == .regional_indicator and
        regional_indicator_odd) return false;

    // WB999.
    return true;
}

/// Only mid-letter, numeric-mid, and Hebrew double-quote cases need WB lookahead.
pub fn needsLookahead(previous: Class, current: Class) bool {
    return (isAhLetter(previous) and isLetterMid(current)) or
        (previous == .numeric and isNumericMid(current)) or
        (previous == .hebrew_letter and current == .double_quote);
}
