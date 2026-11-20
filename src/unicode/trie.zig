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
const state64_remaining_shift: u6 = 59;
const state64_pos_mask: u64 = (@as(u64, 1) << state64_remaining_shift) - 1;

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

    fn readValueChecked(units: []const u16, pos: usize, lead: i32) ?i32 {
        const payload: usize = if (lead < min_two_unit_value_lead)
            0
        else if (lead < three_unit_value_lead)
            1
        else
            2;
        if (pos > units.len or payload > units.len - pos) return null;
        return readValue(units, pos, lead);
    }

    fn readNodeValueChecked(units: []const u16, pos: usize, lead: i32) ?i32 {
        const payload: usize = if (lead < min_two_unit_node_value_lead)
            0
        else if (lead < three_unit_node_value_lead)
            1
        else
            2;
        if (pos > units.len or payload > units.len - pos) return null;
        return readNodeValue(units, pos, lead);
    }

    fn findUniqueValueFromBranch(
        units: []const u16,
        pos_start: usize,
        length_input: i32,
        have_unique_value: *bool,
        unique_value: *i32,
    ) ?usize {
        var pos = pos_start;
        var length = length_input;
        while (length > max_branch_linear_sub_node_length) {
            pos += 1; // Ignore the comparison unit.
            const sub = jumpByDelta(units, pos) orelse return null;
            pos = findUniqueValueFromBranch(
                units,
                sub,
                length >> 1,
                have_unique_value,
                unique_value,
            ) orelse return null;
            length -= length >> 1;
            pos = skipDelta(units, pos) orelse return null;
        }
        while (true) {
            pos += 1; // Ignore the comparison unit.
            if (pos >= units.len) return null;
            var node: i32 = units[pos];
            pos += 1;
            const is_final = node & value_is_final != 0;
            node &= 0x7fff;
            const value = readValueChecked(units, pos, node) orelse return null;
            pos = skipValue(pos, node);
            if (pos > units.len) return null;
            if (is_final) {
                if (have_unique_value.*) {
                    if (value != unique_value.*) return null;
                } else {
                    unique_value.* = value;
                    have_unique_value.* = true;
                }
            } else {
                const target = @as(i64, @intCast(pos)) + value;
                if (target < 0 or target > units.len) return null;
                if (findUniqueValue(
                    units,
                    @intCast(target),
                    have_unique_value,
                    unique_value,
                ) == null) return null;
                have_unique_value.* = true;
            }
            length -= 1;
            if (length <= 1) break;
        }
        if (pos + 1 > units.len) return null;
        return pos + 1; // Ignore the last comparison unit.
    }

    fn findUniqueValue(
        units: []const u16,
        pos_start: usize,
        have_unique_value: *bool,
        unique_value: *i32,
    ) ?void {
        var pos = pos_start;
        if (pos >= units.len) return null;
        var node: i32 = units[pos];
        pos += 1;
        while (true) {
            if (node < min_linear_match) {
                if (node == 0) {
                    if (pos >= units.len) return null;
                    node = units[pos];
                    pos += 1;
                }
                pos = findUniqueValueFromBranch(
                    units,
                    pos,
                    node + 1,
                    have_unique_value,
                    unique_value,
                ) orelse return null;
                have_unique_value.* = true;
                if (pos >= units.len) return null;
                node = units[pos];
                pos += 1;
            } else if (node < min_value_lead) {
                // Skip the rest of a linear-match node.
                const target = @as(i64, @intCast(pos)) +
                    (node - min_linear_match + 1);
                if (target < 0 or target > units.len) return null;
                pos = @intCast(target);
                if (pos >= units.len) return null;
                node = units[pos];
                pos += 1;
            } else {
                const is_final = node & value_is_final != 0;
                const value = if (is_final)
                    readValueChecked(units, pos, node & 0x7fff) orelse return null
                else
                    readNodeValueChecked(units, pos, node) orelse return null;
                if (have_unique_value.*) {
                    if (value != unique_value.*) return null;
                } else {
                    unique_value.* = value;
                    have_unique_value.* = true;
                }
                if (is_final) return;
                pos = skipNodeValue(pos, node);
                if (pos > units.len) return null;
                node &= node_type_mask;
            }
        }
    }

    fn getNextBranchUChars(
        units: []const u16,
        pos_start: usize,
        length_input: i32,
        out: *std.ArrayList(u16),
        allocator: std.mem.Allocator,
    ) !void {
        var pos = pos_start;
        var length = length_input;
        while (length > max_branch_linear_sub_node_length) {
            pos += 1; // Ignore the comparison unit.
            const sub = jumpByDelta(units, pos) orelse return;
            try getNextBranchUChars(units, sub, length >> 1, out, allocator);
            length -= length >> 1;
            pos = skipDelta(units, pos) orelse return;
        }
        while (true) {
            if (pos >= units.len) return;
            try out.append(allocator, units[pos]);
            pos += 1;
            if (pos >= units.len) return;
            const lead: i32 = units[pos];
            pos = skipValue(pos + 1, lead & 0x7fff);
            if (pos > units.len) return;
            length -= 1;
            if (length <= 1) break;
        }
        if (pos >= units.len) return;
        try out.append(allocator, units[pos]);
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

    /// ICU `UCharsTrie.getState64`. Returns 0 when there is no match state.
    pub fn getState64(self: *const UCharsTrie) u64 {
        const pos = self.pos orelse return 0;
        const remaining: u64 = @intCast(self.remaining_match_length + 2);
        return (remaining << state64_remaining_shift) | @as(u64, pos);
    }

    /// ICU `UCharsTrie.resetToState64`.
    pub fn resetToState64(self: *UCharsTrie, state: u64) void {
        if (state == 0) {
            self.pos = null;
            self.remaining_match_length = -1;
            return;
        }
        self.remaining_match_length =
            @as(i32, @intCast(state >> state64_remaining_shift)) - 2;
        self.pos = std.math.cast(usize, state & state64_pos_mask);
    }

    /// ICU `UCharsTrie.hasUniqueValue`.
    pub fn hasUniqueValue(self: *const UCharsTrie, unique_value: *i32) bool {
        const pos = self.pos orelse return false;
        const target = @as(i64, @intCast(pos)) +
            self.remaining_match_length + 1;
        if (target < 0 or target > self.units.len) return false;
        var have_unique_value = false;
        if (findUniqueValue(
            self.units,
            @intCast(target),
            &have_unique_value,
            unique_value,
        ) == null) return false;
        return have_unique_value;
    }

    /// ICU `UCharsTrie.getNextUChars`.
    pub fn getNextUChars(
        self: *const UCharsTrie,
        out: *std.ArrayList(u16),
        allocator: std.mem.Allocator,
    ) !usize {
        const start = self.pos orelse return 0;
        if (self.remaining_match_length >= 0) {
            if (start >= self.units.len) return 0;
            try out.append(allocator, self.units[start]);
            return 1;
        }
        var pos = start;
        if (pos >= self.units.len) return 0;
        var node: i32 = self.units[pos];
        pos += 1;
        if (node >= min_value_lead) {
            if (node & value_is_final != 0) return 0;
            pos = skipNodeValue(pos, node);
            node &= node_type_mask;
        }
        if (node < min_linear_match) {
            if (node == 0) {
                if (pos >= self.units.len) return 0;
                node = self.units[pos];
                pos += 1;
            }
            const count: usize = @intCast(node + 1);
            try getNextBranchUChars(self.units, pos, node + 1, out, allocator);
            return count;
        }
        if (pos >= self.units.len) return 0;
        try out.append(allocator, self.units[pos]);
        return 1;
    }

    /// ICU `UCharsTrie.next(ConstChar16Ptr, length)`.
    pub fn nextString(self: *UCharsTrie, text: []const u16) Result {
        if (text.len == 0) return self.current();
        var result = self.current();
        for (text) |unit| {
            if (!result.hasNext()) {
                self.stop();
                return .no_match;
            }
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

test "UCharsTrie state64, unique value, and next units" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.add(&[_]u16{'a'}, 7);
    try builder.add(&[_]u16{ 'a', 'b' }, 7);
    try builder.add(&[_]u16{ 'a', 'b', 'c' }, 7);
    try builder.add(&[_]u16{'b'}, 7);
    const units = try builder.buildAlloc();
    defer allocator.free(units);

    var trie = UCharsTrie.init(units);
    var unique: i32 = 0;
    trie.reset();
    try testing.expect(trie.hasUniqueValue(&unique));
    try testing.expectEqual(@as(i32, 7), unique);

    var next = std.ArrayList(u16).empty;
    defer next.deinit(allocator);
    try testing.expectEqual(
        @as(usize, 2),
        try trie.getNextUChars(&next, allocator),
    );
    try testing.expectEqualSlices(u16, &[_]u16{ 'a', 'b' }, next.items);

    try testing.expectEqual(Result.intermediate_value, trie.first('a'));
    next.clearRetainingCapacity();
    try testing.expectEqual(
        @as(usize, 1),
        try trie.getNextUChars(&next, allocator),
    );
    try testing.expectEqualSlices(u16, &[_]u16{'b'}, next.items);
    try testing.expect(trie.hasUniqueValue(&unique));
    try testing.expectEqual(@as(i32, 7), unique);

    const state = trie.getState64();
    try testing.expect(state != 0);
    try testing.expectEqual(Result.intermediate_value, trie.next('b'));
    try testing.expectEqual(Result.final_value, trie.next('c'));

    trie.resetToState64(state);
    try testing.expectEqual(Result.intermediate_value, trie.current());
    try testing.expectEqual(@as(i32, 7), trie.getValue());
    try testing.expectEqual(Result.intermediate_value, trie.next('b'));
    try testing.expectEqual(Result.final_value, trie.next('c'));
    try testing.expectEqual(@as(i32, 7), trie.getValue());

    next.clearRetainingCapacity();
    try testing.expectEqual(
        @as(usize, 0),
        try trie.getNextUChars(&next, allocator),
    );

    try testing.expectEqual(Result.no_match, trie.next('x'));
    try testing.expect(!trie.hasUniqueValue(&unique));
    try testing.expectEqual(
        @as(usize, 0),
        try trie.getNextUChars(&next, allocator),
    );
    try testing.expectEqual(@as(u64, 0), trie.getState64());

    var mixed = Builder.init(allocator);
    defer mixed.deinit();
    try mixed.add(&[_]u16{'x'}, 1);
    try mixed.add(&[_]u16{ 'x', 'y' }, 2);
    const mixed_units = try mixed.buildAlloc();
    defer allocator.free(mixed_units);
    var mixed_trie = UCharsTrie.init(mixed_units);
    mixed_trie.reset();
    try testing.expect(!mixed_trie.hasUniqueValue(&unique));
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
        trie.reset();
        var op_index: usize = 0;
        while (op_index < op_count) : (op_index += 1) {
            const kind = fixture[cursor];
            cursor += 1;
            var unit: i32 = 0;
            var codepoint: u21 = 0;
            var text = std.ArrayList(u16).empty;
            defer text.deinit(allocator);
            var expected_next = std.ArrayList(u16).empty;
            defer expected_next.deinit(allocator);
            var expected_state: u64 = 0;
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
            } else if (kind == 4) {
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
            } else if (kind == 5) {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                try expected_next.ensureTotalCapacity(allocator, length);
                for (0..length) |_| {
                    try expected_next.append(
                        allocator,
                        std.mem.readInt(
                            u16,
                            fixture[cursor..][0..2],
                            .little,
                        ),
                    );
                    cursor += 2;
                }
                expected_state = std.mem.readInt(
                    u64,
                    fixture[cursor..][0..8],
                    .little,
                );
                cursor += 8;
            } else {
                return error.InvalidFixture;
            }
            const expected_result: Result = @enumFromInt(fixture[cursor]);
            cursor += 1;
            const expected_value = std.mem.readInt(
                i32,
                fixture[cursor..][0..4],
                .little,
            );
            cursor += 4;

            if (kind == 5) {
                var unique: i32 = 0;
                const has_unique = trie.hasUniqueValue(&unique);
                if (has_unique != (expected_result != .no_match)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "trie unique flag mismatch: case {d} option {d} op {d} got {} want {}\n",
                            .{
                                case_index,
                                option,
                                op_index,
                                has_unique,
                                expected_result != .no_match,
                            },
                        );
                    }
                } else if (has_unique and unique != expected_value) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "trie unique value mismatch: case {d} op {d} got {d} want {d}\n",
                            .{ case_index, op_index, unique, expected_value },
                        );
                    }
                }
                var next = std.ArrayList(u16).empty;
                defer next.deinit(allocator);
                const next_count = try trie.getNextUChars(&next, allocator);
                if (next_count != expected_next.items.len or
                    !std.mem.eql(u16, next.items, expected_next.items))
                {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "trie next mismatch: case {d} op {d} got {any} want {any}\n",
                            .{ case_index, op_index, next.items, expected_next.items },
                        );
                    }
                }
                const actual_state = trie.getState64();
                if (actual_state != expected_state) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "trie state mismatch: case {d} op {d} got {x} want {x}\n",
                            .{ case_index, op_index, actual_state, expected_state },
                        );
                    }
                } else if (expected_state != 0) {
                    var restored = trie;
                    restored.resetToState64(expected_state);
                    if (restored.current() != trie.current() or
                        (trie.current().hasValue() and
                            restored.getValue() != trie.getValue()))
                    {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "trie state restore mismatch: case {d} op {d}\n",
                                .{ case_index, op_index },
                            );
                        }
                    }
                }
                continue;
            }

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

/// ICU `BytesTrie`-compatible reader for byte-keyed tries.
pub const BytesTrie = struct {
    bytes: []const u8,
    pos: ?usize = null,
    remaining_match_length: i32 = -1,

    pub fn init(bytes: []const u8) BytesTrie {
        return .{ .bytes = bytes };
    }

    pub fn reset(self: *BytesTrie) void {
        self.pos = 0;
        self.remaining_match_length = -1;
    }

    fn stop(self: *BytesTrie) void {
        self.pos = null;
    }

    fn byteAt(self: *const BytesTrie, index: usize) ?i32 {
        if (index >= self.bytes.len) return null;
        return self.bytes[index];
    }

    fn readValue(bytes: []const u8, pos: usize, lead: i32) i32 {
        var value: u32 = undefined;
        if (lead < 0x51) {
            value = @intCast(lead - 0x10);
        } else if (lead < 0x6c) {
            value = (@as(u32, @intCast(lead - 0x51)) << 8) | bytes[pos];
        } else if (lead < 0x7e) {
            value = (@as(u32, @intCast(lead - 0x6c)) << 16) |
                (@as(u32, bytes[pos]) << 8) | bytes[pos + 1];
        } else if (lead == 0x7e) {
            value = (@as(u32, bytes[pos]) << 16) |
                (@as(u32, bytes[pos + 1]) << 8) | bytes[pos + 2];
        } else {
            value = (@as(u32, bytes[pos]) << 24) |
                (@as(u32, bytes[pos + 1]) << 16) |
                (@as(u32, bytes[pos + 2]) << 8) | bytes[pos + 3];
        }
        return @bitCast(value);
    }

    fn skipValue(pos_start: usize, lead: i32) usize {
        if (lead >= 0xa2) {
            if (lead < 0xd8) return pos_start + 1;
            if (lead < 0xfc) return pos_start + 2;
            return pos_start + 3 + @as(usize, @intCast((lead >> 1) & 1));
        }
        return pos_start;
    }

    fn jumpByDelta(bytes: []const u8, pos_start: usize) ?usize {
        if (pos_start >= bytes.len) return null;
        var pos = pos_start;
        var delta: u32 = bytes[pos];
        pos += 1;
        if (delta >= 0xc0) {
            if (delta < 0xf0) {
                if (pos >= bytes.len) return null;
                delta = ((delta - 0xc0) << 8) | bytes[pos];
                pos += 1;
            } else if (delta < 0xfe) {
                if (pos + 1 >= bytes.len) return null;
                delta = ((delta - 0xf0) << 16) |
                    (@as(u32, bytes[pos]) << 8) | bytes[pos + 1];
                pos += 2;
            } else if (delta == 0xfe) {
                if (pos + 2 >= bytes.len) return null;
                delta = (@as(u32, bytes[pos]) << 16) |
                    (@as(u32, bytes[pos + 1]) << 8) | bytes[pos + 2];
                pos += 3;
            } else {
                if (pos + 3 >= bytes.len) return null;
                delta = (@as(u32, bytes[pos]) << 24) |
                    (@as(u32, bytes[pos + 1]) << 16) |
                    (@as(u32, bytes[pos + 2]) << 8) | bytes[pos + 3];
                pos += 4;
            }
        }
        const target = @as(i64, @intCast(pos)) + delta;
        if (target < 0 or target > bytes.len) return null;
        return @intCast(target);
    }

    fn skipDelta(bytes: []const u8, pos_start: usize) ?usize {
        if (pos_start >= bytes.len) return null;
        const delta = bytes[pos_start];
        var pos = pos_start + 1;
        if (delta >= 0xc0) {
            if (delta < 0xf0) {
                pos += 1;
            } else if (delta < 0xfe) {
                pos += 2;
            } else {
                pos += 3 + @as(usize, delta & 1);
            }
        }
        if (pos > bytes.len) return null;
        return pos;
    }

    fn valueResult(node: i32) Result {
        return if (node & 1 != 0) .final_value else .intermediate_value;
    }

    fn readValueChecked(bytes: []const u8, pos: usize, lead: i32) ?i32 {
        const payload: usize = if (lead < 0x51)
            0
        else if (lead < 0x6c)
            1
        else if (lead < 0x7e)
            2
        else if (lead == 0x7e)
            3
        else
            4;
        if (pos > bytes.len or payload > bytes.len - pos) return null;
        return readValue(bytes, pos, lead);
    }

    fn findUniqueValueFromBranch(
        bytes: []const u8,
        pos_start: usize,
        length_input: i32,
        have_unique_value: *bool,
        unique_value: *i32,
    ) ?usize {
        var pos = pos_start;
        var length = length_input;
        while (length > max_branch_linear_sub_node_length) {
            pos += 1; // Ignore the comparison byte.
            const sub = jumpByDelta(bytes, pos) orelse return null;
            pos = findUniqueValueFromBranch(
                bytes,
                sub,
                length >> 1,
                have_unique_value,
                unique_value,
            ) orelse return null;
            length -= length >> 1;
            pos = skipDelta(bytes, pos) orelse return null;
        }
        while (true) {
            pos += 1; // Ignore the comparison byte.
            if (pos >= bytes.len) return null;
            const node: i32 = bytes[pos];
            pos += 1;
            const is_final = node & 1 != 0;
            const value = readValueChecked(bytes, pos, node >> 1) orelse
                return null;
            pos = skipValue(pos, node);
            if (pos > bytes.len) return null;
            if (is_final) {
                if (have_unique_value.*) {
                    if (value != unique_value.*) return null;
                } else {
                    unique_value.* = value;
                    have_unique_value.* = true;
                }
            } else {
                const target = @as(i64, @intCast(pos)) + value;
                if (target < 0 or target > bytes.len) return null;
                if (findUniqueValue(
                    bytes,
                    @intCast(target),
                    have_unique_value,
                    unique_value,
                ) == null) return null;
                have_unique_value.* = true;
            }
            length -= 1;
            if (length <= 1) break;
        }
        if (pos + 1 > bytes.len) return null;
        return pos + 1; // Ignore the last comparison byte.
    }

    fn findUniqueValue(
        bytes: []const u8,
        pos_start: usize,
        have_unique_value: *bool,
        unique_value: *i32,
    ) ?void {
        var pos = pos_start;
        while (true) {
            if (pos >= bytes.len) return null;
            var node: i32 = bytes[pos];
            pos += 1;
            if (node < 0x10) {
                if (node == 0) {
                    if (pos >= bytes.len) return null;
                    node = bytes[pos];
                    pos += 1;
                }
                pos = findUniqueValueFromBranch(
                    bytes,
                    pos,
                    node + 1,
                    have_unique_value,
                    unique_value,
                ) orelse return null;
                have_unique_value.* = true;
            } else if (node < 0x20) {
                // Skip the rest of a linear-match node.
                const target = @as(i64, @intCast(pos)) + (node - 0x10 + 1);
                if (target < 0 or target > bytes.len) return null;
                pos = @intCast(target);
            } else {
                const is_final = node & 1 != 0;
                const value = readValueChecked(bytes, pos, node >> 1) orelse
                    return null;
                if (have_unique_value.*) {
                    if (value != unique_value.*) return null;
                } else {
                    unique_value.* = value;
                    have_unique_value.* = true;
                }
                if (is_final) return;
                pos = skipValue(pos, node);
                if (pos > bytes.len) return null;
            }
        }
    }

    fn getNextBranchBytes(
        bytes: []const u8,
        pos_start: usize,
        length_input: i32,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) !void {
        var pos = pos_start;
        var length = length_input;
        while (length > max_branch_linear_sub_node_length) {
            pos += 1; // Ignore the comparison byte.
            const sub = jumpByDelta(bytes, pos) orelse return;
            try getNextBranchBytes(bytes, sub, length >> 1, out, allocator);
            length -= length >> 1;
            pos = skipDelta(bytes, pos) orelse return;
        }
        while (true) {
            if (pos >= bytes.len) return;
            try out.append(allocator, bytes[pos]);
            pos += 1;
            if (pos >= bytes.len) return;
            const lead: i32 = bytes[pos];
            pos = skipValue(pos + 1, lead);
            if (pos > bytes.len) return;
            length -= 1;
            if (length <= 1) break;
        }
        if (pos >= bytes.len) return;
        try out.append(allocator, bytes[pos]);
    }

    fn branchNext(
        self: *BytesTrie,
        pos_start: usize,
        length_input: i32,
        in_byte: i32,
    ) Result {
        var pos = pos_start;
        var length = length_input;
        if (length == 0) {
            const next_node = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            length = next_node;
        }
        length += 1;
        while (length > 5) {
            const compare = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (in_byte < compare) {
                length >>= 1;
                pos = jumpByDelta(self.bytes, pos) orelse {
                    self.stop();
                    return .no_match;
                };
            } else {
                length = length - (length >> 1);
                pos = skipDelta(self.bytes, pos) orelse {
                    self.stop();
                    return .no_match;
                };
            }
        }
        while (true) {
            const key = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (in_byte == key) {
                const node = self.byteAt(pos) orelse {
                    self.stop();
                    return .no_match;
                };
                if (node & 1 != 0) {
                    self.pos = pos;
                    return .final_value;
                }
                pos += 1;
                const lead = node >> 1;
                const delta = readValue(self.bytes, pos, lead);
                var payload: usize = 0;
                if (lead >= 0x51) {
                    if (lead < 0x6c) {
                        payload = 1;
                    } else if (lead < 0x7e) {
                        payload = 2;
                    } else if (lead == 0x7e) {
                        payload = 3;
                    } else {
                        payload = 4;
                    }
                }
                const target = @as(i64, @intCast(pos + payload)) + delta;
                if (target < 0 or target > self.bytes.len) {
                    self.stop();
                    return .no_match;
                }
                pos = @intCast(target);
                const next_node = self.byteAt(pos) orelse {
                    self.stop();
                    return .no_match;
                };
                self.pos = pos;
                return if (next_node >= 0x20) valueResult(next_node) else .no_value;
            }
            length -= 1;
            const lead = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos = skipValue(pos + 1, lead);
            if (length <= 1) break;
        }
        const key = self.byteAt(pos) orelse {
            self.stop();
            return .no_match;
        };
        pos += 1;
        if (in_byte == key) {
            self.pos = pos;
            const node = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            return if (node >= 0x20) valueResult(node) else .no_value;
        }
        self.stop();
        return .no_match;
    }

    fn nextImpl(self: *BytesTrie, pos_start: usize, in_byte: i32) Result {
        var pos = pos_start;
        while (true) {
            const node = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (node < 0x10) {
                return self.branchNext(pos, node, in_byte);
            } else if (node < 0x20) {
                const length = node - 0x10;
                const expected = self.byteAt(pos) orelse {
                    self.stop();
                    return .no_match;
                };
                if (in_byte == expected) {
                    pos += 1;
                    self.remaining_match_length = length - 1;
                    self.pos = pos;
                    if (length - 1 < 0) {
                        const next_node = self.byteAt(pos) orelse {
                            self.stop();
                            return .no_match;
                        };
                        return if (next_node >= 0x20)
                            valueResult(next_node)
                        else
                            .no_value;
                    }
                    return .no_value;
                }
                break;
            } else if (node & 1 != 0) {
                break;
            } else {
                pos = skipValue(pos, node);
            }
        }
        self.stop();
        return .no_match;
    }

    fn normalizeByte(in_byte: i32) ?i32 {
        var value = in_byte;
        if (value < 0) value += 0x100;
        if (value < 0 or value > 0xff) return null;
        return value;
    }

    pub fn first(self: *BytesTrie, in_byte: i32) Result {
        self.remaining_match_length = -1;
        const value = normalizeByte(in_byte) orelse {
            self.stop();
            return .no_match;
        };
        return self.nextImpl(0, value);
    }

    pub fn next(self: *BytesTrie, in_byte: i32) Result {
        const value = normalizeByte(in_byte) orelse {
            self.stop();
            return .no_match;
        };
        return self.nextRaw(value);
    }

    fn nextRaw(self: *BytesTrie, value: i32) Result {
        var pos = self.pos orelse return .no_match;
        var length = self.remaining_match_length;
        if (length >= 0) {
            const expected = self.byteAt(pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
            if (value == expected) {
                length -= 1;
                self.remaining_match_length = length;
                self.pos = pos;
                if (length < 0) {
                    const node = self.byteAt(pos) orelse {
                        self.stop();
                        return .no_match;
                    };
                    return if (node >= 0x20)
                        valueResult(node)
                    else
                        .no_value;
                }
                return .no_value;
            }
            self.stop();
            return .no_match;
        }
        return self.nextImpl(pos, value);
    }

    pub fn current(self: *const BytesTrie) Result {
        const pos = self.pos orelse return .no_match;
        if (self.remaining_match_length < 0) {
            const node = self.byteAt(pos) orelse return .no_match;
            if (node >= 0x20) return valueResult(node);
        }
        return .no_value;
    }

    pub fn getValue(self: *const BytesTrie) i32 {
        const pos = self.pos orelse return 0;
        const lead = self.byteAt(pos) orelse return 0;
        return readValue(self.bytes, pos + 1, lead >> 1);
    }

    /// ICU `BytesTrie.getState64`. Returns 0 when there is no match state.
    pub fn getState64(self: *const BytesTrie) u64 {
        const pos = self.pos orelse return 0;
        const remaining: u64 = @intCast(self.remaining_match_length + 2);
        return (remaining << state64_remaining_shift) | @as(u64, pos);
    }

    /// ICU `BytesTrie.resetToState64`.
    pub fn resetToState64(self: *BytesTrie, state: u64) void {
        if (state == 0) {
            self.pos = null;
            self.remaining_match_length = -1;
            return;
        }
        self.remaining_match_length =
            @as(i32, @intCast(state >> state64_remaining_shift)) - 2;
        self.pos = std.math.cast(usize, state & state64_pos_mask);
    }

    /// ICU `BytesTrie.hasUniqueValue`.
    pub fn hasUniqueValue(self: *const BytesTrie, unique_value: *i32) bool {
        const pos = self.pos orelse return false;
        const target = @as(i64, @intCast(pos)) +
            self.remaining_match_length + 1;
        if (target < 0 or target > self.bytes.len) return false;
        var have_unique_value = false;
        if (findUniqueValue(
            self.bytes,
            @intCast(target),
            &have_unique_value,
            unique_value,
        ) == null) return false;
        return have_unique_value;
    }

    /// ICU `BytesTrie.getNextBytes`.
    pub fn getNextBytes(
        self: *const BytesTrie,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) !usize {
        const start = self.pos orelse return 0;
        if (self.remaining_match_length >= 0) {
            if (start >= self.bytes.len) return 0;
            try out.append(allocator, self.bytes[start]);
            return 1;
        }
        var pos = start;
        if (pos >= self.bytes.len) return 0;
        var node: i32 = self.bytes[pos];
        pos += 1;
        if (node >= 0x20) {
            if (node & 1 != 0) return 0;
            pos = skipValue(pos, node);
            if (pos >= self.bytes.len) return 0;
            node = self.bytes[pos];
            pos += 1;
        }
        if (node < 0x10) {
            if (node == 0) {
                if (pos >= self.bytes.len) return 0;
                node = self.bytes[pos];
                pos += 1;
            }
            const count: usize = @intCast(node + 1);
            try getNextBranchBytes(self.bytes, pos, node + 1, out, allocator);
            return count;
        }
        if (pos >= self.bytes.len) return 0;
        try out.append(allocator, self.bytes[pos]);
        return 1;
    }

    /// ICU's byte-string traversal compares signed `char` values without
    /// normalizing them, so bytes >= 0x80 do not match through this method.
    pub fn nextString(self: *BytesTrie, text: []const u8) Result {
        if (text.len == 0) return self.current();
        var result = self.current();
        for (text) |byte| {
            if (!result.hasNext()) {
                self.stop();
                return .no_match;
            }
            result = self.nextRaw(@as(i8, @bitCast(byte)));
        }
        return result;
    }
};

test "ICU BytesTrie conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("bytes_trie_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJY2", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const option = fixture[cursor];
        const byte_count = std.mem.readInt(
            u16,
            fixture[cursor + 1 ..][0..2],
            .little,
        );
        cursor += 3;
        const bytes = fixture[cursor..][0..byte_count];
        cursor += byte_count;
        const op_count = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;

        var trie = BytesTrie.init(bytes);
        trie.reset();
        var op_index: usize = 0;
        while (op_index < op_count) : (op_index += 1) {
            const kind = fixture[cursor];
            cursor += 1;
            var byte: i32 = 0;
            var text = std.ArrayList(u8).empty;
            defer text.deinit(allocator);
            var expected_next = std.ArrayList(u8).empty;
            defer expected_next.deinit(allocator);
            var expected_state: u64 = 0;
            if (kind == 0 or kind == 1) {
                byte = fixture[cursor];
                cursor += 1;
            } else if (kind == 2) {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                try text.appendSlice(allocator, fixture[cursor..][0..length]);
                cursor += length;
            } else if (kind == 3) {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                try expected_next.appendSlice(
                    allocator,
                    fixture[cursor..][0..length],
                );
                cursor += length;
                expected_state = std.mem.readInt(
                    u64,
                    fixture[cursor..][0..8],
                    .little,
                );
                cursor += 8;
            } else {
                return error.InvalidFixture;
            }
            const expected_result: Result = @enumFromInt(fixture[cursor]);
            cursor += 1;
            const expected_value = std.mem.readInt(
                i32,
                fixture[cursor..][0..4],
                .little,
            );
            cursor += 4;

            if (kind == 3) {
                var unique: i32 = 0;
                const has_unique = trie.hasUniqueValue(&unique);
                if (has_unique != (expected_result != .no_match)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bytes trie unique flag mismatch: case {d} option {d} op {d} got {} want {}\n",
                            .{
                                case_index,
                                option,
                                op_index,
                                has_unique,
                                expected_result != .no_match,
                            },
                        );
                    }
                } else if (has_unique and unique != expected_value) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bytes trie unique value mismatch: case {d} op {d} got {d} want {d}\n",
                            .{ case_index, op_index, unique, expected_value },
                        );
                    }
                }
                var next = std.ArrayList(u8).empty;
                defer next.deinit(allocator);
                const next_count = try trie.getNextBytes(&next, allocator);
                if (next_count != expected_next.items.len or
                    !std.mem.eql(u8, next.items, expected_next.items))
                {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bytes trie next mismatch: case {d} op {d} got {any} want {any}\n",
                            .{ case_index, op_index, next.items, expected_next.items },
                        );
                    }
                }
                const actual_state = trie.getState64();
                if (actual_state != expected_state) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bytes trie state mismatch: case {d} op {d} got {x} want {x}\n",
                            .{ case_index, op_index, actual_state, expected_state },
                        );
                    }
                } else if (expected_state != 0) {
                    var restored = trie;
                    restored.resetToState64(expected_state);
                    if (restored.current() != trie.current() or
                        (trie.current().hasValue() and
                            restored.getValue() != trie.getValue()))
                    {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "bytes trie state restore mismatch: case {d} op {d}\n",
                                .{ case_index, op_index },
                            );
                        }
                    }
                }
                continue;
            }

            const actual = switch (kind) {
                0 => blk: {
                    trie.reset();
                    break :blk trie.first(byte);
                },
                1 => trie.next(byte),
                2 => blk: {
                    trie.reset();
                    break :blk trie.nextString(text.items);
                },
                else => return error.InvalidFixture,
            };
            if (actual != expected_result) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "bytes trie result mismatch: case {d} option {d} op {d} kind {d} got {s} want {s}\n",
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
                        "bytes trie value mismatch: case {d} op {d} got {d} want {d}\n",
                        .{ case_index, op_index, trie.getValue(), expected_value },
                    );
                }
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "BytesTrie conformance: {}/{} cases passed\n",
        .{ case_count - failures, case_count },
    );
}

/// ICU `BytesTrieBuilder`-compatible builder.
pub const BytesTrieBuilder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    pub const Entry = struct {
        units: []u8,
        value: i32,
    };

    pub fn init(allocator: std.mem.Allocator) BytesTrieBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BytesTrieBuilder) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.units);
        }
        self.entries.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
    }

    pub fn add(
        self: *BytesTrieBuilder,
        text: []const u8,
        value: i32,
    ) !void {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.units, text)) {
                return error.DuplicateKey;
            }
        }
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.entries.append(self.allocator, .{
            .units = copy,
            .value = value,
        });
    }

    pub fn buildAlloc(self: *BytesTrieBuilder) ![]u8 {
        std.sort.heap(Entry, self.entries.items, {}, entryLessThan);
        if (self.entries.items.len == 0) {
            return self.allocator.alloc(u8, 0);
        }
        self.bytes.clearRetainingCapacity();
        _ = try self.writeNode(0, self.entries.items.len, 0, null);
        return self.bytes.toOwnedSlice(self.allocator);
    }

    fn entryLessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.units, b.units) == .lt;
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

    fn writeValueBytes(self: *BytesTrieBuilder, value: i32) !void {
        const bits: u32 = @bitCast(value);
        try self.bytes.append(self.allocator, @intCast(bits >> 24));
        try self.bytes.append(self.allocator, @intCast((bits >> 16) & 0xff));
        try self.bytes.append(self.allocator, @intCast((bits >> 8) & 0xff));
        try self.bytes.append(self.allocator, @intCast(bits & 0xff));
    }

    fn writeFinal(self: *BytesTrieBuilder, value: i32) !usize {
        const start = self.bytes.items.len;
        try self.bytes.append(self.allocator, 0xff);
        try self.writeValueBytes(value);
        return start;
    }

    fn writeIntermediate(self: *BytesTrieBuilder, value: i32) !void {
        try self.bytes.append(self.allocator, 0xfe);
        try self.writeValueBytes(value);
    }

    fn writeValueDeltaPlaceholder(self: *BytesTrieBuilder) !usize {
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(self.allocator, &.{ 0xfe, 0, 0, 0, 0 });
        return start;
    }

    fn writeBranchDeltaPlaceholder(self: *BytesTrieBuilder) !usize {
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(self.allocator, &.{ 0xff, 0, 0, 0, 0 });
        return start;
    }

    fn writeDeltaBytes(
        self: *BytesTrieBuilder,
        position: usize,
        delta: u32,
    ) void {
        self.bytes.items[position + 1] = @intCast(delta >> 24);
        self.bytes.items[position + 2] = @intCast((delta >> 16) & 0xff);
        self.bytes.items[position + 3] = @intCast((delta >> 8) & 0xff);
        self.bytes.items[position + 4] = @intCast(delta & 0xff);
    }

    /// Branch value deltas are measured from after the value payload.
    fn patchValueDelta(
        self: *BytesTrieBuilder,
        position: usize,
        target: usize,
    ) void {
        self.writeDeltaBytes(position, @intCast(target - (position + 5)));
    }

    /// Binary-branch deltas are measured from after the delta payload.
    fn patchBranchDelta(
        self: *BytesTrieBuilder,
        position: usize,
        target: usize,
    ) void {
        self.writeDeltaBytes(position, @intCast(target - (position + 5)));
    }

    fn writeNode(
        self: *BytesTrieBuilder,
        start: usize,
        end: usize,
        depth: usize,
        value: ?i32,
    ) error{ OutOfMemory, Unsupported }!usize {
        var first = start;
        var node_value = value;
        if (first < end and self.entries.items[first].units.len == depth) {
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

        var value_start: ?usize = null;
        if (node_value) |current| {
            value_start = self.bytes.items.len;
            try self.writeIntermediate(current);
        }

        if (group_count == 1) {
            const prefix_length = commonPrefix(entries, depth, 16);
            const node_start = self.bytes.items.len;
            try self.bytes.append(
                self.allocator,
                @intCast(0x10 + prefix_length - 1),
            );
            try self.bytes.appendSlice(
                self.allocator,
                entries[0].units[depth..][0..prefix_length],
            );
            _ = try self.writeNode(first, end, depth + prefix_length, null);
            return value_start orelse node_start;
        }

        if (group_count > 256) return error.Unsupported;
        const node_start = self.bytes.items.len;
        if (group_count == 1) {
            try self.bytes.append(self.allocator, 0);
            try self.bytes.append(self.allocator, 0);
        } else if (group_count <= 16) {
            try self.bytes.append(self.allocator, @intCast(group_count - 1));
        } else {
            try self.bytes.append(self.allocator, 0);
            try self.bytes.append(self.allocator, @intCast(group_count - 1));
        }
        try self.writeBranchData(group_starts.items, depth, end);
        return value_start orelse node_start;
    }

    fn writeBranchData(
        self: *BytesTrieBuilder,
        group_starts: []const usize,
        depth: usize,
        end: usize,
    ) error{ OutOfMemory, Unsupported }!void {
        const group_count = group_starts.len;
        if (group_count <= 5) {
            var delta_positions = std.ArrayList(usize).empty;
            defer delta_positions.deinit(self.allocator);
            for (group_starts[0 .. group_count - 1]) |group_start| {
                try self.bytes.append(
                    self.allocator,
                    self.entries.items[group_start].units[depth],
                );
                try delta_positions.append(
                    self.allocator,
                    try self.writeValueDeltaPlaceholder(),
                );
            }
            const last_start = group_starts[group_count - 1];
            try self.bytes.append(
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
                self.patchValueDelta(delta_position, target);
            }
            return;
        }

        const left = group_count / 2;
        const right_start = group_starts[left];
        try self.bytes.append(
            self.allocator,
            self.entries.items[right_start].units[depth],
        );
        const delta_position = try self.writeBranchDeltaPlaceholder();
        try self.writeBranchData(group_starts[left..], depth, end);
        const left_start = self.bytes.items.len;
        try self.writeBranchData(group_starts[0..left], depth, right_start);
        self.patchBranchDelta(delta_position, left_start);
    }
};

test "BytesTrie builder" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var builder = BytesTrieBuilder.init(allocator);
    defer builder.deinit();
    try builder.add("a", 1);
    try builder.add("ab", 2);
    try builder.add("abc", 3);
    try builder.add("b", 4);
    try builder.add("ba", 5);
    const bytes = try builder.buildAlloc();
    defer allocator.free(bytes);
    var trie = BytesTrie.init(bytes);
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

    var wide = BytesTrieBuilder.init(allocator);
    defer wide.deinit();
    for (0..80) |i| {
        const unit = [_]u8{@intCast(0x80 + i)};
        try wide.add(&unit, @intCast(i));
    }
    const wide_bytes = try wide.buildAlloc();
    defer allocator.free(wide_bytes);
    var wide_trie = BytesTrie.init(wide_bytes);
    for (0..80) |i| {
        const result = wide_trie.first(@intCast(0x80 + i));
        try testing.expect(result.hasValue());
        try testing.expectEqual(@as(i32, @intCast(i)), wide_trie.getValue());
    }
    try testing.expectEqual(Result.no_match, wide_trie.first(0x80 + 80));
}

test "BytesTrie state64, unique value, and next bytes" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var builder = BytesTrieBuilder.init(allocator);
    defer builder.deinit();
    try builder.add("a", 7);
    try builder.add("ab", 7);
    try builder.add("abc", 7);
    try builder.add("b", 7);
    const bytes = try builder.buildAlloc();
    defer allocator.free(bytes);

    var trie = BytesTrie.init(bytes);
    var unique: i32 = 0;
    trie.reset();
    try testing.expect(trie.hasUniqueValue(&unique));
    try testing.expectEqual(@as(i32, 7), unique);

    var next = std.ArrayList(u8).empty;
    defer next.deinit(allocator);
    try testing.expectEqual(
        @as(usize, 2),
        try trie.getNextBytes(&next, allocator),
    );
    try testing.expectEqualSlices(u8, "ab", next.items);

    try testing.expectEqual(Result.intermediate_value, trie.first('a'));
    next.clearRetainingCapacity();
    try testing.expectEqual(
        @as(usize, 1),
        try trie.getNextBytes(&next, allocator),
    );
    try testing.expectEqualSlices(u8, "b", next.items);
    try testing.expect(trie.hasUniqueValue(&unique));
    try testing.expectEqual(@as(i32, 7), unique);

    const state = trie.getState64();
    try testing.expect(state != 0);
    try testing.expectEqual(Result.intermediate_value, trie.next('b'));
    try testing.expectEqual(Result.final_value, trie.next('c'));

    trie.resetToState64(state);
    try testing.expectEqual(Result.intermediate_value, trie.current());
    try testing.expectEqual(@as(i32, 7), trie.getValue());
    try testing.expectEqual(Result.intermediate_value, trie.next('b'));
    try testing.expectEqual(Result.final_value, trie.next('c'));
    try testing.expectEqual(@as(i32, 7), trie.getValue());

    next.clearRetainingCapacity();
    try testing.expectEqual(
        @as(usize, 0),
        try trie.getNextBytes(&next, allocator),
    );

    try testing.expectEqual(Result.no_match, trie.next('x'));
    try testing.expect(!trie.hasUniqueValue(&unique));
    try testing.expectEqual(
        @as(usize, 0),
        try trie.getNextBytes(&next, allocator),
    );
    try testing.expectEqual(@as(u64, 0), trie.getState64());

    var mixed = BytesTrieBuilder.init(allocator);
    defer mixed.deinit();
    try mixed.add("x", 1);
    try mixed.add("xy", 2);
    const mixed_bytes = try mixed.buildAlloc();
    defer allocator.free(mixed_bytes);
    var mixed_trie = BytesTrie.init(mixed_bytes);
    mixed_trie.reset();
    try testing.expect(!mixed_trie.hasUniqueValue(&unique));
}
