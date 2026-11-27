//! UTF-16 surrogate validation and exact conversion sizes.
const std = @import("std");
const builtin = @import("builtin");
const invalid = std.math.maxInt(usize);
const Mode = enum { utf8_size, scalar_count };

pub fn isValid(units: []const u16) bool {
    var index: usize = 0;
    if (comptime builtin.cpu.arch.endian() == .little) {
        // Thirty-two units per iteration with pair bitmasks and no serial
        // carry: a high surrogate at bit i and its low partner at bit i + 1
        // mark both lanes valid in one pass.
        const V = @Vector(16, u16);
        while (index + 32 <= units.len) {
            const a = @as(*align(2) const V, @ptrCast(units.ptr + index)).*;
            const b = @as(*align(2) const V, @ptrCast(units.ptr + index + 16)).*;
            const sa: u16 = @bitCast((a & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800)));
            const sb: u16 = @bitCast((b & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800)));
            const surrogates: u32 = @as(u32, sa) | (@as(u32, sb) << 16);
            if (surrogates == 0) {
                index += 32;
                continue;
            }
            const ha: u16 = @bitCast((a & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
            const hb: u16 = @bitCast((b & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
            const low: u32 = ~(@as(u32, ha) | (@as(u32, hb) << 16)) & surrogates;
            const pairs: u32 = low & ((@as(u32, ha) | (@as(u32, hb) << 16)) >> 1);
            const covered: u32 = ~surrogates | pairs | (pairs << 1);
            if (covered == 0xffff_ffff) {
                index += 32;
                continue;
            }
            if (covered == 0x7fff_ffff) {
                // The last unit awaits its partner in the next window.
                index += 31;
                continue;
            }
            return false;
        }
        // Sixteen-unit stage keeps short inputs on the vector path.
        while (index + 16 <= units.len) {
            const v = @as(*align(2) const V, @ptrCast(units.ptr + index)).*;
            const surrogates: u16 = @bitCast((v & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800)));
            if (surrogates == 0) {
                index += 16;
                continue;
            }
            const high: u16 = @bitCast((v & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
            const low: u16 = ~high & surrogates;
            const pairs: u16 = low & (high >> 1);
            const covered: u16 = ~surrogates | pairs | (pairs << 1);
            if (covered == 0xffff) {
                index += 16;
                continue;
            }
            if (covered == 0x7fff) {
                index += 15;
                continue;
            }
            return false;
        }
    }
    while (index < units.len) {
        const unit = units[index];
        if (unit >= 0xd800 and unit <= 0xdfff) {
            if (unit >= 0xdc00 or index + 1 == units.len or units[index + 1] & 0xfc00 != 0xdc00) return false;
            index += 2;
        } else {
            index += 1;
        }
    }
    return true;
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
    if (comptime builtin.cpu.arch.endian() == .little) {
        const V = @Vector(16, u16);
        while (index + 32 <= units.len) {
            const a = @as(*align(2) const V, @ptrCast(units.ptr + index)).*;
            const b = @as(*align(2) const V, @ptrCast(units.ptr + index + 16)).*;
            const sa: u16 = @bitCast((a & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800)));
            const sb: u16 = @bitCast((b & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800)));
            const surrogates: u32 = @as(u32, sa) | (@as(u32, sb) << 16);
            if (surrogates == 0) {
                if (comptime mode == .utf8_size) {
                    if (@reduce(.And, a < @as(V, @splat(0x80))) and @reduce(.And, b < @as(V, @splat(0x80)))) {
                        count += 32;
                    } else if (@reduce(.And, a >= @as(V, @splat(0x800))) and @reduce(.And, b >= @as(V, @splat(0x800)))) {
                        count += 96;
                    } else {
                        const na: u16 = @bitCast(a >= @as(V, @splat(0x80)));
                        const nb: u16 = @bitCast(b >= @as(V, @splat(0x80)));
                        const ta: u16 = @bitCast(a >= @as(V, @splat(0x800)));
                        const tb: u16 = @bitCast(b >= @as(V, @splat(0x800)));
                        count += 32 + @as(usize, @popCount(na)) + @popCount(nb) + @popCount(ta) + @popCount(tb);
                    }
                } else {
                    count += 32;
                }
                index += 32;
                continue;
            }
            const pa: u16 = @bitCast((a & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
            const pb: u16 = @bitCast((b & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
            const partners: u32 = @as(u32, pa) | (@as(u32, pb) << 16);
            const leads: u32 = ~partners & surrogates;
            const pairs: u32 = leads & (partners >> 1);
            const covered: u32 = ~surrogates | pairs | (pairs << 1);
            var width: usize = 32;
            var mask: u32 = 0xffff_ffff;
            if (covered == 0xffff_ffff) {
                width = 32;
            } else if (covered == 0x7fff_ffff) {
                width = 31;
                mask = 0x7fff_ffff;
            } else return invalid;
            if (comptime mode == .utf8_size) {
                const na: u16 = @bitCast(a >= @as(V, @splat(0x80)));
                const nb: u16 = @bitCast(b >= @as(V, @splat(0x80)));
                const ta: u16 = @bitCast(a >= @as(V, @splat(0x800)));
                const tb: u16 = @bitCast(b >= @as(V, @splat(0x800)));
                const non_ascii: u32 = @as(u32, na) | (@as(u32, nb) << 16);
                const three: u32 = @as(u32, ta) | (@as(u32, tb) << 16);
                count += width + @as(usize, @popCount(non_ascii & mask)) + @popCount(three & mask) -
                    2 * @as(usize, @popCount(leads & mask));
            } else {
                count += width - @as(usize, @popCount(leads & mask));
            }
            index += width;
        }
        while (index + 16 <= units.len) {
            const v = @as(*align(2) const V, @ptrCast(units.ptr + index)).*;
            const surrogates: u16 = @bitCast((v & @as(V, @splat(0xf800))) == @as(V, @splat(0xd800)));
            if (surrogates == 0) {
                if (comptime mode == .utf8_size) {
                    if (@reduce(.And, v < @as(V, @splat(0x80)))) {
                        count += 16;
                    } else if (@reduce(.And, v >= @as(V, @splat(0x800)))) {
                        count += 48;
                    } else {
                        const na: u16 = @bitCast(v >= @as(V, @splat(0x80)));
                        const ta: u16 = @bitCast(v >= @as(V, @splat(0x800)));
                        count += 16 + @as(usize, @popCount(na)) + @popCount(ta);
                    }
                } else {
                    count += 16;
                }
                index += 16;
                continue;
            }
            const p: u16 = @bitCast((v & @as(V, @splat(0xfc00))) == @as(V, @splat(0xdc00)));
            const leads: u16 = ~p & surrogates;
            const pairs: u16 = leads & (p >> 1);
            const covered: u16 = ~surrogates | pairs | (pairs << 1);
            var width: usize = 16;
            var mask: u16 = 0xffff;
            if (covered == 0xffff) {
                width = 16;
            } else if (covered == 0x7fff) {
                width = 15;
                mask = 0x7fff;
            } else return invalid;
            if (comptime mode == .utf8_size) {
                const na: u16 = @bitCast(v >= @as(V, @splat(0x80)));
                const ta: u16 = @bitCast(v >= @as(V, @splat(0x800)));
                count += width + @as(usize, @popCount(na & mask)) + @popCount(ta & mask) -
                    2 * @as(usize, @popCount(leads & mask));
            } else {
                count += width - @as(usize, @popCount(leads & mask));
            }
            index += width;
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

test "UTF-16 validation matches the scalar oracle" {
    const testing = std.testing;
    const oracle = struct {
        fn check(units: []const u16) bool {
            var i: usize = 0;
            while (i < units.len) {
                const unit = units[i];
                if (unit >= 0xd800 and unit <= 0xdfff) {
                    if (unit >= 0xdc00 or i + 1 == units.len) return false;
                    const low = units[i + 1];
                    if (low < 0xdc00 or low > 0xdfff) return false;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            return true;
        }
    }.check;
    var buffer: [160]u16 = undefined;
    // Exhaustive sequences over a surrogate-focused alphabet.
    const focused = [_]u16{ 'A', 0xd800, 0xdbff, 0xdc00, 0xdfff };
    for (0..6) |length| {
        var code: usize = 0;
        const total = std.math.pow(usize, focused.len, length);
        while (code < total) : (code += 1) {
            var value = code;
            for (0..length) |i| {
                buffer[i] = focused[value % focused.len];
                value /= focused.len;
            }
            try testing.expectEqual(oracle(buffer[0..length]), isValid(buffer[0..length]));
        }
    }
    // Random longer sequences biased toward surrogates and window edges.
    const symbols = [_]u16{ 'A', 0x00e9, 0x0800, 0xd7ff, 0xd800, 0xdbff, 0xdc00, 0xdfff, 0xe000 };
    var state: u64 = 0x243f_6a88_85a3_08d3;
    for (0..20_000) |_| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const length = @as(usize, @intCast(state % (buffer.len + 1)));
        for (0..length) |i| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            buffer[i] = symbols[@as(usize, @intCast(state % symbols.len))];
        }
        try testing.expectEqual(oracle(buffer[0..length]), isValid(buffer[0..length]));
    }
    // Pairs and lone surrogates at every position around the vector windows.
    for (0..130) |length| {
        for (0..length) |position| {
            @memset(buffer[0..length], 'A');
            const patterns = [_]struct { units: []const u16, valid: bool }{
                .{ .units = &.{ 0xd800, 0xdc00 }, .valid = true },
                .{ .units = &.{0xd800}, .valid = false },
                .{ .units = &.{0xdc00}, .valid = false },
                .{ .units = &.{ 0xdbff, 0xdfff }, .valid = true },
                .{ .units = &.{ 0xd800, 0xd800 }, .valid = false },
                .{ .units = &.{ 0xdc00, 0xdc00 }, .valid = false },
                .{ .units = &.{ 0xdc00, 0xd800 }, .valid = false },
            };
            for (patterns) |pattern| {
                if (position + pattern.units.len > length) continue;
                @memcpy(buffer[position..][0..pattern.units.len], pattern.units);
                try testing.expectEqual(oracle(buffer[0..length]), isValid(buffer[0..length]));
            }
        }
    }
}

test "UTF-8 size and codepoint count match the scalar oracle" {
    const testing = std.testing;
    const sizeOracle = struct {
        fn check(units: []const u16) ?usize {
            var i: usize = 0;
            var n: usize = 0;
            while (i < units.len) {
                const unit = units[i];
                if (unit >= 0xd800 and unit <= 0xdfff) {
                    if (unit >= 0xdc00 or i + 1 == units.len) return null;
                    const low = units[i + 1];
                    if (low < 0xdc00 or low > 0xdfff) return null;
                    n += 4;
                    i += 2;
                } else {
                    n += if (unit < 0x80) @as(usize, 1) else if (unit < 0x800) 2 else 3;
                    i += 1;
                }
            }
            return n;
        }
    }.check;
    const countOracle = struct {
        fn check(units: []const u16) ?usize {
            var i: usize = 0;
            var n: usize = 0;
            while (i < units.len) {
                const unit = units[i];
                if (unit >= 0xd800 and unit <= 0xdfff) {
                    if (unit >= 0xdc00 or i + 1 == units.len) return null;
                    const low = units[i + 1];
                    if (low < 0xdc00 or low > 0xdfff) return null;
                    i += 2;
                } else {
                    i += 1;
                }
                n += 1;
            }
            return n;
        }
    }.check;
    var buffer: [160]u16 = undefined;
    const focused = [_]u16{ 'A', 0xd800, 0xdbff, 0xdc00, 0xdfff };
    for (0..6) |length| {
        var code: usize = 0;
        const total = std.math.pow(usize, focused.len, length);
        while (code < total) : (code += 1) {
            var value = code;
            for (0..length) |i| {
                buffer[i] = focused[value % focused.len];
                value /= focused.len;
            }
            try testing.expectEqual(sizeOracle(buffer[0..length]), utf8Size(buffer[0..length]));
            try testing.expectEqual(countOracle(buffer[0..length]), codepointCount(buffer[0..length]));
        }
    }
    const symbols = [_]u16{ 'A', 0x00e9, 0x0800, 0xd7ff, 0xd800, 0xdbff, 0xdc00, 0xdfff, 0xe000 };
    var state: u64 = 0x1319_8a2e_0370_7344;
    for (0..20_000) |_| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const length = @as(usize, @intCast(state % (buffer.len + 1)));
        for (0..length) |i| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            buffer[i] = symbols[@as(usize, @intCast(state % symbols.len))];
        }
        try testing.expectEqual(sizeOracle(buffer[0..length]), utf8Size(buffer[0..length]));
        try testing.expectEqual(countOracle(buffer[0..length]), codepointCount(buffer[0..length]));
    }
    for (0..130) |length| {
        for (0..length) |position| {
            @memset(buffer[0..length], 'A');
            const patterns = [_][]const u16{
                &.{ 0xd800, 0xdc00 },
                &.{0xd800},
                &.{0xdc00},
                &.{ 0xdbff, 0xdfff },
                &.{ 0xd800, 0xd800 },
                &.{ 0xdc00, 0xdc00 },
            };
            for (patterns) |pattern| {
                if (position + pattern.len > length) continue;
                @memcpy(buffer[position..][0..pattern.len], pattern);
                try testing.expectEqual(sizeOracle(buffer[0..length]), utf8Size(buffer[0..length]));
                try testing.expectEqual(countOracle(buffer[0..length]), codepointCount(buffer[0..length]));
            }
        }
    }
}
