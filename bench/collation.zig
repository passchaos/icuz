// Focused collation benchmark for optimization work. The full harness lives
// in bench.zig; this entry point times one workload at a time so a change can
// be measured and profiled without the rest of the suite.
const std = @import("std");
const icuz = @import("icuz");

var sink: u64 = 0;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
        @as(u64, @intCast(ts.nsec));
}

fn report(name: []const u8, bytes: usize, nanos: u64) void {
    const per_byte = @as(f64, @floatFromInt(nanos)) /
        @as(f64, @floatFromInt(bytes));
    std.debug.print("{s:<28} {d:8.3} ns/B {d:9.1} MB/s\n", .{
        name,
        per_byte,
        @as(f64, @floatFromInt(bytes)) * 1000.0 /
            @as(f64, @floatFromInt(nanos)),
    });
}

const Workload = struct {
    name: []const u8,
    text: []const u8,
    options: icuz.collation.Options = .{},
    codepoints: bool = false,
};

fn bench(work: Workload, allocator: std.mem.Allocator) void {
    const rounds: usize = 2000;
    var best: u64 = std.math.maxInt(u64);
    if (work.codepoints) {
        var codepoints: [512]u21 = undefined;
        var count: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(work.text).iterator();
        while (view.nextCodepoint()) |codepoint| {
            if (count == codepoints.len) break;
            codepoints[count] = codepoint;
            count += 1;
        }
        var key = std.ArrayList(u32).empty;
        defer key.deinit(allocator);
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                icuz.collation.sortKeyCodepointsInto(
                    allocator,
                    codepoints[0..count],
                    work.options,
                    &key,
                ) catch unreachable;
                sink +%= key.items.len;
            }
            const elapsed = now() - start;
            if (elapsed < best) best = elapsed;
        }
    } else {
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                const key = icuz.collation.sortKeyAlloc(
                    allocator,
                    work.text,
                    work.options,
                ) catch unreachable;
                sink +%= key.len;
                allocator.free(key);
            }
            const elapsed = now() - start;
            if (elapsed < best) best = elapsed;
        }
    }
    report(work.name, rounds * work.text.len, best);
}

fn benchCase(
    name: []const u8,
    text: []const u8,
    kind: enum { lower, fold },
    allocator: std.mem.Allocator,
) void {
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = switch (kind) {
                .lower => icuz.case.lowerAlloc(allocator, text),
                .fold => icuz.case.foldAlloc(allocator, text),
            } catch unreachable;
            sink +%= output.len;
            allocator.free(output);
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchCaseInto(
    name: []const u8,
    text: []const u8,
    kind: enum { lower, fold },
    allocator: std.mem.Allocator,
) void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            switch (kind) {
                .lower => icuz.case.lowerInto(
                    allocator,
                    text,
                    &buffer,
                ) catch unreachable,
                .fold => icuz.case.foldInto(
                    allocator,
                    text,
                    &buffer,
                ) catch unreachable,
            }
            sink +%= buffer.items.len;
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchDecode(name: []const u8, text: []const u8) void {
    const rounds: usize = 2000;
    var out: [512]u21 = undefined;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            var cursor: usize = 0;
            var count: usize = 0;
            while (cursor < text.len) {
                const decoded = icuz.scalar.decodeValidatingPacked(
                    text,
                    cursor,
                );
                out[count] = icuz.scalar.packedCodepoint(decoded);
                count += 1;
                cursor += icuz.scalar.packedLength(decoded);
            }
            sink +%= count + out[0];
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

const ascii_text =
    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump! 0123456789 hello_world@example.com https://example.com/path?q=1\n";
const mixed_text = "Hello, 世界! café naïve Straße \u{1f600}\u{1f469}\u{200d}\u{1f4bb} " ++
    "e\u{0301}\u{0323} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} " ++
    "\u{0915}\u{094d}\u{0937}\u{093f} \u{1100}\u{1161}\u{11a8} text.\n";
const swedish_text = "Ångström älskar blåbär och öar. ÅÄÖ åäö " ** 8;
const german_text = "Böttger Mühsam Überlingen ÄÖÜ äöü Straße " ** 8;
const chinese_text = "你好世界中国汉字排序拼音" ** 8;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    const workloads = [_]Workload{
        .{ .name = "ASCII", .text = ascii_text },
        .{ .name = "mixed", .text = mixed_text },
        .{ .name = "Swedish root", .text = swedish_text },
        .{ .name = "Swedish", .text = swedish_text, .options = .{ .locale = "sv" } },
        .{
            .name = "German phonebook",
            .text = german_text,
            .options = .{ .locale = "de", .collation = "phonebook" },
        },
        .{ .name = "Chinese root", .text = chinese_text },
        .{
            .name = "Chinese pinyin",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
        },
        .{ .name = "Swedish root (cp)", .text = swedish_text, .codepoints = true },
        .{
            .name = "Swedish (cp)",
            .text = swedish_text,
            .options = .{ .locale = "sv" },
            .codepoints = true,
        },
        .{
            .name = "Chinese pinyin (cp)",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
            .codepoints = true,
        },
        .{
            .name = "Chinese stroke",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "stroke" },
        },
        .{
            .name = "Chinese stroke (cp)",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "stroke" },
            .codepoints = true,
        },
        .{
            .name = "Chinese zhuyin",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "zhuyin" },
        },
        .{
            .name = "Chinese zhuyin (cp)",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "zhuyin" },
            .codepoints = true,
        },
        .{
            .name = "Chinese pinyin (cp, primary)",
            .text = chinese_text,
            .options = .{
                .locale = "zh",
                .collation = "pinyin",
                .strength = .primary,
            },
            .codepoints = true,
        },
        .{
            .name = "Chinese root (cp, primary)",
            .text = chinese_text,
            .options = .{ .strength = .primary },
            .codepoints = true,
        },
        .{
            .name = "Swedish (cp, primary)",
            .text = swedish_text,
            .options = .{ .locale = "sv", .strength = .primary },
            .codepoints = true,
        },
        .{
            .name = "Swedish root (cp, primary)",
            .text = swedish_text,
            .options = .{ .strength = .primary },
            .codepoints = true,
        },
        .{
            .name = "ASCII (cp, primary)",
            .text = ascii_text,
            .options = .{ .strength = .primary },
            .codepoints = true,
        },
    };
    var filter_buffer: [64]u8 = undefined;
    var filter: []const u8 = "";
    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.skip();
    if (args.next()) |argument| {
        const length = @min(argument.len, filter_buffer.len);
        @memcpy(filter_buffer[0..length], argument[0..length]);
        filter = filter_buffer[0..length];
    }
    if (filter.len == 0 or std.mem.eql(u8, "case", filter)) {
        benchCase("lower mixed", mixed_text, .lower, allocator);
        benchCase("fold mixed", mixed_text, .fold, allocator);
        benchCase("lower ASCII", ascii_text, .lower, allocator);
        benchCase("lower Swedish", swedish_text, .lower, allocator);
        benchCaseInto("lower mixed (reuse)", mixed_text, .lower, allocator);
        benchCaseInto("fold mixed (reuse)", mixed_text, .fold, allocator);
        benchCaseInto(
            "lower Swedish (reuse)",
            swedish_text,
            .lower,
            allocator,
        );
        benchCaseInto("lower ASCII (reuse)", ascii_text, .lower, allocator);
    }
    if (filter.len == 0 or std.mem.eql(u8, "decode", filter)) {
        benchDecode("decode Chinese", chinese_text);
        benchDecode("decode mixed", mixed_text);
        benchDecode("decode ASCII", ascii_text);
    }
    for (workloads) |work| {
        if (filter.len != 0 and !std.mem.eql(u8, work.name, filter)) {
            continue;
        }
        bench(work, allocator);
    }
    std.mem.doNotOptimizeAway(sink);
}
