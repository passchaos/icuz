//! Shared Unicode 17 sentence-boundary state and generated properties.

const std = @import("std");
const scalar_value = @import("../scalar/root.zig");
const data = @embedFile("data.bin");
pub const unicode_version = [3]u8{ 17, 0, 0 };

pub const Class = enum(u4) {
    other,
    cr,
    lf,
    sep,
    extend,
    format,
    space,
    lower,
    upper,
    other_letter,
    numeric,
    a_term,
    s_term,
    close,
    s_continue,
};

const Header = struct {
    index_count: usize,
    page_count: usize,
    index_offset: usize,
    pages_offset: usize,
};

const header = parseHeader();

pub const TerminatorContext = struct {
    class: Class,
    saw_space: bool = false,
};

pub const BoundaryState = struct {
    previous_actual: Class = .other,
    previous_significant: Class = .other,
    last_significant: Class = .other,
    terminator: ?TerminatorContext = null,

    pub fn consume(self: *BoundaryState, class: Class) void {
        self.previous_actual = class;
        if (isIgnored(class)) return;

        self.previous_significant = self.last_significant;
        self.last_significant = class;
        if (isSentenceTerminator(class)) {
            self.terminator = .{ .class = class };
            return;
        }
        if (self.terminator) |*terminator| {
            if (class == .close and !terminator.saw_space) return;
            if (class == .space) {
                terminator.saw_space = true;
                return;
            }
        }
        self.terminator = null;
    }
};

pub fn isIgnored(class: Class) bool {
    return class == .extend or class == .format;
}

pub fn isParagraphSeparator(class: Class) bool {
    return class == .sep or class == .cr or class == .lf;
}

pub fn isSentenceTerminator(class: Class) bool {
    return class == .a_term or class == .s_term;
}

const ascii_classes = blk: {
    @setEvalBranchQuota(10_000);
    var table: [128]Class = undefined;
    for (0..128) |codepoint| {
        table[codepoint] = classForCodepointSlow(@intCast(codepoint));
    }
    break :blk table;
};

pub inline fn classForCodepoint(codepoint: u21) Class {
    if (codepoint < 0x80) return ascii_classes[codepoint];
    return classForCodepointSlow(codepoint);
}

fn classForCodepointSlow(codepoint: u21) Class {
    if (!scalar_value.isValid(codepoint)) return .other;
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(header.index_offset + page * 2);
    return @enumFromInt(data[
        header.pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ]);
}

fn parseHeader() Header {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "CJSB") or
        data[4] != 1 or data[5] != unicode_version[0] or
        data[6] != unicode_version[1] or data[7] != unicode_version[2])
    {
        @compileError("invalid sentence-break data");
    }
    const index_count = readU16(8);
    const page_count = readU16(10);
    const index_offset = 12;
    const pages_offset = index_offset + index_count * 2;
    if (index_count != 0x1100 or
        pages_offset + page_count * 256 != data.len)
    {
        @compileError("invalid sentence-break data lengths");
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

/// SB3-SB7 precede terminator context and SB8 lookahead.
pub fn immediateBreak(current: Class, state: *const BoundaryState) ?bool {
    // SB3.
    if (state.previous_actual == .cr and current == .lf) return false;
    // SB4 is evaluated before ignore replacement. Starting a fresh state
    // after this boundary prevents leading Extend/Format characters from
    // seeing the separator in the previous segment.
    if (isParagraphSeparator(state.previous_actual)) return true;
    // SB5.
    if (isIgnored(current)) return false;
    // SB6.
    if (state.last_significant == .a_term and current == .numeric) {
        return false;
    }
    // SB7.
    if ((state.previous_significant == .upper or
        state.previous_significant == .lower) and
        state.last_significant == .a_term and current == .upper)
    {
        return false;
    }

    return null;
}

/// SB8-SB998, with a monotonic source-specific lower lookahead.
pub fn contextualBreak(current: Class, state: *const BoundaryState, lower_follows: bool) bool {
    const terminator = state.terminator orelse return false; // SB998.
    // SB8. The cached forward query ignores Extend/Format and stops at the
    // first Lower or a class that the rule explicitly excludes.
    if (terminator.class == .a_term and lower_follows) {
        return false;
    }
    // SB8a.
    if (current == .s_continue or isSentenceTerminator(current)) {
        return false;
    }
    // SB9 / SB10.
    if (current == .close and !terminator.saw_space) return false;
    if (current == .space or isParagraphSeparator(current)) return false;
    // SB11.
    return true;
}
