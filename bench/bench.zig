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
const accents_text = "café naïve Straße Ångström Böttger Überlingen ÄÖÜ äöü " ** 8;
const japanese_text = "こんにちは世界。日本語の文字コード変換。" ** 8;
const korean_text = "안녕하세요 세계. 한국어 인코딩 변환." ** 8;
const swedish_text = "Ångström älskar blåbär och öar. ÅÄÖ åäö " ** 8;
const german_text = "Böttger Mühsam Überlingen ÄÖÜ äöü Straße " ** 8;
const chinese_collation_text = "你好世界中国汉字排序拼音" ** 8;
const fullwidth_text = "ＡＢＣ１２３！？　ｶﾞｷﾞｸﾞ " ** 8;
const georgian_text = "საქართველო ქართული ენა " ** 8;
const russian_text = "Москва Санкт-Петербург Россия " ** 8;
const greek_text = "Ελλάδα Αθήνα ελληνική γλώσσα " ** 8;
const greek_case_text = "ΟΔΟΣ ΣΟΦΟΣ ΑΘΗΝΑ " ** 8;
const katakana_text = "ラーメン とうきょう カタカナ ﾃｽﾄ " ** 8;
const amharic_text = "አማርኛ ግዕዝ ፊደል ቋንቋ " ** 8;
const ukrainian_text = "Київ Україна українська мова " ** 8;
const thai_word_text = "ภาษาไทย ประเทศไทย กรุงเทพมหานคร " ** 8;
const cjk_word_text = "中华人民共和国 日本語 東京都 東京大学 " ** 8;

const mixed_text = "Hello, 世界! café naïve Straße \u{1f600}\u{1f469}\u{200d}\u{1f4bb} " ++
    "e\u{0301}\u{0323} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} " ++
    "\u{0915}\u{094d}\u{0937}\u{093f} \u{1100}\u{1161}\u{11a8} text.\n";
const rtl_text = "مرحبا بالعالم! هذا نص عربي للاختبار. " ** 4;

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
            // Match the grapheme, word, and line rows: the caller has
            // validated the text, so segmentation alone is measured.
            var iterator = icuz.unicode.sentenceSegmentsAssumeValid(text);
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

/// Normalize into a caller-owned buffer, matching ICU's `unorm2_normalize`
/// buffer API, so the comparison does not include returning owned memory.
fn benchNormalizationInto(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    buffer.ensureTotalCapacity(allocator, text.len * 4) catch unreachable;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
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
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

/// Normalize UTF-16 into a caller-owned buffer, matching ICU's
/// `unorm2_normalize` input and output units.
fn benchNormalizationUtf16Into(
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
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
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
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchNormalizationUtf16Alloc(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch
        unreachable;
    defer allocator.free(units);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = icuz.normalization.normalizeUtf16Alloc(
                allocator,
                units,
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
    reportBytes(name, rounds * text.len, best);
}

fn benchNormalizationUtf16Check(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch
        unreachable;
    defer allocator.free(units);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            sink +%= @intFromBool(
                icuz.normalization.isNormalizedUtf16(
                    units,
                    .nfc,
                ) catch unreachable,
            );
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

fn benchRegex(
    name: []const u8,
    pattern: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    var regex = icuz.Regex.compileAlloc(allocator, pattern, .{}) catch return;
    defer regex.deinit();
    var matcher = regex.matcher(text) catch return;
    defer matcher.deinit();

    const rounds = 2000;
    var matches: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            matcher.reset(text) catch return;
            while (matcher.find() catch return) {
                matches += 1;
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<32} {d:>8.3} us/scan ({d} matches)\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, rounds) / 1000.0,
        matches,
    });
    sink +%= matches;
}

fn benchRegexMatches(
    name: []const u8,
    pattern: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    var regex = icuz.Regex.compileAlloc(allocator, pattern, .{}) catch return;
    defer regex.deinit();
    var matcher = regex.matcher(text) catch return;
    defer matcher.deinit();

    const rounds = 20_000;
    var matched: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            if (matcher.matches() catch return) matched += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<32} {d:>8.3} ns/op ({d} matches)\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
        matched,
    });
    sink +%= matched;
}

fn benchRegexLookingAt(
    name: []const u8,
    pattern: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    var regex = icuz.Regex.compileAlloc(allocator, pattern, .{}) catch return;
    defer regex.deinit();
    var matcher = regex.matcher(text) catch return;
    defer matcher.deinit();

    const rounds = 20_000;
    var matched: usize = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            if (matcher.lookingAt() catch return) matched += 1;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<32} {d:>8.3} ns/op ({d} matches)\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
        matched,
    });
    sink +%= matched;
}

fn benchRegexCompile(
    name: []const u8,
    pattern: []const u8,
    allocator: std.mem.Allocator,
) void {
    const rounds = 2_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            var regex = icuz.Regex.compileAlloc(allocator, pattern, .{}) catch return;
            regex.deinit();
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<32} {d:>8.3} ns/op\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
    });
}

fn benchRegexMatcherCreate(
    name: []const u8,
    pattern: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
) void {
    var regex = icuz.Regex.compileAlloc(allocator, pattern, .{}) catch return;
    defer regex.deinit();
    const rounds = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = now();
        for (0..rounds) |_| {
            var matcher = regex.matcher(text) catch return;
            matcher.deinit();
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    std.debug.print("{s:<32} {d:>8.3} ns/op\n", .{
        name,
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(rounds)),
    });
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

fn benchFullCase(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
    comptime kind: enum { lower, upper },
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = switch (kind) {
                .lower => icuz.case.fullLowerAlloc(allocator, text, .{}) catch unreachable,
                .upper => icuz.case.fullUpperAlloc(allocator, text, .{}) catch unreachable,
            };
            sink +%= output.len;
            allocator.free(output);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCaseUtf16(
    name: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,
    comptime kind: enum { lower, fold },
) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch unreachable;
    defer allocator.free(units);
    var buffer = std.ArrayList(u16).empty;
    defer buffer.deinit(allocator);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
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
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchBidi(name: []const u8, text: []const u8, allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 5000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            var paragraph = icuz.bidi.resolve(
                allocator,
                text,
                .auto,
            ) catch unreachable;
            sink +%= paragraph.levels.len + paragraph.scalars.len;
            paragraph.deinit();
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
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

    const script_start = now();
    var script_set = icuz.set.fromScript(allocator, .greek) catch unreachable;
    defer script_set.deinit();
    const script_ns: u64 = @intCast(now() - script_start);
    std.debug.print("{s:<32} {d:>8.3} ms\n", .{
        "UnicodeSet build Script Greek",
        @as(f64, @floatFromInt(script_ns)) / 1_000_000.0,
    });

    const complement_start = now();
    var complement = icuz.set.parse(
        allocator,
        "[^\\p{Alphabetic}]",
    ) catch unreachable;
    defer complement.deinit();
    const complement_ns: u64 = @intCast(now() - complement_start);
    std.debug.print("{s:<32} {d:>8.3} ms\n", .{
        "UnicodeSet build complement",
        @as(f64, @floatFromInt(complement_ns)) / 1_000_000.0,
    });

    total = 0;
    best = std.math.maxInt(u64);
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (codepoints) |codepoint| {
                total += @intFromBool(complement.contains(codepoint));
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    sink +%= total;
    reportOps("UnicodeSet contains complement", rounds * codepoints.len, best);

    var small = icuz.set.parse(allocator, "[a]") catch unreachable;
    defer small.deinit();
    const small_rounds = 2000;
    var closure_best: u64 = std.math.maxInt(u64);
    for (0..trials) |_| {
        const start = now();
        for (0..small_rounds) |_| {
            small.closeOver(.simple_case_insensitive) catch unreachable;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < closure_best) closure_best = elapsed;
    }
    reportOps("UnicodeSet closeOver [a]", small_rounds, closure_best);

    const large_rounds = 200;
    var large_closure_best: u64 = std.math.maxInt(u64);
    for (0..trials) |_| {
        const start = now();
        for (0..large_rounds) |_| {
            set.closeOver(.simple_case_insensitive) catch unreachable;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < large_closure_best) large_closure_best = elapsed;
    }
    reportOps(
        "UnicodeSet closeOver Alphabetic",
        large_rounds,
        large_closure_best,
    );

    var cut = icuz.set.fromProperty(allocator, .lowercase) catch unreachable;
    defer cut.deinit();
    const difference_rounds = 200;
    var difference_best: u64 = std.math.maxInt(u64);
    for (0..trials) |_| {
        const start = now();
        for (0..difference_rounds) |_| {
            var work = set.clone(allocator) catch unreachable;
            work.subtract(cut) catch unreachable;
            sink +%= work.count();
            work.deinit();
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < difference_best) difference_best = elapsed;
    }
    reportOps("UnicodeSet difference", difference_rounds, difference_best);

    var upper_set = icuz.set.fromProperty(allocator, .uppercase) catch unreachable;
    defer upper_set.deinit();
    const upper_rounds = 200;
    var upper_best: u64 = std.math.maxInt(u64);
    for (0..trials) |_| {
        const start = now();
        for (0..upper_rounds) |_| {
            var work = upper_set.clone(allocator) catch unreachable;
            work.closeOver(.simple_case_insensitive) catch unreachable;
            sink +%= work.count();
            work.deinit();
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < upper_best) upper_best = elapsed;
    }
    reportOps("UnicodeSet closeOver Uppercase", upper_rounds, upper_best);
}

fn benchCharsetInto(
    name: []const u8,
    text: []const u8,
    from: icuz.charset.Encoding,
    to: icuz.charset.Encoding,
    allocator: std.mem.Allocator,
) void {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    output.ensureTotalCapacity(allocator, text.len * 2 + 32) catch unreachable;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            output.clearRetainingCapacity();
            icuz.charset.convertInto(
                allocator,
                text,
                from,
                to,
                &output,
                .{},
            ) catch unreachable;
            sink +%= output.items.len;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

/// Convert a UTF-8 text from `from` to `to` into a reused buffer. The rate is
/// reported per UTF-8 byte so it is comparable with the other conversion
/// rows.
fn benchConvertBetween(
    name: []const u8,
    text: []const u8,
    from: icuz.charset.Encoding,
    to: icuz.charset.Encoding,
    allocator: std.mem.Allocator,
) void {
    const units = icuz.charset.convertAlloc(
        allocator,
        text,
        .utf8,
        from,
        .{},
    ) catch unreachable;
    defer allocator.free(units);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    output.ensureTotalCapacity(allocator, text.len * 3 + 32) catch unreachable;
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            output.clearRetainingCapacity();
            icuz.charset.convertInto(
                allocator,
                units,
                from,
                to,
                &output,
                .{},
            ) catch unreachable;
            sink +%= output.items.len;
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

/// Charset detection on text encoded in `encoding`. The rate is reported per
/// UTF-8 byte so it is comparable with the other detection rows.
fn benchDetect(
    name: []const u8,
    text: []const u8,
    encoding: icuz.charset.Encoding,
    allocator: std.mem.Allocator,
) void {
    const bytes = icuz.charset.convertAlloc(
        allocator,
        text,
        .utf8,
        encoding,
        .{},
    ) catch unreachable;
    defer allocator.free(bytes);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            if (icuz.charset_detection.detect(bytes, .{})) |match| {
                sink +%= match.confidence;
                sink +%= match.name.len;
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCharName(name: []const u8, codepoints: []const u21) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (codepoints) |codepoint| {
                if (icuz.name.name(codepoint)) |value| sink +%= value.len;
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds * codepoints.len, best);
}

fn benchFindByName(name: []const u8, queries: []const []const u8) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (queries) |query| {
                if (icuz.name.findByName(query)) |codepoint| sink +%= codepoint;
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds * queries.len, best);
}

fn benchTitle(name: []const u8, text: []const u8, allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 4000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const output = icuz.case.fullTitleAlloc(
                allocator,
                text,
                .{},
            ) catch unreachable;
            sink +%= output.len;
            allocator.free(output);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchPlural(name: []const u8, locale: []const u8, comptime ordinal: bool) void {
    var best: u64 = std.math.maxInt(u64);
    const values = [_]i64{ 0, 1, 2, 3, 5, 11, 21, 100, 101, 1_000_001 };
    const trials = 5;
    const rounds = 50_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (values) |value| {
                const result = if (ordinal)
                    icuz.plural.ordinalCategoryForInteger(locale, value)
                else
                    icuz.plural.categoryForInteger(locale, value);
                sink +%= @intFromEnum(result);
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds * values.len, best);
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

fn benchCollationCollator(
    name: []const u8,
    text: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    const collator = icuz.collation.Collator.init(options);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const key = collator.sortKeyAlloc(
                allocator,
                text,
            ) catch unreachable;
            sink +%= key.len;
            allocator.free(key);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes(name, rounds * text.len, best);
}

fn benchCollationCompare(
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
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = collator.compare(
                allocator,
                a,
                b,
                &key_a,
                &key_b,
            ) catch return;
            sink +%= @intFromEnum(order);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
}

fn benchCollationCompareUtf16(
    name: []const u8,
    a: []const u8,
    b: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    const units_a = std.unicode.utf8ToUtf16LeAlloc(allocator, a) catch
        unreachable;
    defer allocator.free(units_a);
    const units_b = std.unicode.utf8ToUtf16LeAlloc(allocator, b) catch
        unreachable;
    defer allocator.free(units_b);
    const collator = icuz.collation.Collator.init(options);
    var key_a = std.ArrayList(u32).empty;
    defer key_a.deinit(allocator);
    var key_b = std.ArrayList(u32).empty;
    defer key_b.deinit(allocator);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = collator.compareUtf16AssumeValid(
                allocator,
                units_a,
                units_b,
                &key_a,
                &key_b,
            ) catch unreachable;
            sink +%= @intFromEnum(order);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
}

fn benchCollationCompareAssumeValid(
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
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = collator.compareAssumeValid(
                allocator,
                a,
                b,
                &key_a,
                &key_b,
            ) catch return;
            sink +%= @intFromEnum(order);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
}

fn benchCollationCompareAlloc(
    name: []const u8,
    a: []const u8,
    b: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 5_000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const order = icuz.collation.compare(
                allocator,
                a,
                b,
                options,
            ) catch unreachable;
            sink +%= @intFromEnum(order);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
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

fn benchNumberParse(
    name: []const u8,
    text: []const u8,
    locale: []const u8,
    options: icuz.number.ParseOptions,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 200000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const value = icuz.number.parseFloat(text, locale, options) orelse
                unreachable;
            sink +%= @intFromFloat(value);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
}

fn benchSearch(
    name: []const u8,
    text: []const u8,
    needle: []const u8,
    options: icuz.collation.Options,
    allocator: std.mem.Allocator,
) void {
    var search = icuz.search.Search.init(
        allocator,
        needle,
        options,
    ) catch unreachable;
    defer search.deinit();
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const position = search.find(text, 0) catch unreachable;
            sink +%= position orelse 0;
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

const idna_domains = [_][]const u8{
    "example.com",
    "m\u{00fc}nchen.de",
    "\u{4f8b}\u{3048}.\u{30c6}\u{30b9}\u{30c8}",
    "\u{03c0}\u{03b1}\u{03c1}\u{03ac}\u{03b4}\u{03b5}\u{03b9}\u{03b3}\u{03bc}\u{03b1}.\u{03b4}\u{03bf}\u{03ba}\u{03b9}\u{03bc}\u{03ae}",
    "\u{09ac}\u{09be}\u{0982}\u{09b2}\u{09be}.\u{09ad}\u{09be}\u{09b0}\u{09a4}",
    "xn--mnchen-3ya.de",
    "\u{043f}\u{0440}\u{0435}\u{0437}\u{0438}\u{0434}\u{0435}\u{043d}\u{0442}.\u{0440}\u{0444}",
    "\u{65e5}\u{672c}\u{8a9e}.jp",
};

const spoof_texts = [_][]const u8{
    "paypal",
    "p\u{0430}ypal",
    "\u{0391}\u{0392}\u{0393}",
    "\u{0410}\u{0412}\u{0421}",
    "l",
    "1",
    "O",
    "0",
    "rn",
    "m",
    "scope",
    "g\u{043e}\u{043e}gle",
    "micros\u{043ef}t",
    "fi",
    "fl",
};

const shape_texts = [_][]const u8{
    "\u{0627}\u{0644}\u{0633}\u{0644}\u{0627}\u{0645} \u{0639}\u{0644}\u{064a}\u{0643}\u{0645} \u{0648}\u{0631}\u{062d}\u{0645}\u{0629} \u{0627}\u{0644}\u{0644}\u{0647} \u{0648}\u{0628}\u{0631}\u{0643}\u{0627}\u{062a}\u{0647} ",
    "\u{0644}\u{0627} \u{0625}\u{0644}\u{0647} \u{0625}\u{0644}\u{0627} \u{0627}\u{0644}\u{0644}\u{0647} ",
};

fn benchShapeArabic(allocator: std.mem.Allocator) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    var bytes: usize = 0;
    for (shape_texts) |text| bytes += text.len;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (shape_texts) |text| {
                const shaped = icuz.shape.shapeArabicAlloc(
                    allocator,
                    text,
                    .{ .letters = .shape },
                ) catch unreachable;
                sink +%= shaped.len;
                allocator.free(shaped);
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes("Arabic shaping", rounds * bytes, best);
}

fn benchShapeArabicUtf16(allocator: std.mem.Allocator) void {
    var units_list: [shape_texts.len][]u16 = undefined;
    var bytes: usize = 0;
    for (shape_texts, 0..) |text, index| {
        units_list[index] = std.unicode.utf8ToUtf16LeAlloc(
            allocator,
            text,
        ) catch unreachable;
        bytes += text.len;
    }
    defer for (units_list) |units| allocator.free(units);
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (units_list) |units| {
                const shaped = icuz.shape.shapeArabicUtf16Alloc(
                    allocator,
                    units,
                    .{ .letters = .shape },
                ) catch unreachable;
                sink +%= shaped.len;
                allocator.free(shaped);
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportBytes("Arabic shaping (utf16)", rounds * bytes, best);
}

fn benchSpoofSkeleton(allocator: std.mem.Allocator) void {
    var checker = icuz.spoof.Checker.init();
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (spoof_texts) |text| {
                const skeleton = checker.bidiSkeletonAlloc(
                    allocator,
                    text,
                    .ltr,
                ) catch unreachable;
                sink +%= skeleton.len;
                allocator.free(skeleton);
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps("spoof bidi skeleton", rounds * spoof_texts.len, best);
}

fn benchIdna(
    name: []const u8,
    ascii: bool,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 2000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            for (idna_domains) |domain| {
                const result = if (ascii)
                    icuz.idna.toAsciiResultAlloc(allocator, domain, .{})
                else
                    icuz.idna.toUnicodeResultAlloc(allocator, domain, .{});
                const value = result catch unreachable;
                sink +%= value.text.len;
                allocator.free(value.text);
            }
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds * idna_domains.len, best);
}

fn benchLocaleCanonicalize(
    name: []const u8,
    tag: []const u8,
    allocator: std.mem.Allocator,
) void {
    var best: u64 = std.math.maxInt(u64);
    const trials = 5;
    const rounds = 20000;
    for (0..trials) |_| {
        const start = now();
        for (0..rounds) |_| {
            const result = icuz.locale.canonicalizeAlloc(
                allocator,
                tag,
            ) catch unreachable;
            sink +%= result.len;
            allocator.free(result);
        }
        const elapsed: u64 = @intCast(now() - start);
        if (elapsed < best) best = elapsed;
    }
    reportOps(name, rounds, best);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

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
    const accents_runtime = try allocator.dupe(u8, accents_text);
    const japanese_runtime = try allocator.dupe(u8, japanese_text);
    const korean_runtime = try allocator.dupe(u8, korean_text);
    const gbk_runtime = try icuz.charset.encodeAlloc(
        allocator,
        chinese_text,
        .gbk,
        .{},
    );
    const swedish_runtime = try allocator.dupe(u8, swedish_text);
    const mixed_compare_runtime = try allocator.dupe(u8, mixed_text);
    // Mutate near the end so the comparison cannot stop early.
    mixed_compare_runtime[mixed_compare_runtime.len - 3] = 'u';
    const mixed_early_runtime = try allocator.dupe(u8, mixed_text);
    mixed_early_runtime[0] = 'Z';
    const chinese_collation_long_compare_runtime = try allocator.dupe(
        u8,
        chinese_collation_text ** 32,
    );
    // Change the last Han scalar's final byte, keeping valid UTF-8.
    chinese_collation_long_compare_runtime[
        chinese_collation_long_compare_runtime.len - 1
    ] = 0xb4;
    const swedish_compare_runtime = try allocator.dupe(u8, swedish_text);
    const german_runtime = try allocator.dupe(u8, german_text);
    const chinese_collation_runtime = try allocator.dupe(u8, chinese_collation_text);
    const chinese_collation_long_runtime = try allocator.dupe(
        u8,
        chinese_collation_text ** 32,
    );
    const fullwidth_runtime = try allocator.dupe(u8, fullwidth_text);
    const georgian_runtime = try allocator.dupe(u8, georgian_text);
    const russian_runtime = try allocator.dupe(u8, russian_text);
    const greek_runtime = try allocator.dupe(u8, greek_text);
    const greek_case_runtime = try allocator.dupe(u8, greek_case_text);
    const katakana_runtime = try allocator.dupe(u8, katakana_text);
    const amharic_runtime = try allocator.dupe(u8, amharic_text);
    const ukrainian_runtime = try allocator.dupe(u8, ukrainian_text);
    const thai_word_runtime = try allocator.dupe(u8, thai_word_text);
    const cjk_word_runtime = try allocator.dupe(u8, cjk_word_text);
    const rtl_runtime = try allocator.dupe(u8, rtl_text);
    std.mem.doNotOptimizeAway(ascii_runtime.ptr);
    std.mem.doNotOptimizeAway(mixed_runtime.ptr);
    std.mem.doNotOptimizeAway(chinese_runtime.ptr);
    std.mem.doNotOptimizeAway(japanese_runtime.ptr);
    std.mem.doNotOptimizeAway(korean_runtime.ptr);
    std.mem.doNotOptimizeAway(gbk_runtime.ptr);
    std.mem.doNotOptimizeAway(swedish_runtime.ptr);
    std.mem.doNotOptimizeAway(mixed_compare_runtime.ptr);
    std.mem.doNotOptimizeAway(swedish_compare_runtime.ptr);
    std.mem.doNotOptimizeAway(mixed_early_runtime.ptr);
    std.mem.doNotOptimizeAway(chinese_collation_long_compare_runtime.ptr);
    std.mem.doNotOptimizeAway(german_runtime.ptr);
    std.mem.doNotOptimizeAway(chinese_collation_runtime.ptr);
    std.mem.doNotOptimizeAway(chinese_collation_long_runtime.ptr);
    std.mem.doNotOptimizeAway(fullwidth_runtime.ptr);
    std.mem.doNotOptimizeAway(georgian_runtime.ptr);
    std.mem.doNotOptimizeAway(russian_runtime.ptr);
    std.mem.doNotOptimizeAway(greek_runtime.ptr);
    std.mem.doNotOptimizeAway(greek_case_runtime.ptr);
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
    benchCollation(
        "UCA sort key Chinese stroke",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "stroke" },
        allocator,
    );
    benchCollation(
        "UCA sort key Chinese zhuyin",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "zhuyin" },
        allocator,
    );
    benchCollation(
        "UCA sort key Chinese long",
        chinese_collation_long_runtime,
        .{},
        allocator,
    );
    benchCollation(
        "UCA sort key Chinese long pinyin",
        chinese_collation_long_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );
    benchCollationCodepoints(
        "UCA sort key ASCII (cp)",
        ascii_runtime,
        .{},
        allocator,
    );
    benchCollationCodepoints(
        "UCA sort key mixed (cp)",
        mixed_runtime,
        .{},
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
    benchCollationCodepoints(
        "UCA sort key Swedish root (cp)",
        swedish_runtime,
        .{},
        allocator,
    );
    benchCollationInto(
        "UCA sort key ASCII (reuse)",
        ascii_runtime,
        .{},
        allocator,
    );
    benchCollationInto(
        "UCA sort key mixed (reuse)",
        mixed_runtime,
        .{},
        allocator,
    );
    benchCollationInto(
        "UCA sort key German phonebook (reuse)",
        german_runtime,
        .{ .locale = "de", .collation = "phonebook" },
        allocator,
    );
    benchCollationInto(
        "UCA sort key Swedish (reuse)",
        swedish_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationInto(
        "UCA sort key Chinese pinyin (reuse)",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );
    benchCollationInto(
        "UCA sort key Chinese long (reuse)",
        chinese_collation_long_runtime,
        .{},
        allocator,
    );
    benchCollationInto(
        "UCA sort key Chinese long pinyin (reuse)",
        chinese_collation_long_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );
    benchCollationUtf16(
        "UCA sort key Chinese pinyin (utf16)",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );
    benchCollationUtf16(
        "UCA sort key mixed (utf16)",
        mixed_runtime,
        .{},
        allocator,
    );
    benchCollationUtf16(
        "UCA sort key Swedish (utf16)",
        swedish_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationCollator(
        "UCA sort key Swedish (collator)",
        swedish_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationCompare(
        "UCA compare mixed",
        mixed_runtime,
        mixed_compare_runtime,
        .{},
        allocator,
    );
    benchCollationCompare(
        "UCA compare Swedish",
        swedish_runtime,
        swedish_compare_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationCompareAlloc(
        "UCA compare mixed (alloc)",
        mixed_runtime,
        mixed_compare_runtime,
        .{},
        allocator,
    );
    benchCollationCompare(
        "UCA compare mixed early",
        mixed_runtime,
        mixed_early_runtime,
        .{},
        allocator,
    );
    benchCollationCompare(
        "UCA compare Chinese long",
        chinese_collation_long_runtime,
        chinese_collation_long_compare_runtime,
        .{},
        allocator,
    );
    benchCollationCompareAssumeValid(
        "UCA compare mixed (assume valid)",
        mixed_runtime,
        mixed_compare_runtime,
        .{},
        allocator,
    );
    benchCollationCompareAssumeValid(
        "UCA compare mixed early (assume valid)",
        mixed_runtime,
        mixed_early_runtime,
        .{},
        allocator,
    );
    benchCollationCompareAssumeValid(
        "UCA compare Chinese long (assume valid)",
        chinese_collation_long_runtime,
        chinese_collation_long_compare_runtime,
        .{},
        allocator,
    );
    benchCollationCompareAssumeValid(
        "UCA compare Swedish (assume valid)",
        swedish_runtime,
        swedish_compare_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationCompareUtf16(
        "UCA compare mixed (utf16)",
        mixed_runtime,
        mixed_compare_runtime,
        .{},
        allocator,
    );
    benchCollationCompareUtf16(
        "UCA compare mixed early (utf16)",
        mixed_runtime,
        mixed_early_runtime,
        .{},
        allocator,
    );
    benchCollationCompareUtf16(
        "UCA compare Swedish (utf16)",
        swedish_runtime,
        swedish_compare_runtime,
        .{ .locale = "sv" },
        allocator,
    );
    benchCollationCollator(
        "UCA sort key Chinese pinyin (collator)",
        chinese_collation_runtime,
        .{ .locale = "zh", .collation = "pinyin" },
        allocator,
    );

    std.debug.print("\n-- charset conversion --\n", .{});
    benchCharset(
        "UTF-8 -> UTF-16LE ASCII (alloc)",
        ascii_runtime,
        .utf8,
        .utf16_le,
        allocator,
    );
    benchCharsetInto(
        "UTF-8 -> UTF-16LE ASCII",
        ascii_runtime,
        .utf8,
        .utf16_le,
        allocator,
    );
    benchCharsetInto(
        "UTF-8 -> UTF-16LE Chinese",
        chinese_runtime,
        .utf8,
        .utf16_le,
        allocator,
    );
    benchConvertBetween("UTF-16LE -> UTF-8 ASCII", ascii_runtime, .utf16_le, .utf8, allocator);
    benchConvertBetween("UTF-16LE -> UTF-8 Chinese", chinese_runtime, .utf16_le, .utf8, allocator);
    benchCharsetInto(
        "UTF-8 -> UTF-32LE ASCII",
        ascii_runtime,
        .utf8,
        .utf32_le,
        allocator,
    );
    benchCharsetInto(
        "UTF-8 -> UTF-32LE Chinese",
        chinese_runtime,
        .utf8,
        .utf32_le,
        allocator,
    );
    benchConvertBetween("UTF-32LE -> UTF-8 ASCII", ascii_runtime, .utf32_le, .utf8, allocator);
    benchConvertBetween("UTF-32LE -> UTF-8 Chinese", chinese_runtime, .utf32_le, .utf8, allocator);
    benchConvertBetween(
        "UTF-16LE -> UTF-32LE ASCII",
        ascii_runtime,
        .utf16_le,
        .utf32_le,
        allocator,
    );
    benchConvertBetween(
        "UTF-16LE -> UTF-32LE Chinese",
        chinese_runtime,
        .utf16_le,
        .utf32_le,
        allocator,
    );
    benchConvertBetween(
        "UTF-32LE -> UTF-16LE ASCII",
        ascii_runtime,
        .utf32_le,
        .utf16_le,
        allocator,
    );
    benchConvertBetween(
        "UTF-32LE -> UTF-16LE Chinese",
        chinese_runtime,
        .utf32_le,
        .utf16_le,
        allocator,
    );
    benchConvertBetween(
        "windows-1252 -> UTF-8 accents",
        accents_runtime,
        .windows_1252,
        .utf8,
        allocator,
    );
    benchConvertBetween(
        "UTF-8 -> windows-1252 accents",
        accents_runtime,
        .utf8,
        .windows_1252,
        allocator,
    );
    benchConvertBetween(
        "IBM866 -> UTF-8 Russian",
        russian_runtime,
        .ibm866,
        .utf8,
        allocator,
    );
    benchConvertBetween(
        "GBK -> UTF-16LE Chinese",
        chinese_runtime,
        .gbk,
        .utf16_le,
        allocator,
    );
    benchConvertBetween(
        "UTF-16LE -> GBK Chinese",
        chinese_runtime,
        .utf16_le,
        .gbk,
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
    benchNumberParse("parse decimal", "1,234,567.89", "en", .{});
    benchNumberParse("parse decimal de", "1.234.567,89", "de", .{});
    benchSearch("search word", ascii_runtime, "fox", .{ .strength = .primary }, allocator);
    benchSearch("search missing", ascii_runtime, "wombat", .{ .strength = .primary }, allocator);
    benchSearch(
        "search Swedish",
        swedish_runtime,
        "\u{00e4}lskar",
        .{ .strength = .primary, .locale = "sv" },
        allocator,
    );
    benchSearch(
        "search missing Swedish",
        swedish_runtime,
        "wombat",
        .{ .strength = .primary, .locale = "sv" },
        allocator,
    );
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
        "currency standard",
        1234.5,
        .{ .style = .currency, .currency = "USD" },
        allocator,
    );
    benchNumber(
        "accounting currency",
        -1234.5,
        .{ .style = .currency, .currency = "USD", .accounting = true },
        allocator,
    );
    benchSkeleton(allocator);

    std.debug.print("\n-- locale tags --\n", .{});
    benchLocaleCanonicalize("canonicalize en-US", "en-US", allocator);
    benchLocaleCanonicalize("canonicalize zh-hant-tw", "zh-hant-tw", allocator);
    benchLocaleCanonicalize("canonicalize sh-RS", "sh-RS", allocator);
    benchLocaleCanonicalize("canonicalize sr-Latn-RS", "sr-Latn-RS", allocator);

    std.debug.print("\n-- shaping --\n", .{});
    benchShapeArabic(allocator);
    benchShapeArabicUtf16(allocator);

    std.debug.print("\n-- spoof --\n", .{});
    benchSpoofSkeleton(allocator);

    std.debug.print("\n-- idna --\n", .{});
    benchIdna("idna toASCII", true, allocator);
    benchIdna("idna toUnicode", false, allocator);

    std.debug.print("\n-- locale formatting --\n", .{});
    benchList(allocator);
    benchRelative(allocator);
    benchUnits(allocator);
    benchDate(allocator);

    std.debug.print("\n-- charset detection --\n", .{});
    benchDetect("detect UTF-8 English", ascii_runtime, .utf8, allocator);
    benchDetect("detect GBK Chinese", chinese_runtime, .gbk, allocator);

    std.debug.print("\n-- character names --\n", .{});
    benchCharName("char name", &[_]u21{
        0x41, 0xe9,    0x20ac,  0x3a9,   0x4e16, 0x3042, 0xac00, 0x1f600,
        0x30, 0x1d160, 0x2f800, 0x10400, 0x9fff, 0x0e33, 0x0f73, 0x0344,
    });
    benchFindByName("find by name", &[_][]const u8{
        "LATIN CAPITAL LETTER A",
        "LATIN SMALL LETTER E WITH ACUTE",
        "EURO SIGN",
        "GREEK CAPITAL LETTER OMEGA",
        "CJK UNIFIED IDEOGRAPH-4E16",
        "HIRAGANA LETTER A",
        "HANGUL SYLLABLE GA",
        "MATHEMATICAL BOLD CAPITAL A",
        "CJK COMPATIBILITY IDEOGRAPH-2F800",
        "DESERET CAPITAL LETTER LONG I",
    });

    std.debug.print("\n-- title casing --\n", .{});
    benchTitle("title ASCII", ascii_runtime, allocator);
    benchTitle("title mixed", mixed_runtime, allocator);
    benchTitle("title German", german_runtime, allocator);

    std.debug.print("\n-- plural rules --\n", .{});
    benchPlural("plural en", "en", false);
    benchPlural("plural ru", "ru", false);
    benchPlural("ordinal en", "en", true);

    std.debug.print("\n-- bidi --\n", .{});
    benchBidi("bidi ASCII", ascii_runtime, allocator);
    benchBidi("bidi mixed", mixed_runtime, allocator);
    benchBidi("bidi RTL", rtl_runtime, allocator);

    std.debug.print("\n-- regular expressions --\n", .{});
    benchRegex(
        "literal find",
        "needle",
        "some text before needle and after needle " ** 8,
        allocator,
    );
    benchRegex(
        "class find",
        "[0-9]{3}-[0-9]{4}",
        "call 555-1234 or 555-9876 for details " ** 8,
        allocator,
    );
    benchRegex(
        "case-insensitive find",
        "(?i)needle",
        "some text before Needle and after NEEDLE " ** 8,
        allocator,
    );
    benchRegex(
        "required literal miss",
        ".*needle",
        "some text without the required token " ** 8,
        allocator,
    );
    benchRegex(
        "literal alternation find",
        "needle|pin",
        "some text with needle or pin in it " ** 8,
        allocator,
    );
    benchRegexMatches(
        "literal matches",
        "needle",
        "needle",
        allocator,
    );
    benchRegexMatches(
        "literal matches miss",
        "needle",
        "some other text",
        allocator,
    );
    benchRegexMatches(
        "class matches miss",
        "[0-9]+",
        "abcdef",
        allocator,
    );
    benchRegexLookingAt(
        "literal lookingAt",
        "needle",
        "needle and more",
        allocator,
    );
    benchRegexLookingAt(
        "literal lookingAt miss",
        "needle",
        "some other text",
        allocator,
    );
    benchRegexCompile("compile literal", "needle", allocator);
    benchRegexCompile("compile class", "[0-9]{3}-[0-9]{4}", allocator);
    benchRegexCompile("compile alternation", "needle|pin", allocator);
    benchRegexCompile("compile lookbehind", "(?<=x)abc", allocator);
    benchRegexCompile("compile word boundary", "\\bneedle\\b", allocator);
    benchRegexCompile("compile word class", "\\w+needle", allocator);
    benchRegexMatcherCreate(
        "matcher create",
        "needle",
        "some text before needle and after needle " ** 8,
        allocator,
    );
    benchRegexMatcherCreate(
        "matcher create class",
        "[0-9]{3}-[0-9]{4}",
        "call 555-1234 for details",
        allocator,
    );

    std.debug.print("\n-- segmentation --\n", .{});
    benchGraphemes("grapheme ASCII", ascii_runtime);
    benchGraphemes("grapheme mixed", mixed_runtime);
    benchWords("word ASCII", ascii_runtime);
    benchWords("word mixed", mixed_runtime);
    benchDictionaryWords("word Thai dictionary", thai_word_runtime);
    benchDictionaryWords("word CJK dictionary", cjk_word_runtime);
    benchLines("line break ASCII", ascii_runtime);
    benchLines("line break mixed", mixed_runtime);
    benchLines("line break Chinese", "你好，世界！" ** 8);
    benchLines("line break e+marks", "e\u{0301}\u{0323} " ** 16);
    benchLines("line break jamo", "\u{1100}\u{1161}\u{11a8} " ** 12);
    benchSentences("sentence ASCII", ascii_runtime);
    benchSentences("sentence mixed", mixed_runtime);

    std.debug.print("\n-- normalization and case --\n", .{});
    benchNormalization("isNormalized ASCII", ascii_runtime, allocator, true);
    benchNormalization("isNormalized mixed", mixed_runtime, allocator, true);
    benchNormalization("NFC ASCII", ascii_runtime, allocator, false);
    benchNormalization("isNormalized Chinese", chinese_runtime, allocator, true);
    benchNormalization("NFC Chinese", chinese_runtime, allocator, false);
    benchNormalization("NFC mixed", mixed_runtime, allocator, false);
    benchNormalizationInto("NFC mixed (reuse)", mixed_runtime, allocator);
    benchNormalizationInto("NFC Chinese (reuse)", chinese_runtime, allocator);
    benchNormalization(
        "NFC precomposed",
        "\u{00e9} \u{00ef} \u{00df} \u{4e16}\u{754c} " ** 8,
        allocator,
        false,
    );
    benchNormalization(
        "NFC e+marks",
        "e\u{0301}\u{0323} " ** 16,
        allocator,
        false,
    );
    benchNormalizationInto(
        "NFC e+marks (reuse)",
        "e\u{0301}\u{0323} " ** 16,
        allocator,
    );
    benchNormalization(
        "NFC Japanese",
        "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}\u{3002}\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{5b57}\u{30b3}\u{30fc}\u{30c9}\u{5909}\u{63db}\u{3002}" ** 8,
        allocator,
        false,
    );
    benchNormalizationInto(
        "NFC Japanese (reuse)",
        "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}\u{3002}\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{5b57}\u{30b3}\u{30fc}\u{30c9}\u{5909}\u{63db}\u{3002}" ** 8,
        allocator,
    );
    benchNormalizationUtf16Into(
        "NFC Japanese (utf16 reuse)",
        "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}\u{3002}\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{5b57}\u{30b3}\u{30fc}\u{30c9}\u{5909}\u{63db}\u{3002}" ** 8,
        allocator,
    );
    benchNormalization(
        "NFC jamo",
        "\u{1100}\u{1161}\u{11a8} " ** 12,
        allocator,
        false,
    );
    benchNormalizationInto(
        "NFC jamo (reuse)",
        "\u{1100}\u{1161}\u{11a8} " ** 12,
        allocator,
    );
    benchNormalizationUtf16Into("NFC mixed (utf16 reuse)", mixed_runtime, allocator);
    benchNormalizationUtf16Alloc("NFC mixed (utf16)", mixed_runtime, allocator);
    benchNormalizationUtf16Alloc(
        "NFC Japanese (utf16)",
        "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}\u{3002}\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{5b57}\u{30b3}\u{30fc}\u{30c9}\u{5909}\u{63db}\u{3002}" ** 8,
        allocator,
    );
    benchNormalizationUtf16Into(
        "NFC e+marks (utf16 reuse)",
        "e\u{0301}\u{0323} " ** 16,
        allocator,
    );
    benchNormalizationUtf16Into(
        "NFC jamo (utf16 reuse)",
        "\u{1100}\u{1161}\u{11a8} " ** 12,
        allocator,
    );
    benchNormalizationUtf16Into(
        "NFC Chinese (utf16 reuse)",
        chinese_runtime,
        allocator,
    );
    benchNormalizationUtf16Check("isNormalized mixed (utf16)", mixed_runtime, allocator);
    benchNormalizationUtf16Check(
        "isNormalized e+marks (utf16)",
        "e\u{0301}\u{0323} " ** 16,
        allocator,
    );
    benchNormalizationUtf16Check(
        "isNormalized Chinese (utf16)",
        chinese_runtime,
        allocator,
    );
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
    benchCase("lower mixed", mixed_runtime, allocator);
    benchFold("case fold mixed", mixed_runtime, allocator);
    benchFullCase("full lower ASCII", ascii_runtime, allocator, .lower);
    benchFullCase("full upper ASCII", ascii_runtime, allocator, .upper);
    benchFullCase("full lower mixed", mixed_runtime, allocator, .lower);
    benchFullCase("full upper mixed", mixed_runtime, allocator, .upper);
    benchFullCase("full lower German", german_runtime, allocator, .lower);
    benchFullCase("full upper German", german_runtime, allocator, .upper);
    benchFullCase("full lower Greek sigma", greek_case_runtime, allocator, .lower);
    benchCaseUtf16("lower mixed (utf16)", mixed_runtime, allocator, .lower);
    benchCaseUtf16(
        "case fold mixed (utf16)",
        mixed_runtime,
        allocator,
        .fold,
    );
    benchCaseUtf16("lower ASCII (utf16)", ascii_runtime, allocator, .lower);

    std.debug.print("\nsink={d}\n", .{sink});
}
