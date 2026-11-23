// Focused collation benchmark for optimization work. The full harness lives
// in bench.zig; this entry point times one workload at a time so a change can
// be measured and profiled without the rest of the suite.
const std = @import("std");
const icuz = @import("icuz");

var sink: u64 = 0;

/// Read through a volatile pointer so a pure validation call cannot be hoisted
/// out of a benchmark loop; the value stays zero.
var validate_salt: u8 = 0;

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
    utf16: bool = false,
    reuse: bool = false,
    fresh: bool = false,
};

fn bench(work: Workload, allocator: std.mem.Allocator) void {
    const rounds: usize = 2000;
    var best: u64 = std.math.maxInt(u64);
    if (work.fresh) {
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                var key = std.ArrayList(u32).empty;
                icuz.collation.sortKeyInto(
                    allocator,
                    work.text,
                    work.options,
                    &key,
                ) catch unreachable;
                sink +%= key.items.len;
                key.deinit(allocator);
            }
            const elapsed = now() - start;
            if (elapsed < best) best = elapsed;
        }
    } else if (work.reuse) {
        var key = std.ArrayList(u32).empty;
        defer key.deinit(allocator);
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                icuz.collation.sortKeyInto(
                    allocator,
                    work.text,
                    work.options,
                    &key,
                ) catch unreachable;
                sink +%= key.items.len;
            }
            const elapsed = now() - start;
            if (elapsed < best) best = elapsed;
        }
    } else if (work.utf16) {
        const units = std.unicode.utf8ToUtf16LeAlloc(
            allocator,
            work.text,
        ) catch unreachable;
        defer allocator.free(units);
        for (0..5) |_| {
            const start = now();
            for (0..rounds) |_| {
                const key = icuz.collation.sortKeyUtf16Alloc(
                    allocator,
                    units,
                    work.options,
                ) catch unreachable;
                sink +%= key.len;
                allocator.free(key);
            }
            const elapsed = now() - start;
            if (elapsed < best) best = elapsed;
        }
    } else if (work.codepoints) {
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

fn benchFullCase(
    name: []const u8,
    text: []const u8,
    kind: enum { lower, upper, fold },
    allocator: std.mem.Allocator,
) void {
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = switch (kind) {
                .lower => icuz.case.fullLowerAlloc(allocator, text, .{}),
                .upper => icuz.case.fullUpperAlloc(allocator, text, .{}),
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

fn benchCompareValidating(
    name: []const u8,
    a: []const u8,
    b: []const u8,
    allocator: std.mem.Allocator,
) void {
    const collator = icuz.collation.Collator.init(.{});
    var key_a = std.ArrayList(u32).empty;
    defer key_a.deinit(allocator);
    var key_b = std.ArrayList(u32).empty;
    defer key_b.deinit(allocator);
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = collator.compare(
                allocator,
                a,
                b,
                &key_a,
                &key_b,
            ) catch unreachable;
            sink +%= @intFromEnum(order);
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<28} {d:8.3} ns/op\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
    });
}

fn benchCanonicalize(
    name: []const u8,
    tag: []const u8,
    allocator: std.mem.Allocator,
) void {
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.locale.canonicalizeAlloc(
                allocator,
                tag,
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<28} {d:8.3} ns/op\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
    });
}

fn benchCompareConvenience(
    name: []const u8,
    a: []const u8,
    b: []const u8,
    allocator: std.mem.Allocator,
) void {
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = icuz.collation.compare(allocator, a, b, .{}) catch
                unreachable;
            sink +%= @intFromEnum(order);
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<28} {d:8.3} ns/op\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
    });
}

fn benchValidate(name: []const u8, text: []const u8) void {
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            sink +%= @intFromBool(std.unicode.utf8ValidateSlice(text));
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchLines(name: []const u8, text: []const u8) void {
    var count: usize = 0;
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            var iterator = icuz.unicode.lineBreaksAssumeValid(text);
            while (iterator.next()) |_| count += 1;
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    sink +%= count;
    report(name, rounds * text.len, best);
}

fn benchQuickCheckUtf16(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch
        unreachable;
    defer allocator.free(units);
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            sink +%= @intFromBool(
                icuz.normalization.isNormalizedUtf16(units, .nfc) catch
                    unreachable,
            );
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchQuickCheck(
    name: []const u8,
    text: []const u8,
) void {
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            sink +%= @intFromBool(
                icuz.normalization.isNormalizedAssumeValid(text),
            );
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchNormalizeInto(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    buffer.ensureTotalCapacity(allocator, text.len * 4) catch unreachable;
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const changed = icuz.normalization.normalizeFormInto(
                allocator,
                text,
                .nfc,
                &buffer,
            ) catch unreachable;
            sink +%= @intFromBool(changed);
            buffer.clearRetainingCapacity();
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchNormalizeUtf16Into(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch
        unreachable;
    defer allocator.free(units);
    var buffer = std.ArrayList(u16).empty;
    defer buffer.deinit(allocator);
    buffer.ensureTotalCapacity(allocator, units.len * 2) catch unreachable;
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const changed = icuz.normalization.normalizeUtf16Into(
                allocator,
                units,
                .nfc,
                &buffer,
            ) catch unreachable;
            sink +%= @intFromBool(changed);
            buffer.clearRetainingCapacity();
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

fn benchCaseUtf16(
    name: []const u8,
    text: []const u8,
    kind: enum { lower, fold },
    allocator: std.mem.Allocator,
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch
        unreachable;
    defer allocator.free(units);
    var buffer = std.ArrayList(u16).empty;
    defer buffer.deinit(allocator);
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            switch (kind) {
                .lower => icuz.case.utf16.lowerInto(
                    allocator,
                    units,
                    &buffer,
                ) catch unreachable,
                .fold => icuz.case.utf16.foldInto(
                    allocator,
                    units,
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

fn selected(filter: []const u8, section: []const u8, name: []const u8) bool {
    return filter.len == 0 or
        std.mem.eql(u8, filter, section) or
        std.mem.eql(u8, filter, name);
}

fn commonBytePrefix(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    var index: usize = 0;
    while (index + 128 <= limit) : (index += 128) {
        const a0: @Vector(32, u8) = a[index..][0..32].*;
        const b0: @Vector(32, u8) = b[index..][0..32].*;
        const a1: @Vector(32, u8) = a[index + 32 ..][0..32].*;
        const b1: @Vector(32, u8) = b[index + 32 ..][0..32].*;
        const a2: @Vector(32, u8) = a[index + 64 ..][0..32].*;
        const b2: @Vector(32, u8) = b[index + 64 ..][0..32].*;
        const a3: @Vector(32, u8) = a[index + 96 ..][0..32].*;
        const b3: @Vector(32, u8) = b[index + 96 ..][0..32].*;
        const mask0: u32 = @bitCast(a0 != b0);
        const mask1: u32 = @bitCast(a1 != b1);
        const mask2: u32 = @bitCast(a2 != b2);
        const mask3: u32 = @bitCast(a3 != b3);
        if ((mask0 | mask1 | mask2 | mask3) != 0) {
            if (mask0 != 0) return index + @ctz(mask0);
            if (mask1 != 0) return index + 32 + @ctz(mask1);
            if (mask2 != 0) return index + 64 + @ctz(mask2);
            return index + 96 + @ctz(mask3);
        }
    }
    while (index + 64 <= limit) : (index += 64) {
        const a0: @Vector(32, u8) = a[index..][0..32].*;
        const b0: @Vector(32, u8) = b[index..][0..32].*;
        const a1: @Vector(32, u8) = a[index + 32 ..][0..32].*;
        const b1: @Vector(32, u8) = b[index + 32 ..][0..32].*;
        const mask0: u32 = @bitCast(a0 != b0);
        const mask1: u32 = @bitCast(a1 != b1);
        if (mask0 != 0) return index + @ctz(mask0);
        if (mask1 != 0) return index + 32 + @ctz(mask1);
    }
    while (index < limit and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn benchPrefix(name: []const u8, a: []const u8, b: []const u8) void {
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            sink +%= commonBytePrefix(a, b);
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * a.len, best);
}

fn benchCompare(
    name: []const u8,
    a: []const u8,
    b: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    const collator = icuz.collation.Collator.init(options);
    var key_a = std.ArrayList(u32).empty;
    defer key_a.deinit(allocator);
    var key_b = std.ArrayList(u32).empty;
    defer key_b.deinit(allocator);
    const rounds: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = collator.compareAssumeValid(
                allocator,
                a,
                b,
                &key_a,
                &key_b,
            ) catch unreachable;
            sink +%= @intFromEnum(order);
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<28} {d:8.3} ns/op\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
    });
}

fn benchValidateVector(name: []const u8, text: []const u8) void {
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            const salt = @as(*volatile u8, &validate_salt).*;
            sink +%= @intFromBool(icuz.scalar.validate.isValid(
                text[0 .. text.len - salt],
            ));
        }
        const elapsed = now() - start;
        if (elapsed < best) best = elapsed;
    }
    report(name, rounds * text.len, best);
}

fn benchValidateOurs(name: []const u8, text: []const u8) void {
    const rounds: usize = 4000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            var cursor: usize = 0;
            var valid = true;
            while (cursor < text.len) {
                const decoded = icuz.scalar.decodeValidatingPacked(
                    text,
                    cursor,
                );
                if (decoded == icuz.scalar.packed_invalid) {
                    valid = false;
                    break;
                }
                cursor += icuz.scalar.packedLength(decoded);
            }
            sink +%= @intFromBool(valid);
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
const greek_case_text = "ΟΔΟΣ ΣΟΦΟΣ ΑΘΗΝΑ " ** 8;
const e_marks_text = "e\u{0301}\u{0323} " ** 16;
const jamo_text = "\u{1100}\u{1161}\u{11a8} " ** 12;
const chinese_text = "你好世界中国汉字排序拼音" ** 8;
const chinese_long_text = "你好世界中国汉字排序拼音" ** 256;
const ascii_long_text =
    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. " ** 4;

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
            .name = "Chinese long",
            .text = chinese_long_text,
        },
        .{
            .name = "Chinese long pinyin",
            .text = chinese_long_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
        },
        .{
            .name = "ASCII long",
            .text = ascii_long_text,
        },
        .{
            .name = "Chinese long pinyin (cp)",
            .text = chinese_long_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
            .codepoints = true,
        },
        .{
            .name = "Chinese long pinyin (reuse)",
            .text = chinese_long_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
            .reuse = true,
        },
        .{
            .name = "Chinese long pinyin (fresh)",
            .text = chinese_long_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
            .fresh = true,
        },
        .{
            .name = "Swedish (utf16)",
            .text = swedish_text,
            .options = .{ .locale = "sv" },
            .utf16 = true,
        },
        .{
            .name = "mixed (utf16)",
            .text = mixed_text,
            .utf16 = true,
        },
        .{
            .name = "Chinese pinyin (utf16)",
            .text = chinese_text,
            .options = .{ .locale = "zh", .collation = "pinyin" },
            .utf16 = true,
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
    if (selected(filter, "case", "lower mixed")) {
        benchCase("lower mixed", mixed_text, .lower, allocator);
    }
    if (selected(filter, "case", "fold mixed")) {
        benchCase("fold mixed", mixed_text, .fold, allocator);
    }
    if (selected(filter, "case", "lower ASCII")) {
        benchCase("lower ASCII", ascii_text, .lower, allocator);
    }
    if (selected(filter, "case", "lower Swedish")) {
        benchCase("lower Swedish", swedish_text, .lower, allocator);
    }
    if (selected(filter, "case", "lower mixed (reuse)")) {
        benchCaseInto("lower mixed (reuse)", mixed_text, .lower, allocator);
    }
    if (selected(filter, "case", "fold mixed (reuse)")) {
        benchCaseInto("fold mixed (reuse)", mixed_text, .fold, allocator);
    }
    if (selected(filter, "case", "lower Swedish (reuse)")) {
        benchCaseInto(
            "lower Swedish (reuse)",
            swedish_text,
            .lower,
            allocator,
        );
    }
    if (selected(filter, "case", "lower ASCII (reuse)")) {
        benchCaseInto("lower ASCII (reuse)", ascii_text, .lower, allocator);
    }
    if (selected(filter, "case", "lower mixed (utf16)")) {
        benchCaseUtf16("lower mixed (utf16)", mixed_text, .lower, allocator);
    }
    if (selected(filter, "case", "fold mixed (utf16)")) {
        benchCaseUtf16("fold mixed (utf16)", mixed_text, .fold, allocator);
    }
    if (selected(filter, "case", "lower ASCII (utf16)")) {
        benchCaseUtf16("lower ASCII (utf16)", ascii_text, .lower, allocator);
    }
    if (selected(filter, "case", "full lower Greek sigma")) {
        benchFullCase("full lower Greek sigma", greek_case_text, .lower, allocator);
    }
    if (selected(filter, "case", "full upper mixed")) {
        benchFullCase("full upper mixed", mixed_text, .upper, allocator);
    }
    if (selected(filter, "case", "full upper German")) {
        benchFullCase("full upper German", german_text, .upper, allocator);
    }
    if (selected(filter, "case", "full lower mixed")) {
        benchFullCase("full lower mixed", mixed_text, .lower, allocator);
    }
    if (selected(filter, "case", "full lower German")) {
        benchFullCase("full lower German", german_text, .lower, allocator);
    }
    if (selected(filter, "case", "full lower Swedish")) {
        benchFullCase("full lower Swedish", swedish_text, .lower, allocator);
    }
    if (selected(filter, "case", "fold mixed (full)")) {
        benchFullCase("fold mixed (full)", mixed_text, .fold, allocator);
    }
    if (selected(filter, "break", "line break mixed")) {
        benchLines("line break mixed", mixed_text);
    }
    if (selected(filter, "break", "line break ASCII")) {
        benchLines("line break ASCII", ascii_text);
    }
    if (selected(filter, "break", "line break emoji zwj")) {
        benchLines("line break emoji zwj", "\u{1f469}\u{200d}\u{1f4bb}" ** 8);
    }
    if (selected(filter, "break", "line break hebrew")) {
        benchLines("line break hebrew", "\u{05e9}\u{05dc}\u{05d5}\u{05dd} " ** 8);
    }
    if (selected(filter, "break", "line break arabic")) {
        benchLines("line break arabic", "\u{0645}\u{0631}\u{062d}\u{0628}\u{0627} " ** 8);
    }
    if (selected(filter, "break", "line break devanagari")) {
        benchLines("line break devanagari", "\u{0915}\u{094d}\u{0937}\u{093f} " ** 8);
    }
    if (selected(filter, "normalize", "NFC precomposed (reuse)")) {
        benchNormalizeInto(
            "NFC precomposed (reuse)",
            "\u{00e9} \u{00ef} \u{00df} \u{4e16}\u{754c} " ** 8,
            allocator,
        );
    }
    if (selected(filter, "quickcheck", "quickcheck mixed (utf16)")) {
        benchQuickCheckUtf16(
            "quickcheck mixed (utf16)",
            mixed_text,
            allocator,
        );
    }
    if (selected(filter, "quickcheck", "quickcheck e+marks (utf16)")) {
        benchQuickCheckUtf16(
            "quickcheck e+marks (utf16)",
            e_marks_text,
            allocator,
        );
    }
    if (selected(filter, "normalize", "NFC Japanese (utf16 reuse)")) {
        benchNormalizeUtf16Into(
            "NFC Japanese (utf16 reuse)",
            "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}\u{3002}\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{5b57}\u{30b3}\u{30fc}\u{30c9}\u{5909}\u{63db}\u{3002}" ** 8,
            allocator,
        );
    }
    if (selected(filter, "normalize", "NFC Chinese (utf16 reuse)")) {
        benchNormalizeUtf16Into(
            "NFC Chinese (utf16 reuse)",
            "\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}\u{ff01}\u{4e2d}\u{6587}\u{7f16}\u{7801}\u{8f6c}\u{6362}\u{57fa}\u{51c6}\u{6d4b}\u{8bd5}\u{3002}" ** 8,
            allocator,
        );
    }
    if (selected(filter, "quickcheck", "quickcheck Chinese (utf16)")) {
        benchQuickCheckUtf16(
            "quickcheck Chinese (utf16)",
            "\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}\u{ff01}\u{4e2d}\u{6587}\u{7f16}\u{7801}\u{8f6c}\u{6362}\u{57fa}\u{51c6}\u{6d4b}\u{8bd5}\u{3002}" ** 8,
            allocator,
        );
    }
    if (selected(filter, "quickcheck", "quickcheck mixed")) {
        benchQuickCheck("quickcheck mixed", mixed_text);
    }
    if (selected(filter, "quickcheck", "quickcheck ASCII")) {
        benchQuickCheck("quickcheck ASCII", ascii_text);
    }
    if (selected(filter, "quickcheck", "quickcheck Chinese")) {
        benchQuickCheck(
            "quickcheck Chinese",
            "\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}\u{ff01}\u{4e2d}\u{6587}\u{7f16}\u{7801}\u{8f6c}\u{6362}\u{57fa}\u{51c6}\u{6d4b}\u{8bd5}\u{3002}" ** 8,
        );
    }
    if (selected(filter, "normalize", "NFC Japanese (reuse)")) {
        benchNormalizeInto(
            "NFC Japanese (reuse)",
            "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}\u{3002}\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{5b57}\u{30b3}\u{30fc}\u{30c9}\u{5909}\u{63db}\u{3002}" ** 8,
            allocator,
        );
    }
    if (selected(filter, "normalize", "NFC Chinese (reuse)")) {
        benchNormalizeInto(
            "NFC Chinese (reuse)",
            "\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}\u{ff01}\u{4e2d}\u{6587}\u{7f16}\u{7801}\u{8f6c}\u{6362}\u{57fa}\u{51c6}\u{6d4b}\u{8bd5}\u{3002}" ** 8,
            allocator,
        );
    }
    if (selected(filter, "normalize", "NFC mixed (reuse)")) {
        benchNormalizeInto("NFC mixed (reuse)", mixed_text, allocator);
    }
    if (selected(filter, "normalize", "NFC jamo (reuse)")) {
        benchNormalizeInto("NFC jamo (reuse)", jamo_text, allocator);
    }
    if (selected(filter, "normalize", "NFC e+marks (reuse)")) {
        benchNormalizeInto("NFC e+marks (reuse)", e_marks_text, allocator);
    }
    if (selected(filter, "normalize", "NFC mixed (utf16 reuse)")) {
        benchNormalizeUtf16Into("NFC mixed (utf16 reuse)", mixed_text, allocator);
    }
    if (selected(filter, "normalize", "NFC jamo (utf16 reuse)")) {
        benchNormalizeUtf16Into("NFC jamo (utf16 reuse)", jamo_text, allocator);
    }
    if (selected(filter, "compare", "compare mixed convenience")) {
        var other = std.ArrayList(u8).empty;
        defer other.deinit(allocator);
        other.appendSlice(allocator, mixed_text) catch unreachable;
        other.items[other.items.len - 3] = 'u';
        benchCompareConvenience(
            "compare mixed convenience",
            mixed_text,
            other.items,
            allocator,
        );
    }
    if (selected(filter, "compare", "compare mixed validating")) {
        var other = std.ArrayList(u8).empty;
        defer other.deinit(allocator);
        other.appendSlice(allocator, mixed_text) catch unreachable;
        other.items[other.items.len - 3] = 'u';
        benchCompareValidating(
            "compare mixed validating",
            mixed_text,
            other.items,
            allocator,
        );
    }
    if (selected(filter, "compare", "compare Chinese long validating")) {
        const source = "你好世界中国汉字排序拼音" ** 256;
        const text = allocator.dupe(u8, source) catch unreachable;
        defer allocator.free(text);
        const other = allocator.dupe(u8, source) catch unreachable;
        defer allocator.free(other);
        other[other.len - 1] = 0xb4;
        benchCompareValidating(
            "compare Chinese long validating",
            text,
            other,
            allocator,
        );
    }
    if (selected(filter, "compare", "compare long")) {
        var long_other = std.ArrayList(u8).empty;
        defer long_other.deinit(allocator);
        long_other.appendSlice(allocator, chinese_long_text) catch unreachable;
        long_other.items[long_other.items.len - 1] = 0xb4;
        benchCompare("compare long", chinese_long_text, long_other.items, .{}, allocator);
        var mixed_other = std.ArrayList(u8).empty;
        defer mixed_other.deinit(allocator);
        mixed_other.appendSlice(allocator, mixed_text) catch unreachable;
        mixed_other.items[mixed_other.items.len - 3] = 'u';
        benchCompare("compare mixed late", mixed_text, mixed_other.items, .{}, allocator);
        var mixed_early = std.ArrayList(u8).empty;
        defer mixed_early.deinit(allocator);
        mixed_early.appendSlice(allocator, mixed_text) catch unreachable;
        mixed_early.items[0] = 'Z';
        benchCompare("compare mixed early", mixed_text, mixed_early.items, .{}, allocator);
    }
    if (selected(filter, "prefix", "prefix long")) {
        var other = std.ArrayList(u8).empty;
        defer other.deinit(allocator);
        other.appendSlice(allocator, chinese_long_text) catch unreachable;
        other.items[other.items.len - 1] = 0xb4;
        benchPrefix("prefix long", chinese_long_text, other.items);
        benchPrefix("prefix mixed", mixed_text, mixed_text);
        var mixed_other = std.ArrayList(u8).empty;
        defer mixed_other.deinit(allocator);
        mixed_other.appendSlice(allocator, mixed_text) catch unreachable;
        mixed_other.items[mixed_other.items.len - 3] = 'u';
        benchPrefix("prefix mixed diff", mixed_text, mixed_other.items);
    }
    if (selected(filter, "locale", "canonicalize en-US")) {
        benchCanonicalize("canonicalize en-US", "en-US", allocator);
    }
    if (selected(filter, "locale", "canonicalize zh-hant-tw")) {
        benchCanonicalize("canonicalize zh-hant-tw", "zh-hant-tw", allocator);
    }
    if (selected(filter, "locale", "canonicalize sh-RS")) {
        benchCanonicalize("canonicalize sh-RS", "sh-RS", allocator);
    }
    if (selected(filter, "locale", "canonicalize sr-Latn-RS")) {
        benchCanonicalize("canonicalize sr-Latn-RS", "sr-Latn-RS", allocator);
    }
    if (selected(filter, "validate", "validate Swedish")) {
        // Runtime copies keep the validator calls from being folded at
        // comptime, which would report a meaningless zero.
        const swedish_rt = allocator.dupe(u8, swedish_text) catch unreachable;
        defer allocator.free(swedish_rt);
        const mixed_rt = allocator.dupe(u8, mixed_text) catch unreachable;
        defer allocator.free(mixed_rt);
        const chinese_rt = allocator.dupe(u8, chinese_long_text) catch unreachable;
        defer allocator.free(chinese_rt);
        const ascii_rt = allocator.dupe(u8, ascii_text) catch unreachable;
        defer allocator.free(ascii_rt);
        benchValidate("validate Swedish std", swedish_rt);
        benchValidateOurs("validate Swedish ours", swedish_rt);
        benchValidateVector("validate Swedish vector", swedish_rt);
        benchValidate("validate mixed std", mixed_rt);
        benchValidateOurs("validate mixed ours", mixed_rt);
        benchValidateVector("validate mixed vector", mixed_rt);
        benchValidate("validate Chinese std", chinese_rt);
        benchValidateOurs("validate Chinese ours", chinese_rt);
        benchValidateVector("validate Chinese vector", chinese_rt);
        benchValidate("validate ASCII std", ascii_rt);
        benchValidateOurs("validate ASCII ours", ascii_rt);
        benchValidateVector("validate ASCII vector", ascii_rt);
    }
    if (selected(filter, "decode", "decode Chinese")) {
        benchDecode("decode Chinese", chinese_text);
    }
    if (selected(filter, "decode", "decode mixed")) {
        benchDecode("decode mixed", mixed_text);
    }
    if (selected(filter, "decode", "decode ASCII")) {
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
