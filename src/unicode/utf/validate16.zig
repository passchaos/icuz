//! UTF-16 surrogate validation and exact conversion sizes.
const std = @import("std");
const builtin = @import("builtin");
const invalid = std.math.maxInt(usize);
const Mode = enum { validate, utf8_size, scalar_count };

pub fn isValid(units: []const u16) bool {
    return scan(.validate, units) != invalid;
}
pub fn utf8Size(units: []const u16) ?usize {
    const n = scan(.utf8_size, units);
    return if (n == invalid) null else n;
}
pub fn codepointCount(units: []const u16) ?usize {
    const n = scan(.scalar_count, units);
    return if (n == invalid) null else n;
}

fn scan(comptime mode: Mode, units: []const u16) usize {
    var index: usize = 0;
    var count: usize = 0;
    var carry: u32 = 0;
    if (comptime builtin.cpu.arch.endian() == .little) {
        const V = @Vector(16, u16);
        while (index + 16 <= units.len) : (index += 16) {
            const v = @as(*align(2) const V, @ptrCast(units.ptr + index)).*;
            const surrogates = (v & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800));
            var high: u16 = 0;
            if (mode == .utf8_size and carry == 0 and !@reduce(.Or, surrogates)) {
                if (@reduce(.And, v < @as(V, @splat(0x80)))) {
                    count += 16;
                    continue;
                }
                if (@reduce(.And, v >= @as(V, @splat(0x800)))) {
                    count += 48;
                    continue;
                }
            }
            if (carry != 0 or @reduce(.Or, surrogates)) {
                high = @bitCast((v & @as(V, @splat(0xfc00))) == @as(V, @splat(0xd800)));
                const low: u16 = @bitCast((v & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
                const expected = (@as(u32, high) << 1) | carry;
                if (low != @as(u16, @truncate(expected))) return invalid;
                carry = expected >> 16;
            }
            if (mode == .utf8_size) {
                const non_ascii: u16 = @bitCast(v >= @as(V, @splat(0x80)));
                const three: u16 = @bitCast(v >= @as(V, @splat(0x800)));
                count += 16 + @as(usize, @popCount(non_ascii)) + @popCount(three) - 2 * @as(usize, @popCount(high));
            } else if (mode == .scalar_count) count += 16 - @as(usize, @popCount(high));
        }
        if (carry != 0) {
            if (index == units.len or units[index] & 0xfc00 != 0xdc00) return invalid;
            if (mode == .utf8_size) count += 3 else if (mode == .scalar_count) count += 1;
            index += 1;
        }
    }
    while (index < units.len) {
        const unit = units[index];
        if (unit >= 0xd800 and unit <= 0xdfff) {
            if (unit >= 0xdc00 or index + 1 == units.len or units[index + 1] & 0xfc00 != 0xdc00) return invalid;
            index += 2;
            if (mode == .utf8_size) count += 4 else if (mode == .scalar_count) count += 1;
        } else {
            index += 1;
            if (mode == .utf8_size) count += if (unit < 0x80) @as(usize, 1) else if (unit < 0x800) 2 else 3 else if (mode == .scalar_count) count += 1;
        }
    }
    return count;
}
