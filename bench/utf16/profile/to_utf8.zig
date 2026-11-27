//! Checked UTF-16 profiling with warmed output and independent content verification.
const std = @import("std");
const utf16 = @import("utf16");
var input_salt: usize = 0;
var sink: usize = 0;

pub fn main(init: std.process.Init) anyerror!void {
    const allocator = std.heap.smp_allocator;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingPath;
    const iterations = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCount, 10);
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    const unit_storage = try allocator.alloc(u16, text.len);
    defer allocator.free(unit_storage);
    const count = try std.unicode.utf8ToUtf16Le(unit_storage, text);
    const units = unit_storage[0..count];
    if (comptime @import("builtin").cpu.arch.endian() == .big) for (units) |*unit| {
        unit.* = @byteSwap(unit.*);
    };
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, units.len * 3);
    for (0..iterations) |_| {
        output.clearRetainingCapacity();
        const salt = @as(*volatile usize, &input_salt).*;
        try utf16.utf16ToUtf8Into(allocator, units[salt..], &output);
        std.mem.doNotOptimizeAway(output.items.ptr);
        sink +%= output.items.len;
    }
    if (!std.mem.eql(u8, output.items, text)) return error.ConversionMismatch;
    std.debug.print("length={d} sink={d}\n", .{ output.items.len, sink });
}
