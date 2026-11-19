//! icuz microbenchmarks.
//!
//! Run with `zig build bench`. The harness intentionally reports the best of
//! several trials because desktop frequency scaling and background load can
//! otherwise dominate short measurements. Compare runs on an otherwise idle
//! machine and keep the same Zig version and optimization mode.

const std = @import("std");
const icuz = @import("icuz");

var sink: u64 = 0;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
        @as(u64, @intCast(ts.nsec));
}

fn reportOps(name: []const u8, ops: usize, ns: u64) void {
    const per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
    std.debug.print("{s:<32} {d:>8.3} ns/op {d:>9.1} Mops/s\n", .{
        name,
        per_op,
        1000.0 / per_op,
    });
}

fn reportBytes(name: []const u8, bytes: usize, ns: u64) void {
    const per_byte = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(bytes));
    std.debug.print("{s:<32} {d:>8.3} ns/B  {d:>9.1} MB/s\n", .{
        name,
        per_byte,
        @as(f64, @floatFromInt(bytes)) * 1000.0 / @as(f64, @floatFromInt(ns)),
    });
}

fn bestOf(
    comptime trials: usize,
    comptime rounds: usize,
    ops_per_round: usize,
    comptime body: fn (usize) void,
) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| body(ops_per_round);
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    return best;
}

fn benchCodepoint(
    name: []const u8,
    codepoints: []const u21,
    comptime f: fn (u21) u64,
) void {
    var total: u64 = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 16;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (codepoints) |codepoint| total +%= f(codepoint);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= total;
    reportOps(name, rounds * codepoints.len, best);
}

fn category(cp: u21) u64 {
    return @intFromEnum(icuz.properties.category(cp));
}
fn alphabetic(cp: u21) u64 {
    return @intFromBool(icuz.properties.isAlphabetic(cp));
}
fn uppercase(cp: u21) u64 {
    return @intFromBool(icuz.properties.isUppercase(cp));
}
fn lowercase(cp: u21) u64 {
    return @intFromBool(icuz.properties.isLowercase(cp));
}
fn math(cp: u21) u64 {
    return @intFromBool(icuz.properties.isMath(cp));
}
fn combiningClass(cp: u21) u64 {
    return icuz.unicode.canonicalCombiningClass(cp);
}
fn quickCheck(cp: u21) u64 {
    return @intFromEnum(icuz.normalization.quickCheckCodepoint(cp));
}
fn script(cp: u21) u64 {
    return @intFromEnum(icuz.script.forCodepoint(cp));
}
fn bidiClass(cp: u21) u64 {
    return @intFromEnum(icuz.unicode.exactBidiClassForCodepoint(cp));
}
fn lineBreakClass(cp: u21) u64 {
    return @intFromEnum(icuz.unicode.lineBreakClassForCodepoint(cp));
}

const ascii_text =
    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump! 0123456789 hello_world@example.com https://example.com/path?q=1\n";

const chinese_text = "你好，世界！中文编码转换基准测试。" ** 8;
const japanese_text = "こんにちは世界。日本語の文字コード変換。" ** 8;
const korean_text = "안녕하세요 세계. 한국어 인코딩 변환." ** 8;
const swedish_text = "Ångström älskar blåbär och öar. ÅÄÖ åäö " ** 8;
const german_text = "Böttger Mühsam Überlingen ÄÖÜ äöü Straße " ** 8;
const chinese_collation_text = "你好世界中国汉字排序拼音" ** 8;
const fullwidth_text = "ＡＢＣ１２３！？　ｶﾞｷﾞｸﾞ " ** 8;
const georgian_text = "საქართველო ქართული ენა " ** 8;
const russian_text = "Москва Санкт-Петербург Россия " ** 8;
const greek_text = "Ελλάδα Αθήνα ελληνική γλώσσα " ** 8;
const katakana_text = "ラーメン とうきょう カタカナ ﾃｽﾄ " ** 8;
const amharic_text = "አማርኛ ግዕዝ ፊደል ቋንቋ " ** 8;
const ukrainian_text = "Київ Україна українська мова " ** 8;
const thai_word_text = "ภาษาไทย ประเทศไทย กรุงเทพมหานคร " ** 8;
const cjk_word_text = "中华人民共和国 日本語 東京都 東京大学 " ** 8;

const mixed_text = "Hello, 世界! café naïve Straße \u{1f600}\u{1f469}\u{200d}\u{1f4bb} " ++
    "e\u{0301}\u{0323} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} " ++
    "\u{0915}\u{094d}\u{0937}\u{093f} \u{1100}\u{1161}\u{11a8} text.\n";

fn benchGraphemes(name: []const u8, text: []const u8) void {
    var count: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            var iterator = icuz.unicode.graphemeClustersAssumeValid(text);
            while (iterator.next()) |_| count += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= count;
    reportBytes(name, rounds * text.len, best);
}

fn benchWords(name: []const u8, text: []const u8) void {
    var count: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            var iterator = icuz.unicode.wordSegmentsAssumeValid(text);
            while (iterator.next()) |_| count += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= count;
    reportBytes(name, rounds * text.len, best);
}

fn benchDictionaryWords(name: []const u8, text: []const u8) void {
    var count: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            var iterator =
                icuz.unicode.wordSegmentsWithDictionariesAssumeValid(text);
            while (iterator.next()) |_| count += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= count;
    reportBytes(name, rounds * text.len, best);
}

fn benchLines(name: []const u8, text: []const u8) void {
    var count: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            var iterator = icuz.unicode.lineBreaksAssumeValid(text);
            while (iterator.next()) |_| count += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= count;
    reportBytes(name, rounds * text.len, best);
}

fn benchSentences(name: []const u8, text: []const u8) void {
    var count: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            var iterator = icuz.unicode.sentenceSegments(text) catch unreachable;
            while (iterator.next()) |_| count += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= count;
    reportBytes(name, rounds * text.len, best);
}

fn benchNormalization(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
    comptime check_only: bool,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            if (check_only) {
                sink +%= @intFromBool(
                    icuz.normalization.isNormalizedAssumeValid(text),
                );
            } else {
                const output = icuz.normalization.normalizeAlloc(
                    allocator,
                    text,
                ) catch unreachable;
                if (output) |owned| {
                    sink +%= owned.len;
                    allocator.free(owned);
                }
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchNormalizationCodepoints(
    name: []const u8,
    codepoints: []const u21,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    var bytes: usize = 0;
    for (codepoints) |cp| bytes += std.unicode.utf8CodepointSequenceLength(cp) catch 1;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = icuz.normalization.normalizeCodepointsAlloc(
                allocator,
                codepoints,
                .nfc,
            ) catch unreachable;
            if (output) |owned| {
                sink +%= owned.len;
                allocator.free(owned);
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * bytes, best);
}

fn benchCase(name: []const u8, text: []const u8, allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = icuz.case.lowerAlloc(allocator, text) catch unreachable;
            sink +%= output.len;
            allocator.free(output);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchFold(name: []const u8, text: []const u8, allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = icuz.case.foldAlloc(allocator, text) catch unreachable;
            sink +%= output.len;
            allocator.free(output);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchSet(allocator: std.mem.Allocator, codepoints: []const u21) void {
    const build_start = now();
    var set = icuz.set.fromProperty(allocator, .alphabetic) catch unreachable;
    defer set.deinit();
    const build_ns: u64 = @intCast(now() - build_start);
    std.debug.print("{s:<32} {d:>8.3} ms\n", .{
        "UnicodeSet build Alphabetic",
        @as(f64, @floatFromInt(build_ns)) / 1_000_000.0,
    });

    var total: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 16;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (codepoints) |codepoint| {
                total += @intFromBool(set.contains(codepoint));
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= total;
    reportOps("UnicodeSet contains", rounds * codepoints.len, best);

    const parse_start = now();
    var parsed = icuz.set.parse(allocator, "\\p{Alphabetic}") catch unreachable;
    defer parsed.deinit();
    const parse_ns: u64 = @intCast(now() - parse_start);
    std.debug.print("{s:<32} {d:>8.3} ms\n", .{
        "UnicodeSet parse Alphabetic",
        @as(f64, @floatFromInt(parse_ns)) / 1_000_000.0,
    });
}

fn benchCollation(
    name: []const u8,
    text: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const key = icuz.collation.sortKeyAlloc(
                allocator,
                text,
                options,
            ) catch unreachable;
            sink +%= key.len;
            allocator.free(key);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCollationCodepoints(
    name: []const u8,
    text: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    var codepoints: [512]u21 = undefined;
    var count: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |codepoint| {
        if (count == codepoints.len) break;
        codepoints[count] = codepoint;
        count += 1;
    }
    var key = std.ArrayList(u32).empty;
    defer key.deinit(allocator);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            icuz.collation.sortKeyCodepointsInto(
                allocator,
                codepoints[0..count],
                options,
                &key,
            ) catch unreachable;
            sink +%= key.items.len;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCollationInto(
    name: []const u8,
    text: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    var key = std.ArrayList(u32).empty;
    defer key.deinit(allocator);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            icuz.collation.sortKeyInto(
                allocator,
                text,
                options,
                &key,
            ) catch unreachable;
            sink +%= key.items.len;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCollationUtf16(
    name: []const u8,
    text: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch unreachable;
    defer allocator.free(units);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const key = icuz.collation.sortKeyUtf16Alloc(
                allocator,
                units,
                options,
            ) catch unreachable;
            sink +%= key.len;
            allocator.free(key);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCharset(
    name: []const u8,
    text: []const u8,
    from: icuz.charset.Encoding,
    to: icuz.charset.Encoding,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const converted = icuz.charset.convertAlloc(
                allocator,
                text,
                from,
                to,
                .{},
            ) catch unreachable;
            sink +%= converted.len;
            allocator.free(converted);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchTransliterate(
    name: []const u8,
    text: []const u8,
    transform: icuz.transliterate.Transform,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const converted = icuz.transliterate.transliterateAlloc(
                allocator,
                text,
                transform,
            ) catch unreachable;
            sink +%= converted.len;
            allocator.free(converted);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchTransliterateByName(
    name: []const u8,
    text: []const u8,
    transform_name: []const u8,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const converted = icuz.transliterate.transliterateByNameAlloc(
                allocator,
                text,
                transform_name,
            ) catch unreachable;
            sink +%= converted.len;
            allocator.free(converted);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchList(allocator: std.mem.Allocator) void {
    const items = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.list.formatAlloc(
                allocator,
                &items,
                "en",
                .{},
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps("list format 4 items", rounds, best);
}

fn benchRelative(allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.relative.formatAlloc(
                allocator,
                -3,
                .day,
                "en",
                .{},
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps("relative time", rounds, best);
}

fn benchDate(allocator: std.mem.Allocator) void {
    const date_time = icuz.date.DateTime{
        .year = 2026,
        .month = 11,
        .day = 19,
        .hour = 13,
        .minute = 45,
        .second = 30,
    };
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.date.formatDateAlloc(
                allocator,
                date_time,
                "en",
                .full,
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps("date full format", rounds, best);
}

fn benchUnits(allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.units.formatAlloc(
                allocator,
                3.5,
                .kilogram,
                "en",
                .{},
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps("unit format", rounds, best);
}

fn benchNumber(
    name: []const u8,
    value: f64,
    options: icuz.number.Options,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.number.formatAlloc(
                allocator,
                value,
                "en",
                options,
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
}

fn benchSkeleton(allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.number.formatSkeletonAlloc(
                allocator,
                1234.5,
                "en",
                "currency/USD group-off .00",
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps("number skeleton", rounds, best);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const codepoints = try allocator.alloc(u21, 1 << 20);
    var state: u32 = 0x12345678;
    for (codepoints) |*codepoint| {
        state = state *% 1664525 +% 1013904223;
        var value: u32 = state >> 8;
        if (value >= 0xd800 and value <= 0xdfff) value += 0x800;
        codepoint.* = @intCast(value & 0x10ffff);
    }
    std.mem.doNotOptimizeAway(codepoints.ptr);

    // Keep the benchmark text in runtime memory so the optimizer cannot fold
    // the whole loop into a constant.
    const ascii_runtime = try allocator.dupe(u8, ascii_text);
    const mixed_runtime = try allocator.dupe(u8, mixed_text);
    const chinese_runtime = try allocator.dupe(u8, chinese_text);
    const japanese_runtime = try allocator.dupe(u8, japanese_text);
    const korean_runtime = try allocator.dupe(u8, korean_text);
    const gbk_runtime = try icuz.charset.encodeAlloc(
        allocator,
        chinese_text,
        .gbk,
        .{},
    );
    const swedish_runtime = try allocator.dupe(u8, swedish_text);
    const german_runtime = try allocator.dupe(u8, german_text);
    const chinese_collation_runtime = try allocator.dupe(u8, chinese_collation_text);
    const fullwidth_runtime = try allocator.dupe(u8, fullwidth_text);
    const georgian_runtime = try allocator.dupe(u8, georgian_text);
    const russian_runtime = try allocator.dupe(u8, russian_text);
    const greek_runtime = try allocator.dupe(u8, greek_text);
    const katakana_runtime = try allocator.dupe(u8, katakana_text);
    const amharic_runtime = try allocator.dupe(u8, amharic_text);
    const ukrainian_runtime = try allocator.dupe(u8, ukrainian_text);
    const thai_word_runtime = try allocator.dupe(u8, thai_word_text);
    const cjk_word_runtime = try allocator.dupe(u8, cjk_word_text);
    std.mem.doNotOptimizeAway(ascii_runtime.ptr);
    std.mem.doNotOptimizeAway(mixed_runtime.ptr);
    std.mem.doNotOptimizeAway(chinese_runtime.ptr);
    std.mem.doNotOptimizeAway(japanese_runtime.ptr);
    std.mem.doNotOptimizeAway(korean_runtime.ptr);
    std.mem.doNotOptimizeAway(gbk_runtime.ptr);
    std.mem.doNotOptimizeAway(swedish_runtime.ptr);
    std.mem.doNotOptimizeAway(german_runtime.ptr);
    std.mem.doNotOptimizeAway(chinese_collation_runtime.ptr);
    std.mem.doNotOptimizeAway(fullwidth_runtime.ptr);
    std.mem.doNotOptimizeAway(georgian_runtime.ptr);
    std.mem.doNotOptimizeAway(russian_runtime.ptr);
    std.mem.doNotOptimizeAway(greek_runtime.ptr);
    std.mem.doNotOptimizeAway(katakana_runtime.ptr);
    std.mem.doNotOptimizeAway(amharic_runtime.ptr);
    std.mem.doNotOptimizeAway(ukrainian_runtime.ptr);
    std.mem.doNotOptimizeAway(thai_word_runtime.ptr);
    std.mem.doNotOptimizeAway(cjk_word_runtime.ptr);

    std.debug.print("icuz {d}.{d}.{d} microbenchmarks\n", .{
        icuz.unicode_version[0],
        icuz.unicode_version[1],
        icuz.unicode_version[2],
    });
    std.debug.print("\n-- scalar properties (random order, all scalars) --\n", .{});
    benchCodepoint("General_Category", codepoints, category);
    benchCodepoint("Alphabetic", codepoints, alphabetic);
    benchCodepoint("Uppercase", codepoints, uppercase);
    benchCodepoint("Lowercase", codepoints, lowercase);
    benchCodepoint("Math", codepoints, math);
    benchCodepoint("Canonical_Combining_Class", codepoints, combiningClass);
    benchCodepoint("NFC_Quick_Check", codepoints, quickCheck);
    benchCodepoint("Script", codepoints, script);
    benchCodepoint("Bidi_Class", codepoints, bidiClass);
    benchCodepoint("Line_Break", codepoints, lineBreakClass);

    std.debug.print("\n-- UnicodeSet --\n", .{});
    benchSet(allocator, codepoints);

    std.debug.print("\n-- collation --\n", .{});
    benchCollation("UCA sort key ASCII", ascii_runtime, .{}, allocator);
    benchCollation("UCA sort key mixed", mixed_runtime, .{}, allocator);
    benchCollation(
        "UCA sort key Swedish root",
        swedish_runtime,
        .{},
        allocator,
    );
    benchCollation(
        "UCA sort key Swedish",
        swedish_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollation(
        "UCA sort key German phonebook",
        german_runtime,
        .{ .locale = "de", .collation = "phonebook" },
        allocator,
    );
    benchCollation(
        "UCA sort key Chinese root",
        chinese_collation_runtime,
        .{},
        allocator,
    );
    benchCollation(
        "UCA sort key Chinese pinyin",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );
    benchCollationCodepoints(
        "UCA sort key Chinese root (cp)",
        chinese_collation_runtime,
        .{},
        allocator,
    );
    benchCollationCodepoints(
        "UCA sort key Chinese pinyin (cp)",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );
    benchCollationCodepoints(
        "UCA sort key Swedish (cp)",
        swedish_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationInto(
        "UCA sort key Swedish (reuse)",
        swedish_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationUtf16(
        "UCA sort key Chinese pinyin (utf16)",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );

    std.debug.print("\n-- charset conversion --\n", .{});
    benchCharset(
        "UTF-8 -> UTF-16LE ASCII",
        ascii_runtime,
        .utf8,
        .utf16_le,
        allocator,
    );
    benchCharset(
        "UTF-8 -> windows-1252 ASCII",
        ascii_runtime,
        .utf8,
        .windows_1252,
        allocator,
    );
    benchCharset("UTF-8 -> GBK Chinese", chinese_runtime, .utf8, .gbk, allocator);
    benchCharset(
        "UTF-8 -> Shift_JIS Japanese",
        japanese_runtime,
        .utf8,
        .shift_jis,
        allocator,
    );
    benchCharset(
        "UTF-8 -> EUC-KR Korean",
        korean_runtime,
        .utf8,
        .euc_kr,
        allocator,
    );
    benchCharset("GBK -> UTF-8 Chinese", gbk_runtime, .gbk, .utf8, allocator);

    std.debug.print("\n-- transliteration --\n", .{});
    benchTransliterate(
        "Latin-ASCII ASCII",
        ascii_runtime,
        .latin_ascii,
        allocator,
    );
    benchTransliterate(
        "Latin-ASCII Swedish",
        swedish_runtime,
        .latin_ascii,
        allocator,
    );
    benchTransliterate(
        "Fullwidth-Halfwidth",
        fullwidth_runtime,
        .fullwidth_halfwidth,
        allocator,
    );
    benchTransliterate(
        "Georgian-Latin-BGN",
        georgian_runtime,
        .georgian_latin_bgn,
        allocator,
    );
    benchTransliterate(
        "Russian-Latin-BGN",
        russian_runtime,
        .russian_latin_bgn,
        allocator,
    );
    benchTransliterate(
        "Greek-Latin-BGN",
        greek_runtime,
        .greek_latin_bgn,
        allocator,
    );
    benchTransliterate(
        "Katakana-Latin-BGN",
        katakana_runtime,
        .katakana_latin_bgn,
        allocator,
    );
    benchTransliterateByName(
        "Amharic-Latin-BGN",
        amharic_runtime,
        "Amharic-Latin-BGN",
        allocator,
    );
    benchTransliterateByName(
        "Ukrainian-Latin-BGN",
        ukrainian_runtime,
        "Ukrainian-Latin-BGN",
        allocator,
    );

    std.debug.print("\n-- number formatting --\n", .{});
    benchNumber("decimal number", 1234.5, .{}, allocator);
    benchNumber(
        "scientific number",
        1234.5,
        .{ .style = .scientific },
        allocator,
    );
    benchNumber(
        "compact number",
        1234567,
        .{ .style = .compact },
        allocator,
    );
    benchNumber(
        "currency name",
        1234.5,
        .{
            .style = .currency,
            .currency = "USD",
            .currency_display = .name,
        },
        allocator,
    );
    benchNumber(
        "accounting currency",
        -1234.5,
        .{ .style = .currency, .currency = "USD", .accounting = true },
        allocator,
    );
    benchSkeleton(allocator);

    std.debug.print("\n-- locale formatting --\n", .{});
    benchList(allocator);
    benchRelative(allocator);
    benchUnits(allocator);
    benchDate(allocator);

    std.debug.print("\n-- segmentation --\n", .{});
    benchGraphemes("grapheme ASCII", ascii_runtime);
    benchGraphemes("grapheme mixed", mixed_runtime);
    benchWords("word ASCII", ascii_runtime);
    benchWords("word mixed", mixed_runtime);
    benchDictionaryWords("word Thai dictionary", thai_word_runtime);
    benchDictionaryWords("word CJK dictionary", cjk_word_runtime);
    benchLines("line break ASCII", ascii_runtime);
    benchLines("line break mixed", mixed_runtime);
    benchSentences("sentence ASCII", ascii_runtime);
    benchSentences("sentence mixed", mixed_runtime);

    std.debug.print("\n-- normalization and case --\n", .{});
    benchNormalization("isNormalized ASCII", ascii_runtime, allocator, true);
    benchNormalization("isNormalized mixed", mixed_runtime, allocator, true);
    benchNormalization("NFC ASCII", ascii_runtime, allocator, false);
    benchNormalization("isNormalized Chinese", chinese_runtime, allocator, true);
    benchNormalization("NFC Chinese", chinese_runtime, allocator, false);
    benchNormalization("NFC mixed", mixed_runtime, allocator, false);
    {
        var decoded: [256]u21 = undefined;
        var count: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(mixed_runtime).iterator();
        while (view.nextCodepoint()) |cp| {
            if (count == decoded.len) break;
            decoded[count] = cp;
            count += 1;
        }
        benchNormalizationCodepoints("NFC mixed codepoints", decoded[0..count], allocator);
    }
    benchCase("lower ASCII", ascii_runtime, allocator);
    benchFold("case fold ASCII", ascii_runtime, allocator);

    std.debug.print("\nsink={d}\n", .{sink});
}
