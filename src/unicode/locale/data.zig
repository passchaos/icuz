//! ICU-compatible locale data (`ulocdata`): exemplar character sets,
//! delimiters, locale display patterns, measurement systems, and paper sizes.

const std = @import("std");
const set_mod = @import("../set.zig");
const likely_subtags = @import("../format/likely_subtags.zig");
const properties = @import("../properties.zig");

pub const ExemplarType = enum(u8) {
    standard = 0,
    auxiliary = 1,
    index = 2,
    punctuation = 3,
};

pub const DelimiterType = enum(u8) {
    quotation_start = 0,
    quotation_end = 1,
    alternate_quotation_start = 2,
    alternate_quotation_end = 3,
};

pub const MeasurementSystem = enum(u8) {
    metric = 0,
    us = 1,
    uk = 2,
};

pub const PaperSize = struct {
    height: i32,
    width: i32,
};

pub const cldr_version = "48";

const data = @embedFile("data.bin");
const magic = "CJL0";
const header_len = 22;
const locale_record_len = 68;
const measurement_record_len = 8;
const paper_record_len = 8;
const reference_count = 11;

const ref_standard = 1;
const ref_auxiliary = 2;
const ref_index = 3;
const ref_punctuation = 4;
const ref_quotation_start = 5;
const ref_quotation_end = 6;
const ref_alternate_quotation_start = 7;
const ref_alternate_quotation_end = 8;
const ref_display_pattern = 9;
const ref_separator = 10;

const header = parseHeader();

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
};

pub const LocaleData = struct {
    allocator: std.mem.Allocator,
    locale: []u8,
    no_substitute: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        locale: []const u8,
    ) !LocaleData {
        return .{
            .allocator = allocator,
            .locale = try allocator.dupe(u8, locale),
        };
    }

    pub fn deinit(self: *LocaleData) void {
        self.allocator.free(self.locale);
    }

    pub fn setNoSubstitute(self: *LocaleData, value: bool) void {
        self.no_substitute = value;
    }

    pub fn getNoSubstitute(self: *const LocaleData) bool {
        return self.no_substitute;
    }

    pub fn exemplarSetAlloc(
        self: *const LocaleData,
        allocator: std.mem.Allocator,
        kind: ExemplarType,
    ) Error!set_mod.Set {
        const reference: usize = switch (kind) {
            .standard => ref_standard,
            .auxiliary => ref_auxiliary,
            .index => ref_index,
            .punctuation => ref_punctuation,
        };
        const pattern = self.field(reference) orelse return set_mod.Set.init(allocator);
        if (pattern.len == 0) return set_mod.Set.init(allocator);
        const decoded = try decodeExemplarPatternAlloc(allocator, pattern);
        defer allocator.free(decoded);
        var parsed = try set_mod.parseWithOptions(
            allocator,
            decoded,
            .{ .ignore_space = true },
        );
        errdefer parsed.deinit();
        return flattenMarkStrings(allocator, &parsed);
    }

    pub fn delimiter(self: *const LocaleData, kind: DelimiterType) ?[]const u8 {
        const reference: usize = switch (kind) {
            .quotation_start => ref_quotation_start,
            .quotation_end => ref_quotation_end,
            .alternate_quotation_start => ref_alternate_quotation_start,
            .alternate_quotation_end => ref_alternate_quotation_end,
        };
        return self.field(reference);
    }

    pub fn localeDisplayPattern(self: *const LocaleData) ?[]const u8 {
        return self.field(ref_display_pattern);
    }

    pub fn localeSeparator(self: *const LocaleData) ?[]const u8 {
        return self.field(ref_separator);
    }

    fn field(self: *const LocaleData, reference: usize) ?[]const u8 {
        const display_reference = reference == ref_display_pattern or
            reference == ref_separator;
        if (self.no_substitute) {
            const index = findLocaleRecord(self.locale) orelse return null;
            if (display_reference) {
                if (!hasDisplayPattern(index)) return null;
                return readReference(index, reference) orelse "";
            }
            return readReference(index, reference);
        }

        if (lookupField(self.locale, reference, display_reference)) |value| {
            return value;
        }
        // ICU falls back unknown locale IDs to the default locale. This
        // library uses "en" as its stable default.
        if (!isRootLocale(self.locale)) {
            return lookupField("en", reference, display_reference);
        }
        return null;
    }
};

pub fn exemplarSetAlloc(
    allocator: std.mem.Allocator,
    locale: []const u8,
    kind: ExemplarType,
) Error!set_mod.Set {
    var locale_data = try LocaleData.init(allocator, locale);
    defer locale_data.deinit();
    return locale_data.exemplarSetAlloc(allocator, kind);
}

pub fn measurementSystem(locale: []const u8) MeasurementSystem {
    const region = likely_subtags.regionForLocale(locale) orelse "001";
    if (findMeasurement(region)) |value| return value;
    if (findMeasurement("001")) |value| return value;
    return .metric;
}

pub fn paperSize(locale: []const u8) PaperSize {
    const region = likely_subtags.regionForLocale(locale) orelse "001";
    const kind = findPaper(region) orelse findPaper("001") orelse .a4;
    return switch (kind) {
        .a4 => .{ .height = 297, .width = 210 },
        .us_letter => .{ .height = 279, .width = 216 },
    };
}

const PaperKind = enum(u8) { a4 = 0, us_letter = 1 };

fn flattenMarkStrings(
    allocator: std.mem.Allocator,
    source: *set_mod.Set,
) !set_mod.Set {
    if (source.stringCount() == 0) return source.*;

    var result = set_mod.Set.init(allocator);
    errdefer result.deinit();
    var ranges = source.rangeIterator();
    while (ranges.next()) |range| {
        try result.addRange(range.first, range.last);
    }

    var flatten_any = false;
    var index: usize = 0;
    while (index < source.stringCount()) : (index += 1) {
        const text = source.stringAt(index);
        var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        var all_marks = true;
        var codepoints: [8]u21 = undefined;
        var count: usize = 0;
        while (iterator.nextCodepoint()) |codepoint| {
            if (count == codepoints.len) {
                all_marks = false;
                break;
            }
            codepoints[count] = codepoint;
            count += 1;
            if (!isMark(codepoint)) all_marks = false;
        }
        if (all_marks and count > 0) {
            flatten_any = true;
            for (codepoints[0..count]) |codepoint| try result.add(codepoint);
        } else {
            try result.addString(text);
        }
    }
    if (!flatten_any) {
        result.deinit();
        return source.*;
    }
    source.deinit();
    try result.finalize();
    return result;
}

fn isMark(codepoint: u21) bool {
    return switch (properties.category(codepoint)) {
        .Mn, .Mc, .Me => true,
        else => false,
    };
}

fn decodeExemplarPatternAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '\\' and index + 1 < pattern.len) {
            const kind = pattern[index + 1];
            const digits: usize = switch (kind) {
                'u' => 4,
                'U' => 8,
                else => 0,
            };
            if (digits != 0 and index + 2 + digits <= pattern.len) {
                if (std.fmt.parseInt(
                    u21,
                    pattern[index + 2 ..][0..digits],
                    16,
                )) |value| {
                    var encoded: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(value, &encoded)) |length| {
                        try output.appendSlice(allocator, encoded[0..length]);
                        index += 2 + digits;
                        continue;
                    } else |_| {}
                } else |_| {}
            }
        }
        try output.append(allocator, pattern[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn findLocaleRecord(locale: []const u8) ?usize {
    var low: usize = 0;
    var high = header.locale_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = readString(header.locale_records_offset + middle * locale_record_len);
        const order = std.mem.order(u8, candidate, locale);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn readReference(index: usize, reference: usize) ?[]const u8 {
    const base = header.locale_records_offset + index * locale_record_len + reference * 6;
    const offset = readU32(base);
    const length = readU16(base + 4);
    if (length == 0) return null;
    return data[header.strings_offset + offset ..][0..length];
}

fn lookupField(
    locale: []const u8,
    reference: usize,
    display_reference: bool,
) ?[]const u8 {
    var buffer: [128]u8 = undefined;
    var current = normalizeLocale(locale, &buffer) orelse locale;
    var found_any = false;
    while (true) {
        if (findLocaleRecord(current)) |index| {
            if (std.mem.eql(u8, current, "root") and !found_any and
                !isRootLocale(locale))
            {
                break;
            }
            found_any = true;
            if (display_reference) {
                // ICU resource bundles fall back per element: a locale that
                // defines localeDisplayPattern but omits a subkey yields an
                // empty value instead of the root subkey.
                if (hasDisplayPattern(index)) {
                    return readReference(index, reference) orelse "";
                }
            } else if (readReference(index, reference)) |value| {
                return value;
            }
        }
        if (std.mem.eql(u8, current, "root")) break;
        if (std.mem.lastIndexOfScalar(u8, current, '-')) |dash| {
            current = current[0..dash];
        } else {
            current = "root";
        }
    }
    return null;
}

fn isRootLocale(locale: []const u8) bool {
    var buffer: [128]u8 = undefined;
    const normalized = normalizeLocale(locale, &buffer) orelse locale;
    return std.mem.eql(u8, normalized, "root") or std.mem.eql(u8, normalized, "und");
}

fn hasDisplayPattern(index: usize) bool {
    const base = header.locale_records_offset + index * locale_record_len;
    return (readU16(base + 66) & 2) != 0;
}

fn readString(base: usize) []const u8 {
    const offset = readU32(base);
    const length = readU16(base + 4);
    return data[header.strings_offset + offset ..][0..length];
}

fn findMeasurement(region: []const u8) ?MeasurementSystem {
    var low: usize = 0;
    var high = header.measurement_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = header.measurement_offset + middle * measurement_record_len;
        const candidate = readString(base);
        const order = std.mem.order(u8, candidate, region);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return @enumFromInt(data[base + 6]),
        }
    }
    return null;
}

fn findPaper(region: []const u8) ?PaperKind {
    var low: usize = 0;
    var high = header.paper_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = header.paper_offset + middle * paper_record_len;
        const candidate = readString(base);
        const order = std.mem.order(u8, candidate, region);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return @enumFromInt(data[base + 6]),
        }
    }
    return null;
}

fn normalizeLocale(locale: []const u8, buffer: *[128]u8) ?[]const u8 {
    if (locale.len > buffer.len) return null;
    var has_underscore = false;
    for (locale, 0..) |byte, index| {
        const value = if (byte == '_') blk: {
            has_underscore = true;
            break :blk '-';
        } else byte;
        buffer[index] = value;
    }
    if (!has_underscore) return null;
    return buffer[0..locale.len];
}

const Header = struct {
    locale_count: usize,
    string_len: usize,
    measurement_count: usize,
    paper_count: usize,
    locale_records_offset: usize,
    measurement_offset: usize,
    paper_offset: usize,
    strings_offset: usize,
};

fn parseHeader() Header {
    if (!std.mem.eql(u8, data[0..4], magic)) @compileError("invalid locale data magic");
    const locale_count = readU32Const(8);
    const string_len = readU32Const(12);
    const measurement_count = readU16Const(16);
    const paper_count = readU16Const(18);
    const locale_records_offset = header_len;
    const measurement_offset = locale_records_offset + locale_count * locale_record_len;
    const paper_offset = measurement_offset + measurement_count * measurement_record_len;
    const strings_offset = paper_offset + paper_count * paper_record_len;
    if (strings_offset + string_len != data.len) {
        @compileError("invalid locale data layout");
    }
    return .{
        .locale_count = locale_count,
        .string_len = string_len,
        .measurement_count = measurement_count,
        .paper_count = paper_count,
        .locale_records_offset = locale_records_offset,
        .measurement_offset = measurement_offset,
        .paper_offset = paper_offset,
        .strings_offset = strings_offset,
    };
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn readU16Const(offset: usize) usize {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32Const(offset: usize) usize {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

test "locale data exemplars and delimiters" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var locale = try LocaleData.init(allocator, "en");
    defer locale.deinit();

    var standard = try locale.exemplarSetAlloc(allocator, .standard);
    defer standard.deinit();
    try testing.expect(standard.contains('a'));
    try testing.expect(standard.contains('z'));
    try testing.expect(!standard.contains('A'));

    var auxiliary = try locale.exemplarSetAlloc(allocator, .auxiliary);
    defer auxiliary.deinit();
    try testing.expect(auxiliary.contains('á'));

    try testing.expectEqualStrings("“", locale.delimiter(.quotation_start).?);
    try testing.expectEqualStrings("”", locale.delimiter(.quotation_end).?);
    try testing.expectEqualStrings("{0} ({1})", locale.localeDisplayPattern().?);
    try testing.expectEqualStrings(", ", locale.localeSeparator().?);
}

test "locale data measurement and paper size" {
    const testing = std.testing;
    try testing.expectEqual(MeasurementSystem.us, measurementSystem("en-US"));
    try testing.expectEqual(MeasurementSystem.uk, measurementSystem("en-GB"));
    try testing.expectEqual(MeasurementSystem.metric, measurementSystem("fr-FR"));
    const us = paperSize("en-US");
    try testing.expectEqual(@as(i32, 279), us.height);
    try testing.expectEqual(@as(i32, 216), us.width);
    const a4 = paperSize("en-GB");
    try testing.expectEqual(@as(i32, 297), a4.height);
    try testing.expectEqual(@as(i32, 210), a4.width);
}

test "locale data fallback and no substitute" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var locale = try LocaleData.init(allocator, "en-US");
    defer locale.deinit();
    var standard = try locale.exemplarSetAlloc(allocator, .standard);
    defer standard.deinit();
    try testing.expect(standard.contains('a'));

    var missing = try LocaleData.init(allocator, "zz-ZZ");
    defer missing.deinit();
    missing.setNoSubstitute(true);
    var empty = try missing.exemplarSetAlloc(allocator, .standard);
    defer empty.deinit();
    try testing.expect(empty.isEmpty());
    try testing.expect(missing.delimiter(.quotation_start) == null);
}

const Fixture = struct {
    data: []const u8,
    index: usize = 0,

    fn readU8(self: *Fixture) !u8 {
        if (self.index >= self.data.len) return error.Truncated;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    fn readU16(self: *Fixture) !u16 {
        if (self.index + 2 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u16, self.data[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn readU32(self: *Fixture) !u32 {
        if (self.index + 4 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u32, self.data[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    fn readI32(self: *Fixture) !i32 {
        return @bitCast(try self.readU32());
    }

    fn string(self: *Fixture) ![]const u8 {
        const length = try self.readU16();
        if (self.index + length > self.data.len) return error.Truncated;
        const value = self.data[self.index..][0..length];
        self.index += length;
        return value;
    }
};

test "locale data ICU conformance fixture" {
    const fixture_data = @embedFile("data_conformance.bin");
    try std.testing.expectEqualSlices(u8, "CJL3", fixture_data[0..4]);
    var fixture = Fixture{ .data = fixture_data, .index = 8 };
    const case_count = std.mem.readInt(u32, fixture.data[fixture.index..][0..4], .little);
    fixture.index += 4;
    const allocator = std.testing.allocator;

    var passed: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const kind = try fixture.readU8();
        const locale_name = try fixture.string();
        var locale = try LocaleData.init(allocator, locale_name);
        defer locale.deinit();

        switch (kind) {
            0 => {
                const type_value = try fixture.readU8();
                const item_count = try fixture.readU32();
                var set = try locale.exemplarSetAlloc(allocator, @enumFromInt(type_value));
                defer set.deinit();

                var range_iterator = set.rangeIterator();
                var string_index: usize = 0;
                var item_index: usize = 0;
                while (item_index < item_count) : (item_index += 1) {
                    const tag = try fixture.readU8();
                    if (tag == 0) {
                        const first = try fixture.readI32();
                        const last = try fixture.readI32();
                        const range = range_iterator.next() orelse return error.TestUnexpectedResult;
                        try std.testing.expectEqual(@as(u32, @intCast(first)), @as(u32, range.first));
                        try std.testing.expectEqual(@as(u32, @intCast(last)), @as(u32, range.last));
                    } else {
                        const expected = try fixture.string();
                        if (string_index >= set.stringCount()) return error.TestUnexpectedResult;
                        try std.testing.expectEqualStrings(expected, set.stringAt(string_index));
                        string_index += 1;
                    }
                }
                try std.testing.expect(range_iterator.next() == null);
                try std.testing.expectEqual(set.stringCount(), string_index);
            },
            1 => {
                const type_value = try fixture.readU8();
                const expected = try fixture.string();
                const actual = locale.delimiter(@enumFromInt(type_value)) orelse "";
                try std.testing.expectEqualStrings(expected, actual);
            },
            2 => {
                const expected = try fixture.string();
                try std.testing.expectEqualStrings(expected, locale.localeDisplayPattern() orelse "");
            },
            3 => {
                const expected = try fixture.string();
                try std.testing.expectEqualStrings(expected, locale.localeSeparator() orelse "");
            },
            4 => {
                const expected = try fixture.readU8();
                try std.testing.expectEqual(
                    @as(MeasurementSystem, @enumFromInt(expected)),
                    measurementSystem(locale_name),
                );
            },
            5 => {
                const height = try fixture.readI32();
                const width = try fixture.readI32();
                const size = paperSize(locale_name);
                try std.testing.expectEqual(height, size.height);
                try std.testing.expectEqual(width, size.width);
            },
            else => return error.UnknownCaseKind,
        }
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), fixture_data.len - fixture.index);
    std.debug.print("locale data conformance: {}/{} passed\n", .{ passed, case_count });
}
