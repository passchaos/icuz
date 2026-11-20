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
