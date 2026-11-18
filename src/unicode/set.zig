//! UnicodeSet: a compact, sorted set of Unicode code points.
//!
//! Sets are stored as non-overlapping, non-adjacent inclusive ranges. The
//! parser accepts a practical subset of ICU's UnicodeSet pattern syntax:
//! ranges, literals, escapes, `\p{...}`/`\P{...}`, `[^...]`, and property
//! selectors such as `Script=Greek` or `General_Category=Lu`.

const std = @import("std");
const properties = @import("properties.zig");
const aliases = @import("properties/aliases.zig");
const script = @import("script/root.zig");
const script_extensions = @import("script_extensions/root.zig");

pub const Error = error{ InvalidPattern, OutOfMemory };

pub const Range = struct {
    first: u21,
    last: u21,
};

pub const Set = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(Range),
    bits: ?[]u64 = null,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{
            .allocator = allocator,
            .ranges = .empty,
            .bits = null,
        };
    }

    pub fn deinit(self: *Set) void {
        if (self.bits) |bits| self.allocator.free(bits);
        self.ranges.deinit(self.allocator);
    }

    pub fn clear(self: *Set) void {
        self.invalidateBits();
        self.ranges.clearRetainingCapacity();
    }

    fn invalidateBits(self: *Set) void {
        if (self.bits) |bits| {
            self.allocator.free(bits);
            self.bits = null;
        }
    }

    /// Materialize a bitset for dense sets. `contains` automatically uses it.
    ///
    /// Sparse sets keep the range representation. Mutating operations
    /// invalidate the bitset; call `finalize` again before heavy membership
    /// testing.
    pub fn finalize(self: *Set) !void {
        if (self.bits != null) return;
        if (self.count() < 4096) return;

        const words = try self.allocator.alloc(u64, 0x110000 / 64);
        errdefer self.allocator.free(words);
        @memset(words, 0);
        for (self.ranges.items) |range| {
            var codepoint: u32 = range.first;
            while (codepoint <= @as(u32, range.last)) : (codepoint += 1) {
                words[@as(usize, codepoint) >> 6] |=
                    @as(u64, 1) << @as(u6, @intCast(codepoint & 63));
            }
        }
        self.bits = words;
    }

    pub fn isEmpty(self: Set) bool {
        return self.ranges.items.len == 0;
    }

    pub fn isFull(self: Set) bool {
        return self.ranges.items.len == 1 and
            self.ranges.items[0].first == 0 and
            self.ranges.items[0].last == 0x10ffff;
    }

    pub fn count(self: Set) u32 {
        var total: u32 = 0;
        for (self.ranges.items) |range| {
            total += @as(u32, range.last) - @as(u32, range.first) + 1;
        }
        return total;
    }

    pub fn contains(self: Set, codepoint: u21) bool {
        if (self.bits) |bits| {
            const word = bits[@as(usize, codepoint) >> 6];
            const mask = @as(u64, 1) << @as(u6, @intCast(codepoint & 63));
            return (word & mask) != 0;
        }
        var low: usize = 0;
        var high = self.ranges.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const range = self.ranges.items[mid];
            if (codepoint < range.first) {
                high = mid;
            } else if (codepoint > range.last) {
                low = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn containsRange(self: Set, first: u21, last: u21) bool {
        if (first > last) return false;
        var low: usize = 0;
        var high = self.ranges.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const range = self.ranges.items[mid];
            if (first < range.first) {
                high = mid;
            } else if (first > range.last) {
                low = mid + 1;
            } else {
                return last <= range.last;
            }
        }
        return false;
    }

    pub fn add(self: *Set, codepoint: u21) !void {
        return self.addRange(codepoint, codepoint);
    }

    pub fn addRange(self: *Set, first: u21, last: u21) !void {
        if (first > last) return;
        self.invalidateBits();

        var index: usize = 0;
        while (index < self.ranges.items.len and
            self.ranges.items[index].last + 1 < first)
        {
            index += 1;
        }

        var merged_first = first;
        var merged_last = last;
        var end = index;
        while (end < self.ranges.items.len and
            self.ranges.items[end].first <= merged_last + 1)
        {
            merged_first = @min(merged_first, self.ranges.items[end].first);
            merged_last = @max(merged_last, self.ranges.items[end].last);
            end += 1;
        }

        if (index == end) {
            try self.ranges.insert(
                self.allocator,
                index,
                .{ .first = merged_first, .last = merged_last },
            );
            return;
        }

        self.ranges.items[index] = .{
            .first = merged_first,
            .last = merged_last,
        };
        const remove_count = end - (index + 1);
        if (remove_count > 0) {
            std.mem.copyForwards(
                Range,
                self.ranges.items[index + 1 ..],
                self.ranges.items[end..],
            );
            self.ranges.shrinkRetainingCapacity(
                self.ranges.items.len - remove_count,
            );
        }
    }

    pub fn remove(self: *Set, codepoint: u21) !void {
        return self.removeRange(codepoint, codepoint);
    }

    pub fn removeRange(self: *Set, first: u21, last: u21) !void {
        if (first > last) return;
        self.invalidateBits();

        var index: usize = 0;
        while (index < self.ranges.items.len) {
            const range = self.ranges.items[index];
            if (range.last < first) {
                index += 1;
                continue;
            }
            if (range.first > last) break;

            if (range.first < first and range.last > last) {
                self.ranges.items[index] = .{
                    .first = range.first,
                    .last = first - 1,
                };
                try self.ranges.insert(
                    self.allocator,
                    index + 1,
                    .{ .first = last + 1, .last = range.last },
                );
                break;
            }
            if (range.first < first) {
                self.ranges.items[index] = .{
                    .first = range.first,
                    .last = first - 1,
                };
                index += 1;
                continue;
            }
            if (range.last > last) {
                self.ranges.items[index] = .{
                    .first = last + 1,
                    .last = range.last,
                };
                break;
            }
            _ = self.ranges.orderedRemove(index);
        }
    }

    pub fn complement(self: *Set) !void {
        self.invalidateBits();
        var result = std.ArrayList(Range).empty;
        errdefer result.deinit(self.allocator);

        var next: u32 = 0;
        for (self.ranges.items) |range| {
            if (next < range.first) {
                try result.append(self.allocator, .{
                    .first = @intCast(next),
                    .last = range.first - 1,
                });
            }
            next = @as(u32, range.last) + 1;
        }
        if (next <= 0x10ffff) {
            try result.append(self.allocator, .{
                .first = @intCast(next),
                .last = 0x10ffff,
            });
        }

        self.ranges.deinit(self.allocator);
        self.ranges = result;
    }

    pub fn unionWith(self: *Set, other: Set) !void {
        self.invalidateBits();
        var result = std.ArrayList(Range).empty;
        errdefer result.deinit(self.allocator);

        var left: usize = 0;
        var right: usize = 0;
        while (left < self.ranges.items.len or
            right < other.ranges.items.len)
        {
            var next: Range = undefined;
            if (right == other.ranges.items.len or
                (left < self.ranges.items.len and
                    self.ranges.items[left].first <=
                        other.ranges.items[right].first))
            {
                next = self.ranges.items[left];
                left += 1;
            } else {
                next = other.ranges.items[right];
                right += 1;
            }

            if (result.items.len > 0 and
                result.items[result.items.len - 1].last + 1 >= next.first)
            {
                const last = result.items.len - 1;
                result.items[last].last = @max(
                    result.items[last].last,
                    next.last,
                );
            } else {
                try result.append(self.allocator, next);
            }
        }

        self.ranges.deinit(self.allocator);
        self.ranges = result;
    }

    pub fn intersectWith(self: *Set, other: Set) !void {
        self.invalidateBits();
        var result = std.ArrayList(Range).empty;
        errdefer result.deinit(self.allocator);

        var left: usize = 0;
        var right: usize = 0;
        while (left < self.ranges.items.len and
            right < other.ranges.items.len)
        {
            const first = @max(
                self.ranges.items[left].first,
                other.ranges.items[right].first,
            );
            const last = @min(
                self.ranges.items[left].last,
                other.ranges.items[right].last,
            );
            if (first <= last) {
                try result.append(self.allocator, .{
                    .first = first,
                    .last = last,
                });
            }
            if (self.ranges.items[left].last <
                other.ranges.items[right].last)
            {
                left += 1;
            } else {
                right += 1;
            }
        }

        self.ranges.deinit(self.allocator);
        self.ranges = result;
    }

    pub fn subtract(self: *Set, other: Set) !void {
        for (other.ranges.items) |range| {
            try self.removeRange(range.first, range.last);
        }
    }

    pub fn eql(self: Set, other: Set) bool {
        if (self.ranges.items.len != other.ranges.items.len) return false;
        for (self.ranges.items, other.ranges.items) |a, b| {
            if (a.first != b.first or a.last != b.last) return false;
        }
        return true;
    }

    pub fn subsetOf(self: Set, other: Set) bool {
        for (self.ranges.items) |range| {
            if (!other.containsRange(range.first, range.last)) return false;
        }
        return true;
    }

    pub fn clone(self: Set, allocator: std.mem.Allocator) !Set {
        var result = Set.init(allocator);
        errdefer result.deinit();
        try result.ranges.appendSlice(allocator, self.ranges.items);
        return result;
    }

    pub fn rangeIterator(self: Set) RangeIterator {
        return .{ .ranges = self.ranges.items };
    }
};

pub const RangeIterator = struct {
    ranges: []const Range,
    index: usize = 0,

    pub fn next(self: *RangeIterator) ?Range {
        if (self.index >= self.ranges.len) return null;
        const range = self.ranges[self.index];
        self.index += 1;
        return range;
    }
};

pub fn fromRange(
    allocator: std.mem.Allocator,
    first: u21,
    last: u21,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();
    try set.addRange(first, last);
    try set.finalize();
    return set;
}

pub fn full(allocator: std.mem.Allocator) !Set {
    return fromRange(allocator, 0, 0x10ffff);
}

pub fn fromProperty(
    allocator: std.mem.Allocator,
    property: properties.BinaryProperty,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();

    var start: ?u21 = null;
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        const present = properties.has(codepoint, property);
        if (present and start == null) start = codepoint;
        if (!present and start != null) {
            try set.addRange(start.?, codepoint - 1);
            start = null;
        }
    }
    if (start != null) try set.addRange(start.?, 0x10ffff);
    try set.finalize();
    return set;
}

pub fn fromCategoryMask(
    allocator: std.mem.Allocator,
    mask: u32,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();

    var start: ?u21 = null;
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        const present = properties.matchesCategoryMask(codepoint, mask);
        if (present and start == null) start = codepoint;
        if (!present and start != null) {
            try set.addRange(start.?, codepoint - 1);
            start = null;
        }
    }
    if (start != null) try set.addRange(start.?, 0x10ffff);
    try set.finalize();
    return set;
}

pub fn fromScript(
    allocator: std.mem.Allocator,
    target: script.Script,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();

    var start: ?u21 = null;
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        const present = script.forCodepoint(codepoint) == target;
        if (present and start == null) start = codepoint;
        if (!present and start != null) {
            try set.addRange(start.?, codepoint - 1);
            start = null;
        }
    }
    if (start != null) try set.addRange(start.?, 0x10ffff);
    try set.finalize();
    return set;
}

pub fn fromScriptExtensions(
    allocator: std.mem.Allocator,
    target: script.Script,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();

    var start: ?u21 = null;
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        const present = script_extensions.contains(codepoint, target);
        if (present and start == null) start = codepoint;
        if (!present and start != null) {
            try set.addRange(start.?, codepoint - 1);
            start = null;
        }
    }
    if (start != null) try set.addRange(start.?, 0x10ffff);
    try set.finalize();
    return set;
}

/// Parse a UnicodeSet pattern.
///
/// Supported syntax: `[...]`, `[^...]`, literal code points, `a-z` ranges,
/// `\uXXXX`/`\UXXXXXXXX` escapes, `\p{Property}`/`\P{Property}`, and property
/// selectors such as `gc=Lu`, `General_Category=Uppercase_Letter`,
/// `sc=Grek`, `Script=Greek`, `scx=Greek`, plus binary property aliases.
pub fn parse(allocator: std.mem.Allocator, pattern: []const u8) Error!Set {
    var parser = Parser{
        .allocator = allocator,
        .pattern = pattern,
        .index = 0,
    };
    return parser.parseSet();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: usize,

    fn parseSet(self: *Parser) Error!Set {
        if (self.index < self.pattern.len and
            self.pattern[self.index] == '\\')
        {
            return self.parsePropertyOnly();
        }
        if (self.peek() != '[') return error.InvalidPattern;
        self.index += 1;

        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.index += 1;
        }

        var set = Set.init(self.allocator);
        errdefer set.deinit();

        while (true) {
            if (self.index >= self.pattern.len) return error.InvalidPattern;
            if (self.peek() == ']') {
                self.index += 1;
                break;
            }

            const atom = try self.parseAtom();
            switch (atom) {
                .literal => |start_codepoint| {
                    if (self.peek() == '-' and
                        self.index + 1 < self.pattern.len and
                        self.pattern[self.index + 1] != ']')
                    {
                        self.index += 1;
                        const end_atom = try self.parseAtom();
                        const end_codepoint = switch (end_atom) {
                            .literal => |codepoint| codepoint,
                            .set => return error.InvalidPattern,
                        };
                        if (start_codepoint > end_codepoint) {
                            return error.InvalidPattern;
                        }
                        try set.addRange(start_codepoint, end_codepoint);
                    } else {
                        try set.add(start_codepoint);
                    }
                },
                .set => |owned| {
                    var owned_set = owned;
                    defer owned_set.deinit();
                    try set.unionWith(owned_set);
                },
            }
        }

        if (self.index != self.pattern.len) return error.InvalidPattern;
        if (negated) try set.complement();
        try set.finalize();
        return set;
    }

    fn parsePropertyOnly(self: *Parser) Error!Set {
        const atom = try self.parseAtom();
        if (self.index != self.pattern.len) return error.InvalidPattern;
        return switch (atom) {
            .literal => error.InvalidPattern,
            .set => |owned| owned,
        };
    }

    const Atom = union(enum) {
        literal: u21,
        set: Set,
    };

    fn parseAtom(self: *Parser) Error!Atom {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];

        if (byte == '\\') {
            self.index += 1;
            if (self.index >= self.pattern.len) return error.InvalidPattern;
            const escape = self.pattern[self.index];
            switch (escape) {
                'p', 'P' => return self.parseProperty(escape == 'P'),
                'u' => return .{ .literal = try self.parseHex(4) },
                'U' => return .{ .literal = try self.parseHex(8) },
                'n' => {
                    self.index += 1;
                    return .{ .literal = '\n' };
                },
                't' => {
                    self.index += 1;
                    return .{ .literal = '\t' };
                },
                'r' => {
                    self.index += 1;
                    return .{ .literal = '\r' };
                },
                '\\', ']', '-', '^' => {
                    self.index += 1;
                    return .{ .literal = escape };
                },
                else => return error.InvalidPattern,
            }
        }

        const length = std.unicode.utf8ByteSequenceLength(byte) catch
            return error.InvalidPattern;
        if (self.index + @as(usize, length) > self.pattern.len) {
            return error.InvalidPattern;
        }
        const codepoint = std.unicode.utf8Decode(
            self.pattern[self.index..][0..@as(usize, length)],
        ) catch return error.InvalidPattern;
        self.index += @as(usize, length);
        return .{ .literal = codepoint };
    }

    fn parseHex(self: *Parser, digits: usize) Error!u21 {
        self.index += 1; // skip 'u' or 'U'
        if (self.index + digits > self.pattern.len) return error.InvalidPattern;
        const value = std.fmt.parseInt(
            u21,
            self.pattern[self.index..][0..digits],
            16,
        ) catch return error.InvalidPattern;
        self.index += digits;
        return value;
    }

    fn parseProperty(self: *Parser, negated: bool) Error!Atom {
        self.index += 1; // skip 'p' or 'P'
        if (self.peek() != '{') return error.InvalidPattern;
        self.index += 1;
        const start = self.index;
        while (self.index < self.pattern.len and
            self.pattern[self.index] != '}')
        {
            self.index += 1;
        }
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const name = self.pattern[start..self.index];
        self.index += 1; // skip '}'

        var set = try propertySet(self.allocator, name);
        if (negated) try set.complement();
        return .{ .set = set };
    }

    fn peek(self: *Parser) u8 {
        if (self.index >= self.pattern.len) return 0;
        return self.pattern[self.index];
    }
};

fn propertySet(allocator: std.mem.Allocator, name: []const u8) Error!Set {
    if (std.mem.eql(u8, name, "Any")) return full(allocator);
    if (std.mem.eql(u8, name, "ASCII")) return fromRange(allocator, 0, 0x7f);

    if (std.mem.indexOfScalar(u8, name, '=')) |equals| {
        const key = name[0..equals];
        const value = name[equals + 1 ..];
        if (std.mem.eql(u8, key, "gc") or
            std.mem.eql(u8, key, "General_Category"))
        {
            const mask = aliases.generalCategoryMaskFromAlias(value) orelse
                return error.InvalidPattern;
            return fromCategoryMask(allocator, mask);
        }
        if (std.mem.eql(u8, key, "sc") or
            std.mem.eql(u8, key, "Script"))
        {
            const target = aliases.scriptFromAlias(value) orelse
                return error.InvalidPattern;
            return fromScript(allocator, target);
        }
        if (std.mem.eql(u8, key, "scx") or
            std.mem.eql(u8, key, "Script_Extensions"))
        {
            const target = aliases.scriptFromAlias(value) orelse
                return error.InvalidPattern;
            return fromScriptExtensions(allocator, target);
        }
        return error.InvalidPattern;
    }

    if (aliases.binaryPropertyFromAlias(name)) |property| {
        return fromProperty(allocator, property);
    }
    if (aliases.generalCategoryMaskFromAlias(name)) |mask| {
        return fromCategoryMask(allocator, mask);
    }
    if (aliases.scriptFromAlias(name)) |target| {
        return fromScript(allocator, target);
    }
    return error.InvalidPattern;
}

test "set ranges, union, intersection, and complement" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var set = try fromRange(allocator, 'a', 'z');
    defer set.deinit();
    try testing.expect(set.contains('a'));
    try testing.expect(set.contains('z'));
    try testing.expect(!set.contains('A'));
    try testing.expectEqual(@as(u32, 26), set.count());

    var digits = try fromRange(allocator, '0', '9');
    defer digits.deinit();
    try set.unionWith(digits);
    try testing.expect(set.contains('5'));
    try testing.expectEqual(@as(u32, 36), set.count());

    var lower = try fromRange(allocator, 'a', 'f');
    defer lower.deinit();
    try set.intersectWith(lower);
    try testing.expectEqual(@as(u32, 6), set.count());

    var complement = try fromRange(allocator, 'a', 'z');
    defer complement.deinit();
    try complement.complement();
    try testing.expect(!complement.contains('a'));
    try testing.expect(complement.contains('A'));
    try testing.expectEqual(@as(u32, 0x110000 - 26), complement.count());
}

test "property-backed sets" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var letters = try fromCategoryMask(allocator, 0x1f);
    defer letters.deinit();
    try testing.expect(letters.contains('A'));
    try testing.expect(!letters.contains('0'));

    var greek = try fromScript(allocator, .greek);
    defer greek.deinit();
    try testing.expect(greek.contains(0x03b1));
    try testing.expect(!greek.contains('a'));

    var emoji = try fromProperty(allocator, .emoji);
    defer emoji.deinit();
    try testing.expect(emoji.contains(0x1f600));
    try testing.expect(!emoji.contains('A'));
}

test "pattern parser" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var lower = try parse(allocator, "[a-z]");
    defer lower.deinit();
    try testing.expect(lower.contains('a'));
    try testing.expect(!lower.contains('A'));

    var not_lower = try parse(allocator, "[^a-z]");
    defer not_lower.deinit();
    try testing.expect(not_lower.contains('A'));
    try testing.expect(!not_lower.contains('a'));

    var upper = try parse(allocator, "\\p{Lu}");
    defer upper.deinit();
    try testing.expect(upper.contains('A'));
    try testing.expect(!upper.contains('a'));

    var greek = try parse(allocator, "\\p{Script=Greek}");
    defer greek.deinit();
    try testing.expect(greek.contains(0x03b1));
    try testing.expect(!greek.contains('a'));

    var alpha = try parse(allocator, "\\p{Alphabetic}");
    defer alpha.deinit();
    try testing.expect(alpha.contains('A'));
    try testing.expect(!alpha.contains('0'));

    var mixed = try parse(allocator, "[a-z0-9_\\u0041-\\u005A]");
    defer mixed.deinit();
    try testing.expect(mixed.contains('_'));
    try testing.expect(mixed.contains('Q'));
    try testing.expect(!mixed.contains('-'));
}

test "set equality, subset, and cloning" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var a = try fromRange(allocator, 'a', 'z');
    defer a.deinit();
    var b = try fromRange(allocator, 'a', 'm');
    defer b.deinit();
    var c = try fromRange(allocator, 'n', 'z');
    defer c.deinit();

    try b.unionWith(c);
    try testing.expect(a.eql(b));
    try testing.expect(c.subsetOf(a));
    try testing.expect(!a.subsetOf(c));

    var copy = try a.clone(allocator);
    defer copy.deinit();
    try testing.expect(copy.eql(a));
}

test "subtract and remove" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var letters = try fromRange(allocator, 'a', 'z');
    defer letters.deinit();
    var vowels = try fromRange(allocator, 'a', 'a');
    defer vowels.deinit();
    try vowels.addRange('e', 'e');
    try vowels.addRange('i', 'i');
    try vowels.addRange('o', 'o');
    try vowels.addRange('u', 'u');

    try letters.subtract(vowels);
    try testing.expect(!letters.contains('a'));
    try testing.expect(letters.contains('b'));

    try letters.remove('b');
    try testing.expect(!letters.contains('b'));
}
