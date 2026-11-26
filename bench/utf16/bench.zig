//! File-identical UTF-8/UTF-16 conversion benchmark.
const std = @import("std");
const utf16 = @import("utf16");

var input_salt: usize = 0;
var sink: usize = 0;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn bench(comptime to_utf16: bool, comptime reuse: bool, path: []const u8, text: []const u8, units: []const u16, allocator: std.mem.Allocator) !void {
    const Out = if (to_utf16) u16 else u8;
    var output = std.ArrayList(Out).empty;
    defer output.deinit(allocator);
    if (reuse) try output.ensureTotalCapacity(allocator, if (to_utf16) text.len else units.len * 3);
    const rounds = @max(2000, 8 * 1024 * 1024 / @max(text.len, 1));
    var best: u64 = std.math.maxInt(u64);
    const expected: usize = if (to_utf16) units.len else text.len;
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const salt = @as(*volatile usize, &input_salt).*;
            if (reuse) {
                output.clearRetainingCapacity();
                if (to_utf16) {
                    try utf16.utf8ToUtf16Into(allocator, text[salt..], &output);
                } else {
                    try utf16.utf16ToUtf8Into(allocator, units[salt..], &output);
                }
                std.mem.doNotOptimizeAway(output.items.ptr);
                sink +%= output.items.len;
            } else {
                const value = if (to_utf16)
                    try utf16.utf8ToUtf16Alloc(allocator, text[salt..])
                else
                    try utf16.utf16ToUtf8Alloc(allocator, units[salt..]);
                std.mem.doNotOptimizeAway(value.ptr);
                sink +%= value.len;
                allocator.free(value);
            }
        }
        best = @min(best, now() - start);
    }
    const value = if (to_utf16) try utf16.utf8ToUtf16Alloc(allocator, text) else try utf16.utf16ToUtf8Alloc(allocator, units);
    defer allocator.free(value);
    const reference = if (to_utf16) units else text;
    if (!std.mem.eql(Out, reference, value)) return error.ConversionMismatch;
    if (reuse and !std.mem.eql(Out, reference, output.items)) return error.ConversionMismatch;
    const ns = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds));
    std.debug.print("{s}\t{s}\t{s}\t{d}\t{d:.6}\t{d}\n", .{
        path,                            if (to_utf16) "utf8-to-utf16" else "utf16-to-utf8",
        if (reuse) "reuse" else "alloc", text.len,
        ns,                              expected,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(text);
        if (text.len == 0) return error.EmptyInput;
        const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
        defer allocator.free(units);
        if (comptime @import("builtin").cpu.arch.endian() == .big) {
            for (units) |*unit| unit.* = @byteSwap(unit.*);
        }
        try bench(true, false, path, text, units, allocator);
        try bench(false, false, path, text, units, allocator);
        if (@hasDecl(utf16, "utf8ToUtf16Into")) {
            try bench(true, true, path, text, units, allocator);
            try bench(false, true, path, text, units, allocator);
        }
    }
}
