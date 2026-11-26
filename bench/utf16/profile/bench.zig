const std = @import("std");
const utf16 = @import("utf16");
var input_salt: usize = 0;
var sink: usize = 0;
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingPath;
    const iterations = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCount, 10);
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    var output = std.ArrayList(u16).empty;
    defer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);
    for (0..iterations) |_| {
        output.clearRetainingCapacity();
        const salt = @as(*volatile usize, &input_salt).*;
        try utf16.utf8ToUtf16Into(allocator, text[salt..], &output);
        std.mem.doNotOptimizeAway(output.items.ptr);
        sink +%= output.items.len;
    }
    const reference = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(reference);
    if (!std.mem.eql(u16, output.items, reference)) return error.ConversionMismatch;
    std.debug.print("length={d} sink={d}\n", .{ output.items.len, sink });
}
