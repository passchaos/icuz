//! ASCII prefix conversion for buffers sized for the complete UTF-16 input.
const std = @import("std");
const builtin = @import("builtin");

inline fn load(comptime n: usize, units: []const u16, index: usize) @Vector(n, u16) {
    const U = @Vector(n, u16);
    return if (builtin.zig_backend == .stage2_llvm)
        @as(*align(2) const U, @ptrCast(units.ptr + index)).*
    else
        units[index..][0..n].*;
}

inline fn store(comptime n: usize, output: []u8, index: usize, v: @Vector(n, u16)) void {
    const bytes: @Vector(n, u8) = @truncate(v);
    output[index..][0..n].* = bytes;
}

noinline fn mixed(comptime n: usize, v: @Vector(n, u16), output: []u8, index: usize) usize {
    return mixedBody(n, v, output, index);
}

inline fn mixedBody(comptime n: usize, v: @Vector(n, u16), output: []u8, index: usize) usize {
    const U = @Vector(n, u16);
    const high = v >= @as(U, @splat(0x80));
    var count: usize = 0;
    if (comptime builtin.cpu.arch.endian() == .little) {
        const mask: std.meta.Int(.unsigned, n) = @bitCast(high);
        count = @ctz(mask);
    } else {
        const flags: [n]bool = high;
        while (!flags[count]) count += 1;
    }
    if (count != 0) {
        // Complete conversion has at least one UTF-8 byte per UTF-16 unit.
        // Padding stays in the spare buffer and is replaced by the next kernel.
        store(n, output, index, v);
    }
    return index + count;
}

pub fn prefix(units: []const u16, output: []u8) usize {
    return prefixFrom(0, units, output);
}

/// Resume a prefix whose first thirty-two ASCII units are already copied.
pub fn after32(units: []const u16, output: []u8) usize {
    return prefixFrom(32, units, output);
}

inline fn prefixFrom(comptime copied: usize, units: []const u16, output: []u8) usize {
    var index: usize = copied;
    inline for (.{ 32, 16, 8, 4 }) |n| {
        const U = @Vector(n, u16);
        while (index + n <= units.len) {
            const v = load(n, units, index);
            if (!@reduce(.And, v < @as(U, @splat(0x80)))) {
                // An initial mixed window is more efficiently packed as BMP.
                if (index == 0) return 0;
                return if (copied == 0) mixed(n, v, output, index) else mixedBody(n, v, output, index);
            }
            store(n, output, index, v);
            index += n;
        }
        if (index == units.len) return index;
        if (units.len >= n and units.len - index >= n / 2) {
            const start = units.len - n;
            const v = load(n, units, start);
            if (!@reduce(.And, v < @as(U, @splat(0x80)))) return if (copied == 0) mixed(n, v, output, start) else mixedBody(n, v, output, start);
            store(n, output, start, v);
            return units.len;
        }
    }
    while (index < units.len and units[index] < 0x80) : (index += 1) output[index] = @intCast(units[index]);
    return index;
}

/// Copy input already proven ASCII by the exact UTF-8 size pass.
pub noinline fn copyValid(units: []const u16, output: []u8) void {
    var index: usize = 0;
    inline for (.{ 32, 16, 8, 4 }) |n| {
        while (index + n <= units.len) : (index += n) store(n, output, index, load(n, units, index));
        if (index == units.len) return;
        if (units.len >= n and units.len - index >= n / 2) {
            const start = units.len - n;
            store(n, output, start, load(n, units, start));
            return;
        }
    }
    while (index < units.len) : (index += 1) output[index] = @intCast(units[index]);
}
