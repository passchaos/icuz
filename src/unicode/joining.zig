//! Unicode joining properties and Arabic-style positional-form resolution.
//!
//! This module owns the data-driven joining state machine but deliberately
//! does not own script classification. Callers provide a comptime policy that
//! decides which scalars actually use Arabic-style positional OpenType forms.
//! Keeping that dependency explicit prevents the low-level joining data from
//! depending on the larger script itemizer.

const std = @import("std");
const scalar_value = @import("scalar/root.zig");

/// Unicode Joining_Type values used by cursive-script shaping.
///
/// Joining_Type comes from the generated Unicode 17 page table in `data.bin`.
/// Unlisted codepoints have the normative Non_Joining default.
pub const Type = enum {
    non_joining,
    right,
    left,
    dual,
    join_causing,
    transparent,
};

/// Positional OpenType form selected by the Unicode joining algorithm.
pub const Form = enum {
    none,
    isolated,
    initial,
    medial,
    final,
};

const data = @embedFile("joining/data.bin");
const header_len = 16;
const index_count = readU16(8);
const page_count = readU16(10);
const index_offset = header_len;
const pages_offset = index_offset + @as(usize, index_count) * 2;

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJJ1") or
        data[4] != 1 or data[5] != 17 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid Unicode Joining_Type data");
    }
    if (index_count != 0x1100 or
        pages_offset + @as(usize, page_count) * 256 != data.len)
    {
        @compileError("invalid Unicode Joining_Type data lengths");
    }
    if (readU32(12) != typeFingerprint()) {
        @compileError(
            "Unicode Joining_Type data was generated for a different Type enum",
        );
    }
}

/// Return the exact Unicode 17 Joining_Type for one scalar.
pub inline fn typeForCodepoint(codepoint: u21) Type {
    if (!scalar_value.isValid(codepoint)) return .non_joining;
    // ASCII and most unassigned scalars are Non_Joining; skip the page table.
    if (codepoint < 0x80) return .non_joining;
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(index_offset + page * 2);
    return @enumFromInt(data[
        pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ]);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn typeFingerprint() u32 {
    @setEvalBranchQuota(10_000);
    var hash: u32 = 2166136261;
    inline for (@typeInfo(Type).@"enum".fields) |field| {
        for (field.name) |byte| {
            hash = (hash ^ byte) *% 16777619;
        }
        hash = (hash ^ 0xff) *% 16777619;
    }
    return hash;
}

/// Resolve positional forms in logical text order.
///
/// `Policy` must expose `pub fn hasForms(codepoint: u21) bool`. The policy is a
/// comptime parameter so script classification remains statically bound and
/// adds neither callback storage nor an indirect call to the shaping path.
///
/// Transparent joining characters do not break the connection between their
/// neighbors and receive no positional feature themselves. Scalars rejected by
/// the policy are left as `.none`, so callers may pass mixed-script runs
/// without accidentally enabling positional features for punctuation or digits.
pub fn resolve(
    comptime Policy: type,
    codepoints: []const u21,
    forms: []Form,
) error{InvalidJoiningInput}!void {
    return resolveWithNeighbors(Policy, codepoints, forms, null, null);
}

/// Resolve a logical subrange while retaining the nearest non-transparent
/// joining types on either side. Itemized shaping uses this form so font,
/// script, style, and bidi boundaries do not turn a joining boundary into a
/// word boundary or require copying/rescanning the complete omitted text.
pub fn resolveWithNeighbors(
    comptime Policy: type,
    codepoints: []const u21,
    forms: []Form,
    before: ?Type,
    after: ?Type,
) error{InvalidJoiningInput}!void {
    if (forms.len != codepoints.len) return error.InvalidJoiningInput;
    @memset(forms, .none);

    var previous = before;
    var pending_index: ?usize = null;
    var pending_kind: Type = .non_joining;
    var pending_joins_previous = false;

    for (codepoints, 0..) |codepoint, index| {
        const current = typeForCodepoint(codepoint);
        if (current == .transparent) continue;

        // The next non-transparent character resolves the pending character's
        // right connection. This avoids two repeated directional searches per
        // scalar while preserving transparent-character semantics.
        if (pending_index) |pending| {
            const joins_next = joinsLeft(pending_kind) and joinsRight(current);
            forms[pending] = formForConnections(pending_joins_previous, joins_next);
        }
        pending_index = null;

        if (current != .non_joining and Policy.hasForms(codepoint)) {
            pending_index = index;
            pending_kind = current;
            pending_joins_previous = if (previous) |kind|
                joinsLeft(kind) and joinsRight(current)
            else
                false;
        }
        previous = current;
    }

    if (pending_index) |pending| {
        const joins_next = if (after) |kind|
            joinsLeft(pending_kind) and joinsRight(kind)
        else
            false;
        forms[pending] = formForConnections(
            pending_joins_previous,
            joins_next,
        );
    }
}

fn formForConnections(joins_previous: bool, joins_next: bool) Form {
    return if (joins_previous and joins_next)
        .medial
    else if (joins_previous)
        .final
    else if (joins_next)
        .initial
    else
        .isolated;
}

fn joinsRight(kind: Type) bool {
    return kind == .right or kind == .dual or kind == .join_causing;
}

fn joinsLeft(kind: Type) bool {
    return kind == .left or kind == .dual or kind == .join_causing;
}

fn resolveReference(
    comptime Policy: type,
    codepoints: []const u21,
    forms: []Form,
) error{InvalidJoiningInput}!void {
    if (forms.len != codepoints.len) return error.InvalidJoiningInput;
    @memset(forms, .none);

    // Retain the former bidirectional implementation as a test oracle for the
    // streaming state machine. This is intentionally not used by shaping.
    for (codepoints, 0..) |codepoint, index| {
        const current = typeForCodepoint(codepoint);
        if (current == .transparent or current == .non_joining or !Policy.hasForms(codepoint)) continue;

        var previous: ?Type = null;
        var previous_index = index;
        while (previous_index > 0) {
            previous_index -= 1;
            const kind = typeForCodepoint(codepoints[previous_index]);
            if (kind == .transparent) continue;
            previous = kind;
            break;
        }

        var next: ?Type = null;
        var next_index = index + 1;
        while (next_index < codepoints.len) : (next_index += 1) {
            const kind = typeForCodepoint(codepoints[next_index]);
            if (kind == .transparent) continue;
            next = kind;
            break;
        }

        const joins_previous = if (previous) |kind| joinsLeft(kind) and joinsRight(current) else false;
        const joins_next = if (next) |kind| joinsLeft(current) and joinsRight(kind) else false;
        forms[index] = formForConnections(joins_previous, joins_next);
    }
}

const TestPolicy = struct {
    pub fn hasForms(codepoint: u21) bool {
        // Mirror the root module's script policy without exposing its private
        // itemizer predicates solely for this white-box state-machine test.
        return (codepoint >= 0x0600 and codepoint <= 0x06FF) or
            (codepoint >= 0x0750 and codepoint <= 0x077F) or
            (codepoint >= 0x0870 and codepoint <= 0x08FF) or
            (codepoint >= 0x10EFD and codepoint <= 0x10EFF) or
            (codepoint >= 0xFB50 and codepoint <= 0xFDFF) or
            (codepoint >= 0xFE70 and codepoint <= 0xFEFC) or
            (codepoint >= 0x1800 and codepoint <= 0x18AF) or
            (codepoint >= 0x1E900 and codepoint <= 0x1E94B) or
            (codepoint >= 0x1E950 and codepoint <= 0x1E959) or
            (codepoint >= 0x1E95E and codepoint <= 0x1E95F) or
            (codepoint >= 0xA840 and codepoint <= 0xA877);
    }
};

test "streaming Arabic joining forms match bidirectional reference" {
    const alphabet = [_]u21{
        0x0628, // Arabic dual joining.
        0x0627, // Arabic right joining.
        0x0621, // Arabic non-joining.
        0x064E, // Arabic transparent.
        0x200D, // Join-causing ZWJ.
        0x200C, // Non-joining ZWNJ.
        0x0712, // Non-Arabic dual-joining Syriac.
        ' ', // Neutral non-joining separator.
    };
    var codepoints: [4]u21 = undefined;
    var expected: [4]Form = undefined;
    var actual: [4]Form = undefined;

    for (1..codepoints.len + 1) |len| {
        var combination_count: usize = 1;
        for (0..len) |_| combination_count *= alphabet.len;
        for (0..combination_count) |encoded| {
            var remaining = encoded;
            for (codepoints[0..len]) |*codepoint| {
                codepoint.* = alphabet[remaining % alphabet.len];
                remaining /= alphabet.len;
            }
            try resolveReference(TestPolicy, codepoints[0..len], expected[0..len]);
            try resolve(TestPolicy, codepoints[0..len], actual[0..len]);
            try std.testing.expectEqualSlices(Form, expected[0..len], actual[0..len]);
        }
    }
}
