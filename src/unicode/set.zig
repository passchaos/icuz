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
const case_mapping = @import("case/root.zig");

pub const Error = error{ InvalidPattern, OutOfMemory };

pub const Range = struct {
    first: u21,
    last: u21,
};

pub const Set = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(Range),
    /// Multi-code-point elements, sorted by byte order.
    strings: std.ArrayList([]u8) = .empty,
    bits: ?[]u64 = null,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{
            .allocator = allocator,
            .ranges = .empty,
            .strings = .empty,
            .bits = null,
        };
    }

    pub fn deinit(self: *Set) void {
        for (self.strings.items) |text| self.allocator.free(text);
        self.strings.deinit(self.allocator);
        if (self.bits) |bits| self.allocator.free(bits);
        self.ranges.deinit(self.allocator);
    }

    pub fn clear(self: *Set) void {
        for (self.strings.items) |text| self.allocator.free(text);
        self.strings.clearRetainingCapacity();
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
        return self.ranges.items.len == 0 and self.strings.items.len == 0;
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

    /// Add a multi-code-point element. Empty strings are ignored.
    pub fn addString(self: *Set, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.stringIndex(text) != null) return;
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        var position: usize = 0;
        while (position < self.strings.items.len and
            std.mem.order(u8, self.strings.items[position], copy) == .lt)
        {
            position += 1;
        }
        try self.strings.insert(self.allocator, position, copy);
    }

    pub fn containsString(self: Set, text: []const u8) bool {
        return self.stringIndex(text) != null;
    }

    pub fn stringCount(self: Set) usize {
        return self.strings.items.len;
    }

    pub fn stringAt(self: Set, index: usize) []const u8 {
        return self.strings.items[index];
    }

    fn stringIndex(self: Set, text: []const u8) ?usize {
        var low: usize = 0;
        var high = self.strings.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.strings.items[middle], text)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return middle,
            }
        }
        return null;
    }

    fn removeString(self: *Set, text: []const u8) void {
        if (self.stringIndex(text)) |index| {
            self.allocator.free(self.strings.items[index]);
            _ = self.strings.orderedRemove(index);
        }
    }

    pub const CaseClosure = enum {
        /// Add simple case variants and full case-folded strings.
        case_insensitive,
        /// Add only simple (one-to-one) case variants.
        simple_case_insensitive,
        /// Add the lower/upper/title/fold mappings of the set's elements.
        add_case_mappings,
    };

    /// Apply ICU-style case closure to this set.
    pub fn closeOver(self: *Set, closure: CaseClosure) !void {
        const allocator = self.allocator;
        var original = try self.clone(allocator);
        defer original.deinit();

        if (closure == .add_case_mappings) {
            for (original.ranges.items) |range| {
                var codepoint: u32 = range.first;
                while (codepoint <= @as(u32, range.last)) : (codepoint += 1) {
                    const cp: u21 = @intCast(codepoint);
                    try self.addMappedCodepointAlloc(cp, .lower);
                    try self.addMappedCodepointAlloc(cp, .upper);
                    try self.addMappedCodepointAlloc(cp, .title);
                    try self.addMappedCodepointAlloc(cp, .fold);
                }
            }
            for (original.strings.items) |text| {
                try self.addMappedStringAlloc(text, .lower);
                try self.addMappedStringAlloc(text, .upper);
                try self.addMappedStringAlloc(text, .title);
                const folded = try case_mapping.foldAlloc(allocator, text);
                defer allocator.free(folded);
                try self.addString(folded);
            }
            return;
        }

        // Case-insensitive closure: find every cased scalar whose case
        // variants intersect the original set. Iterating cased scalars makes
        // the closure symmetric without a reverse case-mapping table.
        var codepoint: u32 = 0;
        while (codepoint <= 0x10FFFF) : (codepoint += 1) {
            const cp: u21 = @intCast(codepoint);
            if (!properties.isCased(cp)) continue;
            const lower = case_mapping.simpleLower(cp);
            const upper = case_mapping.simpleUpper(cp);
            const title = case_mapping.simpleTitle(cp);
            const fold = case_mapping.simpleFold(cp);
            const matches = original.contains(cp) or
                original.contains(lower) or
                original.contains(upper) or
                original.contains(title) or
                original.contains(fold);
            if (!matches) continue;
            try self.add(cp);
            try self.add(lower);
            try self.add(upper);
            try self.add(title);
            try self.add(fold);
            if (closure == .case_insensitive) {
                if (case_mapping.fullFold(cp)) |folded| {
                    try self.addMappedSequence(folded);
                }
            }
        }

        if (closure == .case_insensitive) {
            for (original.strings.items) |text| {
                const folded = try case_mapping.foldAlloc(allocator, text);
                defer allocator.free(folded);
                try self.addString(folded);
            }
        }
    }

    fn addMappedCodepointAlloc(
        self: *Set,
        codepoint: u21,
        kind: enum { lower, upper, title, fold },
    ) !void {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
        const mapped = switch (kind) {
            .lower => try case_mapping.fullLowerAlloc(
                self.allocator,
                buffer[0..length],
                .{},
            ),
            .upper => try case_mapping.fullUpperAlloc(
                self.allocator,
                buffer[0..length],
                .{},
            ),
            .title => try case_mapping.fullTitleAlloc(
                self.allocator,
                buffer[0..length],
                .{},
            ),
            .fold => try case_mapping.foldAlloc(
                self.allocator,
                buffer[0..length],
            ),
        };
        defer self.allocator.free(mapped);
        try self.addMappedUtf8(mapped);
    }

    fn addMappedUtf8(self: *Set, text: []const u8) !void {
        if (text.len == 0) return;
        const length = std.unicode.utf8ByteSequenceLength(text[0]) catch {
            try self.addString(text);
            return;
        };
        const first = std.unicode.utf8Decode(text[0..length]) catch {
            try self.addString(text);
            return;
        };
        if (length == text.len) {
            try self.add(first);
        } else {
            try self.addString(text);
        }
    }

    fn addMappedSequence(self: *Set, codepoints: []const u21) !void {
        if (codepoints.len <= 1) {
            if (codepoints.len == 1) try self.add(codepoints[0]);
            return;
        }
        var buffer: [64]u8 = undefined;
        var length: usize = 0;
        for (codepoints) |cp| {
            const encoded = std.unicode.utf8Encode(cp, buffer[length..][0..4]) catch
                return;
            length += encoded;
        }
        try self.addString(buffer[0..length]);
    }

    fn addMappedStringAlloc(
        self: *Set,
        text: []const u8,
        kind: enum { lower, upper, title },
    ) !void {
        const mapped = switch (kind) {
            .lower => try case_mapping.fullLowerAlloc(
                self.allocator,
                text,
                .{},
            ),
            .upper => try case_mapping.fullUpperAlloc(
                self.allocator,
                text,
                .{},
            ),
            .title => try case_mapping.fullTitleAlloc(
                self.allocator,
                text,
                .{},
            ),
        };
        defer self.allocator.free(mapped);
        try self.addMappedUtf8(mapped);
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
        for (other.strings.items) |text| try self.addString(text);
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
        var string_index: usize = 0;
        while (string_index < self.strings.items.len) {
            if (!other.containsString(self.strings.items[string_index])) {
                self.allocator.free(self.strings.items[string_index]);
                _ = self.strings.orderedRemove(string_index);
            } else {
                string_index += 1;
            }
        }
    }

    pub fn subtract(self: *Set, other: Set) !void {
        if (self.ranges.items.ptr == other.ranges.items.ptr) {
            // Subtracting the same set empties it; avoid iterating the
            // storage that is being freed.
            self.clear();
            return;
        }
        for (other.ranges.items) |range| {
            try self.removeRange(range.first, range.last);
        }
        for (other.strings.items) |text| self.removeString(text);
    }

    pub fn eql(self: Set, other: Set) bool {
        if (self.ranges.items.len != other.ranges.items.len) return false;
        for (self.ranges.items, other.ranges.items) |a, b| {
            if (a.first != b.first or a.last != b.last) return false;
        }
        if (self.strings.items.len != other.strings.items.len) return false;
        for (self.strings.items, other.strings.items) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    pub fn subsetOf(self: Set, other: Set) bool {
        for (self.ranges.items) |range| {
            if (!other.containsRange(range.first, range.last)) return false;
        }
        for (self.strings.items) |text| {
            if (!other.containsString(text)) return false;
        }
        return true;
    }

    pub fn clone(self: Set, allocator: std.mem.Allocator) !Set {
        var result = Set.init(allocator);
        errdefer result.deinit();
        try result.ranges.appendSlice(allocator, self.ranges.items);
        for (self.strings.items) |text| try result.addString(text);
        return result;
    }

    pub const SpanCondition = enum { contained, not_contained };

    /// Length of the prefix of `text` whose code points and strings are all
    /// contained (or all not contained) in this set.
    pub fn span(self: Set, text: []const u8, condition: SpanCondition) usize {
        var index: usize = 0;
        while (index < text.len) {
            if (self.matchStringAt(text, index)) |length| {
                if (condition == .not_contained) break;
                index += length;
                continue;
            }
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
                break;
            if (index + length > text.len) break;
            const codepoint = std.unicode.utf8Decode(
                text[index..][0..length],
            ) catch break;
            const contained = self.contains(codepoint);
            if (condition == .contained and !contained) break;
            if (condition == .not_contained and contained) break;
            index += length;
        }
        return index;
    }

    /// Start offset of the suffix of `text` whose code points and strings are
    /// all contained (or all not contained) in this set.
    pub fn spanBack(self: Set, text: []const u8, condition: SpanCondition) usize {
        var index = text.len;
        while (index > 0) {
            if (self.matchStringEndingAt(text, index)) |length| {
                if (condition == .not_contained) break;
                index -= length;
                continue;
            }
            var start = index - 1;
            while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
            const codepoint = std.unicode.utf8Decode(text[start..index]) catch
                break;
            const contained = self.contains(codepoint);
            if (condition == .contained and !contained) break;
            if (condition == .not_contained and contained) break;
            index = start;
        }
        return index;
    }

    fn matchStringAt(self: Set, text: []const u8, index: usize) ?usize {
        var best: ?usize = null;
        for (self.strings.items) |string| {
            if (string.len > text.len - index) continue;
            if (!std.mem.eql(u8, text[index..][0..string.len], string)) continue;
            if (best == null or string.len > best.?) best = string.len;
        }
        return best;
    }

    fn matchStringEndingAt(self: Set, text: []const u8, index: usize) ?usize {
        var best: ?usize = null;
        for (self.strings.items) |string| {
            if (string.len > index) continue;
            if (!std.mem.eql(u8, text[index - string.len .. index], string)) {
                continue;
            }
            if (best == null or string.len > best.?) best = string.len;
        }
        return best;
    }

    pub fn rangeIterator(self: Set) RangeIterator {
        return .{ .ranges = self.ranges.items };
    }

    /// True when every code point of `other` is in this set.
    pub fn containsAll(self: Set, other: Set) bool {
        return other.subsetOf(self);
    }

    /// True when the two sets share no code point.
    pub fn containsNone(self: Set, other: Set) bool {
        var left: usize = 0;
        var right: usize = 0;
        while (left < self.ranges.items.len and
            right < other.ranges.items.len)
        {
            const a = self.ranges.items[left];
            const b = other.ranges.items[right];
            if (a.last < b.first) {
                left += 1;
            } else if (b.last < a.first) {
                right += 1;
            } else {
                return false;
            }
        }
        for (self.strings.items) |text| {
            if (other.containsString(text)) return false;
        }
        return true;
    }

    /// True when the two sets share at least one code point or string.
    pub fn containsSome(self: Set, other: Set) bool {
        return !self.containsNone(other);
    }

    /// Render an ICU-style pattern that parses back to this set.
    pub fn toPatternAlloc(
        self: Set,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        try output.append(allocator, '[');
        for (self.ranges.items) |range| {
            try appendPatternCodepoint(allocator, &output, range.first);
            if (range.last != range.first) {
                try output.append(allocator, '-');
                try appendPatternCodepoint(allocator, &output, range.last);
            }
        }
        for (self.strings.items) |text| {
            try output.append(allocator, '{');
            for (text) |byte| {
                if (byte == '\\' or byte == '{' or byte == '}') {
                    try output.append(allocator, '\\');
                }
                try output.append(allocator, byte);
            }
            try output.append(allocator, '}');
        }
        try output.append(allocator, ']');
        return output.toOwnedSlice(allocator);
    }
};

fn appendPatternCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u21,
) error{OutOfMemory}!void {
    switch (codepoint) {
        '\\', '[', ']', '-', '^', '&', '{', '}' => {
            try output.append(allocator, '\\');
            try output.append(allocator, @intCast(codepoint));
        },
        else => {
            if (codepoint >= 0x20 and codepoint <= 0x7e) {
                try output.append(allocator, @intCast(codepoint));
            } else if (codepoint <= 0xffff) {
                var buffer: [6]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buffer,
                    "\\u{X:0>4}",
                    .{codepoint},
                ) catch unreachable;
                try output.appendSlice(allocator, text);
            } else {
                var buffer: [10]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buffer,
                    "\\U{X:0>8}",
                    .{codepoint},
                ) catch unreachable;
                try output.appendSlice(allocator, text);
            }
        },
    }
}

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
                            .set, .string => return error.InvalidPattern,
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
                .string => |text| {
                    defer self.allocator.free(text);
                    try set.addString(text);
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
            .literal, .string => error.InvalidPattern,
            .set => |owned| owned,
        };
    }

    const Atom = union(enum) {
        literal: u21,
        set: Set,
        string: []u8,
    };

    fn parseAtom(self: *Parser) Error!Atom {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];

        if (byte == '{') {
            return .{ .string = try self.parseStringAtom() };
        }

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
                else => {
                    // ICU UnicodeSet escapes any other character, so
                    // patterns such as `[-\ ]` match a literal space.
                    const escaped_length = std.unicode.utf8ByteSequenceLength(
                        escape,
                    ) catch return error.InvalidPattern;
                    if (self.index + escaped_length > self.pattern.len) {
                        return error.InvalidPattern;
                    }
                    const literal = std.unicode.utf8Decode(
                        self.pattern[self.index..][0..escaped_length],
                    ) catch return error.InvalidPattern;
                    self.index += escaped_length;
                    return .{ .literal = literal };
                },
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

    fn parseStringAtom(self: *Parser) Error![]u8 {
        self.index += 1; // '{'
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        while (self.index < self.pattern.len) {
            const byte = self.pattern[self.index];
            if (byte == '}') {
                self.index += 1;
                if (buffer.items.len == 0) return error.InvalidPattern;
                return buffer.toOwnedSlice(self.allocator);
            }
            if (byte == '\\') {
                self.index += 1;
                if (self.index >= self.pattern.len) return error.InvalidPattern;
                const escape = self.pattern[self.index];
                if (escape == 'u' or escape == 'U') {
                    const codepoint = try self.parseHex(
                        if (escape == 'u') 4 else 8,
                    );
                    var encoded: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(
                        codepoint,
                        &encoded,
                    ) catch return error.InvalidPattern;
                    try buffer.appendSlice(self.allocator, encoded[0..length]);
                    continue;
                }
                try buffer.append(self.allocator, escape);
                self.index += 1;
                continue;
            }
            try buffer.append(self.allocator, byte);
            self.index += 1;
        }
        return error.InvalidPattern;
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
        if (std.mem.eql(u8, key, "age") or std.mem.eql(u8, key, "Age")) {
            const version = ageVersionFromAlias(value) orelse
                return error.InvalidPattern;
            return fromAgeVersion(allocator, version);
        }
        if (std.mem.eql(u8, key, "nt") or
            std.mem.eql(u8, key, "Numeric_Type"))
        {
            const kind: properties.NumericType = if (std.ascii.eqlIgnoreCase(value, "decimal"))
                .decimal
            else if (std.ascii.eqlIgnoreCase(value, "digit"))
                .digit
            else if (std.ascii.eqlIgnoreCase(value, "numeric"))
                .numeric
            else
                return error.InvalidPattern;
            return fromNumericType(allocator, kind);
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

fn ageVersionFromAlias(value: []const u8) ?u16 {
    var text = value;
    if (text.len != 0 and (text[0] == 'V' or text[0] == 'v')) {
        text = text[1..];
    }
    var major: u16 = 0;
    var minor: u16 = 0;
    var seen_separator = false;
    for (text) |byte| {
        if (byte == '.' or byte == '_') {
            seen_separator = true;
            continue;
        }
        if (!std.ascii.isDigit(byte)) return null;
        const digit: u16 = byte - '0';
        if (seen_separator) {
            minor = minor * 10 + digit;
        } else {
            major = major * 10 + digit;
        }
    }
    if (major == 0 or major > 255 or minor > 255) return null;
    return (major << 8) | minor;
}

pub fn fromNumericType(
    allocator: std.mem.Allocator,
    kind: properties.NumericType,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();
    for (0..properties.numeric.rangeCount()) |index| {
        const range = properties.numeric.rangeAt(index);
        if (range.kind != kind) continue;
        try set.addRange(range.first, range.last);
    }
    try set.finalize();
    return set;
}

pub fn fromAgeVersion(
    allocator: std.mem.Allocator,
    version: u16,
) !Set {
    var set = Set.init(allocator);
    errdefer set.deinit();
    for (0..properties.age.rangeCount()) |index| {
        const range = properties.age.rangeAt(index);
        if (range.version != version) continue;
        try set.addRange(range.first, range.last);
    }
    try set.finalize();
    return set;
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

    var age_1_1 = try parse(allocator, "\\p{age=1.1}");
    defer age_1_1.deinit();
    try testing.expect(age_1_1.contains('A'));
    try testing.expect(!age_1_1.contains(0x1fae8));

    var age_15 = try parse(allocator, "\\p{Age=V15_0}");
    defer age_15.deinit();
    try testing.expect(age_15.contains(0x1fae8));
    try testing.expect(!age_15.contains('A'));

    var decimal = try parse(allocator, "\\p{nt=Decimal}");
    defer decimal.deinit();
    try testing.expect(decimal.contains('5'));
    try testing.expect(!decimal.contains(0x00b2));

    var digit = try parse(allocator, "\\p{Numeric_Type=Digit}");
    defer digit.deinit();
    try testing.expect(digit.contains(0x00b2));
    try testing.expect(!digit.contains('5'));

    var numeric = try parse(allocator, "\\p{nt=Numeric}");
    defer numeric.deinit();
    try testing.expect(numeric.contains(0x00bd));
    try testing.expect(!numeric.contains('5'));
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

test "set algebra and pattern round-trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var a = try parse(allocator, "[a-z]");
    defer a.deinit();
    var b = try parse(allocator, "[m-p0-9]");
    defer b.deinit();

    var union_set = try a.clone(allocator);
    defer union_set.deinit();
    try union_set.unionWith(b);
    try testing.expect(union_set.contains('a'));
    try testing.expect(union_set.contains('5'));
    try testing.expect(union_set.contains('p'));
    try testing.expect(!union_set.contains('A'));

    var intersection = try a.clone(allocator);
    defer intersection.deinit();
    try intersection.intersectWith(b);
    try testing.expect(intersection.contains('m'));
    try testing.expect(intersection.contains('p'));
    try testing.expect(!intersection.contains('9'));
    try testing.expect(!intersection.contains('a'));

    var difference = try a.clone(allocator);
    defer difference.deinit();
    try difference.subtract(b);
    try testing.expect(difference.contains('a'));
    try testing.expect(!difference.contains('m'));

    var small = try parse(allocator, "[a-c]");
    defer small.deinit();
    try testing.expect(a.containsAll(small));
    try testing.expect(!a.containsAll(b));
    try testing.expect(a.containsSome(b));
    var upper = try parse(allocator, "[A-Z]");
    defer upper.deinit();
    try testing.expect(a.containsNone(upper));

    var complement = try a.clone(allocator);
    defer complement.deinit();
    try complement.complement();
    try testing.expect(complement.contains('A'));
    try testing.expect(!complement.contains('a'));
    try testing.expect(complement.contains(0x1f600));

    const patterns = [_][]const u8{
        "[a-z]",
        "[^a-z]",
        "[]",
        "[\\p{Lu}]",
        "[\\u0000-\\u007f]",
        "[\\p{sc=Greek}]",
    };
    for (patterns) |pattern| {
        var original = try parse(allocator, pattern);
        defer original.deinit();
        const rendered = try original.toPatternAlloc(allocator);
        defer allocator.free(rendered);
        var round_trip = try parse(allocator, rendered);
        defer round_trip.deinit();
        try testing.expect(original.eql(round_trip));
    }
}

test "set string elements" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var set = try parse(allocator, "[a-z{abc}{x\\}y}]");
    defer set.deinit();
    try testing.expect(set.contains('a'));
    try testing.expect(set.containsString("abc"));
    try testing.expect(set.containsString("x}y"));
    try testing.expect(!set.containsString("ab"));
    try testing.expectEqual(@as(usize, 2), set.stringCount());

    var other = try parse(allocator, "[{abc}b]");
    defer other.deinit();
    var union_set = try set.clone(allocator);
    defer union_set.deinit();
    try union_set.unionWith(other);
    try testing.expect(union_set.contains('b'));
    try testing.expectEqual(@as(usize, 2), union_set.stringCount());

    var intersection = try set.clone(allocator);
    defer intersection.deinit();
    try intersection.intersectWith(other);
    try testing.expectEqual(@as(usize, 1), intersection.stringCount());
    try testing.expect(intersection.containsString("abc"));

    var difference = try set.clone(allocator);
    defer difference.deinit();
    try difference.subtract(other);
    try testing.expectEqual(@as(usize, 1), difference.stringCount());
    try testing.expect(difference.containsString("x}y"));

    var complement = try set.clone(allocator);
    defer complement.deinit();
    try complement.complement();
    try testing.expect(complement.containsString("abc"));
    try testing.expect(!complement.contains('a'));

    const rendered = try set.toPatternAlloc(allocator);
    defer allocator.free(rendered);
    var round_trip = try parse(allocator, rendered);
    defer round_trip.deinit();
    try testing.expect(set.eql(round_trip));
}

test "set case closure" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var simple = try parse(allocator, "[a]");
    defer simple.deinit();
    try simple.closeOver(.simple_case_insensitive);
    try testing.expect(simple.contains('a'));
    try testing.expect(simple.contains('A'));

    var kelvin = try parse(allocator, "[k]");
    defer kelvin.deinit();
    try kelvin.closeOver(.simple_case_insensitive);
    try testing.expect(kelvin.contains('K'));
    try testing.expect(kelvin.contains(0x212a));

    var long_s = try parse(allocator, "[\u{017F}]");
    defer long_s.deinit();
    try long_s.closeOver(.simple_case_insensitive);
    try testing.expect(long_s.contains('s'));
    try testing.expect(long_s.contains('S'));

    var sharp = try parse(allocator, "[\u{00DF}]");
    defer sharp.deinit();
    try sharp.closeOver(.case_insensitive);
    try testing.expect(sharp.containsString("ss"));
    try testing.expect(sharp.contains(0x1e9e));

    var mapped = try parse(allocator, "[\u{00DF}]");
    defer mapped.deinit();
    try mapped.closeOver(.add_case_mappings);
    try testing.expect(mapped.containsString("SS"));
    try testing.expect(mapped.containsString("ss"));

    var idempotent = try parse(allocator, "[a]");
    defer idempotent.deinit();
    try idempotent.closeOver(.case_insensitive);
    const first = try idempotent.toPatternAlloc(allocator);
    defer allocator.free(first);
    try idempotent.closeOver(.case_insensitive);
    const second = try idempotent.toPatternAlloc(allocator);
    defer allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "set span" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var set = try parse(allocator, "[a-w{abc}]");
    defer set.deinit();
    try testing.expectEqual(@as(usize, 4), set.span("abcd", .contained));
    try testing.expectEqual(@as(usize, 2), set.span("abx", .contained));
    try testing.expectEqual(@as(usize, 3), set.span("123abc", .not_contained));
    try testing.expectEqual(@as(usize, 1), set.spanBack("xabc", .contained));
    try testing.expectEqual(@as(usize, 3), set.spanBack("abc1", .not_contained));
    try testing.expectEqual(@as(usize, 2), set.spanBack("xxab", .contained));
}

test "set algebra conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("set/conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJSU", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |_| {
        const op = fixture[cursor];
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
        const sample_count = std.mem.readInt(
            u16,
            fixture[cursor + 5 ..][0..2],
            .little,
        );
        cursor += 11;
        const first_pattern = fixture[cursor .. cursor + first_length];
        cursor += first_length;
        const second_pattern = fixture[cursor .. cursor + second_length];
        cursor += second_length;

        var first = parse(allocator, first_pattern) catch {
            failures += 1;
            continue;
        };
        defer first.deinit();
        var second = Set.init(allocator);
        defer second.deinit();
        if (second_length > 0) {
            second.deinit();
            second = parse(allocator, second_pattern) catch {
                failures += 1;
                continue;
            };
        }

        if (op <= 3) {
            var result = try first.clone(allocator);
            defer result.deinit();
            switch (op) {
                0 => try result.unionWith(second),
                1 => try result.intersectWith(second),
                2 => try result.subtract(second),
                else => try result.complement(),
            }
            for (0..sample_count) |_| {
                const codepoint: u21 = @intCast(std.mem.readInt(
                    u32,
                    fixture[cursor..][0..4],
                    .little,
                ));
                const expected = fixture[cursor + 4] != 0;
                cursor += 5;
                if (result.contains(codepoint) != expected) failures += 1;
            }
        } else {
            const expected = fixture[cursor] != 0;
            cursor += 1;
            const actual = switch (op) {
                4 => first.containsAll(second),
                5 => first.containsNone(second),
                else => first.containsSome(second),
            };
            if (actual != expected) failures += 1;
        }
    }
    std.debug.print("set conformance: {d}/{d} cases passed\n", .{
        case_count - failures,
        case_count,
    });
    try testing.expect(failures == 0);
}
