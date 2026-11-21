//! CLDR 48 root collation (UTS #10 / UTS #35) with UCA 17.0.0 implicit weights.
//!
//! Input is normalized to NFD before lookup. Explicit DUCET entries, including
//! contractions, are used first; code points without an entry receive the
//! standard implicit weights. Root weights carry twelve low bits reserved for
//! locale tailorings. Sort keys are sequences of `u32` weights with zero
//! separators between levels, so comparison is lexicographic.

const std = @import("std");
const implicit = @import("implicit.zig");
const tailorings = @import("tailorings.zig");
const normalization = @import("../normalization/root.zig");
const properties = @import("../properties.zig");
const scalar = @import("../scalar/root.zig");
const utf16 = @import("../utf16.zig");
const combining_class = @import("../canonical/combining_class.zig");

pub const uca_version = [3]u8{ 17, 0, 0 };
pub const cldr_version = "48";

pub const Strength = enum { primary, secondary, tertiary, quaternary, identical };
pub const VariableWeighting = enum { non_ignorable, shifted };
pub const CaseFirst = tailorings.CaseFirst;

pub const Options = struct {
    strength: Strength = .tertiary,
    variable_weighting: VariableWeighting = .non_ignorable,
    /// BCP 47 locale tag. When a CLDR tailoring exists it is applied before
    /// the root collation; otherwise the root order is used.
    locale: ?[]const u8 = null,
    /// CLDR collation type such as `standard`, `search`, `phonebook`,
    /// `traditional`, `stroke`, or `zhuyin`. Unknown types fall back to the
    /// locale's standard tailoring.
    collation: []const u8 = "standard",
    /// Overrides the locale tailoring's `caseFirst` setting. `null` uses the
    /// tailoring setting (default `off`, which orders lowercase first).
    case_first: ?CaseFirst = null,
    /// Overrides the locale tailoring's backwards-secondary setting (French
    /// style accent ordering). `null` uses the tailoring setting.
    backwards_secondary: ?bool = null,
    /// Compare runs of decimal digits by numeric value (ICU's numeric
    /// collation): `a2` sorts before `a10`, and leading zeros are ignored.
    numeric: bool = false,
    /// Add a case level between the secondary and tertiary levels. Case
    /// differences then stop affecting the tertiary level.
    case_level: bool = false,
};

const data = @embedFile("data.bin");
const header_len = 20;
const index_count = readU16(8);
const page_count = readU16(10);
const entry_count = readU32(12);
const ce_count = readU32(16);
const index_offset = header_len;
const pages_offset = index_offset + @as(usize, index_count) * 2;
const entries_offset = pages_offset + @as(usize, page_count) * 256 * 2;
const ces_offset = entries_offset + @as(usize, entry_count) * 20;

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJCL") or
        data[4] != 2 or data[5] != 17 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid UCA collation data");
    }
    if (index_count != 0x1100 or
        ces_offset + @as(usize, ce_count) * 16 != data.len)
    {
        @compileError("invalid UCA collation data lengths");
    }
}

pub const CollationElement = struct {
    primary: u32,
    secondary: u32,
    tertiary: u32,
    variable: bool,
};

/// Element buffer that starts on the stack and spills to the heap only for
/// long inputs, so a typical sort key costs no allocation.
fn ElementBuffer(comptime T: type) type {
    return struct {
        stack: []T,
        len: usize = 0,
        heap: ?std.ArrayList(T) = null,
        allocator: std.mem.Allocator,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, stack: []T) Self {
            return .{ .stack = stack, .allocator = allocator };
        }

        fn deinit(self: *Self) void {
            if (self.heap) |*list| list.deinit(self.allocator);
        }

        fn items(self: *const Self) []const T {
            return if (self.heap) |list| list.items else self.stack[0..self.len];
        }

        fn ensureTotalCapacity(
            self: *Self,
            capacity: usize,
        ) error{OutOfMemory}!void {
            if (capacity <= self.stack.len) return;
            if (self.heap) |*list| {
                try list.ensureTotalCapacity(self.allocator, capacity);
                return;
            }
            var list = std.ArrayList(T).empty;
            try list.ensureTotalCapacity(self.allocator, capacity);
            try list.appendSlice(self.allocator, self.stack[0..self.len]);
            self.heap = list;
            self.len = 0;
        }

        inline fn append(
            self: *Self,
            allocator: std.mem.Allocator,
            element: T,
        ) error{OutOfMemory}!void {
            _ = allocator;
            if (self.heap) |*list| {
                try list.append(self.allocator, element);
                return;
            }
            if (self.len < self.stack.len) {
                self.stack[self.len] = element;
                self.len += 1;
                return;
            }
            try self.ensureTotalCapacity(self.stack.len * 2);
            try self.heap.?.append(self.allocator, element);
        }
    };
}

const CeBuffer = ElementBuffer(CollationElement);
const LevelBuffer = ElementBuffer(u32);

/// Collects primary, secondary, and tertiary weights straight from the
/// collation-element stream, so root sort keys do not need an intermediate
/// element buffer. The strength is comptime so unused levels drop out.
fn LevelSink(comptime strength: Strength) type {
    return struct {
        primary: *LevelBuffer,
        secondary: *LevelBuffer,
        tertiary: *LevelBuffer,

        fn append(
            self: *@This(),
            allocator: std.mem.Allocator,
            element: CollationElement,
        ) error{OutOfMemory}!void {
            if (element.primary != 0) {
                try self.primary.append(allocator, element.primary);
            }
            if (strength != .primary and element.secondary != 0) {
                try self.secondary.append(allocator, element.secondary);
            }
            if (strength != .primary and strength != .secondary and
                element.tertiary != 0)
            {
                try self.tertiary.append(allocator, element.tertiary);
            }
        }
    };
}

const WeightedElement = struct {
    primary: u32,
    secondary: u32,
    tertiary: u32,
    quaternary: u32,
};

const Entry = struct {
    first: u21,
    second: u21,
    third: u21,
    ce_offset: u32,
    ce_count: u8,
    len: u8,
};

fn entryAt(index: usize) Entry {
    const base = entries_offset + index * 20;
    return .{
        .first = @intCast(readU32(base)),
        .second = @intCast(readU32(base + 4)),
        .third = @intCast(readU32(base + 8)),
        .ce_offset = readU32(base + 12),
        .ce_count = data[base + 16],
        .len = data[base + 17],
    };
}

fn ceAt(index: usize) CollationElement {
    const base = ces_offset + index * 16;
    return .{
        .primary = readU32(base),
        .secondary = readU32(base + 4),
        .tertiary = readU32(base + 8),
        .variable = data[base + 12] != 0,
    };
}

fn pageStart(codepoint: u21) usize {
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(index_offset + page * 2);
    return readU16(
        pages_offset + (@as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)) * 2,
    );
}

/// Return an allocator-owned sort key for UTF-8 text.
pub fn sortKeyAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) error{ InvalidUtf8, OutOfMemory }![]u32 {
    var key = std.ArrayList(u32).empty;
    errdefer key.deinit(allocator);
    try sortKeyInto(allocator, text, options, &key);
    return key.toOwnedSlice(allocator);
}

/// Append a sort key for UTF-8 text to `output`. Callers that build many
/// keys can reuse one output list and keep its capacity.
pub fn sortKeyInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
    output: *std.ArrayList(u32),
) error{ InvalidUtf8, OutOfMemory }!void {
    const collator = Collator.init(options);
    return collator.sortKeyInto(allocator, text, output);
}

/// Collation elements for UTF-8 text, mirroring ICU's
/// `ucol_openElements`. The returned elements use the configured strength,
/// variable weighting, numeric ordering, and locale tailoring.
pub fn collationElementsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) error{ InvalidUtf8, OutOfMemory }![]CollationElement {
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, text.len);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidatingPacked(text, cursor);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        try codepoints.append(allocator, scalar.packedCodepoint(decoded));
        cursor += scalar.packedLength(decoded);
    }
    const collator = Collator.init(options);
    return collator.elementsAlloc(allocator, codepoints.items);
}

/// A collator with the locale tailoring resolved once, mirroring ICU's
/// `UCollator`. Reuse one across many sort keys to skip the locale lookup
/// and page-index claim on every call.
pub const Collator = struct {
    options: Options,
    tailoring: ?tailorings.Tailoring,
    pages: ?*tailorings.PageIndex,

    pub fn init(options: Options) Collator {
        const tailoring = if (options.locale) |locale|
            tailorings.find(locale, options.collation)
        else
            null;
        return .{
            .options = options,
            .tailoring = tailoring,
            .pages = if (tailoring) |value|
                tailorings.pageIndex(value)
            else
                null,
        };
    }

    /// ICU `UColAttribute` values.
    pub const Attribute = enum(u8) {
        french_collation = 0,
        alternate_handling = 1,
        case_first = 2,
        case_level = 3,
        normalization_mode = 4,
        strength = 5,
        hiragana_quaternary_mode = 6,
        numeric_collation = 7,
    };

    /// ICU `UColAttributeValue` values used by the supported attributes.
    pub const AttributeValue = struct {
        pub const off: u32 = 0;
        pub const on: u32 = 1;
        pub const lower_first: u32 = 1;
        pub const upper_first: u32 = 2;
        pub const primary: u32 = 0;
        pub const secondary: u32 = 1;
        pub const tertiary: u32 = 2;
        pub const quaternary: u32 = 3;
        pub const identical: u32 = 4;
    };

    pub fn getAttribute(self: *const Collator, attribute: Attribute) u32 {
        return switch (attribute) {
            .french_collation => blk: {
                if (self.options.backwards_secondary) |value| {
                    break :blk @intFromBool(value);
                }
                break :blk if (self.tailoring) |tailoring|
                    @intFromBool(tailoring.backwards)
                else
                    0;
            },
            .alternate_handling => if (self.options.variable_weighting == .shifted)
                @as(u32, 1)
            else
                0,
            .case_first => blk: {
                const value = self.options.case_first orelse
                    if (self.tailoring) |tailoring| tailoring.case_first else .off;
                break :blk switch (value) {
                    .off => 0,
                    .lower => 1,
                    .upper => 2,
                };
            },
            .case_level => @intFromBool(self.options.case_level),
            .normalization_mode => 1,
            .strength => @intFromEnum(self.options.strength),
            .hiragana_quaternary_mode => 0,
            .numeric_collation => @intFromBool(self.options.numeric),
        };
    }

    pub fn setAttribute(
        self: *Collator,
        attribute: Attribute,
        value: u32,
    ) void {
        switch (attribute) {
            .french_collation => {
                self.options.backwards_secondary = value != 0;
            },
            .alternate_handling => {
                self.options.variable_weighting = if (value == 0)
                    .non_ignorable
                else
                    .shifted;
            },
            .case_first => {
                self.options.case_first = switch (value) {
                    0 => .off,
                    1 => .lower,
                    2 => .upper,
                    else => return,
                };
            },
            .case_level => {
                self.options.case_level = value != 0;
            },
            .strength => {
                if (value > @intFromEnum(Strength.identical)) return;
                self.options.strength = @enumFromInt(value);
            },
            .numeric_collation => {
                self.options.numeric = value != 0;
            },
            .normalization_mode, .hiragana_quaternary_mode => {},
        }
    }

    pub fn sortKeyInto(
        self: *const Collator,
        allocator: std.mem.Allocator,
        text: []const u8,
        output: *std.ArrayList(u32),
    ) error{ InvalidUtf8, OutOfMemory }!void {
        return sortKeyUtf8Resolved(
            allocator,
            text,
            self.options,
            self.tailoring,
            self.pages,
            output,
        );
    }

    /// Append a sort key for already decoded code points. Search paths use
    /// this to avoid re-validating and decoding each candidate substring.
    pub fn sortKeyCodepointsInto(
        self: *const Collator,
        allocator: std.mem.Allocator,
        codepoints: []const u21,
        output: *std.ArrayList(u32),
    ) error{OutOfMemory}!void {
        return sortKeyCodepointsResolved(
            allocator,
            codepoints,
            self.options,
            self.tailoring,
            self.pages,
            output,
        );
    }

    /// True when the ASCII root fast paths are available.
    pub fn asciiFastPathUsable(self: *const Collator) bool {
        return self.tailoring == null and ascii_usable;
    }

    /// Primary weights of one ASCII scalar under the root collation.
    pub const AsciiPrimary = struct {
        values: [2]u32 = .{ 0, 0 },
        count: u8 = 0,
    };

    pub fn asciiPrimaryWeights(self: *const Collator, codepoint: u21) AsciiPrimary {
        if (self.tailoring != null or codepoint >= 128 or
            !ascii_usable)
        {
            return .{};
        }
        const entry = ascii_elements_table[codepoint];
        var result = AsciiPrimary{};
        for (entry.elements[0..entry.count]) |element| {
            if (element.primary != 0 and result.count < result.values.len) {
                result.values[result.count] = element.primary;
                result.count += 1;
            }
        }
        return result;
    }

    /// First primary weight for an ASCII scalar when no tailoring applies,
    /// or null when the key depends on the locale or the character has no
    /// primary weight.
    pub fn asciiFirstPrimary(self: *const Collator, codepoint: u21) ?u32 {
        if (self.tailoring != null) return null;
        if (codepoint >= 128) return null;
        if (!ascii_usable) return null;
        const entry = ascii_elements_table[codepoint];
        if (entry.count == 0) return null;
        for (entry.elements[0..entry.count]) |element| {
            if (element.primary != 0) return element.primary;
        }
        return null;
    }

    /// True when a contraction starting at `codepoints[index]` could
    /// consume the next code point, either by matching it or by skipping it
    /// as a combining mark.
    pub fn contractionExtends(
        self: *const Collator,
        codepoints: []const u21,
        index: usize,
    ) bool {
        const first = codepoints[index];
        if (index + 1 >= codepoints.len) return false;
        const next = codepoints[index + 1];
        if (!self.startsContraction(first)) return false;
        if (next >= 0x300 and combining_class.forCodepoint(next) != 0) {
            return true;
        }
        if (self.tailoring) |tailoring| {
            if (tailorings.longerRuleMatches(
                tailoring,
                self.pages,
                first,
                next,
            )) {
                return true;
            }
        }
        var entry_index = pageStart(first);
        while (entry_index < @as(usize, entry_count)) : (entry_index += 1) {
            const entry = entryAt(entry_index);
            if (entry.first != first) break;
            if (entry.len > 1 and entry.second == next) return true;
        }
        return false;
    }

    /// True when a multi-code-point rule or contraction can start with this
    /// code point, so its single-character key depends on what follows.
    pub fn startsContraction(self: *const Collator, codepoint: u21) bool {
        if (self.tailoring) |tailoring| {
            if (tailorings.startsLongerRule(
                tailoring,
                self.pages,
                codepoint,
            )) {
                return true;
            }
        }
        var entry_index = pageStart(codepoint);
        while (entry_index < @as(usize, entry_count)) : (entry_index += 1) {
            const entry = entryAt(entry_index);
            if (entry.first != codepoint) break;
            if (entry.len > 1) return true;
        }
        return false;
    }

    pub fn sortKeyAlloc(
        self: *const Collator,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) error{ InvalidUtf8, OutOfMemory }![]u32 {
        var key = std.ArrayList(u32).empty;
        errdefer key.deinit(allocator);
        try self.sortKeyInto(allocator, text, &key);
        return key.toOwnedSlice(allocator);
    }

    /// Collation elements for already decoded code points.
    pub fn elementsAlloc(
        self: *const Collator,
        allocator: std.mem.Allocator,
        codepoints: []const u21,
    ) error{OutOfMemory}![]CollationElement {
        const normalized = try normalization.normalizeCodepointsAlloc(
            allocator,
            codepoints,
            .nfd,
        );
        defer if (normalized) |owned| allocator.free(owned);
        const source = normalized orelse codepoints;
        const reorder = if (self.tailoring) |tailoring|
            tailoring.reorder
        else
            null;
        const shifted = self.options.variable_weighting == .shifted;
        var stack: [512]CollationElement = undefined;
        var ces = CeBuffer.init(allocator, &stack);
        defer ces.deinit();
        try buildElements(
            allocator,
            source,
            self.options,
            self.tailoring,
            self.pages,
            reorder,
            shifted,
            &ces,
        );
        return allocator.dupe(CollationElement, ces.items());
    }

    pub fn sortKeyUtf16Into(
        self: *const Collator,
        allocator: std.mem.Allocator,
        units: []const u16,
        output: *std.ArrayList(u32),
    ) error{ InvalidUtf16, OutOfMemory }!void {
        return sortKeyUtf16Resolved(
            allocator,
            units,
            self.options,
            self.tailoring,
            self.pages,
            output,
        );
    }

    pub fn sortKeyUtf16Alloc(
        self: *const Collator,
        allocator: std.mem.Allocator,
        units: []const u16,
    ) error{ InvalidUtf16, OutOfMemory }![]u32 {
        var key = std.ArrayList(u32).empty;
        errdefer key.deinit(allocator);
        try self.sortKeyUtf16Into(allocator, units, &key);
        return key.toOwnedSlice(allocator);
    }

    /// Compare two UTF-8 strings using caller-owned scratch lists.
    pub fn compare(
        self: *const Collator,
        allocator: std.mem.Allocator,
        a: []const u8,
        b: []const u8,
        key_a: *std.ArrayList(u32),
        key_b: *std.ArrayList(u32),
    ) error{ InvalidUtf8, OutOfMemory }!std.math.Order {
        try self.sortKeyInto(allocator, a, key_a);
        try self.sortKeyInto(allocator, b, key_b);
        return std.mem.order(u32, key_a.items, key_b.items);
    }

    /// Compare two UTF-16 strings using caller-owned scratch lists.
    pub fn compareUtf16(
        self: *const Collator,
        allocator: std.mem.Allocator,
        a: []const u16,
        b: []const u16,
        key_a: *std.ArrayList(u32),
        key_b: *std.ArrayList(u32),
    ) error{ InvalidUtf16, OutOfMemory }!std.math.Order {
        try self.sortKeyUtf16Into(allocator, a, key_a);
        try self.sortKeyUtf16Into(allocator, b, key_b);
        return std.mem.order(u32, key_a.items, key_b.items);
    }
};

fn sortKeyUtf8Resolved(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
    locale_tailoring: ?tailorings.Tailoring,
    tailoring_pages: ?*tailorings.PageIndex,
    output: *std.ArrayList(u32),
) error{ InvalidUtf8, OutOfMemory }!void {
    // Most callers sort short labels and keys; decode those into a stack
    // buffer so a sort key costs one allocation instead of two. Validation is
    // fused into the decode so mixed text pays one pass instead of two.
    var stack_codepoints: [512]u21 = undefined;
    if (text.len <= stack_codepoints.len) {
        var count: usize = 0;
        var cursor: usize = 0;
        while (cursor < text.len) {
            const decoded = scalar.decodeValidatingPacked(text, cursor);
            if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
            stack_codepoints[count] = scalar.packedCodepoint(decoded);
            count += 1;
            cursor += scalar.packedLength(decoded);
        }
        return sortKeyCodepointsResolved(
            allocator,
            stack_codepoints[0..count],
            options,
            locale_tailoring,
            tailoring_pages,
            output,
        );
    }

    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, text.len);

    var cursor: usize = 0;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidatingPacked(text, cursor);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        try codepoints.append(allocator, scalar.packedCodepoint(decoded));
        cursor += scalar.packedLength(decoded);
    }
    try sortKeyCodepointsResolved(
        allocator,
        codepoints.items,
        options,
        locale_tailoring,
        tailoring_pages,
        output,
    );
}

/// Separator inserted between the two fields of a merged sort key. It is
/// greater than every collation weight, like ICU's 0x02 merge byte.
pub const merge_separator: u32 = std.math.maxInt(u32);

/// Merge two sort keys level by level, so the result sorts by `first` and
/// then by `second` at each strength level. This is ICU's
/// `ucol_mergeSortkeys` for multi-field sorting.
pub fn mergeSortKeysAlloc(
    allocator: std.mem.Allocator,
    first: []const u32,
    second: []const u32,
    separator: u32,
) error{OutOfMemory}![]u32 {
    var output = std.ArrayList(u32).empty;
    errdefer output.deinit(allocator);
    if (first.len == 0 and second.len == 0) return output.toOwnedSlice(allocator);
    try output.ensureTotalCapacity(allocator, first.len + second.len + 4);
    var first_index: usize = 0;
    var second_index: usize = 0;
    while (true) {
        while (first_index < first.len and first[first_index] != 0) {
            try output.append(allocator, first[first_index]);
            first_index += 1;
        }
        try output.append(allocator, separator);
        while (second_index < second.len and second[second_index] != 0) {
            try output.append(allocator, second[second_index]);
            second_index += 1;
        }
        const first_more = first_index + 1 < first.len;
        const second_more = second_index + 1 < second.len;
        if (first_more and second_more) {
            first_index += 1;
            second_index += 1;
            try output.append(allocator, 0);
            continue;
        }
        if (first_more) {
            try output.appendSlice(allocator, first[first_index..]);
        } else if (second_more) {
            try output.appendSlice(allocator, second[second_index..]);
        } else {
            try output.append(allocator, 0);
        }
        break;
    }
    if (output.items[output.items.len - 1] != 0) {
        try output.append(allocator, 0);
    }
    return output.toOwnedSlice(allocator);
}

pub const SortKeyBound = enum { lower, upper, upper_long };

/// Return the prefix of `key` covering the first `levels` strength levels,
/// optionally with an exclusive upper-bound suffix, like ICU's
/// `ucol_getBound`. The result is a valid sort key terminated by 0.
pub fn sortKeyBoundAlloc(
    allocator: std.mem.Allocator,
    key: []const u32,
    levels: usize,
    bound: SortKeyBound,
) error{OutOfMemory}![]u32 {
    var end: usize = 0;
    var seen: usize = 0;
    while (end < key.len and seen < levels) {
        if (key[end] == 0) seen += 1;
        end += 1;
    }
    var prefix = key[0..end];
    if (prefix.len != 0 and prefix[prefix.len - 1] == 0) {
        prefix = prefix[0 .. prefix.len - 1];
    }
    var output = std.ArrayList(u32).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, prefix.len + 3);
    try output.appendSlice(allocator, prefix);
    switch (bound) {
        .lower => {},
        .upper => try output.append(allocator, merge_separator),
        .upper_long => {
            try output.append(allocator, merge_separator);
            try output.append(allocator, merge_separator);
        },
    }
    try output.append(allocator, 0);
    return output.toOwnedSlice(allocator);
}

test "sort key merge and bound" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const primary = try mergeSortKeysAlloc(
        allocator,
        &.{ 2, 0 },
        &.{ 3, 0 },
        merge_separator,
    );
    defer allocator.free(primary);
    try testing.expectEqualSlices(
        u32,
        &.{ 2, merge_separator, 3, 0 },
        primary,
    );

    const levels = try mergeSortKeysAlloc(
        allocator,
        &.{ 1, 0, 10, 0 },
        &.{ 2, 0, 20, 0 },
        merge_separator,
    );
    defer allocator.free(levels);
    try testing.expectEqualSlices(
        u32,
        &.{ 1, merge_separator, 2, 0, 10, merge_separator, 20, 0 },
        levels,
    );

    const key = [_]u32{ 5, 0, 7, 0, 9, 0 };
    const lower = try sortKeyBoundAlloc(allocator, &key, 1, .lower);
    defer allocator.free(lower);
    try testing.expectEqualSlices(u32, &.{ 5, 0 }, lower);
    const upper = try sortKeyBoundAlloc(allocator, &key, 1, .upper);
    defer allocator.free(upper);
    try testing.expectEqualSlices(
        u32,
        &.{ 5, merge_separator, 0 },
        upper,
    );
    const two = try sortKeyBoundAlloc(allocator, &key, 2, .lower);
    defer allocator.free(two);
    try testing.expectEqualSlices(u32, &.{ 5, 0, 7, 0 }, two);
    const long = try sortKeyBoundAlloc(allocator, &key, 2, .upper_long);
    defer allocator.free(long);
    try testing.expectEqualSlices(
        u32,
        &.{ 5, 0, 7, merge_separator, merge_separator, 0 },
        long,
    );
}

/// Append a sort key for UTF-16 text to `output`.
pub fn sortKeyUtf16Into(
    allocator: std.mem.Allocator,
    units: []const u16,
    options: Options,
    output: *std.ArrayList(u32),
) error{ InvalidUtf16, OutOfMemory }!void {
    const collator = Collator.init(options);
    return collator.sortKeyUtf16Into(allocator, units, output);
}

fn sortKeyUtf16Resolved(
    allocator: std.mem.Allocator,
    units: []const u16,
    options: Options,
    locale_tailoring: ?tailorings.Tailoring,
    tailoring_pages: ?*tailorings.PageIndex,
    output: *std.ArrayList(u32),
) error{ InvalidUtf16, OutOfMemory }!void {
    if (!utf16.validate(units)) return error.InvalidUtf16;

    var stack_codepoints: [512]u21 = undefined;
    if (units.len <= stack_codepoints.len) {
        var count: usize = 0;
        var iterator = utf16.Iterator{ .units = units };
        while (iterator.next()) |codepoint| {
            stack_codepoints[count] = codepoint;
            count += 1;
        }
        return sortKeyCodepointsResolved(
            allocator,
            stack_codepoints[0..count],
            options,
            locale_tailoring,
            tailoring_pages,
            output,
        );
    }

    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, units.len);
    var iterator = utf16.Iterator{ .units = units };
    while (iterator.next()) |codepoint| {
        try codepoints.append(allocator, codepoint);
    }
    try sortKeyCodepointsResolved(
        allocator,
        codepoints.items,
        options,
        locale_tailoring,
        tailoring_pages,
        output,
    );
}

/// Return an allocator-owned sort key for UTF-16 text.
pub fn sortKeyUtf16Alloc(
    allocator: std.mem.Allocator,
    units: []const u16,
    options: Options,
) error{ InvalidUtf16, OutOfMemory }![]u32 {
    var key = std.ArrayList(u32).empty;
    errdefer key.deinit(allocator);
    try sortKeyUtf16Into(allocator, units, options, &key);
    return key.toOwnedSlice(allocator);
}

/// Append a sort key for a code-point slice to `output`.
pub fn sortKeyCodepointsInto(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    options: Options,
    output: *std.ArrayList(u32),
) error{OutOfMemory}!void {
    const locale_tailoring = if (options.locale) |locale|
        tailorings.find(locale, options.collation)
    else
        null;
    const tailoring_pages = if (locale_tailoring) |tailoring|
        tailorings.pageIndex(tailoring)
    else
        null;
    return sortKeyCodepointsResolved(
        allocator,
        codepoints,
        options,
        locale_tailoring,
        tailoring_pages,
        output,
    );
}

/// Append a sort key using an already resolved locale tailoring.
/// Append the collation elements for NFD-normalized `source` to `ces`.
/// Numeric runs and locale tailoring rules are applied in the same order as
/// the sort-key path.
fn buildElements(
    allocator: std.mem.Allocator,
    source: []const u21,
    options: Options,
    locale_tailoring: ?tailorings.Tailoring,
    tailoring_pages: ?*tailorings.PageIndex,
    reorder: ?tailorings.Reorder,
    shifted: bool,
    ces: *CeBuffer,
) error{OutOfMemory}!void {
    try ces.ensureTotalCapacity(source.len + 8);
    const tables: ?*const RootTables =
        if (reorder == null and !shifted) &root_tables_storage else null;
    var index: usize = 0;
    while (index < source.len) {
        if (options.numeric) {
            if (decimalValue(source[index]) != null) {
                const end = decimalRunEnd(source, index);
                try appendNumeric(allocator, ces, source[index..end]);
                index = end;
                continue;
            }
        }
        if (locale_tailoring) |tailoring| {
            const first = source[index];
            const tag = tailorings.cacheTag(tailoring, first);
            const cached = tailorings.cachedElement(first);
            if (cached.tag == tag) {
                switch (cached.kind) {
                    .single => {
                        try ces.append(allocator, .{
                            .primary = cached.primary,
                            .secondary = cached.secondary,
                            .tertiary = cached.tertiary,
                            .variable = cached.variable,
                        });
                        index += 1;
                        continue;
                    },
                    .absent => {
                        index += try appendElements(
                            allocator,
                            ces,
                            source,
                            index,
                            reorder,
                            shifted,
                            tables,
                        );
                        continue;
                    },
                    .complex, .empty => {},
                }
            }
            if (tailorings.couldMatch(tailoring_pages, first)) {
                if (tailorings.match(
                    tailoring,
                    tailoring_pages,
                    source,
                    index,
                )) |matched| {
                    const rule = matched.rule;
                    if (rule.sequence_len == 1 and rule.ce_count == 1) {
                        const element = tailorings.elementAt(rule, 0);
                        cached.* = .{
                            .tag = tag,
                            .primary = element.primary,
                            .secondary = element.secondary,
                            .tertiary = element.tertiary,
                            .kind = .single,
                            .variable = element.variable,
                        };
                        try ces.append(allocator, .{
                            .primary = element.primary,
                            .secondary = element.secondary,
                            .tertiary = element.tertiary,
                            .variable = element.variable,
                        });
                    } else {
                        cached.* = .{ .tag = tag, .kind = .complex };
                        try appendTailored(allocator, ces, rule);
                    }
                    index += matched.length;
                    continue;
                }
            }
            cached.* = .{ .tag = tag, .kind = .absent };
        }
        index += try appendElements(
            allocator,
            ces,
            source,
            index,
            reorder,
            shifted,
            tables,
        );
    }
}

fn sortKeyCodepointsResolved(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    options: Options,
    locale_tailoring: ?tailorings.Tailoring,
    tailoring_pages: ?*tailorings.PageIndex,
    output: *std.ArrayList(u32),
) error{OutOfMemory}!void {
    output.clearRetainingCapacity();

    const reorder = if (locale_tailoring) |tailoring| tailoring.reorder else null;
    const shifted = options.variable_weighting == .shifted;
    const case_first = options.case_first orelse
        (if (locale_tailoring) |tailoring| tailoring.case_first else .off);
    const backwards = options.backwards_secondary orelse
        (if (locale_tailoring) |tailoring| tailoring.backwards else false);

    const fast_conditions = !shifted and case_first == .off and !backwards and
        !options.numeric and !options.case_level;
    ensureRootTables();
    if (fast_conditions) {
        if (locale_tailoring) |tailoring| {
            if (try appendTailoredLatinSortKey(
                allocator,
                output,
                codepoints,
                tailoring,
                tailoring_pages,
                options.strength,
            )) {
                return;
            }
        } else if (try appendLatinSortKey(
            allocator,
            output,
            codepoints,
            options.strength,
        )) {
            return;
        }
    }

    // The implicit-only fast path and the normalization step both need the
    // NFD answer; scan the input once for both.
    const nfd = normalization.isNormalizedCodepoints(codepoints, .nfd);

    if (fast_conditions and locale_tailoring == null and nfd) {
        if (try appendImplicitSortKey(
            allocator,
            output,
            codepoints,
            options.strength,
        )) {
            return;
        }
    }

    // Short inputs dominate sort-key traffic; normalize them on the stack so
    // the common case does not allocate.
    var normalized_stack: [512]u21 = undefined;
    var normalized_owned: ?[]u21 = null;
    defer if (normalized_owned) |owned| allocator.free(owned);
    const source: []const u21 = if (nfd)
        codepoints
    else switch (normalization.normalizeCodepointsTryIntoChanged(
        &normalized_stack,
        codepoints,
        .nfd,
    )) {
        .unchanged => codepoints,
        .written => |items| items,
        .overflow => blk: {
            normalized_owned = try normalization.normalizeCodepointsAlloc(
                allocator,
                codepoints,
                .nfd,
            );
            break :blk normalized_owned orelse codepoints;
        },
    };

    // Root collation without weighting or case-level options can emit the
    // three levels directly while scanning, skipping the collation-element
    // buffer and its second pass. Short inputs stay on the buffered path:
    // their elements fit in the stack buffer, where the extra pass is
    // cheaper than three interleaved level buffers.
    if (source.len > 512 and locale_tailoring == null and !shifted and
        case_first == .off and !backwards and !options.numeric and
        !options.case_level and options.strength != .quaternary)
    {
        return appendRootLevelsDirect(
            allocator,
            output,
            codepoints,
            source,
            options.strength,
        );
    }

    var stack_ces: [512]CollationElement = undefined;
    var ces = CeBuffer.init(allocator, &stack_ces);
    defer ces.deinit();
    try buildElements(
        allocator,
        source,
        options,
        locale_tailoring,
        tailoring_pages,
        reorder,
        shifted,
        &ces,
    );

    if (!shifted and (case_first != .upper or options.case_level)) {
        // The common path can emit levels straight from the collation
        // elements without materializing the weighted copy.
        if (!backwards and !options.case_level and
            try appendLevelElementsAll(
                allocator,
                output,
                ces.items(),
                options.strength,
            ))
        {
            if (options.strength == .identical) {
                try appendIdenticalLevel(allocator, output, codepoints);
            }
            return;
        }
        try appendLevelElements(allocator, output, ces.items(), .primary);
        if (options.strength == .primary) return;
        if (backwards) {
            try appendSecondaryLevelBackwardsElements(
                allocator,
                output,
                ces.items(),
            );
        } else {
            try appendLevelElements(allocator, output, ces.items(), .secondary);
        }
        if (options.strength == .secondary) return;
        if (options.case_level) {
            try appendCaseLevelElements(
                allocator,
                output,
                ces.items(),
                case_first,
            );
        }
        try appendLevelElements(allocator, output, ces.items(), .tertiary);
        if (options.strength == .tertiary) return;
        try output.append(allocator, 0);
        if (options.strength == .quaternary) return;
        try appendIdenticalLevel(allocator, output, codepoints);
        return;
    }

    const elements = try allocator.alloc(WeightedElement, ces.items().len);
    defer allocator.free(elements);
    transform(ces.items(), elements, shifted);
    if (case_first == .upper and !options.case_level) {
        applyCaseFirstUpper(elements);
    }

    try appendLevel(allocator, output, elements, .primary);
    if (options.strength == .primary) return;

    if (backwards) {
        try appendSecondaryLevelBackwards(allocator, output, elements);
    } else {
        try appendLevel(allocator, output, elements, .secondary);
    }
    if (options.strength == .secondary) return;

    if (options.case_level) {
        try appendCaseLevelWeighted(
            allocator,
            output,
            elements,
            case_first,
        );
    }
    try appendLevel(allocator, output, elements, .tertiary);
    if (options.strength == .tertiary) return;

    if (shifted) {
        try appendLevel(allocator, output, elements, .quaternary);
    } else {
        try output.append(allocator, 0);
    }
    if (options.strength == .quaternary) return;
    try appendIdenticalLevel(allocator, output, codepoints);
}

/// Compare two UTF-8 strings under the requested collation options.
pub fn compare(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    options: Options,
) error{ InvalidUtf8, OutOfMemory }!std.math.Order {
    const key_a = try sortKeyAlloc(allocator, a, options);
    defer allocator.free(key_a);
    const key_b = try sortKeyAlloc(allocator, b, options);
    defer allocator.free(key_b);
    return std.mem.order(u32, key_a, key_b);
}

/// Compare two UTF-16 strings.
pub fn compareUtf16(
    allocator: std.mem.Allocator,
    a: []const u16,
    b: []const u16,
    options: Options,
) error{ InvalidUtf16, OutOfMemory }!std.math.Order {
    const collator = Collator.init(options);
    var key_a = std.ArrayList(u32).empty;
    defer key_a.deinit(allocator);
    var key_b = std.ArrayList(u32).empty;
    defer key_b.deinit(allocator);
    return collator.compareUtf16(allocator, a, b, &key_a, &key_b);
}

const EntryMatch = struct {
    entry: Entry,
    length: usize,
};

fn findContiguous(codepoints: []const u21, index: usize) ?EntryMatch {
    return findContiguousFrom(codepoints, index, pageStart(codepoints[index]));
}

fn findContiguousFrom(
    codepoints: []const u21,
    index: usize,
    entry_index: usize,
) ?EntryMatch {
    const first = codepoints[index];
    var cursor = entry_index;
    while (cursor < @as(usize, entry_count)) : (cursor += 1) {
        const entry = entryAt(cursor);
        if (entry.first != first) break;

        const length = @as(usize, entry.len);
        if (length > codepoints.len - index) continue;
        if (length > 1 and entry.second != codepoints[index + 1]) continue;
        if (length > 2 and entry.third != codepoints[index + 2]) continue;
        return .{ .entry = entry, .length = length };
    }
    return null;
}

fn findEntryExact(sequence: []const u21) ?Entry {
    const first = sequence[0];
    var entry_index = pageStart(first);
    while (entry_index < @as(usize, entry_count)) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.first != first) break;
        if (entry.len != sequence.len) continue;
        if (sequence.len > 1 and entry.second != sequence[1]) continue;
        if (sequence.len > 2 and entry.third != sequence[2]) continue;
        return entry;
    }
    return null;
}

fn reorderPrimary(map: tailorings.Reorder, primary: u32) u32 {
    if (primary == 0 or primary >= 0xFFFD000) return primary;
    var low: usize = 0;
    var high = map.groupCount();
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (map.oldStart(middle) <= primary) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == 0) return primary;
    const index = low - 1;
    if (primary >= map.oldEnd(index)) return primary;
    return map.newBase(index) + (primary - map.oldStart(index));
}

fn appendEntry(
    allocator: std.mem.Allocator,
    ces: anytype,
    entry: Entry,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!void {
    var last_group_primary: u32 = 0;
    var ce_index: usize = 0;
    while (ce_index < @as(usize, entry.ce_count)) : (ce_index += 1) {
        const element = ceAt(@as(usize, entry.ce_offset) + ce_index);
        var primary = element.primary;
        if (reorder) |map| {
            if (primary >= 0xFFFD000) {
                // Reserved and trailing weights are never reordered.
                last_group_primary = 0;
            } else if (primary != 0) {
                if (primary >= 0x8000000 and primary < 0xFB40000 and
                    last_group_primary >= 0xFB40000)
                {
                    // Implicit continuation of the preceding Han/unassigned CE.
                    primary = map.contBase() + (primary - 0x8000000);
                } else {
                    primary = reorderPrimary(map, primary);
                    last_group_primary = element.primary;
                }
            }
        }
        try ces.append(allocator, .{
            .primary = primary,
            .secondary = element.secondary,
            .tertiary = element.tertiary,
            .variable = element.variable,
        });
    }
}

fn appendTailored(
    allocator: std.mem.Allocator,
    ces: *CeBuffer,
    rule: tailorings.Rule,
) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < @as(usize, rule.ce_count)) : (index += 1) {
        const element = tailorings.elementAt(rule, index);
        try ces.append(allocator, .{
            .primary = element.primary,
            .secondary = element.secondary,
            .tertiary = element.tertiary,
            .variable = element.variable,
        });
    }
}

inline fn appendImplicit(
    allocator: std.mem.Allocator,
    ces: anytype,
    codepoint: u21,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!void {
    const weights = implicitWeights(codepoint);
    var first = weights.first;
    var second = weights.second;
    if (reorder) |map| {
        const group = if (weights.unified)
            map.haniGroup()
        else
            map.othersGroup();
        if (group < map.groupCount()) {
            const old_start = map.oldStart(group);
            if (first >= old_start) {
                first = map.newBase(group) + (first - old_start);
            }
        }
        second = map.contBase() + (second - 0x8000000);
    }
    try ces.append(allocator, .{
        .primary = first,
        .secondary = 0x20000,
        .tertiary = 0x02000,
        .variable = false,
    });
    try ces.append(allocator, .{
        .primary = second,
        .secondary = 0,
        .tertiary = 0,
        .variable = false,
    });
}

fn appendSingle(
    allocator: std.mem.Allocator,
    ces: *CeBuffer,
    codepoint: u21,
    reorder: ?tailorings.Reorder,
) error{OutOfMemory}!void {
    const sequence = [_]u21{codepoint};
    if (findEntryExact(&sequence)) |entry| {
        return appendEntry(allocator, ces, entry, reorder);
    }
    return appendImplicit(allocator, ces, codepoint, reorder);
}

const ReorderAsciiSlot = struct {
    /// 0 = empty, 1 = building, 2 = published.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    index: u16 = 0,
    entries: [128]AsciiEntry = undefined,
};

var reorder_ascii_slots = [_]ReorderAsciiSlot{.{}} ** 4;
var reorder_ascii_next = std.atomic.Value(usize).init(0);

threadlocal var cached_reorder_index: u16 = 0xFFFF;
threadlocal var cached_reorder_ascii: ?*const [128]AsciiEntry = null;

/// ASCII elements remapped by `map`. Script reordering also moves Latin
/// primary weights, so the root table cannot be used directly; the remapped
/// copy is built once per plan and cached per thread.
fn reorderedAsciiTable(map: tailorings.Reorder) ?*const [128]AsciiEntry {
    if (cached_reorder_index == map.index) {
        if (cached_reorder_ascii) |table| return table;
    }
    for (&reorder_ascii_slots) |*slot| {
        if (slot.state.load(.acquire) == 2 and slot.index == map.index) {
            cached_reorder_index = map.index;
            cached_reorder_ascii = &slot.entries;
            return &slot.entries;
        }
    }
    const claimed = reorder_ascii_next.fetchAdd(1, .monotonic);
    if (claimed >= reorder_ascii_slots.len) return null;
    const slot = &reorder_ascii_slots[claimed];
    if (slot.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        return null;
    }
    for (0..128) |codepoint| {
        const entry = ascii_elements_table[codepoint];
        var stored = AsciiEntry{ .count = entry.count, .elements = undefined };
        for (entry.elements[0..entry.count], 0..) |element, element_index| {
            stored.elements[element_index] = .{
                .primary = reorderPrimary(map, element.primary),
                .secondary = element.secondary,
                .tertiary = element.tertiary,
            };
        }
        slot.entries[codepoint] = stored;
    }
    slot.index = map.index;
    slot.state.store(2, .release);
    cached_reorder_index = map.index;
    cached_reorder_ascii = &slot.entries;
    return &slot.entries;
}

/// Single-element Latin-1 entry for `first`, remapped by `map`. Script
/// reordering also shifts these primary weights, and the root direct table is
/// unavailable when a reorder is active, so the remapped element is cached per
/// thread. Returns null for multi-element entries, which keep the full path.
inline fn reorderedLatinElement(
    first: u21,
    map: tailorings.Reorder,
) ?CollationElement {
    if (!latin_elements.usable or first >= latin_limit) return null;
    const tag = (@as(u64, 1) << 63) |
        (@as(u64, map.index) << 21) | first;
    const cached = tailorings.cachedElement(first);
    if (cached.tag == tag + 1 and cached.kind == .single) {
        return .{
            .primary = cached.primary,
            .secondary = cached.secondary,
            .tertiary = cached.tertiary,
            .variable = false,
        };
    }
    const entry = latin_elements.table[@as(usize, first)];
    if (entry.count != 1) return null;
    const element = entry.elements[0];
    const primary = reorderPrimary(map, element.primary);
    cached.* = .{
        .tag = tag + 1,
        .primary = primary,
        .secondary = element.secondary,
        .tertiary = element.tertiary,
        .kind = .single,
        .variable = false,
    };
    return .{
        .primary = primary,
        .secondary = element.secondary,
        .tertiary = element.tertiary,
        .variable = false,
    };
}

/// ASCII elements for `first`, remapped for `reorder` when one applies.
/// Returns a pointer so the caller iterates the entry in place instead of
/// copying the multi-element record.
inline fn asciiEntryFor(
    first: u21,
    reorder: ?tailorings.Reorder,
) ?*const AsciiEntry {
    if (reorder) |map| {
        const table = reorderedAsciiTable(map) orelse return null;
        return &table[@as(usize, first)];
    }
    return &ascii_elements_table[@as(usize, first)];
}

inline fn appendElements(
    allocator: std.mem.Allocator,
    ces: anytype,
    codepoints: []const u21,
    index: usize,
    reorder: ?tailorings.Reorder,
    shifted: bool,
    tables: ?*const RootTables,
) error{OutOfMemory}!usize {
    const first = codepoints[index];
    // Root ASCII entries are precomputed; keep that hot path inline and let
    // the contraction, mark, and implicit cases pay a call.
    if (!shifted and first < 128 and ascii_usable and
        !ascii_contractions[@as(usize, first)])
    {
        const ascii_entry = asciiEntryFor(first, reorder) orelse
            return appendElementsSlow(
                allocator,
                ces,
                codepoints,
                index,
                reorder,
                shifted,
                tables,
            );
        for (ascii_entry.elements[0..ascii_entry.count]) |element| {
            try ces.append(allocator, .{
                .primary = element.primary,
                .secondary = element.secondary,
                .tertiary = element.tertiary,
                .variable = false,
            });
        }
        return 1;
    }
    if (!shifted and first >= 128 and first < latin_limit) {
        if (reorder) |map| {
            if (reorderedLatinElement(first, map)) |element| {
                try ces.append(allocator, element);
                return 1;
            }
        }
    }
    return appendElementsSlow(
        allocator,
        ces,
        codepoints,
        index,
        reorder,
        shifted,
        tables,
    );
}

fn appendElementsSlow(
    allocator: std.mem.Allocator,
    ces: anytype,
    codepoints: []const u21,
    index: usize,
    reorder: ?tailorings.Reorder,
    shifted: bool,
    tables: ?*const RootTables,
) error{OutOfMemory}!usize {
    const first = codepoints[index];
    if (tables) |root| {
        if (first < direct_bmp_limit) {
            const entry = &root.direct[first];
            switch (entry.kind) {
                .direct => {
                    try ces.append(allocator, .{
                        .primary = entry.primary,
                        .secondary = entry.secondary,
                        .tertiary = entry.tertiary,
                        .variable = entry.variable,
                    });
                    return 1;
                },
                .implicit => {
                    try appendImplicit(allocator, ces, first, reorder);
                    return 1;
                },
                .complex => {},
            }
        }
        if (!root.page_has_entries[first >> 8]) {
            try appendImplicit(allocator, ces, first, reorder);
            return 1;
        }
    }
    var sequence: [3]u21 = .{ codepoints[index], 0, 0 };
    var length: usize = 1;
    var entry: ?Entry = null;

    // Without an explicit entry there is no contraction to extend, so the
    // discontiguous-mark scan below cannot change the result.
    const first_entry = pageStart(first);
    if (first_entry >= entry_count or entryAt(first_entry).first != first) {
        try appendImplicit(allocator, ces, first, reorder);
        return 1;
    }

    if (findContiguousFrom(codepoints, index, first_entry)) |matched| {
        entry = matched.entry;
        length = matched.length;
        if (length > 1) sequence[1] = codepoints[index + 1];
        if (length > 2) sequence[2] = codepoints[index + 2];
    }

    // S2.1.1-S2.1.3: extend the initial match with unblocked following
    // non-starters, which handles discontiguous contractions. Skipped
    // non-starters are emitted after the contraction's collation elements.
    var skipped = std.ArrayList(u21).empty;
    defer skipped.deinit(allocator);

    var cursor = index + length;
    while (cursor < codepoints.len) {
        const candidate = codepoints[cursor];
        // U+0300 is the first code point with a non-zero combining class.
        if (candidate < 0x300) break;
        const candidate_class = combining_class.forCodepoint(candidate);
        if (candidate_class == 0) break;

        var blocked = false;
        for (skipped.items) |skipped_codepoint| {
            if (combining_class.forCodepoint(skipped_codepoint) >=
                candidate_class)
            {
                blocked = true;
                break;
            }
        }

        if (!blocked and length < sequence.len) {
            sequence[length] = candidate;
            if (findEntryExact(sequence[0 .. length + 1])) |extended| {
                entry = extended;
                length += 1;
                cursor += 1;
                continue;
            }
        }

        try skipped.append(allocator, candidate);
        cursor += 1;
    }

    if (entry) |matched| {
        try appendEntry(allocator, ces, matched, reorder);
    } else {
        try appendImplicit(allocator, ces, sequence[0], reorder);
    }
    var skipped_offset: usize = 0;
    while (skipped_offset < skipped.items.len) {
        skipped_offset += try appendElements(
            allocator,
            ces,
            skipped.items,
            skipped_offset,
            reorder,
            shifted,
            tables,
        );
    }
    return cursor - index;
}

/// Emit root-collation sort-key levels directly from the collation-element
/// stream, without materializing the intermediate element buffer.
fn appendRootLevelsDirect(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    source: []const u21,
    strength: Strength,
) error{OutOfMemory}!void {
    return switch (strength) {
        .primary => appendRootLevelsStrength(
            allocator,
            output,
            codepoints,
            source,
            .primary,
        ),
        .secondary => appendRootLevelsStrength(
            allocator,
            output,
            codepoints,
            source,
            .secondary,
        ),
        .tertiary => appendRootLevelsStrength(
            allocator,
            output,
            codepoints,
            source,
            .tertiary,
        ),
        .identical => appendRootLevelsStrength(
            allocator,
            output,
            codepoints,
            source,
            .identical,
        ),
        .quaternary => unreachable,
    };
}

fn appendRootLevelsStrength(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    source: []const u21,
    comptime strength: Strength,
) error{OutOfMemory}!void {
    var primary_stack: [512]u32 = undefined;
    var secondary_stack: [512]u32 = undefined;
    var tertiary_stack: [512]u32 = undefined;
    var primary = LevelBuffer.init(allocator, &primary_stack);
    defer primary.deinit();
    var secondary = LevelBuffer.init(allocator, &secondary_stack);
    defer secondary.deinit();
    var tertiary = LevelBuffer.init(allocator, &tertiary_stack);
    defer tertiary.deinit();
    var sink = LevelSink(strength){
        .primary = &primary,
        .secondary = &secondary,
        .tertiary = &tertiary,
    };

    var index: usize = 0;
    while (index < source.len) {
        index += try appendElements(
            allocator,
            &sink,
            source,
            index,
            null,
            false,
            &root_tables_storage,
        );
    }

    const need_secondary = strength != .primary;
    const need_tertiary = strength != .primary and strength != .secondary;
    const separator = strength == .identical;
    const total = primary.items().len + 1 +
        (if (need_secondary) secondary.items().len + 1 else 0) +
        (if (need_tertiary) tertiary.items().len + 1 else 0) +
        @as(usize, @intFromBool(separator));
    try output.ensureTotalCapacityPrecise(allocator, total);
    output.appendSliceAssumeCapacity(primary.items());
    output.appendAssumeCapacity(0);
    if (need_secondary) {
        output.appendSliceAssumeCapacity(secondary.items());
        output.appendAssumeCapacity(0);
    }
    if (need_tertiary) {
        output.appendSliceAssumeCapacity(tertiary.items());
        output.appendAssumeCapacity(0);
    }
    if (separator) {
        output.appendAssumeCapacity(0);
        try appendIdenticalLevel(allocator, output, codepoints);
    }
}

const LatinElement = struct {
    primary: u32,
    secondary: u32,
    tertiary: u32,
};

const LatinEntry = struct {
    count: u8,
    elements: [4]LatinElement,
};

/// Latin-1 Supplement and Latin Extended-A/B, which cover the precomposed
/// letters and combining marks of Latin-script text after NFD.
pub const latin_limit: usize = 0x370;

/// Recursive canonical decomposition for every scalar the tailored Latin
/// fast path accepts. Precomposed Latin letters decompose to at most four
/// scalars, so a direct table replaces the generated binary search in the
/// hottest NFD path.
const LatinNfd = struct {
    parts: [4]u21 = .{ 0, 0, 0, 0 },
    len: u4 = 0,
};

const latin_nfd: [latin_limit]LatinNfd = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [latin_limit]LatinNfd = [_]LatinNfd{.{}} ** latin_limit;
    for (0..latin_limit) |codepoint| {
        const mapping = normalization.decompositionFor(@intCast(codepoint)) orelse
            continue;
        if (mapping.len > 4) {
            @compileError("Latin decomposition longer than four scalars");
        }
        table[codepoint].len = @intCast(mapping.len);
        for (mapping, 0..) |part, index| table[codepoint].parts[index] = part;
    }
    break :blk table;
};

/// Direct root-collation results for the first 4096 scalars. Most letters in
/// the BMP scripts that dominate mixed text (Hebrew, Arabic, Indic) have
/// exactly one single-element entry, so the page lookup, contraction scan,
/// and skipped-mark loop can be bypassed with one table read.
const direct_bmp_limit: usize = 0x1000;

const DirectKind = enum(u2) { complex, direct, implicit };

const DirectEntry = struct {
    kind: DirectKind = .complex,
    primary: u32 = 0,
    secondary: u32 = 0,
    tertiary: u32 = 0,
    variable: bool = false,
};

const RootTables = struct {
    direct: [direct_bmp_limit]DirectEntry = undefined,
    /// True when at least one root entry starts on the 256-scalar page.
    page_has_entries: [0x1100]bool = undefined,
};

var root_tables_storage: RootTables = undefined;
var root_tables_state = std.atomic.Value(u8).init(0);

/// Build the root lookup tables once per process. Doing this at runtime
/// keeps them out of the comptime build cost while every later lookup is
/// still a single table read.
fn ensureRootTables() void {
    if (root_tables_state.load(.acquire) == 2) return;
    while (root_tables_state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        if (root_tables_state.load(.acquire) == 2) return;
        std.atomic.spinLoopHint();
    }
    for (0..direct_bmp_limit) |codepoint| {
        var entry_index = pageStart(@intCast(codepoint));
        var single: ?Entry = null;
        var has_long = false;
        while (entry_index < entry_count) : (entry_index += 1) {
            const entry = entryAt(entry_index);
            if (entry.first != codepoint) break;
            if (entry.len > 1) {
                has_long = true;
                continue;
            }
            if (single != null) has_long = true;
            single = entry;
        }
        if (has_long) {
            root_tables_storage.direct[codepoint] = .{ .kind = .complex };
            continue;
        }
        if (single) |entry| {
            if (entry.ce_count != 1) {
                root_tables_storage.direct[codepoint] = .{ .kind = .complex };
                continue;
            }
            const element = ceAt(entry.ce_offset);
            root_tables_storage.direct[codepoint] = .{
                .kind = .direct,
                .primary = element.primary,
                .secondary = element.secondary,
                .tertiary = element.tertiary,
                .variable = element.variable,
            };
        } else {
            root_tables_storage.direct[codepoint] = .{ .kind = .implicit };
        }
    }
    for (0..0x1100) |page| {
        const entry_index = pageStart(@intCast(page << 8));
        const page_end: u32 = @intCast((page + 1) << 8);
        root_tables_storage.page_has_entries[page] =
            entry_index < entry_count and entryAt(entry_index).first < page_end;
    }
    root_tables_state.store(2, .release);
}

const latin_elements = blk: {
    @setEvalBranchQuota(2_000_000);
    var table: [latin_limit]LatinEntry = undefined;
    var usable = true;
    for (0..latin_limit) |codepoint| {
        const sequence = [_]u21{@intCast(codepoint)};
        if (findEntryExact(&sequence)) |entry| {
            if (entry.len != 1 or entry.ce_count > 4) {
                usable = false;
                table[codepoint] = .{ .count = 0, .elements = undefined };
                continue;
            }
            var stored = LatinEntry{
                .count = entry.ce_count,
                .elements = undefined,
            };
            var element_index: usize = 0;
            while (element_index < entry.ce_count) : (element_index += 1) {
                const element = ceAt(
                    @as(usize, entry.ce_offset) + element_index,
                );
                stored.elements[element_index] = .{
                    .primary = element.primary,
                    .secondary = element.secondary,
                    .tertiary = element.tertiary,
                };
            }
            table[codepoint] = stored;
        } else {
            usable = false;
            table[codepoint] = .{ .count = 0, .elements = undefined };
        }
    }
    // Contractions that start and continue inside the table would make the
    // one-character entries incomplete. The root table only has `L`/`l`
    // followed by U+00B7; the fast path falls back for that pair.
    var entry_index = pageStart(0);
    while (entry_index < entry_count) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.first >= latin_limit) break;
        if (entry.len > 1 and entry.second < latin_limit and
            !((entry.first == 'L' or entry.first == 'l') and
                entry.second == 0xb7))
        {
            usable = false;
        }
    }
    break :blk .{ .usable = usable, .table = table };
};

const ascii_usable = ascii_layout.usable;
/// Runtime copy so the hot path can take a pointer into the table instead of
/// copying an entry by value.
var ascii_elements_table: [128]AsciiEntry = ascii_layout.table;

const AsciiEntry = struct {
    count: u8,
    elements: [2]LatinElement,
};

/// Compact table for pure-ASCII text. Latin-1/Extended entries need up to
/// four elements and would quadruple the cache footprint of the hottest
/// collation path.
const ascii_layout = blk: {
    @setEvalBranchQuota(2_000_000);
    var table: [128]AsciiEntry = undefined;
    var usable = true;
    for (0..128) |codepoint| {
        const sequence = [_]u21{@intCast(codepoint)};
        if (findEntryExact(&sequence)) |entry| {
            if (entry.len != 1 or entry.ce_count > 2) {
                usable = false;
                table[codepoint] = .{ .count = 0, .elements = undefined };
                continue;
            }
            var stored = AsciiEntry{
                .count = entry.ce_count,
                .elements = undefined,
            };
            var element_index: usize = 0;
            while (element_index < entry.ce_count) : (element_index += 1) {
                const element = ceAt(
                    @as(usize, entry.ce_offset) + element_index,
                );
                stored.elements[element_index] = .{
                    .primary = element.primary,
                    .secondary = element.secondary,
                    .tertiary = element.tertiary,
                };
            }
            table[codepoint] = stored;
        } else {
            usable = false;
            table[codepoint] = .{ .count = 0, .elements = undefined };
        }
    }
    // A contraction whose continuation is also ASCII could match inside a
    // pure-ASCII string, so the one-character table would be incomplete.
    var entry_index = pageStart(0);
    while (entry_index < entry_count) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.first >= 128) break;
        if (entry.len > 1 and (entry.second < 128 or
            (entry.len > 2 and entry.third < 128)))
        {
            usable = false;
        }
    }
    break :blk .{ .usable = usable, .table = table };
};

/// ASCII code points that start a contraction; those keep the generic path.
const ascii_contractions = blk: {
    @setEvalBranchQuota(100_000);
    var flags = [_]bool{false} ** 128;
    var entry_index = pageStart(0);
    while (entry_index < entry_count) : (entry_index += 1) {
        const entry = entryAt(entry_index);
        if (entry.first >= 128) break;
        if (entry.len > 1) flags[@as(usize, entry.first)] = true;
    }
    break :blk flags;
};

/// Emit all requested levels from one pass over pure-ASCII text.
fn appendAsciiLevels(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    strength: Strength,
) error{OutOfMemory}!bool {
    var primary: [1024]u32 = undefined;
    var secondary: [1024]u32 = undefined;
    var tertiary: [1024]u32 = undefined;
    var primary_len: usize = 0;
    var secondary_len: usize = 0;
    var tertiary_len: usize = 0;
    const need_secondary = strength != .primary;
    const need_tertiary = strength != .primary and strength != .secondary;
    for (codepoints) |codepoint| {
        const entry = ascii_elements_table[codepoint];
        for (entry.elements[0..entry.count]) |element| {
            if (element.primary != 0) {
                if (primary_len == primary.len) return false;
                primary[primary_len] = element.primary;
                primary_len += 1;
            }
            if (need_secondary and element.secondary != 0) {
                if (secondary_len == secondary.len) return false;
                secondary[secondary_len] = element.secondary;
                secondary_len += 1;
            }
            if (need_tertiary and element.tertiary != 0) {
                if (tertiary_len == tertiary.len) return false;
                tertiary[tertiary_len] = element.tertiary;
                tertiary_len += 1;
            }
        }
    }
    const separator = strength == .quaternary or strength == .identical;
    const total: usize = primary_len + 1 +
        (if (need_secondary) secondary_len + 1 else 0) +
        (if (need_tertiary) tertiary_len + 1 else 0) +
        @as(usize, @intFromBool(separator));
    try output.ensureTotalCapacityPrecise(allocator, total);
    output.appendSliceAssumeCapacity(primary[0..primary_len]);
    output.appendAssumeCapacity(0);
    if (need_secondary) {
        output.appendSliceAssumeCapacity(secondary[0..secondary_len]);
        output.appendAssumeCapacity(0);
    }
    if (need_tertiary) {
        output.appendSliceAssumeCapacity(tertiary[0..tertiary_len]);
        output.appendAssumeCapacity(0);
    }
    if (separator) output.appendAssumeCapacity(0);
    return true;
}

fn appendAsciiLevel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    level: Level,
) error{OutOfMemory}!void {
    for (codepoints) |codepoint| {
        const entry = ascii_elements_table[codepoint];
        for (entry.elements[0..entry.count]) |element| {
            const weight = switch (level) {
                .primary => element.primary,
                .secondary => element.secondary,
                .tertiary => element.tertiary,
                .quaternary => 0,
            };
            if (weight != 0) try output.append(allocator, weight);
        }
    }
    try output.append(allocator, 0);
}

/// Emit a root-order sort key for Latin-script text from a compact table,
/// bypassing page lookups and the collation-element list. Text with
/// precomposed letters is decomposed into a stack buffer first.
/// Emit the root sort key for ASCII-only text straight from the
/// precomputed table, without a collation-element buffer.
fn appendAsciiSortKey(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    strength: Strength,
) error{OutOfMemory}!void {
    if (try appendAsciiLevels(allocator, output, codepoints, strength)) {
        if (strength == .identical) {
            try appendIdenticalLevel(allocator, output, codepoints);
        }
        return;
    }
    try output.ensureTotalCapacity(allocator, codepoints.len * 6 + 8);
    try appendAsciiLevel(allocator, output, codepoints, .primary);
    if (strength == .primary) return;
    try appendAsciiLevel(allocator, output, codepoints, .secondary);
    if (strength == .secondary) return;
    try appendAsciiLevel(allocator, output, codepoints, .tertiary);
    if (strength == .tertiary) return;
    try output.append(allocator, 0);
    if (strength == .quaternary) return;
    try appendIdenticalLevel(allocator, output, codepoints);
}

fn appendLatinSortKey(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    strength: Strength,
) error{OutOfMemory}!bool {
    if (!latin_elements.usable) return false;
    var all_ascii = true;
    for (codepoints) |codepoint| {
        if (codepoint >= latin_limit) return false;
        if (codepoint >= 0x80) all_ascii = false;
    }

    if (all_ascii and ascii_usable) {
        try appendAsciiSortKey(allocator, output, codepoints, strength);
        return true;
    }

    var buffer: [1024]u21 = undefined;
    const source = if (all_ascii)
        codepoints
    else
        normalizeNfdLatinInto(&buffer, codepoints) orelse return false;

    // `L`/`l` + U+00B7 is a root contraction; use the general path for it.
    for (source, 0..) |codepoint, index| {
        if ((codepoint == 'L' or codepoint == 'l') and
            index + 1 < source.len and source[index + 1] == 0xb7)
        {
            return false;
        }
    }

    if (try appendLatinLevels(allocator, output, source, strength)) {
        if (strength == .identical) {
            try appendIdenticalLevel(allocator, output, codepoints);
        }
        return true;
    }
    try output.ensureTotalCapacity(allocator, source.len * 9 + 8);
    try appendLatinLevel(allocator, output, source, .primary);
    if (strength == .primary) return true;
    try appendLatinLevel(allocator, output, source, .secondary);
    if (strength == .secondary) return true;
    try appendLatinLevel(allocator, output, source, .tertiary);
    if (strength == .tertiary) return true;
    try output.append(allocator, 0);
    if (strength == .quaternary) return true;
    try appendIdenticalLevel(allocator, output, codepoints);
    return true;
}

/// Emit a root sort key directly for text made only of code points that
/// receive implicit weights: no explicit entries, contractions, or
/// combining marks. Han, emoji, and unassigned text take this path.
fn appendImplicitSortKey(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    strength: Strength,
) error{OutOfMemory}!bool {
    if (strength != .primary and strength != .secondary and
        strength != .tertiary)
    {
        return false;
    }
    // The caller already proved the input is NFD.
    for (codepoints, 0..) |codepoint, index| {
        if (codepoint >= 0x300 and
            combining_class.forCodepoint(codepoint) != 0)
        {
            return false;
        }
        if (findContiguous(codepoints, index) != null) return false;
    }

    const count = codepoints.len;
    try output.ensureTotalCapacity(allocator, count * 4 + 8);
    for (codepoints) |codepoint| {
        const weights = implicitWeights(codepoint);
        output.appendAssumeCapacity(weights.first);
        output.appendAssumeCapacity(weights.second);
    }
    output.appendAssumeCapacity(0);
    if (strength == .primary) return true;
    for (0..count) |_| output.appendAssumeCapacity(0x20000);
    output.appendAssumeCapacity(0);
    if (strength == .secondary) return true;
    for (0..count) |_| output.appendAssumeCapacity(0x02000);
    output.appendAssumeCapacity(0);
    return true;
}

/// Tailored variant of the Latin fast path: tailored rules are matched with
/// the page index and every other code point comes from the root table.
fn appendTailoredLatinSortKey(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    tailoring: tailorings.Tailoring,
    pages: ?*tailorings.PageIndex,
    strength: Strength,
) error{OutOfMemory}!bool {
    if (!latin_elements.usable) return false;
    if (tailoring.reorder != null or tailoring.case_first != .off or
        tailoring.backwards)
    {
        return false;
    }
    var all_ascii = true;
    for (codepoints) |codepoint| {
        if (codepoint >= latin_limit) return false;
        if (codepoint >= 0x80) all_ascii = false;
    }
    // ASCII text sorts like the root collation when the tailoring has no
    // rule starting with an ASCII code point.
    if (all_ascii and ascii_usable) {
        if (pages) |page_index| {
            if (page_index.ascii_untailored) {
                try appendAsciiSortKey(allocator, output, codepoints, strength);
                return true;
            }
        }
    }
    var buffer: [1024]u21 = undefined;
    const source = normalizeNfdLatinInto(&buffer, codepoints) orelse return false;

    // `L`/`l` + U+00B7 is a root contraction; the general path handles it.
    for (source, 0..) |codepoint, index| {
        if ((codepoint == 'L' or codepoint == 'l') and
            index + 1 < source.len and source[index + 1] == 0xb7)
        {
            return false;
        }
    }

    var stack_ces: [512]LatinElement = undefined;
    var ces = ElementBuffer(LatinElement).init(allocator, &stack_ces);
    defer ces.deinit();
    try ces.ensureTotalCapacity(source.len + 8);
    var index: usize = 0;
    while (index < source.len) {
        const codepoint = source[index];
        if (pages) |page_index| {
            if (codepoint < latin_limit) {
                const direct = page_index.single_rules[codepoint];
                if (direct >= 2) {
                    const rule = tailorings.ruleAt(
                        tailoring.rule_start + direct - 2,
                    );
                    var element_index: usize = 0;
                    while (element_index < rule.ce_count) : (element_index += 1) {
                        const element = tailorings.elementAt(rule, element_index);
                        try ces.append(allocator, .{
                            .primary = element.primary,
                            .secondary = element.secondary,
                            .tertiary = element.tertiary,
                        });
                    }
                    index += 1;
                    continue;
                }
                if (direct == 0) {
                    const entry = latin_elements.table[codepoint];
                    for (entry.elements[0..entry.count]) |element| {
                        try ces.append(allocator, element);
                    }
                    index += 1;
                    continue;
                }
                // direct == 1: a contraction or multiple rules; use the
                // general matcher below.
            }
        }
        if (tailorings.couldMatch(pages, codepoint)) {
            if (tailorings.match(tailoring, pages, source, index)) |matched| {
                const rule = matched.rule;
                var element_index: usize = 0;
                while (element_index < rule.ce_count) : (element_index += 1) {
                    const element = tailorings.elementAt(rule, element_index);
                    try ces.append(allocator, .{
                        .primary = element.primary,
                        .secondary = element.secondary,
                        .tertiary = element.tertiary,
                    });
                }
                index += matched.length;
                continue;
            }
        }
        const entry = latin_elements.table[codepoint];
        for (entry.elements[0..entry.count]) |element| {
            try ces.append(allocator, element);
        }
        index += 1;
    }

    if (try appendLatinCesLevels(allocator, output, ces.items(), strength)) {
        if (strength == .identical) {
            try appendIdenticalLevel(allocator, output, codepoints);
        }
        return true;
    }
    try output.ensureTotalCapacity(allocator, ces.items().len * 3 + 8);
    try appendLatinCesLevel(allocator, output, ces.items(), .primary);
    if (strength == .primary) return true;
    try appendLatinCesLevel(allocator, output, ces.items(), .secondary);
    if (strength == .secondary) return true;
    try appendLatinCesLevel(allocator, output, ces.items(), .tertiary);
    if (strength == .tertiary) return true;
    try output.append(allocator, 0);
    if (strength == .quaternary) return true;
    try appendIdenticalLevel(allocator, output, codepoints);
    return true;
}

/// Emit all requested levels from one pass over the tailored elements.
fn appendLatinCesLevels(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const LatinElement,
    strength: Strength,
) error{OutOfMemory}!bool {
    var primary: [1024]u32 = undefined;
    var secondary: [1024]u32 = undefined;
    var tertiary: [1024]u32 = undefined;
    var primary_len: usize = 0;
    var secondary_len: usize = 0;
    var tertiary_len: usize = 0;
    const need_secondary = strength != .primary;
    const need_tertiary = strength != .primary and strength != .secondary;
    for (elements) |element| {
        if (element.primary != 0) {
            if (primary_len == primary.len) return false;
            primary[primary_len] = element.primary;
            primary_len += 1;
        }
        if (need_secondary and element.secondary != 0) {
            if (secondary_len == secondary.len) return false;
            secondary[secondary_len] = element.secondary;
            secondary_len += 1;
        }
        if (need_tertiary and element.tertiary != 0) {
            if (tertiary_len == tertiary.len) return false;
            tertiary[tertiary_len] = element.tertiary;
            tertiary_len += 1;
        }
    }
    const separator = strength == .quaternary or strength == .identical;
    const total: usize = primary_len + 1 +
        (if (need_secondary) secondary_len + 1 else 0) +
        (if (need_tertiary) tertiary_len + 1 else 0) +
        @as(usize, @intFromBool(separator));
    try output.ensureTotalCapacityPrecise(allocator, total);
    output.appendSliceAssumeCapacity(primary[0..primary_len]);
    output.appendAssumeCapacity(0);
    if (need_secondary) {
        output.appendSliceAssumeCapacity(secondary[0..secondary_len]);
        output.appendAssumeCapacity(0);
    }
    if (need_tertiary) {
        output.appendSliceAssumeCapacity(tertiary[0..tertiary_len]);
        output.appendAssumeCapacity(0);
    }
    if (separator) output.appendAssumeCapacity(0);
    return true;
}

fn appendLatinCesLevel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const LatinElement,
    level: Level,
) error{OutOfMemory}!void {
    for (elements) |element| {
        const weight = switch (level) {
            .primary => element.primary,
            .secondary => element.secondary,
            .tertiary => element.tertiary,
            .quaternary => 0,
        };
        if (weight != 0) try output.append(allocator, weight);
    }
    try output.append(allocator, 0);
}

/// NFD for Latin-script code points into a fixed buffer, without allocating.
/// Returns null when the buffer is too small.
fn normalizeNfdLatinInto(
    buffer: []u21,
    codepoints: []const u21,
) ?[]const u21 {
    var length: usize = 0;
    var segment: [64]u21 = undefined;
    var segment_len: usize = 0;
    var pending: ?u21 = null;

    for (codepoints) |codepoint| {
        // ASCII is a starter with no decomposition; skip the decomposition
        // lookup for the common prose case.
        if (codepoint < 0x80) {
            if (segment_len > 0) {
                if (segment_len > 2 or segment[0] >= 0x80) {
                    normalization.canonicalOrder(segment[0..segment_len]);
                }
                if (length + segment_len > buffer.len) return null;
                @memcpy(
                    buffer[length..][0..segment_len],
                    segment[0..segment_len],
                );
                length += segment_len;
                segment_len = 0;
            }
            if (pending) |previous| {
                if (length == buffer.len) return null;
                buffer[length] = previous;
                length += 1;
            }
            pending = codepoint;
            continue;
        }
        std.debug.assert(codepoint < latin_limit);
        const entry = &latin_nfd[codepoint];
        var single: [1]u21 = undefined;
        const parts: []const u21 = if (entry.len == 0) blk: {
            single[0] = codepoint;
            break :blk &single;
        } else entry.parts[0..entry.len];
        for (parts) |part| {
            const starter = part < 0x80 or
                combining_class.forCodepoint(part) == 0;
            if (starter) {
                if (segment_len > 0) {
                    // A two-scalar segment with an ASCII starter is already
                    // in canonical order; only longer or mark-led segments
                    // can need reordering.
                    if (segment_len > 2 or segment[0] >= 0x80) {
                        normalization.canonicalOrder(segment[0..segment_len]);
                    }
                    if (length + segment_len > buffer.len) return null;
                    @memcpy(
                        buffer[length..][0..segment_len],
                        segment[0..segment_len],
                    );
                    length += segment_len;
                    segment_len = 0;
                }
                if (pending) |previous| {
                    if (length == buffer.len) return null;
                    buffer[length] = previous;
                    length += 1;
                }
                pending = part;
            } else {
                if (pending) |previous| {
                    segment[0] = previous;
                    segment_len = 1;
                    pending = null;
                }
                if (segment_len == segment.len) return null;
                segment[segment_len] = part;
                segment_len += 1;
            }
        }
    }
    if (segment_len > 0) {
        if (segment_len > 2 or segment[0] >= 0x80) {
            normalization.canonicalOrder(segment[0..segment_len]);
        }
        if (length + segment_len > buffer.len) return null;
        @memcpy(buffer[length..][0..segment_len], segment[0..segment_len]);
        length += segment_len;
    }
    if (pending) |previous| {
        if (length == buffer.len) return null;
        buffer[length] = previous;
        length += 1;
    }
    return buffer[0..length];
}

/// Identical level: the per-code-point canonical decomposition of the input,
/// offset by one so the zero level terminator stays below every weight. ICU
/// decomposes each code point in place, so combining marks keep their input
/// order (the collation levels above already ignored that difference).
fn appendIdenticalLevel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    source: []const u21,
) error{OutOfMemory}!void {
    var decomposed = std.ArrayList(u21).empty;
    defer decomposed.deinit(allocator);
    for (source) |codepoint| {
        decomposed.clearRetainingCapacity();
        try normalization.appendCanonicalDecompositionInto(
            allocator,
            codepoint,
            &decomposed,
        );
        for (decomposed.items) |value| {
            try output.append(allocator, @as(u32, value) + 1);
        }
    }
    try output.append(allocator, 0);
}

/// Emit all requested levels from one pass over the source. Returns false
/// when the stack level buffers overflow, so the caller can use the
/// multi-pass path.
fn appendLatinLevels(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    source: []const u21,
    strength: Strength,
) error{OutOfMemory}!bool {
    var primary: [1024]u32 = undefined;
    var secondary: [1024]u32 = undefined;
    var tertiary: [1024]u32 = undefined;
    var primary_len: usize = 0;
    var secondary_len: usize = 0;
    var tertiary_len: usize = 0;
    const need_secondary = strength != .primary;
    const need_tertiary = strength != .primary and strength != .secondary;
    for (source) |codepoint| {
        const entry = latin_elements.table[codepoint];
        for (entry.elements[0..entry.count]) |element| {
            if (element.primary != 0) {
                if (primary_len == primary.len) return false;
                primary[primary_len] = element.primary;
                primary_len += 1;
            }
            if (need_secondary and element.secondary != 0) {
                if (secondary_len == secondary.len) return false;
                secondary[secondary_len] = element.secondary;
                secondary_len += 1;
            }
            if (need_tertiary and element.tertiary != 0) {
                if (tertiary_len == tertiary.len) return false;
                tertiary[tertiary_len] = element.tertiary;
                tertiary_len += 1;
            }
        }
    }
    const separator = strength == .quaternary or strength == .identical;
    const total: usize = primary_len + 1 +
        (if (need_secondary) secondary_len + 1 else 0) +
        (if (need_tertiary) tertiary_len + 1 else 0) +
        @as(usize, @intFromBool(separator));
    try output.ensureTotalCapacityPrecise(allocator, total);
    output.appendSliceAssumeCapacity(primary[0..primary_len]);
    output.appendAssumeCapacity(0);
    if (need_secondary) {
        output.appendSliceAssumeCapacity(secondary[0..secondary_len]);
        output.appendAssumeCapacity(0);
    }
    if (need_tertiary) {
        output.appendSliceAssumeCapacity(tertiary[0..tertiary_len]);
        output.appendAssumeCapacity(0);
    }
    if (separator) output.appendAssumeCapacity(0);
    return true;
}

fn appendLatinLevel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    codepoints: []const u21,
    level: Level,
) error{OutOfMemory}!void {
    for (codepoints) |codepoint| {
        const entry = latin_elements.table[codepoint];
        for (entry.elements[0..entry.count]) |element| {
            const weight = switch (level) {
                .primary => element.primary,
                .secondary => element.secondary,
                .tertiary => element.tertiary,
                .quaternary => 0,
            };
            if (weight != 0) try output.append(allocator, weight);
        }
    }
    try output.append(allocator, 0);
}

/// Decimal value of a `General_Category=Nd` code point, or null.
fn decimalValue(codepoint: u21) ?u8 {
    if (properties.category(codepoint) != .Nd) return null;
    var zero = codepoint;
    while (zero > 0 and properties.category(zero - 1) == .Nd) zero -= 1;
    return @intCast((@as(u32, codepoint) - @as(u32, zero)) % 10);
}

fn decimalRunEnd(codepoints: []const u21, start: usize) usize {
    var end = start;
    while (end < codepoints.len and decimalValue(codepoints[end]) != null) {
        end += 1;
    }
    return end;
}

const digit_zero = blk: {
    const sequence = [_]u21{'0'};
    const entry = findEntryExact(&sequence) orelse
        @compileError("missing digit collation entry");
    break :blk ceAt(entry.ce_offset);
};

comptime {
    @setEvalBranchQuota(100_000);
    for (0..10) |digit| {
        const sequence = [_]u21{'0' + @as(u21, @intCast(digit))};
        const entry = findEntryExact(&sequence) orelse
            @compileError("missing digit collation entry");
        const element = ceAt(entry.ce_offset);
        if (element.primary != digit_zero.primary + digit * 0x1000) {
            @compileError("digit collation primaries are not contiguous");
        }
    }
}

/// Emit collation elements for a decimal digit run. Length weights make
/// shorter numbers sort first; each significant digit then contributes its
/// numeric weight. Secondary and tertiary weights are the Latin digit's, so
/// digits from different numbering systems compare equal.
fn appendNumeric(
    allocator: std.mem.Allocator,
    ces: *CeBuffer,
    digits: []const u21,
) error{OutOfMemory}!void {
    var start: usize = 0;
    while (start + 1 < digits.len and decimalValue(digits[start]).? == 0) {
        start += 1;
    }
    const significant = digits.len - start;
    const length_bytes = [_]u32{
        @intCast((significant >> 16) & 0xff),
        @intCast((significant >> 8) & 0xff),
        @intCast(significant & 0xff),
    };
    for (length_bytes) |byte| {
        try ces.append(allocator, .{
            .primary = digit_zero.primary + byte * 0x1000,
            .secondary = digit_zero.secondary,
            .tertiary = digit_zero.tertiary,
            .variable = false,
        });
    }
    for (digits[start..]) |codepoint| {
        const value = decimalValue(codepoint).?;
        try ces.append(allocator, .{
            .primary = digit_zero.primary + @as(u32, value) * 0x1000,
            .secondary = digit_zero.secondary,
            .tertiary = digit_zero.tertiary,
            .variable = false,
        });
    }
}

const ImplicitWeights = struct {
    first: u32,
    second: u32,
    unified: bool,
};

inline fn implicitWeights(codepoint: u21) ImplicitWeights {
    // U+4E00..U+9FFF are all unified ideographs and dominate implicit
    // lookups, so they skip the property lookup.
    if (codepoint >= 0x4e00 and codepoint <= 0x9fff) {
        return .{
            .first = (0xFB40 + @as(u32, codepoint >> 15)) << 12,
            .second = ((@as(u32, codepoint) & 0x7fff) | 0x8000) << 12,
            .unified = true,
        };
    }
    if (properties.isUnifiedIdeograph(codepoint)) {
        const core = codepoint >= 0xf900 and codepoint <= 0xfaff;
        const base: u32 = if (core) 0xFB40 else 0xFB80;
        return .{
            .first = (base + @as(u32, codepoint >> 15)) << 12,
            .second = ((@as(u32, codepoint) & 0x7fff) | 0x8000) << 12,
            .unified = true,
        };
    }

    // Only the Tangut, Khitan, and Nushu ranges consult the range table.
    if (codepoint >= 0x17000 and codepoint <= 0x1b2ff and
        properties.category(codepoint) != .Cn)
    {
        for (implicit.ranges) |range| {
            if (codepoint < range.first or codepoint > range.last) continue;
            const bbbb: u32 = @as(u32, codepoint) - @as(u32, range.origin);
            return .{
                .first = range.base,
                .second = (bbbb | 0x8000) << 12,
                .unified = false,
            };
        }
    }

    return .{
        .first = (0xFBC0 + @as(u32, codepoint >> 15)) << 12,
        .second = ((@as(u32, codepoint) & 0x7fff) | 0x8000) << 12,
        .unified = false,
    };
}

fn transform(
    source: []const CollationElement,
    destination: []WeightedElement,
    shifted: bool,
) void {
    var after_variable = false;
    for (source, destination) |element, *out| {
        if (!shifted) {
            out.* = .{
                .primary = element.primary,
                .secondary = element.secondary,
                .tertiary = element.tertiary,
                .quaternary = 0,
            };
            continue;
        }

        if (element.variable) {
            out.* = .{
                .primary = 0,
                .secondary = 0,
                .tertiary = 0,
                .quaternary = element.primary,
            };
            after_variable = true;
            continue;
        }

        if (element.primary == 0) {
            if (after_variable or
                (element.secondary == 0 and element.tertiary == 0))
            {
                out.* = .{
                    .primary = 0,
                    .secondary = 0,
                    .tertiary = 0,
                    .quaternary = 0,
                };
            } else {
                out.* = .{
                    .primary = 0,
                    .secondary = element.secondary,
                    .tertiary = element.tertiary,
                    .quaternary = 0xFFFFFFFF,
                };
            }
            continue;
        }

        out.* = .{
            .primary = element.primary,
            .secondary = element.secondary,
            .tertiary = element.tertiary,
            .quaternary = 0xFFFFFFFF,
        };
        after_variable = false;
    }
}

const Level = enum { primary, secondary, tertiary, quaternary };

fn appendLevelElements(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const CollationElement,
    level: Level,
) error{OutOfMemory}!void {
    for (elements) |element| {
        const weight = switch (level) {
            .primary => element.primary,
            .secondary => element.secondary,
            .tertiary => element.tertiary,
            .quaternary => 0,
        };
        if (weight != 0) try output.append(allocator, weight);
    }
    try output.append(allocator, 0);
}

/// Emit primary/secondary/tertiary levels from one pass over the collation
/// elements. Returns false when the stack level buffers overflow.
fn appendLevelElementsAll(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const CollationElement,
    strength: Strength,
) error{OutOfMemory}!bool {
    var primary: [1024]u32 = undefined;
    var secondary: [1024]u32 = undefined;
    var tertiary: [1024]u32 = undefined;
    var primary_len: usize = 0;
    var secondary_len: usize = 0;
    var tertiary_len: usize = 0;
    const need_secondary = strength != .primary;
    const need_tertiary = strength != .primary and strength != .secondary;
    for (elements) |element| {
        if (element.primary != 0) {
            if (primary_len == primary.len) return false;
            primary[primary_len] = element.primary;
            primary_len += 1;
        }
        if (need_secondary and element.secondary != 0) {
            if (secondary_len == secondary.len) return false;
            secondary[secondary_len] = element.secondary;
            secondary_len += 1;
        }
        if (need_tertiary and element.tertiary != 0) {
            if (tertiary_len == tertiary.len) return false;
            tertiary[tertiary_len] = element.tertiary;
            tertiary_len += 1;
        }
    }
    const separator = strength == .quaternary or strength == .identical;
    const total: usize = primary_len + 1 +
        (if (need_secondary) secondary_len + 1 else 0) +
        (if (need_tertiary) tertiary_len + 1 else 0) +
        @as(usize, @intFromBool(separator));
    try output.ensureTotalCapacityPrecise(allocator, total);
    output.appendSliceAssumeCapacity(primary[0..primary_len]);
    output.appendAssumeCapacity(0);
    if (need_secondary) {
        output.appendSliceAssumeCapacity(secondary[0..secondary_len]);
        output.appendAssumeCapacity(0);
    }
    if (need_tertiary) {
        output.appendSliceAssumeCapacity(tertiary[0..tertiary_len]);
        output.appendAssumeCapacity(0);
    }
    if (separator) output.appendAssumeCapacity(0);
    return true;
}

fn appendCaseLevelElements(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const CollationElement,
    case_first: CaseFirst,
) error{OutOfMemory}!void {
    for (elements) |element| {
        if (element.tertiary == 0) continue;
        const upper = isUpperCaseTertiary(element.tertiary);
        const weight: u32 = if (case_first == .upper)
            (if (upper) 1 else 2)
        else
            (if (upper) 2 else 1);
        try output.append(allocator, weight);
    }
    try output.append(allocator, 0);
}

fn appendCaseLevelWeighted(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const WeightedElement,
    case_first: CaseFirst,
) error{OutOfMemory}!void {
    for (elements) |element| {
        if (element.tertiary == 0) continue;
        const upper = isUpperCaseTertiary(element.tertiary);
        const weight: u32 = if (case_first == .upper)
            (if (upper) 1 else 2)
        else
            (if (upper) 2 else 1);
        try output.append(allocator, weight);
    }
    try output.append(allocator, 0);
}

fn appendSecondaryLevelBackwardsElements(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const CollationElement,
) error{OutOfMemory}!void {
    var index = elements.len;
    while (index > 0) {
        index -= 1;
        if (elements[index].secondary != 0) {
            try output.append(allocator, elements[index].secondary);
        }
    }
    try output.append(allocator, 0);
}

fn appendLevel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const WeightedElement,
    level: Level,
) error{OutOfMemory}!void {
    for (elements) |element| {
        const weight = switch (level) {
            .primary => element.primary,
            .secondary => element.secondary,
            .tertiary => element.tertiary,
            .quaternary => element.quaternary,
        };
        if (weight != 0) try output.append(allocator, weight);
    }
    try output.append(allocator, 0);
}

/// Tertiary weights with the UCA uppercase case bits (see UTS #35, Case
/// Parameters). The root table has no mixed-case tertiary values.
fn isUpperCaseTertiary(tertiary: u32) bool {
    return switch (tertiary >> 12) {
        0x08...0x0C, 0x0E, 0x11, 0x12, 0x1D => true,
        else => false,
    };
}

/// `caseFirst=upper`: uppercase sorts before lowercase at the tertiary level.
/// The case class becomes the high part of the tertiary weight so that
/// variants within a class keep their relative order.
fn applyCaseFirstUpper(elements: []WeightedElement) void {
    for (elements) |*element| {
        if (element.tertiary == 0) continue;
        if (element.primary == 0 and element.secondary == 0) {
            // Tertiary-only CEs must stay greater than the tertiary weights of
            // primary and secondary CEs (UTS #10 WF2).
            element.tertiary += 3 << 24;
            continue;
        }
        const rank: u32 = if (isUpperCaseTertiary(element.tertiary)) 0 else 2;
        element.tertiary += rank << 24;
    }
}

/// French secondary ordering: compare secondary weights from the end of the
/// string. ICU delimits reversal segments with U+FFFE (the merge separator);
/// for normal text this is a whole-string reversal.
fn appendSecondaryLevelBackwards(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    elements: []const WeightedElement,
) error{OutOfMemory}!void {
    var index = elements.len;
    while (index > 0) {
        index -= 1;
        if (elements[index].secondary != 0) {
            try output.append(allocator, elements[index].secondary);
        }
    }
    try output.append(allocator, 0);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

test "basic collation ordering" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const options = Options{};

    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "b", options),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "A", options),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "\u{00e1}", options),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "\u{00e4}", "a", options),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a", "a", options),
    );
}

test "sort key buffer and UTF-16 APIs" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, options: Options }{
        .{ .text = "Hello, world!", .options = .{} },
        .{
            .text = "\u{00c5}ngstr\u{00f6}m bl\u{00e5}b\u{00e4}r",
            .options = .{ .locale = "sv" },
        },
        .{ .text = "\u{4f60}\u{597d}\u{4e16}\u{754c}", .options = .{} },
    };

    var reused = std.ArrayList(u32).empty;
    defer reused.deinit(allocator);

    for (cases) |case| {
        const expected = try sortKeyAlloc(allocator, case.text, case.options);
        defer allocator.free(expected);

        // Write into a reused buffer twice to exercise capacity reuse.
        try sortKeyInto(allocator, case.text, case.options, &reused);
        try testing.expectEqualSlices(u32, expected, reused.items);
        try sortKeyInto(allocator, case.text, case.options, &reused);
        try testing.expectEqualSlices(u32, expected, reused.items);

        const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, case.text);
        defer allocator.free(units);
        const utf16_key = try sortKeyUtf16Alloc(allocator, units, case.options);
        defer allocator.free(utf16_key);
        try testing.expectEqualSlices(u32, expected, utf16_key);

        try sortKeyUtf16Into(allocator, units, case.options, &reused);
        try testing.expectEqualSlices(u32, expected, reused.items);
    }

    try testing.expectError(
        error.InvalidUtf16,
        sortKeyUtf16Alloc(allocator, &[_]u16{0xD800}, .{}),
    );
    try testing.expectError(
        error.InvalidUtf8,
        sortKeyAlloc(allocator, "\xff", .{}),
    );
}

test "collation elements match the sort key weights" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, options: Options }{
        .{ .text = "Hello, world!", .options = .{} },
        .{
            .text = "\u{00c5}ngstr\u{00f6}m",
            .options = .{ .locale = "sv" },
        },
        .{ .text = "\u{4f60}\u{597d}", .options = .{} },
    };
    for (cases) |case| {
        const elements = try collationElementsAlloc(
            allocator,
            case.text,
            case.options,
        );
        defer allocator.free(elements);
        const key = try sortKeyAlloc(allocator, case.text, case.options);
        defer allocator.free(key);

        var primaries: [64]u32 = undefined;
        var count: usize = 0;
        for (elements) |element| {
            if (element.primary == 0) continue;
            try testing.expect(count < primaries.len);
            primaries[count] = element.primary;
            count += 1;
        }
        try testing.expectEqualSlices(u32, key[0..count], primaries[0..count]);
        try testing.expectEqual(@as(u32, 0), key[count]);
    }

    // Swedish tailoring gives a-ring a distinct primary weight.
    const root = try collationElementsAlloc(allocator, "\u{00e5}", .{});
    defer allocator.free(root);
    const swedish = try collationElementsAlloc(
        allocator,
        "\u{00e5}",
        .{ .locale = "sv" },
    );
    defer allocator.free(swedish);
    try testing.expect(root.len > 0 and swedish.len > 0);
    try testing.expect(root[0].primary != swedish[0].primary);

    try testing.expectError(
        error.InvalidUtf8,
        collationElementsAlloc(allocator, "\xff", .{}),
    );
}

test "implicit-only sort keys match the generic path" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // Han and an unassigned scalar take implicit weights; emoji such as
    // U+1F600 have explicit DUCET entries and use the general path.
    const text = "\u{4f60}\u{597d}\u{4e01}\u{0378}";
    const codepoints = [_]u21{ 0x4f60, 0x597d, 0x4e01, 0x0378 };

    const fast = try sortKeyAlloc(allocator, text, .{});
    defer allocator.free(fast);

    // `numeric` forces the general path without changing the key of text
    // that has no digit runs.
    const generic = try sortKeyAlloc(allocator, text, .{ .numeric = true });
    defer allocator.free(generic);
    try testing.expectEqualSlices(u32, generic, fast);

    var expected = std.ArrayList(u32).empty;
    defer expected.deinit(allocator);
    for (codepoints) |codepoint| {
        const weights = implicitWeights(codepoint);
        try expected.append(allocator, weights.first);
        try expected.append(allocator, weights.second);
    }
    try expected.append(allocator, 0);
    for (codepoints) |_| try expected.append(allocator, 0x20000);
    try expected.append(allocator, 0);
    for (codepoints) |_| try expected.append(allocator, 0x02000);
    try expected.append(allocator, 0);
    try testing.expectEqualSlices(u32, expected.items, fast);
}

test "collator reuses a resolved tailoring" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const text = "\u{00c5}ngstr\u{00f6}m";
    const collator = Collator.init(.{ .locale = "sv" });
    const direct = try sortKeyAlloc(allocator, text, .{ .locale = "sv" });
    defer allocator.free(direct);

    var key = std.ArrayList(u32).empty;
    defer key.deinit(allocator);
    try collator.sortKeyInto(allocator, text, &key);
    try testing.expectEqualSlices(u32, direct, key.items);

    const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(units);
    try collator.sortKeyUtf16Into(allocator, units, &key);
    try testing.expectEqualSlices(u32, direct, key.items);

    var other = std.ArrayList(u32).empty;
    defer other.deinit(allocator);
    const z_units = try std.unicode.utf8ToUtf16LeAlloc(allocator, "z");
    defer allocator.free(z_units);
    try testing.expectEqual(
        std.math.Order.lt,
        try collator.compare(allocator, "z", text, &key, &other),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try collator.compareUtf16(
            allocator,
            z_units,
            units,
            &key,
            &other,
        ),
    );

    const unknown = Collator.init(.{ .locale = "zz" });
    try unknown.sortKeyInto(allocator, "abc", &key);
    const plain = try sortKeyAlloc(allocator, "abc", .{});
    defer allocator.free(plain);
    try testing.expectEqualSlices(u32, plain, key.items);
}

test "locale collation tailorings" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const sv = Options{ .locale = "sv" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "z", "\u{00e5}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "\u{00e4}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e4}", "\u{00f6}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "\u{00c5}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00c5}", "\u{00e4}", sv),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "z",
            "\u{00e5}",
            .{ .locale = "sv-SE" },
        ),
    );

    const da = Options{ .locale = "da" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "z", "\u{00e6}", da),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e6}", "\u{00f8}", da),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00f8}", "\u{00e5}", da),
    );

    const no = Options{ .locale = "no" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00f8}", "\u{00e5}", no),
    );

    const es = Options{ .locale = "es" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "n", "\u{00f1}", es),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00f1}", "o", es),
    );

    const tr = Options{ .locale = "tr" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "h", "\u{0131}", tr),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{0131}", "i", tr),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "i", "j", tr),
    );

    const cs = Options{ .locale = "cs" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "c", "\u{010d}", cs),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{010d}", "d", cs),
    );

    const fi = Options{ .locale = "fi" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "z", "\u{00e5}", fi),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "\u{00e4}", fi),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e4}", "\u{00f6}", fi),
    );

    // Unknown locales and root requests keep the root order.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "z", .{}),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e5}", "z", .{ .locale = "zz" }),
    );
}

test "caseFirst and backwards secondary" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // The root order is lowercase-first.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "A", .{}),
    );

    // Danish standard collation requests caseFirst=upper.
    const da = Options{ .locale = "da" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "A", "a", da),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "A", "\u{00e1}", da),
    );
    // Tailored letters carry the case bits of their source strings.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{0110}", "\u{0111}", da),
    );
    // An explicit option overrides the locale setting.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "a",
            "A",
            .{ .locale = "da", .case_first = .lower },
        ),
    );

    // fr-CA uses backwards secondary ordering: accents are compared from the
    // end of the string, so côte sorts before coté.
    const fr_ca = Options{ .locale = "fr-CA" };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "cote", "c\u{00f4}te", fr_ca),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "c\u{00f4}te", "cot\u{00e9}", fr_ca),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "cot\u{00e9}", "c\u{00f4}t\u{00e9}", fr_ca),
    );
    // Forward secondary ordering keeps the accent-on-o word last.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "cot\u{00e9}", "c\u{00f4}te", .{}),
    );
    // French France uses the root order, not the Canadian reversal.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "cot\u{00e9}",
            "c\u{00f4}te",
            .{ .locale = "fr" },
        ),
    );
}

test "script reordering" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const lt = std.math.Order.lt;

    // Root order: Latin before Greek, Cyrillic, Hebrew, Arabic, Indic, Thai,
    // and Han.
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{03b1}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{044f}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{05d0}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{0627}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{0905}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{0e01}", .{}));
    try testing.expectEqual(lt, try compare(allocator, "a", "\u{6c49}", .{}));

    // Locale reordering moves the native script group first.
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{044f}", "a", .{ .locale = "ru" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{03b1}", "a", .{ .locale = "el" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{05d0}", "a", .{ .locale = "he" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{0627}", "a", .{ .locale = "ar" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{0905}", "a", .{ .locale = "hi" }),
    );
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{0e01}", "a", .{ .locale = "th" }),
    );
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "\u{6c49}",
            "a",
            .{ .locale = "zh", .collation = "pinyin" },
        ),
    );
    // Tailored pinyin Han weights stay inside the reordered Hani block.
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "\u{6c49}",
            "\u{5b57}",
            .{ .locale = "zh", .collation = "pinyin" },
        ),
    );
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "\u{6c49}",
            "a",
            .{ .locale = "zh", .collation = "stroke" },
        ),
    );

    // Korean: Hangul, then Han, then other groups.
    const ko = Options{ .locale = "ko" };
    try testing.expectEqual(
        lt,
        try compare(allocator, "\u{ac00}", "\u{6c49}", ko),
    );
    try testing.expectEqual(lt, try compare(allocator, "\u{6c49}", "a", ko));

    // German EOR moves digits after all other groups.
    try testing.expectEqual(
        lt,
        try compare(
            allocator,
            "a",
            "1",
            .{ .locale = "de", .collation = "eor" },
        ),
    );
    try testing.expectEqual(lt, try compare(allocator, "1", "a", .{}));
}

test "Chinese default collation" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // zh defaults to pinyin; a before b, b before bo.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{963f}", "\u{516b}", .{ .locale = "zh" }),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{516b}", "\u{6ce2}", .{ .locale = "zh" }),
    );
    // zh-Hant defaults to stroke order: one stroke before two.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{4e00}", "\u{516b}", .{ .locale = "zh-Hant" }),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{4e00}", "\u{4eba}", .{ .locale = "zh-TW" }),
    );
}

test "collation types" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const de_phonebook = Options{
        .locale = "de",
        .collation = "phonebook",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "ae", "\u{00e4}", de_phonebook),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{00e4}", "af", de_phonebook),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "\u{00e4}",
            "ae",
            .{ .locale = "de" },
        ),
    );

    const es_traditional = Options{
        .locale = "es",
        .collation = "traditional",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "c", "ch", es_traditional),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "ch", "d", es_traditional),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "l", "ll", es_traditional),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "ll", "m", es_traditional),
    );

    const root_search = Options{
        .locale = "root",
        .collation = "search",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "=", "\u{2260}", root_search),
    );

    const zh_pinyin = Options{
        .locale = "zh",
        .collation = "pinyin",
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{963F}", "\u{516B}", zh_pinyin),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{516B}", "\u{64E6}", zh_pinyin),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{56FD}", "\u{4E2D}", zh_pinyin),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{4E2D}", "\u{56FD}", .{}),
    );

    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "z",
            "\u{00e5}",
            .{ .locale = "sv", .collation = "no-such-type" },
        ),
    );
}

test "contractions are longer than their first code point" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const options = Options{};

    // DUCET has an explicit contraction for l + middle dot.
    const contraction = try sortKeyAlloc(allocator, "l\u{00b7}", options);
    defer allocator.free(contraction);
    const separate = try sortKeyAlloc(allocator, "l\u{00b7}x", options);
    defer allocator.free(separate);
    try testing.expect(contraction.len > 0);
    try testing.expect(separate.len > contraction.len);
}

test "shifted variable weighting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const shifted_tertiary = Options{
        .strength = .tertiary,
        .variable_weighting = .shifted,
    };
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a b", "ab", shifted_tertiary),
    );

    const shifted_quaternary = Options{
        .strength = .quaternary,
        .variable_weighting = .shifted,
    };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a b", "ab", shifted_quaternary),
    );
}

const non_ignorable_conformance = @embedFile("conformance_non_ignorable.bin");
const shifted_conformance = @embedFile("conformance_shifted.bin");

fn runConformance(fixture: []const u8, options: Options) !void {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    if (fixture.len < 12 or !std.mem.eql(u8, fixture[0..4], "CJCT") or
        fixture[4] != 1 or fixture[5] != 17 or fixture[6] != 0 or fixture[7] != 0)
    {
        return error.InvalidFixture;
    }

    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    // The fixtures contain the full CLDR root short suites. The default
    // sampled run keeps `zig build test` fast; set this to true for a full
    // conformance pass.
    const full_conformance = false;
    const stride: usize = if (full_conformance) 1 else 16;

    var offset: usize = 12;
    var previous = std.ArrayList(u32).empty;
    defer previous.deinit(allocator);
    var current = std.ArrayList(u32).empty;
    defer current.deinit(allocator);
    var codepoints: [256]u21 = undefined;
    var sampled: usize = 0;

    for (0..case_count) |case_index| {
        if (offset >= fixture.len) return error.InvalidFixture;
        const length = fixture[offset];
        offset += 1;
        if (length > codepoints.len or
            offset + @as(usize, length) * 4 > fixture.len)
        {
            return error.InvalidFixture;
        }
        for (0..length) |index| {
            codepoints[index] = @intCast(std.mem.readInt(
                u32,
                fixture[offset..][0..4],
                .little,
            ));
            offset += 4;
        }
        if (case_index % stride != 0) continue;

        try sortKeyCodepointsInto(
            allocator,
            codepoints[0..length],
            options,
            &current,
        );
        if (sampled > 0 and
            std.mem.order(u32, previous.items, current.items) == .gt)
        {
            std.debug.print(
                "collation conformance failure at case {d}: {any} > {any}\n",
                .{ case_index, previous.items, current.items },
            );
            return error.TestUnexpectedResult;
        }
        sampled += 1;
        std.mem.swap(std.ArrayList(u32), &previous, &current);
    }
    if (offset != fixture.len) return error.InvalidFixture;
}

test "CLDR 48 non-ignorable conformance" {
    try runConformance(
        non_ignorable_conformance,
        .{ .strength = .tertiary, .variable_weighting = .non_ignorable },
    );
}

test "CLDR 48 shifted conformance" {
    try runConformance(
        shifted_conformance,
        .{ .strength = .quaternary, .variable_weighting = .shifted },
    );
}

test "numeric collation orders digit runs by value" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const numeric = Options{ .numeric = true };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a2", "a10", numeric),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "a10", "a2", numeric),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a02", "a2", numeric),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a0", "a00", numeric),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a0002", "a10", numeric),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "1.5", "1.10", numeric),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "x9y", "x10y", numeric),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "2", "b", numeric),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "2", "-", numeric),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "\u{0662}", "2", numeric),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(
            allocator,
            "99999999999999999999",
            "100000000000000000000",
            numeric,
        ),
    );
    // Numeric ordering must also work with a locale tailoring active.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a2", "a10", .{ .numeric = true, .locale = "sv" }),
    );
    // Disabled numeric collation keeps digit-by-digit order.
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "a2", "a10", .{}),
    );
}

test "ascii fast path keeps the quaternary separator" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const tertiary_key = try sortKeyAlloc(allocator, "ab", .{
        .strength = .tertiary,
    });
    defer allocator.free(tertiary_key);
    const quaternary_key = try sortKeyAlloc(allocator, "ab", .{
        .strength = .quaternary,
    });
    defer allocator.free(quaternary_key);
    try testing.expectEqual(tertiary_key.len + 1, quaternary_key.len);
    try testing.expectEqualSlices(
        u32,
        tertiary_key,
        quaternary_key[0..tertiary_key.len],
    );
    try testing.expectEqual(@as(u32, 0), quaternary_key[quaternary_key.len - 1]);
}

test "collation options conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("options_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJNC", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |_| {
        const locale_length = fixture[cursor];
        const first_length = std.mem.readInt(
            u16,
            fixture[cursor + 1 ..][0..2],
            .little,
        );
        const second_length = std.mem.readInt(
            u16,
            fixture[cursor + 3 ..][0..2],
            .little,
        );
        const expected: i8 = @bitCast(fixture[cursor + 5]);
        const options_byte = fixture[cursor + 6];
        cursor += 8;
        const locale = fixture[cursor .. cursor + locale_length];
        cursor += locale_length;
        const first = fixture[cursor .. cursor + first_length];
        cursor += first_length;
        const second = fixture[cursor .. cursor + second_length];
        cursor += second_length;

        const order = compare(allocator, first, second, .{
            .numeric = options_byte & 1 != 0,
            .case_level = options_byte & 2 != 0,
            .case_first = if (options_byte & 4 != 0) .upper else null,
            .variable_weighting = if (options_byte & 8 != 0)
                .shifted
            else
                .non_ignorable,
            .strength = if (options_byte & 16 != 0)
                .identical
            else
                .tertiary,
            .locale = locale,
        }) catch {
            failures += 1;
            continue;
        };
        const actual: i8 = switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
        if (actual != expected) {
            failures += 1;
            std.debug.print(
                "collation option mismatch {s} opts {d}: '{s}' vs '{s}' got {d} expected {d}\n",
                .{ locale, options_byte, first, second, actual, expected },
            );
        }
    }
    std.debug.print("collation options conformance: {d}/{d} cases passed\n", .{
        case_count - failures,
        case_count,
    });
    try testing.expect(failures == 0);
}

test "identical strength collation" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const level = Options{ .strength = .identical };
    // Collation-ignorable characters only differ at the identical level.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "a\u{ad}", level),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "a\u{ad}", "a", level),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "a", "a", level),
    );
    // Canonical equivalents stay equal: ICU decomposes each code point in
    // place before comparing.
    try testing.expectEqual(
        std.math.Order.eq,
        try compare(allocator, "\u{e9}", "e\u{301}", level),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "\u{e1}\u{323}", "\u{1ea1}\u{301}", level),
    );
    // Tertiary differences still win over the identical level.
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "A", level),
    );
}

test "case level collation" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const level = Options{ .case_level = true };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a", "A", level),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "A", "a", level),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "abc", "Abc", level),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "aB", "Ab", level),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a1", "aA", level),
    );

    const upper = Options{ .case_level = true, .case_first = .upper };
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "a", "A", upper),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        try compare(allocator, "aB", "Ab", upper),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a1", "aA", upper),
    );

    const shifted = Options{ .case_level = true, .variable_weighting = .shifted };
    try testing.expectEqual(
        std.math.Order.lt,
        try compare(allocator, "a b", "aB", shifted),
    );
}

fn compareWith(
    collator: *const Collator,
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
) !std.math.Order {
    var key_a = std.ArrayList(u32).empty;
    defer key_a.deinit(allocator);
    var key_b = std.ArrayList(u32).empty;
    defer key_b.deinit(allocator);
    return collator.compare(allocator, a, b, &key_a, &key_b);
}

test "collator attributes" {
    const testing = @import("std").testing;
    var collator = Collator.init(.{});
    try testing.expectEqual(@as(u32, 2), collator.getAttribute(.strength));
    collator.setAttribute(.strength, 0);
    try testing.expectEqual(@as(u32, 0), collator.getAttribute(.strength));
    try testing.expectEqual(std.math.Order.eq, try compareWith(&collator, testing.allocator, "a", "A"));

    collator.setAttribute(.strength, 2);
    collator.setAttribute(.numeric_collation, 1);
    try testing.expectEqual(@as(u32, 1), collator.getAttribute(.numeric_collation));
    try testing.expectEqual(std.math.Order.lt, try compareWith(&collator, testing.allocator, "a2", "a10"));

    collator.setAttribute(.case_first, 2);
    try testing.expectEqual(@as(u32, 2), collator.getAttribute(.case_first));
    try testing.expectEqual(std.math.Order.lt, try compareWith(&collator, testing.allocator, "A", "a"));

    collator.setAttribute(.alternate_handling, 1);
    try testing.expectEqual(@as(u32, 1), collator.getAttribute(.alternate_handling));

    var french = Collator.init(.{});
    french.setAttribute(.french_collation, 1);
    try testing.expectEqual(@as(u32, 1), french.getAttribute(.french_collation));
    french.setAttribute(.french_collation, 0);
    try testing.expectEqual(@as(u32, 0), french.getAttribute(.french_collation));
}

test "direct collation table matches the generic lookup" {
    const testing = @import("std").testing;
    ensureRootTables();
    for (0..direct_bmp_limit) |codepoint| {
        const direct = root_tables_storage.direct[codepoint];
        var entry_index = pageStart(@intCast(codepoint));
        var single: ?Entry = null;
        var has_long = false;
        while (entry_index < entry_count) : (entry_index += 1) {
            const entry = entryAt(entry_index);
            if (entry.first != codepoint) break;
            if (entry.len > 1) {
                has_long = true;
                continue;
            }
            if (single != null) has_long = true;
            single = entry;
        }
        if (has_long or (single != null and single.?.ce_count != 1)) {
            try testing.expectEqual(DirectKind.complex, direct.kind);
        } else if (single) |entry| {
            try testing.expectEqual(DirectKind.direct, direct.kind);
            const element = ceAt(entry.ce_offset);
            try testing.expectEqual(element.primary, direct.primary);
            try testing.expectEqual(element.secondary, direct.secondary);
            try testing.expectEqual(element.tertiary, direct.tertiary);
            try testing.expectEqual(element.variable, direct.variable);
        } else {
            try testing.expectEqual(DirectKind.implicit, direct.kind);
        }
    }
    for (0..0x1100) |page| {
        const page_start: u32 = @intCast(page << 8);
        const page_end = page_start + 256;
        var entry_index = pageStart(@intCast(page_start));
        var has_entry = false;
        while (entry_index < entry_count) : (entry_index += 1) {
            if (entryAt(entry_index).first >= page_end) break;
            has_entry = true;
        }
        try testing.expectEqual(
            has_entry,
            root_tables_storage.page_has_entries[page],
        );
    }
}
