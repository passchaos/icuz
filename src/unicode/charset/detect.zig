//! ICU-compatible charset detection (`ucsdet`).
//!
//! The recognizers and confidence heuristics mirror ICU's `csrutf8`,
//! `csrucode`, `csrsbcs`, `csrmbcs`, and `csr2022` implementations. The
//! statistical tables in `detect_tables.zig` are generated from ICU's
//! recognizer sources.

const std = @import("std");
const tables = @import("detect_tables.zig");
const charset = @import("../charset.zig");

pub const Match = struct {
    name: []const u8,
    confidence: u8,
    language: []const u8 = "",
};

pub const Options = struct {
    /// Remove HTML/XML markup before detection, like ICU's input filter.
    strip_tags: bool = false,
    /// Include ICU's legacy IBM420/IBM424 recognizers (disabled by default).
    legacy_recognizers: bool = true,
};

pub const Error = error{OutOfMemory};

const buffer_size = 8192;

const Input = struct {
    raw: []const u8,
    bytes: []const u8,
    c1_bytes: bool,
};

fn prepareInput(
    text: []const u8,
    strip_tags: bool,
    storage: *[buffer_size]u8,
) Input {
    var length: usize = 0;
    if (strip_tags) {
        var in_markup = false;
        var open_tags: usize = 0;
        var bad_tags: usize = 0;
        for (text) |byte| {
            if (length >= buffer_size) break;
            if (byte == '<') {
                if (in_markup) bad_tags += 1;
                in_markup = true;
                open_tags += 1;
            }
            if (!in_markup) {
                storage[length] = byte;
                length += 1;
            }
            if (byte == '>') in_markup = false;
        }
        if (open_tags < 5 or open_tags / 5 < bad_tags or
            (length < 100 and text.len > 600))
        {
            length = @min(text.len, buffer_size);
            @memcpy(storage[0..length], text[0..length]);
        }
    } else {
        length = @min(text.len, buffer_size);
        @memcpy(storage[0..length], text[0..length]);
    }
    var c1 = false;
    for (storage[0..length]) |byte| {
        if (byte >= 0x80 and byte <= 0x9f) {
            c1 = true;
            break;
        }
    }
    return .{ .raw = text, .bytes = storage[0..length], .c1_bytes = c1 };
}

/// Detect all matching charsets, sorted by descending confidence.
pub fn detectAll(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) Error![]Match {
    var storage: [buffer_size]u8 = undefined;
    const input = prepareInput(text, options.strip_tags, &storage);
    var matches: [32]Match = undefined;
    const count = runRecognizers(&input, options, &matches);
    const result = try allocator.alloc(Match, count);
    @memcpy(result, matches[0..count]);
    return result;
}

/// Best charset match, or null when no recognizer accepts the input.
pub fn detect(text: []const u8, options: Options) ?Match {
    var storage: [buffer_size]u8 = undefined;
    const input = prepareInput(text, options.strip_tags, &storage);
    var matches: [32]Match = undefined;
    const count = runRecognizers(&input, options, &matches);
    if (count == 0) return null;
    return matches[0];
}

fn runRecognizers(
    input: *const Input,
    options: Options,
    matches: *[32]Match,
) usize {
    var count: usize = 0;
    count += add(matches, count, recognizeUtf8(input));
    count += add(matches, count, recognizeUtf16(input, true));
    count += add(matches, count, recognizeUtf16(input, false));
    count += add(matches, count, recognizeUtf32(input, true));
    count += add(matches, count, recognizeUtf32(input, false));
    count += add(matches, count, recognize8859_1(input));
    count += add(matches, count, recognize8859_2(input));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = "ISO-8859-5",
        .language = "ru",
        .ngrams = &tables.ngrams_8859_5_ru,
        .map = &tables.charMap_8859_5,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = "ISO-8859-6",
        .language = "ar",
        .ngrams = &tables.ngrams_8859_6_ar,
        .map = &tables.charMap_8859_6,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = if (input.c1_bytes) "windows-1253" else "ISO-8859-7",
        .language = "el",
        .ngrams = &tables.ngrams_8859_7_el,
        .map = &tables.charMap_8859_7,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = if (input.c1_bytes) "windows-1255" else "ISO-8859-8-I",
        .language = "he",
        .ngrams = &tables.ngrams_8859_8_I_he,
        .map = &tables.charMap_8859_8,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = if (input.c1_bytes) "windows-1255" else "ISO-8859-8",
        .language = "he",
        .ngrams = &tables.ngrams_8859_8_he,
        .map = &tables.charMap_8859_8,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = "windows-1251",
        .language = "ru",
        .ngrams = &tables.ngrams_windows_1251,
        .map = &tables.charMap_windows_1251,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = "windows-1256",
        .language = "ar",
        .ngrams = &tables.ngrams_windows_1256,
        .map = &tables.charMap_windows_1256,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = "KOI8-R",
        .language = "ru",
        .ngrams = &tables.ngrams_KOI8_R,
        .map = &tables.charMap_KOI8_R,
    }));
    count += add(matches, count, recognizeSbcs(input, .{
        .name = if (input.c1_bytes) "windows-1254" else "ISO-8859-9",
        .language = "tr",
        .ngrams = &tables.ngrams_8859_9_tr,
        .map = &tables.charMap_8859_9,
    }));
    count += add(matches, count, recognizeSjis(input));
    count += add(matches, count, recognizeGb18030(input));
    count += add(matches, count, recognizeEucJp(input));
    count += add(matches, count, recognizeEucKr(input));
    count += add(matches, count, recognizeBig5(input));
    count += add(matches, count, recognize2022(input, .jp));
    count += add(matches, count, recognize2022(input, .kr));
    count += add(matches, count, recognize2022(input, .cn));
    if (options.legacy_recognizers) {
        count += add(matches, count, recognizeIbm424(input, true));
        count += add(matches, count, recognizeIbm424(input, false));
        count += add(matches, count, recognizeIbm420(input, true));
        count += add(matches, count, recognizeIbm420(input, false));
    }
    stableSortByConfidence(matches[0..count]);
    return count;
}

fn add(matches: *[32]Match, count: usize, match: ?Match) usize {
    if (match) |value| {
        if (count < matches.len) {
            matches[count] = value;
            return 1;
        }
    }
    return 0;
}

fn stableSortByConfidence(matches: []Match) void {
    var index: usize = 1;
    while (index < matches.len) : (index += 1) {
        const value = matches[index];
        var position = index;
        while (position > 0 and
            matches[position - 1].confidence < value.confidence)
        {
            matches[position] = matches[position - 1];
            position -= 1;
        }
        matches[position] = value;
    }
}

fn recognizeUtf8(input: *const Input) ?Match {
    const bytes = input.raw;
    var has_bom = false;
    if (bytes.len >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and
        bytes[2] == 0xbf)
    {
        has_bom = true;
    }
    var valid: i32 = 0;
    var invalid: i32 = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte & 0x80 == 0) continue;
        var trail: u8 = 0;
        if (byte & 0xe0 == 0xc0) {
            trail = 1;
        } else if (byte & 0xf0 == 0xe0) {
            trail = 2;
        } else if (byte & 0xf8 == 0xf0) {
            trail = 3;
        } else {
            invalid += 1;
            continue;
        }
        while (true) {
            index += 1;
            if (index >= bytes.len) break;
            if (bytes[index] & 0xc0 != 0x80) {
                invalid += 1;
                break;
            }
            trail -= 1;
            if (trail == 0) {
                valid += 1;
                break;
            }
        }
    }
    const confidence: i32 = if (has_bom and invalid == 0)
        100
    else if (has_bom and valid > invalid * 10)
        80
    else if (valid > 3 and invalid == 0)
        100
    else if (valid > 0 and invalid == 0)
        80
    else if (valid == 0 and invalid == 0)
        15
    else if (valid > invalid * 10)
        25
    else
        0;
    if (confidence <= 0) return null;
    return .{ .name = "UTF-8", .confidence = @intCast(confidence) };
}

fn recognizeUtf16(input: *const Input, big_endian: bool) ?Match {
    const bytes = input.raw;
    var confidence: i32 = 10;
    const to_check = @min(bytes.len, 30);
    var index: usize = 0;
    while (index + 1 < to_check) : (index += 2) {
        const unit: u16 = if (big_endian)
            (@as(u16, bytes[index]) << 8) | bytes[index + 1]
        else
            @as(u16, bytes[index]) | (@as(u16, bytes[index + 1]) << 8);
        if (index == 0 and unit == 0xfeff) {
            confidence = 100;
            if (!big_endian and bytes.len >= 4 and
                bytes[2] == 0 and bytes[3] == 0)
            {
                confidence = 0;
            }
            break;
        }
        if (unit == 0) {
            confidence -= 10;
        } else if ((unit >= 0x20 and unit <= 0xff) or unit == 0x0a) {
            confidence += 10;
        }
        confidence = std.math.clamp(confidence, 0, 100);
        if (confidence == 0 or confidence == 100) break;
    }
    if (to_check < 4 and confidence < 100) confidence = 0;
    if (confidence <= 0) return null;
    return .{
        .name = if (big_endian) "UTF-16BE" else "UTF-16LE",
        .confidence = @intCast(confidence),
    };
}

fn recognizeUtf32(input: *const Input, big_endian: bool) ?Match {
    const bytes = input.raw;
    const limit = (bytes.len / 4) * 4;
    var has_bom = false;
    if (limit > 0 and readUtf32(bytes, 0, big_endian) == 0xfeff) {
        has_bom = true;
    }
    var valid: i32 = 0;
    var invalid: i32 = 0;
    var index: usize = 0;
    while (index < limit) : (index += 4) {
        const codepoint = readUtf32(bytes, index, big_endian);
        if (codepoint < 0 or codepoint >= 0x10ffff or
            (codepoint >= 0xd800 and codepoint <= 0xdfff))
        {
            invalid += 1;
        } else {
            valid += 1;
        }
    }
    const confidence: i32 = if (has_bom and invalid == 0)
        100
    else if (has_bom and valid > invalid * 10)
        80
    else if (valid > 3 and invalid == 0)
        100
    else if (valid > 0 and invalid == 0)
        80
    else if (valid > invalid * 10)
        25
    else
        0;
    if (confidence <= 0) return null;
    return .{
        .name = if (big_endian) "UTF-32BE" else "UTF-32LE",
        .confidence = @intCast(confidence),
    };
}

fn readUtf32(bytes: []const u8, index: usize, big_endian: bool) i32 {
    if (big_endian) {
        return @as(i32, @bitCast(
            (@as(u32, bytes[index]) << 24) |
                (@as(u32, bytes[index + 1]) << 16) |
                (@as(u32, bytes[index + 2]) << 8) |
                bytes[index + 3],
        ));
    }
    return @as(i32, @bitCast(
        (@as(u32, bytes[index + 3]) << 24) |
            (@as(u32, bytes[index + 2]) << 16) |
            (@as(u32, bytes[index + 1]) << 8) |
            bytes[index],
    ));
}

const SbcsSpec = struct {
    name: []const u8,
    language: []const u8,
    ngrams: []const i32,
    map: *const [256]u8,
};

fn recognizeSbcs(input: *const Input, spec: SbcsSpec) ?Match {
    const confidence = matchSbcs(input, spec.ngrams, spec.map);
    if (confidence <= 0) return null;
    return .{
        .name = spec.name,
        .confidence = @intCast(confidence),
        .language = spec.language,
    };
}

fn recognize8859_1(input: *const Input) ?Match {
    const name = if (input.c1_bytes) "windows-1252" else "ISO-8859-1";
    var best: i32 = -1;
    var language: []const u8 = "";
    for (tables.ngrams_8859_1) |entry| {
        const confidence = matchSbcs(
            input,
            entry.ngrams,
            &tables.charMap_8859_1,
        );
        if (confidence > best) {
            best = confidence;
            language = entry.language;
        }
    }
    if (best <= 0) return null;
    return .{ .name = name, .confidence = @intCast(best), .language = language };
}

fn recognize8859_2(input: *const Input) ?Match {
    const name = if (input.c1_bytes) "windows-1250" else "ISO-8859-2";
    var best: i32 = -1;
    var language: []const u8 = "";
    for (tables.ngrams_8859_2) |entry| {
        const confidence = matchSbcs(
            input,
            entry.ngrams,
            &tables.charMap_8859_2,
        );
        if (confidence > best) {
            best = confidence;
            language = entry.language;
        }
    }
    if (best <= 0) return null;
    return .{ .name = name, .confidence = @intCast(best), .language = language };
}

fn matchSbcs(
    input: *const Input,
    ngrams: []const i32,
    byte_map: *const [256]u8,
) i32 {
    var ngram: u32 = 0;
    var ngram_count: i32 = 0;
    var hit_count: i32 = 0;
    var ignore_space = false;
    for (input.bytes) |byte| {
        const mapped = byte_map[byte];
        if (mapped == 0) continue;
        if (!(mapped == 0x20 and ignore_space)) {
            ngram = ((ngram << 8) + mapped) & 0xffffff;
            ngram_count += 1;
            if (searchNgram(ngrams, ngram)) hit_count += 1;
        }
        ignore_space = mapped == 0x20;
    }
    ngram = ((ngram << 8) + 0x20) & 0xffffff;
    ngram_count += 1;
    if (searchNgram(ngrams, ngram)) hit_count += 1;
    if (ngram_count == 0) return 0;
    const percent = @as(f64, @floatFromInt(hit_count)) /
        @as(f64, @floatFromInt(ngram_count));
    if (percent > 0.33) return 98;
    return @intFromFloat(percent * 300.0);
}

fn searchNgram(ngrams: []const i32, value: u32) bool {
    var low: usize = 0;
    var high = ngrams.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = ngrams[middle];
        if (entry < value) {
            low = middle + 1;
        } else if (entry > value) {
            high = middle;
        } else {
            return true;
        }
    }
    return false;
}

fn recognizeIbm424(input: *const Input, rtl: bool) ?Match {
    const confidence = matchSbcs(
        input,
        if (rtl) &tables.ngrams_IBM424_he_rtl else &tables.ngrams_IBM424_he_ltr,
        &tables.charMap_IBM424_he,
    );
    if (confidence <= 0) return null;
    return .{
        .name = if (rtl) "IBM424_rtl" else "IBM424_ltr",
        .confidence = @intCast(confidence),
        .language = "he",
    };
}

fn recognizeIbm420(input: *const Input, rtl: bool) ?Match {
    const confidence = matchSbcsIbm420(
        input,
        if (rtl) &tables.ngrams_IBM420_ar_rtl else &tables.ngrams_IBM420_ar_ltr,
    );
    if (confidence <= 0) return null;
    return .{
        .name = if (rtl) "IBM420_rtl" else "IBM420_ltr",
        .confidence = @intCast(confidence),
        .language = "ar",
    };
}

fn matchSbcsIbm420(input: *const Input, ngrams: []const i32) i32 {
    const char_map = &tables.charMap_IBM420_ar;
    var ngram: u32 = 0;
    var ngram_count: i32 = 0;
    var hit_count: i32 = 0;
    var ignore_space = false;
    for (input.bytes) |byte| {
        if (byte == 0) break;
        var unshaped = tables.unshapeMap_IBM420[byte];
        if (isLamAlef(byte) != 0) unshaped = 0xb1;
        const mapped = char_map[unshaped];
        if (mapped != 0) {
            if (!(mapped == 0x20 and ignore_space)) {
                ngram = ((ngram << 8) + mapped) & 0xffffff;
                ngram_count += 1;
                if (searchNgram(ngrams, ngram)) hit_count += 1;
            }
            ignore_space = mapped == 0x20;
        }
        const alef = isLamAlef(byte);
        if (alef != 0) {
            const alef_mapped = char_map[alef];
            if (alef_mapped != 0) {
                if (!(alef_mapped == 0x20 and ignore_space)) {
                    ngram = ((ngram << 8) + alef_mapped) & 0xffffff;
                    ngram_count += 1;
                    if (searchNgram(ngrams, ngram)) hit_count += 1;
                }
                ignore_space = alef_mapped == 0x20;
            }
        }
    }
    ngram = ((ngram << 8) + 0x20) & 0xffffff;
    ngram_count += 1;
    if (searchNgram(ngrams, ngram)) hit_count += 1;
    if (ngram_count == 0) return 0;
    const percent = @as(f64, @floatFromInt(hit_count)) /
        @as(f64, @floatFromInt(ngram_count));
    if (percent > 0.33) return 98;
    return @intFromFloat(percent * 300.0);
}

fn isLamAlef(byte: u8) u8 {
    return switch (byte) {
        0xb2, 0xb3 => 0x47,
        0xb4, 0xb5 => 0x49,
        0xb8, 0xb9 => 0x56,
        else => 0,
    };
}

const IteratedChar = struct {
    char_value: u32 = 0,
    index: usize = 0,
    next_index: usize = 0,
    had_error: bool = false,
    done: bool = false,
};

fn nextRawByte(input: *const Input, iter: *IteratedChar) ?u8 {
    if (iter.next_index >= input.raw.len) {
        iter.done = true;
        return null;
    }
    const byte = input.raw[iter.next_index];
    iter.next_index += 1;
    return byte;
}

fn matchMbcs(
    input: *const Input,
    comptime nextChar: fn (*IteratedChar, *const Input) bool,
    common_chars: []const u16,
) i32 {
    var double_byte: i32 = 0;
    var common: i32 = 0;
    var bad: i32 = 0;
    var total: i32 = 0;
    var iter = IteratedChar{};
    while (nextChar(&iter, input)) {
        total += 1;
        if (iter.had_error) {
            bad += 1;
        } else if (iter.char_value > 0xff) {
            double_byte += 1;
            if (binarySearchU16(common_chars, @intCast(iter.char_value))) {
                common += 1;
            }
        }
        if (bad >= 2 and bad * 5 >= double_byte) return 0;
    }
    if (double_byte <= 10 and bad == 0) {
        if (double_byte == 0 and total < 10) return 0;
        return 10;
    }
    if (double_byte < 20 * bad) return 0;
    var confidence: i32 = undefined;
    if (common_chars.len == 0) {
        confidence = 30 + double_byte - 20 * bad;
        if (confidence > 100) confidence = 100;
    } else {
        const max_value = @log(@as(f64, @floatFromInt(double_byte)) / 4.0);
        const scale = 90.0 / max_value;
        confidence = @intFromFloat(
            @log(@as(f64, @floatFromInt(common)) + 1.0) * scale + 10.0,
        );
        if (confidence > 100) confidence = 100;
    }
    if (confidence < 0) confidence = 0;
    return confidence;
}

fn binarySearchU16(values: []const u16, target: u16) bool {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (values[middle] < target) {
            low = middle + 1;
        } else if (values[middle] > target) {
            high = middle;
        } else {
            return true;
        }
    }
    return false;
}

fn nextCharSjis(iter: *IteratedChar, input: *const Input) bool {
    iter.index = iter.next_index;
    iter.had_error = false;
    const first = nextRawByte(input, iter) orelse return false;
    iter.char_value = first;
    if (first <= 0x7f or (first > 0xa0 and first <= 0xdf)) return true;
    const second = nextRawByte(input, iter);
    if (second) |value| {
        iter.char_value = (@as(u32, first) << 8) | value;
    }
    const valid = if (second) |value|
        (value >= 0x40 and value <= 0x7f) or
            (value >= 0x80 and value <= 0xfe)
    else
        false;
    if (!valid) iter.had_error = true;
    return true;
}

fn nextCharEuc(iter: *IteratedChar, input: *const Input) bool {
    iter.index = iter.next_index;
    iter.had_error = false;
    const first = nextRawByte(input, iter) orelse return false;
    iter.char_value = first;
    if (first <= 0x8d) return true;
    const second = nextRawByte(input, iter);
    if (second) |value| {
        iter.char_value = (iter.char_value << 8) | value;
    }
    if (first >= 0xa1 and first <= 0xfe) {
        if (second == null or second.? < 0xa1) iter.had_error = true;
        return true;
    }
    if (first == 0x8e) {
        if (second == null or second.? < 0xa1) iter.had_error = true;
        return true;
    }
    if (first == 0x8f) {
        const third = nextRawByte(input, iter);
        if (third) |value| {
            iter.char_value = (iter.char_value << 8) | value;
        }
        if (third == null or third.? < 0xa1) iter.had_error = true;
    }
    return true;
}

fn nextCharBig5(iter: *IteratedChar, input: *const Input) bool {
    iter.index = iter.next_index;
    iter.had_error = false;
    const first = nextRawByte(input, iter) orelse return false;
    iter.char_value = first;
    if (first <= 0x7f or first == 0xff) return true;
    const second = nextRawByte(input, iter);
    if (second) |value| {
        iter.char_value = (iter.char_value << 8) | value;
    }
    const valid = if (second) |value|
        value >= 0x40 and value != 0x7f and value != 0xff
    else
        false;
    if (!valid) iter.had_error = true;
    return true;
}

fn nextCharGb18030(iter: *IteratedChar, input: *const Input) bool {
    iter.index = iter.next_index;
    iter.had_error = false;
    const first = nextRawByte(input, iter) orelse return false;
    iter.char_value = first;
    if (first <= 0x80) return true;
    const second = nextRawByte(input, iter);
    if (second) |value| {
        iter.char_value = (iter.char_value << 8) | value;
    }
    if (first >= 0x81 and first <= 0xfe) {
        if (second) |value| {
            if ((value >= 0x40 and value <= 0x7e) or
                (value >= 0x80 and value <= 0xfe))
            {
                return true;
            }
            if (value >= 0x30 and value <= 0x39) {
                const third = nextRawByte(input, iter);
                if (third) |third_value| {
                    if (third_value >= 0x81 and third_value <= 0xfe) {
                        const fourth = nextRawByte(input, iter);
                        if (fourth) |fourth_value| {
                            if (fourth_value >= 0x30 and fourth_value <= 0x39) {
                                iter.char_value =
                                    (iter.char_value << 16) |
                                    (@as(u32, third_value) << 8) |
                                    fourth_value;
                                return true;
                            }
                        }
                    }
                }
            }
        }
        iter.had_error = true;
    }
    return true;
}

fn recognizeSjis(input: *const Input) ?Match {
    const confidence = matchMbcs(input, nextCharSjis, &tables.commonChars_sjis);
    if (confidence <= 0) return null;
    return .{ .name = "Shift_JIS", .confidence = @intCast(confidence), .language = "ja" };
}

fn recognizeEucJp(input: *const Input) ?Match {
    const confidence = matchMbcs(input, nextCharEuc, &tables.commonChars_euc_jp);
    if (confidence <= 0) return null;
    return .{ .name = "EUC-JP", .confidence = @intCast(confidence), .language = "ja" };
}

fn recognizeEucKr(input: *const Input) ?Match {
    const confidence = matchMbcs(input, nextCharEuc, &tables.commonChars_euc_kr);
    if (confidence <= 0) return null;
    return .{ .name = "EUC-KR", .confidence = @intCast(confidence), .language = "ko" };
}

fn recognizeBig5(input: *const Input) ?Match {
    const confidence = matchMbcs(input, nextCharBig5, &tables.commonChars_big5);
    if (confidence <= 0) return null;
    return .{ .name = "Big5", .confidence = @intCast(confidence), .language = "zh" };
}

fn recognizeGb18030(input: *const Input) ?Match {
    const confidence = matchMbcs(
        input,
        nextCharGb18030,
        &tables.commonChars_gb_18030,
    );
    if (confidence <= 0) return null;
    return .{ .name = "GB18030", .confidence = @intCast(confidence), .language = "zh" };
}

const Iso2022Kind = enum { jp, kr, cn };

fn recognize2022(input: *const Input, kind: Iso2022Kind) ?Match {
    const confidence = match2022(input, switch (kind) {
        .jp => &escape_2022_jp,
        .kr => &escape_2022_kr,
        .cn => &escape_2022_cn,
    });
    if (confidence <= 0) return null;
    return .{
        .name = switch (kind) {
            .jp => "ISO-2022-JP",
            .kr => "ISO-2022-KR",
            .cn => "ISO-2022-CN",
        },
        .confidence = @intCast(confidence),
    };
}

fn match2022(input: *const Input, sequences: []const []const u8) i32 {
    const text = input.bytes;
    var hits: i32 = 0;
    var misses: i32 = 0;
    var shifts: i32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            var matched = false;
            for (sequences) |sequence| {
                if (index + sequence.len <= text.len and
                    std.mem.eql(u8, text[index .. index + sequence.len], sequence))
                {
                    hits += 1;
                    index += sequence.len - 1;
                    matched = true;
                    break;
                }
            }
            if (!matched) misses += 1;
        } else if (text[index] == 0x0e or text[index] == 0x0f) {
            shifts += 1;
        }
        index += 1;
    }
    if (hits == 0) return 0;
    var quality = @divTrunc(100 * hits - 100 * misses, hits + misses);
    if (hits + shifts < 5) quality -= (5 - (hits + shifts)) * 10;
    if (quality < 0) quality = 0;
    return quality;
}

const escape_2022_jp = [_][]const u8{
    &.{ 0x1b, 0x24, 0x28, 0x43 },
    &.{ 0x1b, 0x24, 0x28, 0x44 },
    &.{ 0x1b, 0x24, 0x40 },
    &.{ 0x1b, 0x24, 0x41 },
    &.{ 0x1b, 0x24, 0x42 },
    &.{ 0x1b, 0x26, 0x40 },
    &.{ 0x1b, 0x28, 0x42 },
    &.{ 0x1b, 0x28, 0x48 },
    &.{ 0x1b, 0x28, 0x49 },
    &.{ 0x1b, 0x28, 0x4a },
    &.{ 0x1b, 0x2e, 0x41 },
    &.{ 0x1b, 0x2e, 0x46 },
};

const escape_2022_kr = [_][]const u8{
    &.{ 0x1b, 0x24, 0x29, 0x43 },
};

const escape_2022_cn = [_][]const u8{
    &.{ 0x1b, 0x24, 0x29, 0x41 },
    &.{ 0x1b, 0x24, 0x29, 0x47 },
    &.{ 0x1b, 0x24, 0x2a, 0x48 },
    &.{ 0x1b, 0x24, 0x29, 0x45 },
    &.{ 0x1b, 0x24, 0x2b, 0x49 },
    &.{ 0x1b, 0x24, 0x2b, 0x4a },
    &.{ 0x1b, 0x24, 0x2b, 0x4b },
    &.{ 0x1b, 0x24, 0x2b, 0x4c },
    &.{ 0x1b, 0x24, 0x2b, 0x4d },
    &.{ 0x1b, 0x4e },
    &.{ 0x1b, 0x4f },
};

test "charset detection matches ICU samples" {
    const testing = @import("std").testing;
    const samples = [_]struct { text: []const u8, name: []const u8 }{
        .{ .text = "hello world", .name = "ISO-8859-1" },
        .{ .text = "你好世界", .name = "UTF-8" },
        .{ .text = "😀😀😀", .name = "UTF-8" },
    };
    for (samples) |sample| {
        const match = detect(sample.text, .{}) orelse {
            std.debug.print("no match for {s}\n", .{sample.name});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(sample.name, match.name);
    }
    const utf16 = [_]u8{ 0xff, 0xfe, 'h', 0, 'e', 0, 'l', 0, 'l', 0, 'o', 0 };
    const match = detect(&utf16, .{}).?;
    try testing.expectEqualStrings("UTF-16LE", match.name);
    try testing.expectEqual(@as(u8, 100), match.confidence);
}

const conformance = @embedFile("detection_conformance.bin");

test "charset detection conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    try testing.expect(conformance.len >= 12);
    try testing.expectEqualSlices(u8, "CJSD", conformance[0..4]);
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    var offset: usize = 12;
    var failures: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const input_len = std.mem.readInt(
            u16,
            conformance[offset..][0..2],
            .little,
        );
        const match_count = conformance[offset + 2];
        offset += 4;
        const input = conformance[offset..][0..input_len];
        offset += input_len;
        var expected: [32]Match = undefined;
        for (0..match_count) |match_index| {
            const name_len = conformance[offset];
            const confidence = conformance[offset + 1];
            const language_len = conformance[offset + 2];
            offset += 3;
            const name = conformance[offset..][0..name_len];
            offset += name_len;
            const language = conformance[offset..][0..language_len];
            offset += language_len;
            expected[match_index] = .{
                .name = name,
                .confidence = confidence,
                .language = language,
            };
        }
        const actual = try detectAll(allocator, input, .{});
        defer allocator.free(actual);
        var used = [_]bool{false} ** 32;
        var case_ok = actual.len == match_count;
        for (expected[0..match_count]) |wanted| {
            var found = false;
            for (actual, 0..) |value, value_index| {
                if (used[value_index]) continue;
                if (std.mem.eql(u8, value.name, wanted.name) and
                    value.confidence == wanted.confidence and
                    std.mem.eql(u8, value.language, wanted.language))
                {
                    used[value_index] = true;
                    found = true;
                    break;
                }
            }
            if (!found) case_ok = false;
        }
        if (!case_ok) {
            failures += 1;
            if (printed < 20) {
                printed += 1;
                std.debug.print(
                    "detection mismatch: got {d} matches, expected {d}\n",
                    .{ actual.len, match_count },
                );
                for (expected[0..match_count]) |wanted| {
                    std.debug.print(
                        "  expected {s}/{d}/{s}\n",
                        .{ wanted.name, wanted.confidence, wanted.language },
                    );
                }
                for (actual) |value| {
                    std.debug.print(
                        "  actual   {s}/{d}/{s}\n",
                        .{ value.name, value.confidence, value.language },
                    );
                }
            }
        }
    }
    std.debug.print(
        "charset detection conformance: {d}/{d} passed\n",
        .{ case_count - failures, case_count },
    );
    try testing.expectEqual(conformance.len, offset);
    try testing.expect(failures == 0);
}

const detectFree = detect;
const detectAllFree = detectAll;

/// Stateful `ucsdet`-style detector.
pub const Detector = struct {
    text: []const u8 = "",
    declared: ?[]const u8 = null,
    options: Options = .{},
    input_filter: bool = false,

    pub fn init() Detector {
        return .{};
    }

    pub fn setText(self: *Detector, text: []const u8) void {
        self.text = text;
    }

    /// Set a declared encoding. Returns false when the name is not a
    /// converter label known to icuz.
    pub fn setDeclaredEncoding(
        self: *Detector,
        name: []const u8,
    ) bool {
        if (charset.fromLabel(name) == null) {
            self.declared = null;
            return false;
        }
        self.declared = name;
        return true;
    }

    pub fn setInputFilter(self: *Detector, enabled: bool) void {
        self.input_filter = enabled;
    }

    pub fn detect(self: *const Detector) ?Match {
        if (self.declared) |name| {
            return .{ .name = name, .confidence = 100 };
        }
        var options = self.options;
        options.strip_tags = self.input_filter;
        return detectFree(self.text, options);
    }

    pub fn detectAll(
        self: *const Detector,
        allocator: std.mem.Allocator,
    ) Error![]Match {
        if (self.declared) |name| {
            const result = try allocator.alloc(Match, 1);
            result[0] = .{ .name = name, .confidence = 100 };
            return result;
        }
        var options = self.options;
        options.strip_tags = self.input_filter;
        return detectAllFree(allocator, self.text, options);
    }
};

/// Charset names that icuz's recognizers can report.
pub const detectable_charsets = [_][]const u8{
    "UTF-8",
    "UTF-16LE",
    "UTF-16BE",
    "UTF-32LE",
    "UTF-32BE",
    "ISO-8859-1",
    "ISO-8859-2",
    "ISO-8859-5",
    "ISO-8859-6",
    "ISO-8859-7",
    "ISO-8859-8",
    "ISO-8859-9",
    "windows-1250",
    "windows-1251",
    "windows-1252",
    "windows-1253",
    "windows-1254",
    "windows-1255",
    "windows-1256",
    "KOI8-R",
    "Shift_JIS",
    "GB18030",
    "EUC-JP",
    "EUC-KR",
    "Big5",
    "ISO-2022-JP",
    "ISO-2022-KR",
    "ISO-2022-CN",
    "IBM420",
    "IBM424",
};

test "stateful charset detector" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var detector = Detector.init();
    detector.setText("hello world");
    try testing.expectEqualStrings("ISO-8859-1", detector.detect().?.name);
    try testing.expect(detector.setDeclaredEncoding("UTF-8"));
    try testing.expectEqualStrings("UTF-8", detector.detect().?.name);
    try testing.expectEqual(@as(u8, 100), detector.detect().?.confidence);
    const matches = try detector.detectAll(allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expect(!detector.setDeclaredEncoding("not-a-charset"));
}
