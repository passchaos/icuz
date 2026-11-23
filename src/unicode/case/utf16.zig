//! UTF-16 case mapping and folding into caller-owned buffers.
//!
//! The mappings are the same tables the UTF-8 path uses. Working in UTF-16
//! avoids re-decoding and re-encoding non-ASCII scalars, which is how ICU's
//! `u_strToLower` family operates.

const std = @import("std");
const full = @import("full.zig");
const full_data = @import("full_data.zig");
const data = @import("data.zig");

pub const Error = error{ InvalidUtf16, OutOfMemory };

/// Append the simple lowercase mapping of UTF-16 text to `output`.
pub fn lowerInto(
    allocator: std.mem.Allocator,
    units: []const u16,
    output: *std.ArrayList(u16),
) Error!void {
    return mapInto(allocator, units, .lower, .simple, output);
}

/// Append the simple uppercase mapping of UTF-16 text to `output`.
pub fn upperInto(
    allocator: std.mem.Allocator,
    units: []const u16,
    output: *std.ArrayList(u16),
) Error!void {
    return mapInto(allocator, units, .upper, .simple, output);
}

/// Append the full case folding of UTF-16 text to `output`.
pub fn foldInto(
    allocator: std.mem.Allocator,
    units: []const u16,
    output: *std.ArrayList(u16),
) Error!void {
    return mapInto(allocator, units, .lower, .fold, output);
}

const Mode = enum { simple, fold };

fn mapInto(
    allocator: std.mem.Allocator,
    units: []const u16,
    comptime kind: full_data.Kind,
    comptime mode: Mode,
    output: *std.ArrayList(u16),
) Error!void {
    output.clearRetainingCapacity();
    if (mode == .fold) full.ensureFoldInterest();
    // Simple mappings preserve the UTF-16 length, so one exact reservation
    // covers every write. Folding may expand and keeps checked appends.
    if (mode == .simple) {
        try output.ensureTotalCapacityPrecise(allocator, units.len);
    } else {
        try output.ensureTotalCapacityPrecise(allocator, units.len + 8);
    }
    const ascii_chunk = 16;
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (unit < 0x80) {
            while (index + ascii_chunk <= units.len) {
                const chunk: @Vector(ascii_chunk, u16) =
                    units[index..][0..ascii_chunk].*;
                const high: @Vector(ascii_chunk, bool) =
                    chunk >= @as(@Vector(ascii_chunk, u16), @splat(0x80));
                const bits: u16 = @bitCast(high);
                const count: usize = if (bits == 0)
                    ascii_chunk
                else
                    @ctz(bits);
                if (count == 0) break;
                if (mode == .simple) {
                    output.unusedCapacitySlice()[0..ascii_chunk].* =
                        asciiMap(chunk, kind);
                    output.items.len += count;
                } else {
                    if (output.unusedCapacitySlice().len < ascii_chunk) {
                        try output.ensureUnusedCapacity(
                            allocator,
                            ascii_chunk,
                        );
                    }
                    output.unusedCapacitySlice()[0..ascii_chunk].* =
                        asciiMap(chunk, kind);
                    output.items.len += count;
                }
                index += count;
                if (count < ascii_chunk) break;
            }
            while (index < units.len and units[index] < 0x80) {
                const mapped = asciiMapScalar(units[index], kind);
                if (mode == .simple) {
                    output.appendAssumeCapacity(mapped);
                } else {
                    try output.append(allocator, mapped);
                }
                index += 1;
            }
            continue;
        }
        var codepoint: u21 = unit;
        if (unit >= 0xd800 and unit <= 0xdbff) {
            if (index + 1 >= units.len) return error.InvalidUtf16;
            const low = units[index + 1];
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidUtf16;
            codepoint = 0x10000 +
                (@as(u21, unit - 0xd800) << 10) +
                (low - 0xdc00);
            index += 2;
        } else if (unit >= 0xdc00 and unit <= 0xdfff) {
            return error.InvalidUtf16;
        } else {
            index += 1;
        }
        if (mode == .fold) {
            // Copy runs of identity BMP units in bulk; the per-unit fold
            // check still runs, but the output write is one memcpy.
            var run_end = index - 1;
            while (run_end < units.len) {
                const candidate = units[run_end];
                if (candidate >= 0xd800 and candidate <= 0xdfff) break;
                if (full.foldInteresting(candidate, true)) break;
                run_end += 1;
            }
            if (run_end > index - 1) {
                const run = units[index - 1 .. run_end];
                if (output.unusedCapacitySlice().len >= run.len) {
                    output.appendSliceAssumeCapacity(run);
                } else {
                    try output.appendSlice(allocator, run);
                }
                index = run_end;
                continue;
            }
            const may_map = full.foldInteresting(codepoint, true);
            if (may_map) {
                if (data.fullFold(codepoint)) |components| {
                    for (components) |component| {
                        try appendChecked(allocator, output, component);
                    }
                    continue;
                }
            }
            try appendChecked(allocator, output, codepoint);
            continue;
        }
        const mapped = switch (kind) {
            .lower => full.simpleLowerFast(codepoint),
            .upper => full.simpleUpperFast(codepoint),
            .title => unreachable,
        };
        if (mapped < 0x10000) {
            output.appendAssumeCapacity(@intCast(mapped));
        } else {
            const value = mapped - 0x10000;
            output.appendAssumeCapacity(@intCast(0xd800 + (value >> 10)));
            output.appendAssumeCapacity(@intCast(0xdc00 + (value & 0x3ff)));
        }
    }
}

inline fn asciiMapScalar(unit: u16, comptime kind: full_data.Kind) u16 {
    return switch (kind) {
        .lower => if (unit >= 'A' and unit <= 'Z') unit + 0x20 else unit,
        .upper, .title => if (unit >= 'a' and unit <= 'z') unit - 0x20 else unit,
    };
}

inline fn asciiMap(
    chunk: @Vector(16, u16),
    comptime kind: full_data.Kind,
) @Vector(16, u16) {
    const Vector = @Vector(16, u16);
    const delta: Vector = @splat(0x20);
    const zero: Vector = @splat(0);
    return switch (kind) {
        .lower => chunk +% @select(
            u16,
            (chunk >= @as(Vector, @splat('A'))) &
                (chunk <= @as(Vector, @splat('Z'))),
            delta,
            zero,
        ),
        .upper, .title => chunk -% @select(
            u16,
            (chunk >= @as(Vector, @splat('a'))) &
                (chunk <= @as(Vector, @splat('z'))),
            delta,
            zero,
        ),
    };
}

inline fn appendChecked(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u16),
    codepoint: u21,
) Error!void {
    if (codepoint < 0x10000) {
        try output.append(allocator, @intCast(codepoint));
        return;
    }
    const value = codepoint - 0x10000;
    try output.ensureUnusedCapacity(allocator, 2);
    output.appendAssumeCapacity(@intCast(0xd800 + (value >> 10)));
    output.appendAssumeCapacity(@intCast(0xdc00 + (value & 0x3ff)));
}

test "UTF-16 mappings match the UTF-8 entry points" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const cases = [_][]const u8{
        "Hello, world!",
        "Stra\u{00df}e",
        "\u{0130}stanbul",
        "\u{1e921}\u{1e922}",
        "\u{1100}\u{1161}\u{11a8}",
        "\u{03a3}\u{03bf}\u{03c6}\u{03bf}\u{03c2}",
    };
    const case_root = @import("root.zig");
    for (cases) |text| {
        const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
        defer allocator.free(units);

        const lower = try case_root.lowerAlloc(allocator, text);
        defer allocator.free(lower);
        var lower16 = std.ArrayList(u16).empty;
        defer lower16.deinit(allocator);
        try lowerInto(allocator, units, &lower16);
        const lower_back = try std.unicode.utf16LeToUtf8Alloc(
            allocator,
            lower16.items,
        );
        defer allocator.free(lower_back);
        try testing.expectEqualStrings(lower, lower_back);

        const upper = try case_root.upperAlloc(allocator, text);
        defer allocator.free(upper);
        var upper16 = std.ArrayList(u16).empty;
        defer upper16.deinit(allocator);
        try upperInto(allocator, units, &upper16);
        const upper_back = try std.unicode.utf16LeToUtf8Alloc(
            allocator,
            upper16.items,
        );
        defer allocator.free(upper_back);
        try testing.expectEqualStrings(upper, upper_back);

        const folded = try case_root.foldAlloc(allocator, text);
        defer allocator.free(folded);
        var fold16 = std.ArrayList(u16).empty;
        defer fold16.deinit(allocator);
        try foldInto(allocator, units, &fold16);
        const fold_back = try std.unicode.utf16LeToUtf8Alloc(
            allocator,
            fold16.items,
        );
        defer allocator.free(fold_back);
        try testing.expectEqualStrings(folded, fold_back);
    }
    var out = std.ArrayList(u16).empty;
    defer out.deinit(allocator);
    try testing.expectError(
        error.InvalidUtf16,
        lowerInto(allocator, &[_]u16{0xd800}, &out),
    );
    try testing.expectError(
        error.InvalidUtf16,
        lowerInto(allocator, &[_]u16{0xdc00}, &out),
    );
}

test "simple UTF-16 mappings preserve the unit count" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var out = std.ArrayList(u16).empty;
    defer out.deinit(allocator);
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) continue;
        var units: [2]u16 = undefined;
        const length: usize = if (codepoint < 0x10000) blk: {
            units[0] = @intCast(codepoint);
            break :blk 1;
        } else blk: {
            const value = codepoint - 0x10000;
            units[0] = @intCast(0xd800 + (value >> 10));
            units[1] = @intCast(0xdc00 + (value & 0x3ff));
            break :blk 2;
        };
        try lowerInto(allocator, units[0..length], &out);
        try testing.expectEqual(length, out.items.len);
        try upperInto(allocator, units[0..length], &out);
        try testing.expectEqual(length, out.items.len);
    }
}
