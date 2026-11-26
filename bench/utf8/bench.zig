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
        // A first-byte rejection can otherwise finish in a few microseconds
        // for long offered inputs. Give that latency row enough operations
        // to keep timer resolution and scheduling from dominating it.
        const first = text[0];
        const immediate_reject = (first >= 0x80 and first < 0xc2) or first >= 0xf5;
        const minimum_rounds: usize = if (immediate_reject) 2_000_000 else 2000;
        const rounds = @max(minimum_rounds, 16 * 1024 * 1024 / text.len);
        var best: u64 = std.math.maxInt(u64);
        var count: usize = 0;
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                // Both the pointer and length depend on a volatile read,
                // so even an inlined first-byte test must run each time.
                // The salt remains zero and the entire file is validated.
                const salt = @as(*volatile usize, &length_salt).*;
                count += @intFromBool(validate.isValid(text[salt..]));
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
