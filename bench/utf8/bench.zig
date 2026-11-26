//! File-driven UTF-8 validation benchmark. The comparison driver supplies
//! exactly the same bytes to this executable and the simdutf executable.
const std = @import("std");
const validate = @import("validate");

var length_salt: usize = 0;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
        @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(text);
        if (text.len == 0) return error.EmptyInput;
        const rounds = @max(2000, 16 * 1024 * 1024 / text.len);
        var best: u64 = std.math.maxInt(u64);
        var count: usize = 0;
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                // A volatile dependency prevents a pure validator from
                // being hoisted out of the loop. The salt remains zero.
                const salt = @as(*volatile usize, &length_salt).*;
                count += @intFromBool(validate.isValid(text[0 .. text.len - salt]));
            }
            best = @min(best, now() - start);
        }
        const ns = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds));
        // TSV: path, bytes, ns/op, ns/B, successful validations. Count makes
        // incorrect acceptance or rejection visible to the driver as well.
        std.debug.print("{s}\t{d}\t{d:.6}\t{d:.6}\t{d}\n", .{
            path, text.len, ns, ns / @as(f64, @floatFromInt(text.len)), count,
        });
    }
}
