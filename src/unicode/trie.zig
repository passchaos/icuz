//! ICU `UCharsTrie`-compatible reader.
//!
//! The serialized format is the one produced by ICU's `UCharsTrieBuilder`:
//! 16-bit units with linear-match, branch, intermediate-value, and
//! final-value nodes. The reader does not own the units.

const std = @import("std");

pub const Result = enum(u8) {
    no_match = 0,
    no_value = 1,
    final_value = 2,
    intermediate_value = 3,

    pub fn hasNext(self: Result) bool {
        return self == .no_value or self == .intermediate_value;
    }

    pub fn hasValue(self: Result) bool {
        return self == .final_value or self == .intermediate_value;
    }
};

const min_linear_match: i32 = 0x30;
const max_linear_match_length: i32 = 0x10;
const min_value_lead: i32 = min_linear_match + max_linear_match_length;
const node_type_mask: i32 = min_value_lead - 1;
const value_is_final: i32 = 0x8000;
const max_branch_linear_sub_node_length: i32 = 5;
const max_one_unit_value: i32 = 0x3fff;
const min_two_unit_value_lead: i32 = max_one_unit_value + 1;
const three_unit_value_lead: i32 = 0x7fff;
const max_two_unit_value: i32 = ((three_unit_value_lead - min_two_unit_value_lead) << 16) - 1;
const max_one_unit_node_value: i32 = 0xff;
const min_two_unit_node_value_lead: i32 = min_value_lead + ((max_one_unit_node_value + 1) << 6);
const three_unit_node_value_lead: i32 = 0x7fc0;
const max_two_unit_node_value: i32 =
    ((three_unit_node_value_lead - min_two_unit_node_value_lead) << 10) - 1;
const max_one_unit_delta: i32 = 0xfbff;
const min_two_unit_delta_lead: i32 = max_one_unit_delta + 1;
const three_unit_delta_lead: i32 = 0xffff;

pub const UCharsTrie = struct {
    units: []const u16,
    pos: ?usize = null,
    remaining_match_length: i32 = -1,

    pub fn init(units: []const u16) UCharsTrie {
        return .{ .units = units };
    }

    pub fn reset(self: *UCharsTrie) void {
        self.pos = 0;
        self.remaining_match_length = -1;
    }

    fn unitAt(self: *const UCharsTrie, index: usize) ?i32 {
        if (index >= self.units.len) return null;
        return self.units[index];
    }

    fn stop(self: *UCharsTrie) void {
        self.pos = null;
    }

    fn readValue(units: []const u16, pos: usize, lead: i32) i32 {
        if (lead < min_two_unit_value_lead) return lead;
        if (lead < three_unit_value_lead) {
            return ((lead - min_two_unit_value_lead) << 16) |
                @as(i32, units[pos]);
        }
        return (@as(i32, units[pos]) << 16) | @as(i32, units[pos + 1]);
    }

    fn skipValue(pos_start: usize, lead: i32) usize {
        if (lead >= min_two_unit_value_lead) {
            if (lead < three_unit_value_lead) return pos_start + 1;
            return pos_start + 2;
        }
        return pos_start;
    }

    fn readNodeValue(units: []const u16, pos: usize, lead: i32) i32 {
        if (lead < min_two_unit_node_value_lead) {
            return (lead >> 6) - 1;
        }
        if (lead < three_unit_node_value_lead) {
            return (((lead & 0x7fc0) - min_two_unit_node_value_lead) << 10) |
                @as(i32, units[pos]);
        }
        return (@as(i32, units[pos]) << 16) | @as(i32, units[pos + 1]);
    }

    fn skipNodeValue(pos_start: usize, lead: i32) usize {
        if (lead >= min_two_unit_node_value_lead) {
            if (lead < three_unit_node_value_lead) return pos_start + 1;
            return pos_start + 2;
        }
        return pos_start;
    }

    fn jumpByValue(
        units: []const u16,
        pos_after_lead: usize,
        lead: i32,
    ) ?usize {
        var delta: i32 = undefined;
        var extra: usize = 0;
        if (lead < min_two_unit_value_lead) {
            delta = lead;
        } else if (lead < three_unit_value_lead) {
            if (pos_after_lead >= units.len) return null;
            delta = ((lead - min_two_unit_value_lead) << 16) |
                @as(i32, units[pos_after_lead]);
            extra = 1;
        } else {
            if (pos_after_lead + 1 >= units.len) return null;
            delta = (@as(i32, units[pos_after_lead]) << 16) |
                @as(i32, units[pos_after_lead + 1]);
            extra = 2;
        }
        const target = @as(i64, @intCast(pos_after_lead + extra)) + delta;
        if (target < 0 or target > units.len) return null;
        return @intCast(target);
    }

    fn jumpByDelta(units: []const u16, pos_start: usize) ?usize {
        if (pos_start >= units.len) return null;
        var pos = pos_start;
        var delta: i32 = units[pos];
        pos += 1;
        if (delta >= min_two_unit_delta_lead) {
            if (delta == three_unit_delta_lead) {
                if (pos + 1 >= units.len) return null;
                delta = (@as(i32, units[pos]) << 16) |
                    @as(i32, units[pos + 1]);
                pos += 2;
            } else {
                if (pos >= units.len) return null;
                delta = ((delta - min_two_unit_delta_lead) << 16) |
                    @as(i32, units[pos]);
                pos += 1;
            }
        }
        const target = @as(i64, @intCast(pos)) + delta;
        if (target < 0 or target > units.len) return null;
        return @intCast(target);
    }

    fn skipDelta(units: []const u16, pos_start: usize) ?usize {
        if (pos_start >= units.len) return null;
        var pos = pos_start;
        const delta: i32 = units[pos];
        pos += 1;
        if (delta >= min_two_unit_delta_lead) {
            if (delta == three_unit_delta_lead) {
                pos += 2;
            } else {
                pos += 1;
            }
        }
        if (pos > units.len) return null;
        return pos;
    }

    fn valueResult(node: i32) Result {
        return if (node & value_is_final != 0)
            .final_value
        else
            .intermediate_value;
    }

    fn branchNext(
        self: *UCharsTrie,
        pos_start: usize,
        length_input: i32,
        unit: i32,
    ) Result {
        var pos = pos_start;
        var length = length_input;
        if (length == 0) {
            const next_node = self.unitAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            length = next_node;
        }
        length += 1;
        while (length > max_branch_linear_sub_node_length) {
            const compare = self.unitAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (unit < compare) {
                length >>= 1;
                pos = jumpByDelta(self.units, pos) orelse {
                    self.stop();
                    return .no_match;
                };
            } else {
                length = length - (length >> 1);
                pos = skipDelta(self.units, pos) orelse {
                    self.stop();
                    return .no_match;
                };
            }
        }
        while (true) {
            const key = self.unitAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (unit == key) {
                const node = self.unitAt(pos) orelse {
                    self.stop();
                    return .no_match;
                };
                if (node & value_is_final != 0) {
                    self.pos = pos;
                    return .final_value;
                }
                const target = jumpByValue(self.units, pos + 1, node) orelse {
                    self.stop();
                    return .no_match;
                };
                const next_node = self.unitAt(target) orelse {
                    self.stop();
                    return .no_match;
                };
                self.pos = target;
                return if (next_node >= min_value_lead)
                    valueResult(next_node)
                else
                    .no_value;
            }
            length -= 1;
            const lead = self.unitAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos = skipValue(pos + 1, lead & 0x7fff);
            if (length <= 1) break;
        }
        const key = self.unitAt(pos) orelse {
            self.stop();
            return .no_match;
        };
        pos += 1;
        if (unit == key) {
            self.pos = pos;
            const node = self.unitAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            return if (node >= min_value_lead)
                valueResult(node)
            else
                .no_value;
        }
        self.stop();
        return .no_match;
    }

    fn nextImpl(self: *UCharsTrie, pos_start: usize, unit: i32) Result {
        var pos = pos_start;
        var node = self.unitAt(pos) orelse {
            self.stop();
            return .no_match;
        };
        pos += 1;
        while (true) {
            if (node < min_linear_match) {
                return self.branchNext(pos, node, unit);
            } else if (node < min_value_lead) {
                const length = node - min_linear_match;
                const expected = self.unitAt(pos) orelse {
                    self.stop();
                    return .no_match;
                };
                if (unit == expected) {
                    pos += 1;
                    self.remaining_match_length = length - 1;
                    self.pos = pos;
                    if (length - 1 < 0) {
                        const next_node = self.unitAt(pos) orelse {
                            self.stop();
                            return .no_match;
                        };
                        return if (next_node >= min_value_lead)
                            valueResult(next_node)
                        else
                            .no_value;
                    }
                    return .no_value;
                }
                break;
            } else if (node & value_is_final != 0) {
                break;
            } else {
                pos = skipNodeValue(pos, node);
                node &= node_type_mask;
            }
        }
        self.stop();
        return .no_match;
    }

    /// ICU `UCharsTrie.first`.
    pub fn first(self: *UCharsTrie, unit: i32) Result {
        self.remaining_match_length = -1;
        if (unit < 0 or unit > 0xffff) {
            self.stop();
            return .no_match;
        }
        return self.nextImpl(0, unit);
    }

    /// ICU `UCharsTrie.next`.
    pub fn next(self: *UCharsTrie, unit: i32) Result {
        var pos = self.pos orelse {
            return .no_match;
        };
        if (unit < 0 or unit > 0xffff) {
            self.stop();
            return .no_match;
        }
        var length = self.remaining_match_length;
        if (length >= 0) {
            const expected = self.unitAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (unit == expected) {
                length -= 1;
                self.remaining_match_length = length;
                self.pos = pos;
                if (length < 0) {
                    const node = self.unitAt(pos) orelse {
                        self.stop();
                        return .no_match;
                    };
                    return if (node >= min_value_lead)
                        valueResult(node)
                    else
                        .no_value;
                }
                return .no_value;
            }
            self.stop();
            return .no_match;
        }
        return self.nextImpl(pos, unit);
    }

    pub fn firstForCodePoint(self: *UCharsTrie, codepoint: u21) Result {
        if (codepoint <= 0xffff) return self.first(codepoint);
        const lead: u16 = @intCast(0xD800 + ((codepoint - 0x10000) >> 10));
        const trail: u16 = @intCast(0xDC00 + ((codepoint - 0x10000) & 0x3ff));
        const result = self.first(lead);
        if (!result.hasNext()) return .no_match;
        return self.next(trail);
    }

    pub fn nextForCodePoint(self: *UCharsTrie, codepoint: u21) Result {
        if (codepoint <= 0xffff) return self.next(codepoint);
        const lead: u16 = @intCast(0xD800 + ((codepoint - 0x10000) >> 10));
        const trail: u16 = @intCast(0xDC00 + ((codepoint - 0x10000) & 0x3ff));
        const result = self.next(lead);
        if (!result.hasNext()) return .no_match;
        return self.next(trail);
    }

    /// ICU `UCharsTrie.current`.
    pub fn current(self: *const UCharsTrie) Result {
        const pos = self.pos orelse return .no_match;
        if (self.remaining_match_length < 0) {
            const node = self.unitAt(pos) orelse return .no_match;
            if (node >= min_value_lead) return valueResult(node);
        }
        return .no_value;
    }

    /// ICU `UCharsTrie.getValue`.
    pub fn getValue(self: *const UCharsTrie) i32 {
        const pos = self.pos orelse return 0;
        const lead = self.unitAt(pos) orelse return 0;
        const after = pos + 1;
        if (lead & value_is_final != 0) {
            return readValue(self.units, after, lead & 0x7fff);
        }
        return readNodeValue(self.units, after, lead);
    }

    /// ICU `UCharsTrie.next(ConstChar16Ptr, length)`.
    pub fn nextString(self: *UCharsTrie, text: []const u16) Result {
        if (text.len == 0) return self.current();
        var result = self.current();
        for (text) |unit| {
            if (!result.hasNext()) return .no_match;
            result = self.next(unit);
        }
        return result;
    }
};


/// ICU `UCharsTrieBuilder`-compatible builder.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    units: std.ArrayList(u16) = .empty,

    pub const Entry = struct {
        units: []u16,
        value: i32,
    };

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.units);
        }
        self.entries.deinit(self.allocator);
        self.units.deinit(self.allocator);
    }

    pub fn add(
        self: *Builder,
        text: []const u16,
        value: i32,
    ) !void {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u16, entry.units, text)) {
                return error.DuplicateKey;
            }
        }
        const copy = try self.allocator.dupe(u16, text);
        errdefer self.allocator.free(copy);
        try self.entries.append(self.allocator, .{
            .units = copy,
            .value = value,
        });
    }

    pub fn buildAlloc(self: *Builder) ![]u16 {
        std.sort.heap(Entry, self.entries.items, {}, entryLessThan);
        if (self.entries.items.len == 0) {
            return self.allocator.alloc(u16, 0);
        }
        self.units.clearRetainingCapacity();
        _ = try self.writeNode(0, self.entries.items.len, 0, null);
        return self.units.toOwnedSlice(self.allocator);
    }

    fn entryLessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u16, a.units, b.units) == .lt;
    }

    fn commonPrefix(
        entries: []const Entry,
        depth: usize,
        cap: usize,
    ) usize {
        var max = cap;
        for (entries) |entry| {
            max = @min(max, entry.units.len - depth);
        }
        var length: usize = 0;
        while (length < max) : (length += 1) {
            const unit = entries[0].units[depth + length];
            for (entries[1..]) |entry| {
                if (entry.units[depth + length] != unit) return length;
            }
        }
        return length;
    }

    fn writeValueUnits(self: *Builder, value: i32) !void {
        const bits: u32 = @bitCast(value);
        try self.units.append(self.allocator, @intCast(bits >> 16));
        try self.units.append(
            self.allocator,
            @intCast(bits & 0xffff),
        );
    }

    fn writeFinal(self: *Builder, value: i32) !usize {
        const start = self.units.items.len;
        try self.units.append(self.allocator, 0xffff);
        try self.writeValueUnits(value);
        return start;
    }

    fn writeIntermediate(
        self: *Builder,
        node_type: u16,
        value: i32,
    ) !void {
        try self.units.append(self.allocator, 0x7fc0 | node_type);
        try self.writeValueUnits(value);
    }

    fn writeValueDeltaPlaceholder(self: *Builder) !usize {
        const start = self.units.items.len;
        try self.units.appendSlice(self.allocator, &.{ 0x7fff, 0, 0 });
        return start;
    }

    fn writeBranchDeltaPlaceholder(self: *Builder) !usize {
        const start = self.units.items.len;
        try self.units.appendSlice(self.allocator, &.{ 0xffff, 0, 0 });
        return start;
    }

    fn patchDelta(self: *Builder, position: usize, target: usize) void {
        const delta: u32 = @intCast(target - (position + 3));
        self.units.items[position + 1] = @intCast(delta >> 16);
        self.units.items[position + 2] = @intCast(delta & 0xffff);
    }

    fn writeNode(
        self: *Builder,
        start: usize,
        end: usize,
        depth: usize,
        value: ?i32,
    ) error{ OutOfMemory, Unsupported }!usize {
        var first = start;
        var node_value = value;
        if (first < end and
            self.entries.items[first].units.len == depth)
        {
            node_value = self.entries.items[first].value;
            first += 1;
        }
        if (first == end) {
            return self.writeFinal(node_value orelse 0);
        }

        const entries = self.entries.items[first..end];
        var group_starts = std.ArrayList(usize).empty;
        defer group_starts.deinit(self.allocator);
        try group_starts.append(self.allocator, first);
        var index = first + 1;
        while (index < end) : (index += 1) {
            if (self.entries.items[index].units[depth] !=
                self.entries.items[index - 1].units[depth])
            {
                try group_starts.append(self.allocator, index);
            }
        }
        const group_count = group_starts.items.len;

        if (group_count == 1) {
            const prefix_length = commonPrefix(entries, depth, 16);
            const node_type: u16 = @intCast(0x30 + prefix_length - 1);
            const node_start = self.units.items.len;
            if (node_value) |current| {
                try self.writeIntermediate(node_type, current);
            } else {
                try self.units.append(self.allocator, node_type);
            }
            try self.units.appendSlice(
                self.allocator,
                entries[0].units[depth..][0..prefix_length],
            );
            _ = try self.writeNode(
                first,
                end,
                depth + prefix_length,
                null,
            );
            return node_start;
        }

        return self.writeBranchNode(first, end, depth, node_value);
    }

    fn writeBranchNode(
        self: *Builder,
        start: usize,
        end: usize,
        depth: usize,
        node_value: ?i32,
    ) error{ OutOfMemory, Unsupported }!usize {
        var group_starts = std.ArrayList(usize).empty;
        defer group_starts.deinit(self.allocator);
        try group_starts.append(self.allocator, start);
        var index = start + 1;
        while (index < end) : (index += 1) {
            if (self.entries.items[index].units[depth] !=
                self.entries.items[index - 1].units[depth])
            {
                try group_starts.append(self.allocator, index);
            }
        }
        const group_count = group_starts.items.len;
        if (group_count > 0x30 and node_value != null) {
            return error.Unsupported;
        }
        const node_type: u16 = if (group_count > 0x30)
            0
        else
            @intCast(group_count - 1);
        const node_start = self.units.items.len;
        if (node_value) |current| {
            try self.writeIntermediate(node_type, current);
        } else {
            try self.units.append(self.allocator, node_type);
        }
        if (group_count > 0x30) {
            try self.units.append(
                self.allocator,
                @intCast(group_count - 1),
            );
        }
        try self.writeBranchData(group_starts.items, depth, end);
        return node_start;
    }

    fn writeBranchData(
        self: *Builder,
        group_starts: []const usize,
        depth: usize,
        end: usize,
    ) error{ OutOfMemory, Unsupported }!void {
        const group_count = group_starts.len;
        if (group_count <= 5) {
            var delta_positions = std.ArrayList(usize).empty;
            defer delta_positions.deinit(self.allocator);
            for (group_starts[0 .. group_count - 1]) |group_start| {
                try self.units.append(
                    self.allocator,
                    self.entries.items[group_start].units[depth],
                );
                try delta_positions.append(
                    self.allocator,
                    try self.writeValueDeltaPlaceholder(),
                );
            }
            const last_start = group_starts[group_count - 1];
            try self.units.append(
                self.allocator,
                self.entries.items[last_start].units[depth],
            );
            _ = try self.writeNode(last_start, end, depth + 1, null);
            for (
                group_starts[0 .. group_count - 1],
                delta_positions.items,
                0..,
            ) |group_start, delta_position, group_index| {
                const next_start = group_starts[group_index + 1];
                const target = try self.writeNode(
                    group_start,
                    next_start,
                    depth + 1,
                    null,
                );
                self.patchDelta(delta_position, target);
            }
            return;
        }

        const left = group_count / 2;
        const right_start = group_starts[left];
        try self.units.append(
            self.allocator,
            self.entries.items[right_start].units[depth],
        );
        const delta_position = try self.writeBranchDeltaPlaceholder();
        try self.writeBranchData(group_starts[left..], depth, end);
        const left_start = self.units.items.len;
        try self.writeBranchData(group_starts[0..left], depth, right_start);
        self.patchDelta(delta_position, left_start);
    }
};

test "UCharsTrie builder" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.add(&[_]u16{ 'a' }, 1);
    try builder.add(&[_]u16{ 'a', 'b' }, 2);
    try builder.add(&[_]u16{ 'a', 'b', 'c' }, 3);
    try builder.add(&[_]u16{ 'b' }, 4);
    try builder.add(&[_]u16{ 'b', 'a' }, 5);
    const units = try builder.buildAlloc();
    defer allocator.free(units);
    var trie = UCharsTrie.init(units);
    try testing.expectEqual(Result.intermediate_value, trie.first('a'));
    try testing.expectEqual(@as(i32, 1), trie.getValue());
    try testing.expectEqual(Result.intermediate_value, trie.next('b'));
    try testing.expectEqual(@as(i32, 2), trie.getValue());
    try testing.expectEqual(Result.final_value, trie.next('c'));
    try testing.expectEqual(@as(i32, 3), trie.getValue());
    try testing.expectEqual(Result.intermediate_value, trie.first('b'));
    try testing.expectEqual(@as(i32, 4), trie.getValue());
    try testing.expectEqual(Result.final_value, trie.next('a'));
    try testing.expectEqual(@as(i32, 5), trie.getValue());
    try testing.expectEqual(Result.no_match, trie.first('z'));
    try testing.expectEqual(Result.intermediate_value, trie.first('a'));
    try testing.expectEqual(Result.no_match, trie.next('x'));

    var wide = Builder.init(allocator);
    defer wide.deinit();
    var words: [80][1]u16 = undefined;
    for (0..80) |i| {
        words[i][0] = @intCast(0x100 + i);
        try wide.add(&words[i], @intCast(i));
    }
    const wide_units = try wide.buildAlloc();
    defer allocator.free(wide_units);
    var wide_trie = UCharsTrie.init(wide_units);
    for (0..80) |i| {
        const result = wide_trie.first(@intCast(0x100 + i));
        try testing.expect(result.hasValue());
        try testing.expectEqual(@as(i32, @intCast(i)), wide_trie.getValue());
    }
    try testing.expectEqual(
        Result.no_match,
        wide_trie.first(0x100 + 80),
    );
}

test "UCharsTrie reader" {
    const testing = @import("std").testing;
    const units = [_]u16{
        0x0001, 0x0061, 0x0004, 0x0062, 0x0170, 0x0061, 0x8005, 0x00b0,
        0x0062, 0x00f0, 0x0063, 0x8003,
    };
    var trie = UCharsTrie.init(&units);
    try testing.expectEqual(Result.intermediate_value, trie.first('a'));
    try testing.expectEqual(@as(i32, 1), trie.getValue());
    try testing.expectEqual(Result.intermediate_value, trie.next('b'));
    try testing.expectEqual(@as(i32, 2), trie.getValue());
    try testing.expectEqual(Result.final_value, trie.next('c'));
    try testing.expectEqual(@as(i32, 3), trie.getValue());
    try testing.expectEqual(Result.no_match, trie.next('d'));

    try testing.expectEqual(Result.intermediate_value, trie.first('b'));
    try testing.expectEqual(@as(i32, 4), trie.getValue());
    try testing.expectEqual(Result.final_value, trie.next('a'));
    try testing.expectEqual(@as(i32, 5), trie.getValue());

    try testing.expectEqual(Result.no_match, trie.first('c'));
    trie.reset();
    try testing.expectEqual(Result.no_value, trie.current());
}

test "ICU UCharsTrie conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("trie_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJU2", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const option = fixture[cursor];
        const unit_count = std.mem.readInt(
            u16,
            fixture[cursor + 1 ..][0..2],
            .little,
        );
        cursor += 3;
        const units = try allocator.alloc(u16, unit_count);
        defer allocator.free(units);
        for (units) |*unit| {
            unit.* = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
        }
        const op_count = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;

        var trie = UCharsTrie.init(units);
        var op_index: usize = 0;
        while (op_index < op_count) : (op_index += 1) {
            const kind = fixture[cursor];
            cursor += 1;
            var unit: i32 = 0;
            var codepoint: u21 = 0;
            var text = std.ArrayList(u16).empty;
            defer text.deinit(allocator);
            if (kind == 0 or kind == 1) {
                unit = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
            } else if (kind == 2 or kind == 3) {
                codepoint = @intCast(std.mem.readInt(
                    u32,
                    fixture[cursor..][0..4],
                    .little,
                ));
                cursor += 4;
            } else {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                try text.ensureTotalCapacity(allocator, length);
                for (0..length) |_| {
                    try text.append(
                        allocator,
                        std.mem.readInt(
                            u16,
                            fixture[cursor..][0..2],
                            .little,
                        ),
                    );
                    cursor += 2;
                }
            }
            const expected_result: Result = @enumFromInt(fixture[cursor]);
            cursor += 1;
            const expected_value = std.mem.readInt(
                i32,
                fixture[cursor..][0..4],
                .little,
            );
            cursor += 4;

            const actual = switch (kind) {
                0 => blk: {
                    trie.reset();
                    break :blk trie.first(unit);
                },
                1 => trie.next(unit),
                2 => blk: {
                    trie.reset();
                    break :blk trie.firstForCodePoint(codepoint);
                },
                3 => trie.nextForCodePoint(codepoint),
                4 => blk: {
                    trie.reset();
                    break :blk trie.nextString(text.items);
                },
                else => return error.InvalidFixture,
            };
            if (actual != expected_result) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "trie result mismatch: case {d} option {d} op {d} kind {d} got {s} want {s}\n",
                        .{
                            case_index,
                            option,
                            op_index,
                            kind,
                            @tagName(actual),
                            @tagName(expected_result),
                        },
                    );
                }
            } else if (actual.hasValue() and trie.getValue() != expected_value) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "trie value mismatch: case {d} op {d} got {d} want {d}\n",
                        .{ case_index, op_index, trie.getValue(), expected_value },
                    );
                }
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "UCharsTrie conformance: {}/{} cases passed\n",
        .{ case_count - failures, case_count },
    );
}
