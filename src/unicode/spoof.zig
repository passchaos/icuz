//! UTS #39 confusable detection and identifier status.
//!
//! A skeleton is computed by NFD-normalizing the input, replacing every code
//! point with its prototype from the Unicode security data, and
//! NFD-normalizing the result. Two strings are confusable when their
//! skeletons match. `identifierAllowed` checks the Identifier_Status set.

const std = @import("std");
const scalar = @import("scalar/root.zig");
const normalization = @import("normalization/root.zig");
const case = @import("case/root.zig");
const properties = @import("properties.zig");
const script = @import("script/root.zig");
const script_extensions = @import("script_extensions/root.zig");
const set_mod = @import("set.zig");
const bidi_paragraph = @import("bidi/paragraph.zig");

const blob = @embedFile("spoof/confusables_data.bin");
const conformance = @embedFile("spoof/conformance.bin");
const identifier_blob = @embedFile("spoof/identifier_status.bin");

const header_len = 16;
const record_count = readU32(8);
const pool_length = readU32(12);
const records_offset = header_len;
const pool_offset = records_offset + @as(usize, record_count) * 12;

const identifier_header_len = 12;
const identifier_range_count = std.mem.readInt(
    u32,
    identifier_blob[8..12],
    .little,
);
const identifier_ranges_offset = identifier_header_len;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJXC") or
        blob[4] != 1)
    {
        @compileError("invalid confusables data");
    }
    if (pool_offset + @as(usize, pool_length) * 4 != blob.len) {
        @compileError("invalid confusables data lengths");
    }
    if (identifier_blob.len < identifier_header_len or
        !std.mem.eql(u8, identifier_blob[0..4], "CJXI") or
        identifier_blob[4] != 1)
    {
        @compileError("invalid identifier status data");
    }
    if (identifier_ranges_offset +
        @as(usize, identifier_range_count) * 8 != identifier_blob.len)
    {
        @compileError("invalid identifier status data lengths");
    }
}

pub const Error = error{ InvalidUtf8, InvalidState, OutOfMemory };

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

/// Longest prototype sequence in the pinned confusables data.
pub const max_mapping_length = 18;

/// Prototype sequence for a code point, or null when it maps to itself.
/// The values are read into `buffer` because the embedded blob has byte
/// alignment.
pub fn mappingInto(
    codepoint: u21,
    buffer: *[max_mapping_length]u32,
) ?[]const u32 {
    var low: usize = 0;
    var high: usize = record_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = records_offset + middle * 12;
        const source = readU32(base);
        if (source < codepoint) {
            low = middle + 1;
        } else if (source > codepoint) {
            high = middle;
        } else {
            const offset = readU32(base + 4);
            const length = blob[base + 8];
            std.debug.assert(length <= max_mapping_length);
            const start = pool_offset + @as(usize, offset) * 4;
            for (0..length) |index| {
                buffer[index] = readU32(start + index * 4);
            }
            return buffer[0..length];
        }
    }
    return null;
}

/// True when the code point's Identifier_Status is Allowed.
pub fn isAllowedIdentifier(codepoint: u21) bool {
    var low: usize = 0;
    var high: usize = identifier_range_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = identifier_ranges_offset + middle * 8;
        const start = std.mem.readInt(
            u32,
            identifier_blob[base..][0..4],
            .little,
        );
        const end = std.mem.readInt(
            u32,
            identifier_blob[base + 4 ..][0..4],
            .little,
        );
        if (codepoint < start) {
            high = middle;
        } else if (codepoint > end) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// True when every code point in `text` has Identifier_Status=Allowed and
/// the string is not empty. This checks status only; confusable and script
/// restrictions are separate checks.
pub fn identifierAllowed(text: []const u8) Error!bool {
    if (text.len == 0) return false;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidatingPacked(text, cursor);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        if (!isAllowedIdentifier(scalar.packedCodepoint(decoded))) return false;
        cursor += scalar.packedLength(decoded);
    }
    return true;
}

/// UTS #39 restriction levels, most restrictive first.
pub const RestrictionLevel = enum {
    ascii_only,
    single_script,
    highly_restrictive,
    moderately_restrictive,
    minimally_restrictive,
    unrestricted,
};

const script_count = @typeInfo(script.Script).@"enum".fields.len;
const ScriptSet = std.StaticBitSet(script_count + 3);

// UTS #39 augments script sets with the composite script codes Jpan, Kore,
// and Hanb, which are not Script property values.
const jpan_bit = script_count;
const kore_bit = script_count + 1;
const hanb_bit = script_count + 2;

fn augmentedScriptSet(codepoint: u21) ScriptSet {
    var set = ScriptSet.initEmpty();
    const extensions = script_extensions.forCodepoint(codepoint);
    var index: usize = 0;
    while (index < extensions.len()) : (index += 1) {
        const value = extensions.at(index) orelse continue;
        set.set(@intFromEnum(value));
    }
    if (set.isSet(@intFromEnum(script.Script.common)) or
        set.isSet(@intFromEnum(script.Script.inherited)))
    {
        return ScriptSet.initFull();
    }
    if (set.isSet(@intFromEnum(script.Script.han))) {
        set.set(hanb_bit);
        set.set(jpan_bit);
        set.set(kore_bit);
    }
    if (set.isSet(@intFromEnum(script.Script.hiragana)) or
        set.isSet(@intFromEnum(script.Script.katakana)))
    {
        set.set(jpan_bit);
    }
    if (set.isSet(@intFromEnum(script.Script.hangul))) set.set(kore_bit);
    if (set.isSet(@intFromEnum(script.Script.bopomofo))) set.set(hanb_bit);
    return set;
}

fn decodeCodepoint(
    text: []const u8,
    cursor: *usize,
) Error!u21 {
    if (cursor.* >= text.len) return error.InvalidUtf8;
    const decoded = scalar.decodeValidatingPacked(text, cursor.*);
    if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
    cursor.* += scalar.packedLength(decoded);
    return scalar.packedCodepoint(decoded);
}

/// Characters accepted by a spoof checker's restriction-level and
/// character-limit checks.
pub const AllowedChars = union(enum) {
    /// Every code point is allowed, ICU's default for `uspoof_open`.
    all,
    /// Only Identifier_Status=Allowed code points.
    identifier_status,
    /// An explicit UnicodeSet, as set by `uspoof_setAllowedChars`.
    set: *const set_mod.Set,

    pub fn contains(self: AllowedChars, codepoint: u21) bool {
        return switch (self) {
            .all => true,
            .identifier_status => isAllowedIdentifier(codepoint),
            .set => |value| value.contains(codepoint),
        };
    }
};

fn scriptSetsIntersect(a: ScriptSet, b: ScriptSet) bool {
    var intersection = a;
    intersection.setIntersection(b);
    return !intersection.eql(ScriptSet.initEmpty());
}

fn computeRestrictionLevel(
    text: []const u8,
    allowed: AllowedChars,
) Error!RestrictionLevel {
    var ascii = true;
    var resolved = ScriptSet.initFull();
    var resolved_without_latin = ScriptSet.initFull();
    var has_without_latin = false;

    var cursor: usize = 0;
    while (cursor < text.len) {
        const codepoint = try decodeCodepoint(text, &cursor);
        if (!allowed.contains(codepoint)) return .unrestricted;
        if (codepoint > 0x7F) ascii = false;
        const set = augmentedScriptSet(codepoint);
        resolved.setIntersection(set);
        if (!set.isSet(@intFromEnum(script.Script.latin))) {
            has_without_latin = true;
            resolved_without_latin.setIntersection(set);
        }
    }

    if (ascii) return .ascii_only;
    if (!resolved.eql(ScriptSet.initEmpty())) return .single_script;
    if (has_without_latin and
        (resolved_without_latin.isSet(kore_bit) or
            resolved_without_latin.isSet(hanb_bit) or
            resolved_without_latin.isSet(jpan_bit)))
    {
        return .highly_restrictive;
    }
    if (has_without_latin and
        !resolved_without_latin.isSet(@intFromEnum(script.Script.cyrillic)) and
        !resolved_without_latin.isSet(@intFromEnum(script.Script.greek)) and
        !resolved_without_latin.isSet(@intFromEnum(script.Script.cherokee)))
    {
        return .moderately_restrictive;
    }
    return .minimally_restrictive;
}

/// Compute the UTS #39 restriction level of an identifier.
///
/// The default identifier profile is Identifier_Status=Allowed, so strings
/// containing disallowed characters (spaces, emoji, ...) are Unrestricted.
/// ICU's checker defaults to allowing every code point instead; use
/// `Checker` for that behavior.
pub fn restrictionLevel(text: []const u8) Error!RestrictionLevel {
    return computeRestrictionLevel(text, .identifier_status);
}

fn decimalDigitValue(codepoint: u21) ?u8 {
    if (properties.category(codepoint) != .Nd) return null;
    var zero = codepoint;
    while (zero > 0 and properties.category(zero - 1) == .Nd) zero -= 1;
    return @intCast((@as(u32, codepoint) - @as(u32, zero)) % 10);
}

/// True when the string mixes decimal number systems (UTS #39 section 5.3,
/// matching ICU's `getNumerics`: only Numeric_Type=Decimal characters are
/// counted).
pub fn hasMixedNumbers(text: []const u8) Error!bool {
    var zero: ?u21 = null;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const codepoint = try decodeCodepoint(text, &cursor);
        if (properties.category(codepoint) != .Nd) continue;
        const value = decimalDigitValue(codepoint) orelse continue;
        const zero_codepoint: u21 = @intCast(codepoint - value);
        if (zero) |existing| {
            if (existing != zero_codepoint) return true;
        } else {
            zero = zero_codepoint;
        }
    }
    return false;
}

/// True when the string's resolved script set is empty, i.e. its scripts
/// have no common member (UTS #39 mixed-script detection).
pub fn isMixedScript(text: []const u8) Error!bool {
    var resolved = ScriptSet.initFull();
    var seen = false;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const codepoint = try decodeCodepoint(text, &cursor);
        resolved.setIntersection(augmentedScriptSet(codepoint));
        seen = true;
    }
    return seen and resolved.eql(ScriptSet.initEmpty());
}

fn resolvedScriptSet(text: []const u8) Error!ScriptSet {
    var resolved = ScriptSet.initFull();
    var cursor: usize = 0;
    while (cursor < text.len) {
        const codepoint = try decodeCodepoint(text, &cursor);
        resolved.setIntersection(augmentedScriptSet(codepoint));
    }
    return resolved;
}

/// ICU `uspoof` check bits.
pub const Checks = struct {
    pub const single_script_confusable: u32 = 0x1;
    pub const mixed_script_confusable: u32 = 0x2;
    pub const whole_script_confusable: u32 = 0x4;
    pub const confusable: u32 = 0x7;
    pub const restriction_level: u32 = 0x10;
    pub const invisible: u32 = 0x20;
    pub const char_limit: u32 = 0x40;
    pub const mixed_numbers: u32 = 0x80;
    pub const hidden_overlay: u32 = 0x100;
    pub const all: u32 = 0xFFFF;
    pub const aux_info: u32 = 0x40000000;
};

/// ICU `URestrictionLevel` flag values.
pub fn restrictionLevelFlag(level: RestrictionLevel) u32 {
    return switch (level) {
        .ascii_only => 0x10000000,
        .single_script => 0x20000000,
        .highly_restrictive => 0x30000000,
        .moderately_restrictive => 0x40000000,
        .minimally_restrictive => 0x50000000,
        .unrestricted => 0x60000000,
    };
}

pub const CheckResult = struct {
    /// Failure bits, excluding the AUX_INFO restriction-level bits.
    checks: u32 = 0,
    /// Populated when the restriction-level check is enabled.
    restriction_level: ?RestrictionLevel = null,

    /// ICU's combined bitmask: OR in the restriction level when
    /// `Checks.aux_info` is enabled.
    pub fn bitmask(self: CheckResult, enabled: u32) u32 {
        if (enabled & Checks.aux_info != 0) {
            if (self.restriction_level) |level| {
                return self.checks | restrictionLevelFlag(level);
            }
        }
        return self.checks;
    }
};

/// ICU `USpoofChecker`-compatible configuration.
pub const Checker = struct {
    checks: u32 = Checks.all,
    restriction_level: RestrictionLevel = .highly_restrictive,
    allowed: AllowedChars = .all,

    pub fn init() Checker {
        return .{};
    }

    pub fn setChecks(self: *Checker, checks: u32) void {
        self.checks = checks & (Checks.all | Checks.aux_info);
    }

    pub fn getChecks(self: *const Checker) u32 {
        return self.checks;
    }

    /// Set the loosest accepted restriction level, enabling the check.
    pub fn setRestrictionLevel(
        self: *Checker,
        level: RestrictionLevel,
    ) void {
        self.restriction_level = level;
        self.checks |= Checks.restriction_level;
    }

    pub fn getRestrictionLevel(self: *const Checker) RestrictionLevel {
        return self.restriction_level;
    }

    /// Restrict accepted characters to `chars`, enabling the char-limit
    /// check. The set is borrowed and must outlive the checker's use.
    pub fn setAllowedChars(self: *Checker, chars: *const set_mod.Set) void {
        self.allowed = .{ .set = chars };
        self.checks |= Checks.char_limit;
    }

    /// Run the enabled checks and return ICU's failure bitmask.
    pub fn checkAlloc(
        self: *const Checker,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) Error!u32 {
        const result = try self.checkResultAlloc(allocator, text);
        return result.bitmask(self.checks);
    }

    pub fn checkResultAlloc(
        self: *const Checker,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) Error!CheckResult {
        var result = CheckResult{};
        if (self.checks & Checks.restriction_level != 0) {
            const level = try computeRestrictionLevel(text, self.allowed);
            if (@intFromEnum(level) > @intFromEnum(self.restriction_level)) {
                result.checks |= Checks.restriction_level;
            }
            result.restriction_level = level;
        }
        if (self.checks & Checks.mixed_numbers != 0 and
            try hasMixedNumbers(text))
        {
            result.checks |= Checks.mixed_numbers;
        }
        if (self.checks & Checks.hidden_overlay != 0 and
            try hasHiddenOverlay(text))
        {
            result.checks |= Checks.hidden_overlay;
        }
        if (self.checks & Checks.char_limit != 0 and
            !try self.allowsAll(text))
        {
            result.checks |= Checks.char_limit;
        }
        if (self.checks & Checks.invisible != 0 and
            try hasInvisibleMarks(allocator, text))
        {
            result.checks |= Checks.invisible;
        }
        return result;
    }

    /// Classify two strings as ICU's `uspoof_areConfusableUTF8` does.
    /// Returns a bitmask of `single_script_confusable`,
    /// `mixed_script_confusable`, and `whole_script_confusable`, masked by
    /// the enabled confusable checks. Returns `error.InvalidState` when no
    /// confusable check is enabled.
    pub fn areConfusableAlloc(
        self: *const Checker,
        allocator: std.mem.Allocator,
        a: []const u8,
        b: []const u8,
        case_fold: bool,
    ) Error!u32 {
        if (self.checks & Checks.confusable == 0) return error.InvalidState;

        var folded_a: ?[]u8 = null;
        defer if (folded_a) |owned| allocator.free(owned);
        var folded_b: ?[]u8 = null;
        defer if (folded_b) |owned| allocator.free(owned);
        var first = a;
        var second = b;
        if (case_fold) {
            folded_a = try case.foldAlloc(allocator, a);
            folded_b = try case.foldAlloc(allocator, b);
            first = folded_a.?;
            second = folded_b.?;
        }

        var skeleton_a = std.ArrayList(u21).empty;
        defer skeleton_a.deinit(allocator);
        var skeleton_b = std.ArrayList(u21).empty;
        defer skeleton_b.deinit(allocator);
        try skeletonCodepointsInto(allocator, first, &skeleton_a);
        try skeletonCodepointsInto(allocator, second, &skeleton_b);
        if (!std.mem.eql(u21, skeleton_a.items, skeleton_b.items)) return 0;
        return self.confusableClass(first, second);
    }

    /// Classify two strings whose skeletons match.
    fn confusableClass(
        self: *const Checker,
        first: []const u8,
        second: []const u8,
    ) Error!u32 {
        const resolved_a = try resolvedScriptSet(first);
        const resolved_b = try resolvedScriptSet(second);
        var result: u32 = 0;
        if (scriptSetsIntersect(resolved_a, resolved_b)) {
            result |= Checks.single_script_confusable;
        } else {
            result |= Checks.mixed_script_confusable;
            if (!resolved_a.eql(ScriptSet.initEmpty()) and
                !resolved_b.eql(ScriptSet.initEmpty()))
            {
                result |= Checks.whole_script_confusable;
            }
        }
        return result & self.checks;
    }

    /// ICU `uspoof_getBidiSkeletonUTF8`: reorder with the given base
    /// direction, keeping base combining marks and mirroring, then compute
    /// the confusable skeleton.
    pub fn bidiSkeletonAlloc(
        self: *const Checker,
        allocator: std.mem.Allocator,
        text: []const u8,
        direction: bidi_paragraph.BaseDirection,
    ) Error![]u8 {
        _ = self;
        return bidiSkeletonImpl(allocator, text, direction);
    }

    /// ICU `uspoof_areBidiConfusableUTF8`.
    pub fn areBidiConfusableAlloc(
        self: *const Checker,
        allocator: std.mem.Allocator,
        a: []const u8,
        b: []const u8,
        direction: bidi_paragraph.BaseDirection,
        case_fold: bool,
    ) Error!u32 {
        if (self.checks & Checks.confusable == 0) return error.InvalidState;

        var folded_a: ?[]u8 = null;
        defer if (folded_a) |owned| allocator.free(owned);
        var folded_b: ?[]u8 = null;
        defer if (folded_b) |owned| allocator.free(owned);
        var first = a;
        var second = b;
        if (case_fold) {
            folded_a = try case.foldAlloc(allocator, a);
            folded_b = try case.foldAlloc(allocator, b);
            first = folded_a.?;
            second = folded_b.?;
        }

        const skeleton_a = try bidiSkeletonImpl(allocator, first, direction);
        defer allocator.free(skeleton_a);
        const skeleton_b = try bidiSkeletonImpl(allocator, second, direction);
        defer allocator.free(skeleton_b);
        if (!std.mem.eql(u8, skeleton_a, skeleton_b)) return 0;
        return self.confusableClass(first, second);
    }

    fn allowsAll(self: *const Checker, text: []const u8) Error!bool {
        var cursor: usize = 0;
        while (cursor < text.len) {
            const codepoint = try decodeCodepoint(text, &cursor);
            if (!self.allowed.contains(codepoint)) return false;
        }
        return true;
    }
};

fn isIllegalDotLeadCharacterNoLookup(codepoint: u21) bool {
    return codepoint == 'i' or codepoint == 'j' or codepoint == 0x0131 or
        codepoint == 0x0237 or codepoint == 'l' or
        properties.isSoftDotted(codepoint);
}

fn isIllegalDotLeadCharacter(codepoint: u21) bool {
    if (isIllegalDotLeadCharacterNoLookup(codepoint)) return true;
    var buffer: [max_mapping_length]u32 = undefined;
    const target = mappingInto(codepoint, &buffer) orelse return false;
    if (target.len == 0) return false;
    const final: u21 = @intCast(target[target.len - 1]);
    return final != codepoint and isIllegalDotLeadCharacterNoLookup(final);
}

/// True when the string contains a combining dot above after a character
/// whose prototype is soft-dotted, ICU's hidden-overlay check.
pub fn hasHiddenOverlay(text: []const u8) Error!bool {
    var saw_lead = false;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const codepoint = try decodeCodepoint(text, &cursor);
        if (saw_lead and codepoint == 0x0307) return true;
        const combining_class = normalization.combiningClass(codepoint);
        if (combining_class == 0 or combining_class == 230) {
            saw_lead = isIllegalDotLeadCharacter(codepoint);
        }
    }
    return false;
}

/// True when a combining sequence contains the same non-spacing mark twice,
/// ICU's invisible-character check.
pub fn hasInvisibleMarks(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!bool {
    var decoded = std.ArrayList(u21).empty;
    defer decoded.deinit(allocator);
    try decodeUtf8(allocator, text, &decoded);
    const decomposed = try normalization.normalizeCodepointsAlloc(
        allocator,
        decoded.items,
        .nfd,
    );
    defer if (decomposed) |owned| allocator.free(owned);
    const source = decomposed orelse decoded.items;

    var first_mark: u21 = 0;
    var have_multiple = false;
    var seen = std.ArrayList(u21).empty;
    defer seen.deinit(allocator);
    for (source) |codepoint| {
        if (properties.category(codepoint) != .Mn) {
            first_mark = 0;
            if (have_multiple) {
                seen.clearRetainingCapacity();
                have_multiple = false;
            }
            continue;
        }
        if (first_mark == 0) {
            first_mark = codepoint;
            continue;
        }
        if (!have_multiple) {
            try seen.append(allocator, first_mark);
            have_multiple = true;
        }
        if (std.mem.indexOfScalar(u21, seen.items, codepoint) != null) {
            return true;
        }
        try seen.append(allocator, codepoint);
    }
    return false;
}

/// Append a one- to four-byte UTF-8 sequence with inline stores; the list
/// slice helpers call memcpy for every runtime length.
inline fn appendShort(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
    bytes: []const u8,
) error{OutOfMemory}!void {
    if (list.unusedCapacitySlice().len < bytes.len) {
        try list.ensureUnusedCapacity(allocator, bytes.len);
    }
    const dest = list.unusedCapacitySlice();
    const length = bytes.len;
    if (length != 0) {
        dest[0] = bytes[0];
        if (length > 1) {
            dest[1] = bytes[1];
            if (length > 2) {
                dest[2] = bytes[2];
                if (length > 3) dest[3] = bytes[3];
            }
        }
    }
    list.items.len += length;
}

fn decodeUtf8(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u21),
) Error!void {
    try output.ensureTotalCapacity(allocator, text.len);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[cursor]) catch
            return error.InvalidUtf8;
        if (cursor + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(
            text[cursor..][0..length],
        ) catch return error.InvalidUtf8;
        try output.append(allocator, codepoint);
        cursor += length;
    }
}

/// Codepoint scratch that stays on the caller's stack until it overflows.
const CodepointBuffer = struct {
    stack: []u21,
    len: usize = 0,
    heap: ?std.ArrayList(u21) = null,
    allocator: std.mem.Allocator,

    fn append(self: *CodepointBuffer, codepoint: u21) Error!void {
        if (self.heap) |*list| {
            try list.append(self.allocator, codepoint);
            return;
        }
        if (self.len < self.stack.len) {
            self.stack[self.len] = codepoint;
            self.len += 1;
            return;
        }
        var list = std.ArrayList(u21).empty;
        try list.ensureTotalCapacity(self.allocator, self.stack.len * 2);
        try list.appendSlice(self.allocator, self.stack[0..self.len]);
        try list.append(self.allocator, codepoint);
        self.heap = list;
        self.len = 0;
    }

    fn items(self: *CodepointBuffer) []const u21 {
        return if (self.heap) |list| list.items else self.stack[0..self.len];
    }

    fn deinit(self: *CodepointBuffer) void {
        if (self.heap) |*list| list.deinit(self.allocator);
    }
};

/// Decode UTF-8 into a stack-backed buffer.
fn decodeUtf8Into(text: []const u8, output: *CodepointBuffer) Error!void {
    var cursor: usize = 0;
    while (cursor < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[cursor]) catch
            return error.InvalidUtf8;
        if (cursor + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(
            text[cursor..][0..length],
        ) catch return error.InvalidUtf8;
        try output.append(codepoint);
        cursor += length;
    }
}

/// NFD `codepoints`, preferring the caller's stack buffer and falling back
/// to the allocating API only when the buffer overflows.
fn normalizeSkeleton(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    buffer: []u21,
    owned: *?[]u21,
) Error![]const u21 {
    switch (normalization.normalizeCodepointsTryInto(
        buffer,
        codepoints,
        .nfd,
    )) {
        .unchanged => return codepoints,
        .written => |items| return items,
        .overflow => {
            owned.* = try normalization.normalizeCodepointsAlloc(
                allocator,
                codepoints,
                .nfd,
            );
            return owned.* orelse codepoints;
        },
    }
}

/// Append the skeleton of UTF-8 `text` to `output` as code points.
pub fn skeletonCodepointsInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u21),
) Error!void {
    // Skeleton inputs are short; decoding and both normalization stages run
    // on the stack so the common case allocates nothing before `output`.
    var decoded_stack: [128]u21 = undefined;
    var decoded = CodepointBuffer{
        .stack = &decoded_stack,
        .allocator = allocator,
    };
    defer decoded.deinit();
    try decodeUtf8Into(text, &decoded);

    var nfd_stack: [256]u21 = undefined;
    var nfd_owned: ?[]u21 = null;
    defer if (nfd_owned) |owned| allocator.free(owned);
    const source = try normalizeSkeleton(
        allocator,
        decoded.items(),
        &nfd_stack,
        &nfd_owned,
    );

    var mapped_stack: [256]u21 = undefined;
    var mapped = CodepointBuffer{
        .stack = &mapped_stack,
        .allocator = allocator,
    };
    defer mapped.deinit();
    var mapping_buffer: [max_mapping_length]u32 = undefined;
    for (source) |codepoint| {
        if (mappingInto(codepoint, &mapping_buffer)) |target| {
            for (target) |value| try mapped.append(@intCast(value));
        } else {
            try mapped.append(codepoint);
        }
    }

    var final_stack: [256]u21 = undefined;
    var final_owned: ?[]u21 = null;
    defer if (final_owned) |owned| allocator.free(owned);
    const normalized = try normalizeSkeleton(
        allocator,
        mapped.items(),
        &final_stack,
        &final_owned,
    );
    // Default-ignorable characters cannot affect a visual comparison.
    for (normalized) |codepoint| {
        if (properties.isDefaultIgnorableCodePoint(codepoint)) continue;
        try output.append(allocator, codepoint);
    }
}

/// Return the allocator-owned UTF-8 skeleton of `text`.
pub fn skeletonAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]u8 {
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try skeletonCodepointsInto(allocator, text, &codepoints);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, codepoints.items.len * 4);
    var buffer: [4]u8 = undefined;
    for (codepoints.items) |codepoint| {
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch
            return error.InvalidUtf8;
        try appendShort(allocator, &output, buffer[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

/// ICU `uspoof_getBidiSkeletonUTF8`: reorder with `direction`, keeping base
/// combining marks and mirroring, then compute the confusable skeleton.
pub fn bidiSkeletonAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    direction: bidi_paragraph.BaseDirection,
) Error![]u8 {
    return bidiSkeletonImpl(allocator, text, direction);
}

fn bidiSkeletonImpl(
    allocator: std.mem.Allocator,
    text: []const u8,
    direction: bidi_paragraph.BaseDirection,
) Error![]u8 {
    // Skeleton inputs are short; the bidi and normalization stages allocate
    // several scratch buffers, so run them against a stack arena and hand
    // back one exact allocation. Longer inputs retry on the heap.
    var stack: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&stack);
    if (bidiSkeletonInner(fixed.allocator(), text, direction)) |result| {
        return allocator.dupe(u8, result);
    } else |err| switch (err) {
        error.OutOfMemory => {},
        else => return err,
    }
    return bidiSkeletonInner(allocator, text, direction);
}

fn bidiSkeletonInner(
    allocator: std.mem.Allocator,
    text: []const u8,
    direction: bidi_paragraph.BaseDirection,
) Error![]u8 {
    var paragraph = try bidi_paragraph.resolve(allocator, text, direction);
    defer paragraph.deinit();
    const reordered = try paragraph.reorderAlloc(allocator, text, .{
        .mirroring = true,
        .keep_base_combining = true,
    });
    defer allocator.free(reordered);
    return skeletonAlloc(allocator, reordered);
}

/// Report whether two strings have the same skeleton. When `case_fold` is
/// set, both inputs are case-folded first, matching ICU's case-insensitive
/// confusable check.
pub fn areConfusable(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    case_fold: bool,
) Error!bool {
    var folded_a: ?[]u8 = null;
    defer if (folded_a) |owned| allocator.free(owned);
    var folded_b: ?[]u8 = null;
    defer if (folded_b) |owned| allocator.free(owned);
    var first = a;
    var second = b;
    if (case_fold) {
        folded_a = try case.foldAlloc(allocator, a);
        folded_b = try case.foldAlloc(allocator, b);
        first = folded_a.?;
        second = folded_b.?;
    }

    var skeleton_a = std.ArrayList(u21).empty;
    defer skeleton_a.deinit(allocator);
    var skeleton_b = std.ArrayList(u21).empty;
    defer skeleton_b.deinit(allocator);
    try skeletonCodepointsInto(allocator, first, &skeleton_a);
    try skeletonCodepointsInto(allocator, second, &skeleton_b);
    return std.mem.eql(u21, skeleton_a.items, skeleton_b.items);
}

test "confusable skeletons" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const latin = try skeletonAlloc(allocator, "paypal");
    defer allocator.free(latin);
    const cyrillic = try skeletonAlloc(allocator, "p\u{0430}ypal");
    defer allocator.free(cyrillic);
    try testing.expectEqualStrings(latin, cyrillic);

    try testing.expect(try areConfusable(
        allocator,
        "paypal",
        "p\u{0430}ypal",
        false,
    ));
    try testing.expect(!(try areConfusable(
        allocator,
        "hello",
        "world",
        false,
    )));
    try testing.expect(try areConfusable(
        allocator,
        "PayPal",
        "p\u{0430}ypal",
        true,
    ));

    const angstrom = try skeletonAlloc(allocator, "\u{212b}");
    defer allocator.free(angstrom);
    const composed = try skeletonAlloc(allocator, "\u{00c5}");
    defer allocator.free(composed);
    try testing.expectEqualStrings(angstrom, composed);

    try testing.expectError(
        error.InvalidUtf8,
        skeletonAlloc(allocator, "\xff"),
    );
}

test "identifier status" {
    const testing = @import("std").testing;

    try testing.expect(isAllowedIdentifier('a'));
    try testing.expect(isAllowedIdentifier('0'));
    try testing.expect(isAllowedIdentifier('_'));
    try testing.expect(isAllowedIdentifier(0x00e9));
    try testing.expect(isAllowedIdentifier(0x4f60));
    try testing.expect(!isAllowedIdentifier(' '));
    try testing.expect(!isAllowedIdentifier('@'));
    try testing.expect(!isAllowedIdentifier(0x1f600));

    try testing.expect(try identifierAllowed("abc_123"));
    try testing.expect(try identifierAllowed("caf\u{00e9}"));
    try testing.expect(!(try identifierAllowed("a b")));
    try testing.expect(!(try identifierAllowed("")));
    try testing.expectError(error.InvalidUtf8, identifierAllowed("\xff"));
}

test "restriction levels" {
    const testing = @import("std").testing;

    try testing.expectEqual(
        RestrictionLevel.ascii_only,
        try restrictionLevel("abc123"),
    );
    try testing.expectEqual(
        RestrictionLevel.ascii_only,
        try restrictionLevel(""),
    );
    try testing.expectEqual(
        RestrictionLevel.single_script,
        try restrictionLevel("caf\u{00e9}"),
    );
    try testing.expectEqual(
        RestrictionLevel.single_script,
        try restrictionLevel("\u{0421}\u{0456}\u{0433}\u{0441}\u{04c0}\u{0435}"),
    );
    try testing.expectEqual(
        RestrictionLevel.single_script,
        try restrictionLevel("\u{65e5}\u{672c}\u{8a9e}"),
    );
    try testing.expectEqual(
        RestrictionLevel.single_script,
        try restrictionLevel("\u{306d}\u{30ac}"),
    );
    try testing.expectEqual(
        RestrictionLevel.single_script,
        try restrictionLevel("\u{d55c}\u{ad6d}\u{c5b4}"),
    );
    // Han resolves through Hanb/Jpan/Kore, so Latin + Han is Highly
    // Restrictive, matching ICU.
    try testing.expectEqual(
        RestrictionLevel.highly_restrictive,
        try restrictionLevel("abc\u{65e5}"),
    );
    try testing.expectEqual(
        RestrictionLevel.highly_restrictive,
        try restrictionLevel("abc\u{d55c}"),
    );
    try testing.expectEqual(
        RestrictionLevel.moderately_restrictive,
        try restrictionLevel("abc\u{05d0}"),
    );
    try testing.expectEqual(
        RestrictionLevel.minimally_restrictive,
        try restrictionLevel("\u{0421}ir\u{0441}l\u{0435}"),
    );
    try testing.expectEqual(
        RestrictionLevel.minimally_restrictive,
        try restrictionLevel("\u{03a9}mega"),
    );
    try testing.expectEqual(
        RestrictionLevel.unrestricted,
        try restrictionLevel("a b"),
    );
    try testing.expectEqual(
        RestrictionLevel.unrestricted,
        try restrictionLevel("\u{1f600}"),
    );

    try testing.expect(try isMixedScript("\u{0421}ir\u{0441}l\u{0435}"));
    try testing.expect(!(try isMixedScript("abc")));
    try testing.expect(!(try isMixedScript("\u{65e5}\u{672c}\u{8a9e}")));
    try testing.expect(!(try isMixedScript("123")));
}

test "mixed number detection" {
    const testing = @import("std").testing;

    try testing.expect(!(try hasMixedNumbers("abc123")));
    try testing.expect(!(try hasMixedNumbers("")));
    try testing.expect(!(try hasMixedNumbers("\u{0661}\u{0662}\u{0663}")));
    try testing.expect(try hasMixedNumbers("1\u{0662}"));
    // ICU only counts Numeric_Type=Decimal characters.
    try testing.expect(!(try hasMixedNumbers("\u{2460}")));
    try testing.expect(!(try hasMixedNumbers("\u{2167}")));
    try testing.expectError(error.InvalidUtf8, hasMixedNumbers("\xff"));
}

test "USpoofChecker ICU conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const fixture = @embedFile("spoof/check_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJSP", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    const levels = [_]RestrictionLevel{
        .ascii_only,
        .single_script,
        .highly_restrictive,
        .moderately_restrictive,
        .minimally_restrictive,
        .unrestricted,
    };
    const patterns = [_][]const u8{
        "",
        "[a-z]",
        "[a-zA-Z0-9_]",
        "[\\u0000-\\u007F]",
    };
    var allowed: [patterns.len]set_mod.Set = undefined;
    var allowed_ready = [_]bool{false} ** patterns.len;
    defer for (0..patterns.len) |index| {
        if (allowed_ready[index]) allowed[index].deinit();
    };
    for (1..patterns.len) |index| {
        allowed[index] = try set_mod.parse(allocator, patterns[index]);
        allowed_ready[index] = true;
    }

    var cursor: usize = 12;
    var failures: usize = 0;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const kind = fixture[cursor];
        const level_index = fixture[cursor + 1];
        const allowed_index = fixture[cursor + 2];
        const checks = std.mem.readInt(
            u32,
            fixture[cursor + 4 ..][0..4],
            .little,
        );
        cursor += 8;
        const first_len = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        const first = fixture[cursor..][0..first_len];
        cursor += first_len;
        const second_len = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        const second = fixture[cursor..][0..second_len];
        cursor += second_len;
        const expected = std.mem.readInt(
            u32,
            fixture[cursor..][0..4],
            .little,
        );
        cursor += 4;

        var checker = Checker.init();
        if (allowed_index != 0) {
            checker.setAllowedChars(&allowed[allowed_index]);
        }
        checker.setRestrictionLevel(levels[level_index]);
        checker.setChecks(checks);

        const actual = switch (kind) {
            1 => try checker.areConfusableAlloc(allocator, first, second, false),
            2 => try checker.areBidiConfusableAlloc(
                allocator,
                first,
                second,
                if (level_index == 0) .ltr else .rtl,
                false,
            ),
            else => try checker.checkAlloc(allocator, first),
        };
        if (actual != expected) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "spoof check mismatch: {s} checks={x} got={x} want={x}\n",
                    .{ first, checks, actual, expected },
                );
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "spoof checker conformance: {}/{} passed\n",
        .{ case_count - failures, case_count },
    );
}

test "spoof checker configuration" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var checker = Checker.init();
    try testing.expectEqual(Checks.all, checker.getChecks());
    try testing.expectEqual(
        RestrictionLevel.highly_restrictive,
        checker.getRestrictionLevel(),
    );
    try testing.expectEqual(@as(u32, 0), try checker.checkAlloc(allocator, "abc"));

    checker.setChecks(Checks.mixed_numbers);
    try testing.expectEqual(
        Checks.mixed_numbers,
        try checker.checkAlloc(allocator, "1\u{0662}"),
    );
    try testing.expectEqual(@as(u32, 0), try checker.checkAlloc(allocator, "abc"));

    checker.setChecks(Checks.invisible);
    try testing.expectEqual(
        Checks.invisible,
        try checker.checkAlloc(allocator, "a\u{0301}\u{0301}"),
    );

    checker.setChecks(Checks.hidden_overlay);
    try testing.expectEqual(
        Checks.hidden_overlay,
        try checker.checkAlloc(allocator, "i\u{0307}"),
    );

    checker.setChecks(0);
    try testing.expectError(
        error.InvalidState,
        checker.areConfusableAlloc(allocator, "a", "b", false),
    );
    checker.setChecks(Checks.confusable);
    try testing.expectEqual(
        Checks.single_script_confusable,
        try checker.areConfusableAlloc(allocator, "paypal", "paypa1", false),
    );
    try testing.expectEqual(
        Checks.mixed_script_confusable,
        try checker.areConfusableAlloc(allocator, "paypal", "p\u{0430}ypal", false),
    );
    try testing.expectEqual(
        @as(u32, 0),
        try checker.areConfusableAlloc(allocator, "abc", "abd", false),
    );

    checker.setChecks(Checks.restriction_level | Checks.aux_info);
    const result = try checker.checkResultAlloc(
        allocator,
        "\u{0421}\u{0456}\u{0433}\u{0441}\u{04c0}\u{0435}",
    );
    try testing.expectEqual(
        RestrictionLevel.single_script,
        result.restriction_level.?,
    );
    try testing.expectEqual(
        @as(u32, 0x20000000),
        result.bitmask(checker.checks),
    );

    checker.setRestrictionLevel(.single_script);
    try testing.expectEqual(
        Checks.restriction_level | Checks.aux_info,
        try checker.checkAlloc(allocator, "abc\u{05d0}"),
    );
}

test "UTS 39 skeleton conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    try testing.expect(conformance.len >= 12);
    try testing.expectEqualStrings("CJXS", conformance[0..4]);
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const input_len = std.mem.readInt(
            u16,
            conformance[cursor..][0..2],
            .little,
        );
        const skeleton_len = std.mem.readInt(
            u16,
            conformance[cursor + 2 ..][0..2],
            .little,
        );
        cursor += 4;
        const input = conformance[cursor..][0..input_len];
        cursor += input_len;
        const expected = conformance[cursor..][0..skeleton_len];
        cursor += skeleton_len;

        const actual = try skeletonAlloc(allocator, input);
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print("skeleton mismatch: {s} -> {s} (want {s})\n", .{
                    input,
                    actual,
                    expected,
                });
            }
        }
    }
    try testing.expectEqual(conformance.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
}

test "bidi confusable skeletons" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const ltr = try bidiSkeletonAlloc(allocator, "abc \u{05d0}\u{05d1}", .ltr);
    defer allocator.free(ltr);
    const rtl = try bidiSkeletonAlloc(allocator, "abc \u{05d0}\u{05d1}", .rtl);
    defer allocator.free(rtl);
    try testing.expect(ltr.len > 0);
    try testing.expect(rtl.len > 0);

    var checker = Checker.init();
    checker.setChecks(Checks.confusable);
    try testing.expectEqual(
        Checks.single_script_confusable,
        try checker.areBidiConfusableAlloc(
            allocator,
            "abc",
            "abc",
            .ltr,
            false,
        ),
    );
    try testing.expectEqual(
        @as(u32, 0),
        try checker.areBidiConfusableAlloc(
            allocator,
            "abc",
            "abd",
            .rtl,
            false,
        ),
    );
    try testing.expect(
        (try checker.areBidiConfusableAlloc(
            allocator,
            "paypal",
            "p\u{0430}ypal",
            .ltr,
            false,
        )) != 0,
    );
}
