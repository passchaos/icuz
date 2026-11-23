//! CLDR alphabetic index labels and bucket assignment.
//!
//! Buckets are the locale's CLDR index characters, ordered by the locale's
//! primary collation. Names before the first label fall into the underflow
//! bucket; names in a different script than the labels fall into the
//! overflow bucket. Chinese pinyin label redirection and inflow buckets for
//! skipped scripts are not implemented.

const std = @import("std");
const scalar = @import("../scalar/root.zig");
const collation = @import("../collation/root.zig");
const tailorings = @import("../collation/tailorings.zig");
const locale_mod = @import("../locale.zig");
const properties = @import("../properties.zig");
const script_mod = @import("../script/root.zig");

const data_blob = @embedFile("alphabetic_index_data.bin");

pub const Error = error{ InvalidLocale, InvalidUtf8, OutOfMemory };

const header_len = 24;
const locale_record_len = 16;
const label_ref_len = 8;

const locale_count = readU32(data_blob, 8);
const locale_records_offset = readU32(data_blob, 12);
const label_refs_offset = readU32(data_blob, 16);
const pool_offset = readU32(data_blob, 20);

comptime {
    if (data_blob.len < header_len or
        !std.mem.eql(u8, data_blob[0..4], "CJXA") or
        data_blob[4] != 1)
    {
        @compileError("invalid alphabetic index data");
    }
    if (locale_records_offset != header_len or
        locale_records_offset + @as(usize, locale_count) * locale_record_len >
            data_blob.len or
        label_refs_offset > data_blob.len or
        pool_offset > data_blob.len)
    {
        @compileError("invalid alphabetic index data layout");
    }
}

fn readU16(blob: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(blob: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

const StrRef = struct { offset: u32, length: u16 };

fn strRefAt(offset: usize) StrRef {
    return .{
        .offset = readU32(data_blob, offset),
        .length = readU16(data_blob, offset + 4),
    };
}

fn strText(ref: StrRef) []const u8 {
    return data_blob[pool_offset + ref.offset ..][0..ref.length];
}

const LocaleRecord = struct {
    locale: StrRef,
    label_count: u16,
    label_start: u32,
};

fn localeRecordAt(index: usize) LocaleRecord {
    const base = locale_records_offset + index * locale_record_len;
    return .{
        .locale = strRefAt(base),
        .label_count = readU16(data_blob, base + 8),
        .label_start = readU32(data_blob, base + 12),
    };
}

fn findLocaleRecord(locale: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = locale_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, strText(localeRecordAt(middle).locale), locale)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn normalizeLocaleAlloc(
    allocator: std.mem.Allocator,
    locale: []const u8,
) Error![]u8 {
    if (locale.len == 0) return error.InvalidLocale;
    const canonical = locale_mod.canonicalizeAlloc(allocator, locale) catch |err| {
        return switch (err) {
            error.InvalidLocale => error.InvalidLocale,
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    defer allocator.free(canonical);
    const result = try allocator.alloc(u8, canonical.len);
    for (canonical, 0..) |byte, index| {
        result[index] = if (byte == '-') '_' else byte;
    }
    return result;
}

fn decodeFirst(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (length > text.len) return null;
    return std.unicode.utf8Decode(text[0..length]) catch null;
}

const pinyin_letters = [_][]const u8{
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
};

fn languageOf(locale: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, locale, "_-@") orelse locale.len;
    return locale[0..end];
}

fn firstLetterScript(text: []const u8) ?script_mod.Script {
    var cursor: usize = 0;
    while (cursor < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[cursor]) catch
            return null;
        if (cursor + length > text.len) return null;
        const codepoint = std.unicode.utf8Decode(
            text[cursor..][0..length],
        ) catch return null;
        if (properties.isLetter(codepoint)) {
            return script_mod.forCodepoint(codepoint);
        }
        cursor += length;
    }
    return null;
}

const Label = struct {
    text: []const u8,
    key: []u32,
};

/// An alphabetic index built from one locale's CLDR index characters.
pub const AlphabeticIndex = struct {
    allocator: std.mem.Allocator,
    locale: []u8,
    collator: collation.Collator,
    labels: []Label = &.{},
    labels_storage: []Label = &.{},
    label_script: ?script_mod.Script = null,
    pinyin: bool = false,
    scratch: std.ArrayList(u32) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        locale: []const u8,
    ) Error!AlphabeticIndex {
        const normalized = try normalizeLocaleAlloc(allocator, locale);

        var record: ?LocaleRecord = null;
        var current: []const u8 = normalized;
        while (true) {
            if (findLocaleRecord(current)) |index| {
                record = localeRecordAt(index);
                break;
            }
            const position = std.mem.lastIndexOfScalar(u8, current, '_') orelse
                break;
            current = current[0..position];
        }

        var index = AlphabeticIndex{
            .allocator = allocator,
            .locale = normalized,
            .collator = collation.Collator.init(.{
                .locale = normalized,
                .strength = .primary,
            }),
        };
        errdefer index.deinit();

        if (record) |locale_record| {
            const count: usize = locale_record.label_count;
            if (count != 0) {
                const storage = try allocator.alloc(Label, count);
                var initialized: usize = 0;
                errdefer {
                    for (storage[0..initialized]) |label| {
                        allocator.free(label.key);
                    }
                    allocator.free(storage);
                }
                for (0..count) |label_index| {
                    const ref = strRefAt(
                        label_refs_offset +
                            (@as(usize, locale_record.label_start) +
                                label_index) * label_ref_len,
                    );
                    const label_text = strText(ref);
                    index.scratch.clearRetainingCapacity();
                    try index.collator.sortKeyInto(
                        allocator,
                        label_text,
                        &index.scratch,
                    );
                    storage[label_index] = .{
                        .text = label_text,
                        .key = try allocator.dupe(u32, index.scratch.items),
                    };
                    initialized += 1;
                }

                // Stable insertion sort by primary key; labels are short.
                var sort_index: usize = 1;
                while (sort_index < count) : (sort_index += 1) {
                    const value = storage[sort_index];
                    var move = sort_index;
                    while (move > 0 and
                        std.mem.order(
                            u32,
                            value.key,
                            storage[move - 1].key,
                        ) == .lt)
                    {
                        storage[move] = storage[move - 1];
                        move -= 1;
                    }
                    storage[move] = value;
                }

                // Drop labels that collate the same as the previous label,
                // keeping the first in CLDR order (for example, ru keeps Е
                // and drops Ё).
                var kept: usize = 0;
                for (storage) |label| {
                    if (kept > 0 and
                        std.mem.eql(u32, storage[kept - 1].key, label.key))
                    {
                        allocator.free(label.key);
                        continue;
                    }
                    storage[kept] = label;
                    kept += 1;
                }
                index.labels_storage = storage;
                index.labels = storage[0..kept];
                if (kept != 0) {
                    index.label_script = firstLetterScript(storage[0].text);
                }
            }
        }
        try index.setupPinyin();
        return index;
    }

    /// Replace the Latin A-Z index labels with the collation's Chinese
    /// `BASE+A-Z` boundaries when the locale defaults to pinyin.
    fn setupPinyin(self: *AlphabeticIndex) Error!void {
        if (!std.mem.eql(u8, languageOf(self.locale), "zh")) return;
        const tailoring = tailorings.find(self.locale, "standard") orelse return;
        if (!std.mem.eql(u8, tailoring.collation_type, "pinyin")) return;
        const present = tailorings.baseLetterBoundaries(tailoring);

        const storage = try self.allocator.alloc(Label, 26);
        var initialized: usize = 0;
        errdefer {
            for (storage[0..initialized]) |label| {
                self.allocator.free(label.key);
            }
            self.allocator.free(storage);
        }
        var keys: [26]?[]u32 = .{null} ** 26;
        errdefer for (keys) |key| {
            if (key) |value| self.allocator.free(value);
        };
        for (0..26) |letter| {
            if (!present[letter]) continue;
            const boundary = [_]u8{
                0xEF,
                0xB7,
                0x90,
                'A' + @as(u8, @intCast(letter)),
            };
            self.scratch.clearRetainingCapacity();
            try self.collator.sortKeyInto(self.allocator, &boundary, &self.scratch);
            keys[letter] = try self.allocator.dupe(u32, self.scratch.items);
        }
        // Pinyin has no I, U, or V initials. Give those buckets the next
        // existing boundary so the label list stays A-Z and sorted.
        var next: ?[]const u32 = null;
        var letter: usize = 26;
        while (letter > 0) {
            letter -= 1;
            if (keys[letter]) |key| {
                next = key;
            } else if (next) |key| {
                keys[letter] = try self.allocator.dupe(u32, key);
            }
        }
        for (0..26) |index| {
            const key = keys[index] orelse continue;
            storage[index] = .{
                .text = pinyin_letters[index],
                .key = key,
            };
            keys[index] = null;
            initialized += 1;
        }
        for (self.labels) |label| self.allocator.free(label.key);
        if (self.labels_storage.len != 0) {
            self.allocator.free(self.labels_storage);
        }
        self.labels_storage = storage;
        self.labels = storage;
        self.label_script = .latin;
        self.pinyin = true;
    }

    pub fn deinit(self: *AlphabeticIndex) void {
        for (self.labels) |label| self.allocator.free(label.key);
        if (self.labels_storage.len != 0) {
            self.allocator.free(self.labels_storage);
        }
        self.scratch.deinit(self.allocator);
        self.allocator.free(self.locale);
    }

    /// Number of buckets, including underflow and overflow.
    pub fn bucketCount(self: *const AlphabeticIndex) usize {
        if (self.labels.len == 0) return 1;
        return self.labels.len + 2;
    }

    /// Label for a bucket index.
    pub fn bucketLabel(self: *const AlphabeticIndex, index: usize) []const u8 {
        if (self.labels.len == 0) return "\u{2026}";
        if (index == 0 or index == self.labels.len + 1) return "\u{2026}";
        return self.labels[index - 1].text;
    }

    /// Bucket index for a name.
    pub fn bucketFor(self: *AlphabeticIndex, name: []const u8) Error!usize {
        if (self.labels.len == 0) return 0;
        if (!scalar.validate.isValid(name)) return error.InvalidUtf8;

        if (self.pinyin) {
            if (decodeFirst(name)) |codepoint| {
                if (codepoint >= 'A' and codepoint <= 'Z') {
                    return 1 + @as(usize, codepoint - 'A');
                }
                if (codepoint >= 'a' and codepoint <= 'z') {
                    return 1 + @as(usize, codepoint - 'a');
                }
                if (properties.isLetter(codepoint)) {
                    if (script_mod.forCodepoint(codepoint) != .han) {
                        return self.labels.len + 1;
                    }
                } else {
                    return 0;
                }
            }
        } else if (decodeFirst(name)) |codepoint| {
            // Names whose first code point is a letter in another script
            // belong to the overflow bucket, matching the CLDR label script.
            if (properties.isLetter(codepoint)) {
                const name_script = script_mod.forCodepoint(codepoint);
                if (self.label_script) |label_script| {
                    if (name_script != label_script) {
                        return self.labels.len + 1;
                    }
                }
            }
        }

        self.scratch.clearRetainingCapacity();
        try self.collator.sortKeyInto(self.allocator, name, &self.scratch);
        const key = self.scratch.items;

        // Find the last label whose key is <= the name's key.
        var low: usize = 0;
        var high = self.labels.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (std.mem.order(u32, self.labels[middle].key, key) == .gt) {
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        return low;
    }
};

test "alphabetic index labels and buckets" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var english = try AlphabeticIndex.init(allocator, "en");
    defer english.deinit();
    try testing.expectEqual(@as(usize, 28), english.bucketCount());
    try testing.expectEqualStrings("A", english.bucketLabel(1));
    try testing.expectEqualStrings("Z", english.bucketLabel(26));
    const english_cases = [_]struct { name: []const u8, bucket: usize }{
        .{ .name = "Apple", .bucket = 1 },
        .{ .name = "banana", .bucket = 2 },
        .{ .name = "Öberg", .bucket = 15 },
        .{ .name = "Ångström", .bucket = 1 },
        .{ .name = "Zebra", .bucket = 26 },
        .{ .name = "Éclair", .bucket = 5 },
        .{ .name = "1st", .bucket = 0 },
        .{ .name = "", .bucket = 0 },
        .{ .name = "...", .bucket = 0 },
        .{ .name = "Иван", .bucket = 27 },
        .{ .name = "中国", .bucket = 27 },
    };
    for (english_cases) |case| {
        try testing.expectEqual(case.bucket, try english.bucketFor(case.name));
    }

    var swedish = try AlphabeticIndex.init(allocator, "sv");
    defer swedish.deinit();
    try testing.expectEqual(@as(usize, 31), swedish.bucketCount());
    try testing.expectEqualStrings("Å", swedish.bucketLabel(27));
    try testing.expectEqualStrings("Ä", swedish.bucketLabel(28));
    try testing.expectEqualStrings("Ö", swedish.bucketLabel(29));
    try testing.expectEqual(@as(usize, 27), try swedish.bucketFor("Ångström"));
    try testing.expectEqual(@as(usize, 29), try swedish.bucketFor("Öberg"));

    var turkish = try AlphabeticIndex.init(allocator, "tr");
    defer turkish.deinit();
    try testing.expectEqualStrings("I", turkish.bucketLabel(10));
    try testing.expectEqualStrings("İ", turkish.bucketLabel(11));
    try testing.expectEqual(@as(usize, 10), try turkish.bucketFor("ıi"));
    try testing.expectEqual(@as(usize, 11), try turkish.bucketFor("İstanbul"));

    var russian = try AlphabeticIndex.init(allocator, "ru");
    defer russian.deinit();
    try testing.expectEqualStrings("Е", russian.bucketLabel(6));
    try testing.expectEqualStrings("Ж", russian.bucketLabel(7));
    try testing.expectEqual(@as(usize, 9), try russian.bucketFor("Иван"));
    try testing.expectEqual(
        @as(usize, russian.bucketCount() - 1),
        try russian.bucketFor("Apple"),
    );

    var hindi = try AlphabeticIndex.init(allocator, "hi");
    defer hindi.deinit();
    try testing.expectEqual(@as(usize, 44), try hindi.bucketFor("हिन्दी"));
    try testing.expectEqual(
        @as(usize, hindi.bucketCount() - 1),
        try hindi.bucketFor("Apple"),
    );

    var spanish = try AlphabeticIndex.init(allocator, "es");
    defer spanish.deinit();
    try testing.expectEqualStrings("Ñ", spanish.bucketLabel(15));
    try testing.expectEqual(@as(usize, 16), try spanish.bucketFor("Öberg"));
    try testing.expectEqual(@as(usize, 9), try spanish.bucketFor("İstanbul"));

    try testing.expectError(
        error.InvalidUtf8,
        english.bucketFor("\xff"),
    );
}

test "Chinese alphabetic index uses pinyin buckets" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var chinese = try AlphabeticIndex.init(allocator, "zh");
    defer chinese.deinit();
    try testing.expectEqual(@as(usize, 28), chinese.bucketCount());
    try testing.expectEqualStrings("A", chinese.bucketLabel(1));
    try testing.expectEqualStrings("Z", chinese.bucketLabel(26));
    const cases = [_]struct { name: []const u8, bucket: usize }{
        .{ .name = "阿", .bucket = 1 },
        .{ .name = "八", .bucket = 2 },
        .{ .name = "中", .bucket = 26 },
        .{ .name = "中国", .bucket = 26 },
        .{ .name = "Apple", .bucket = 1 },
        .{ .name = "zebra", .bucket = 26 },
        .{ .name = "1st", .bucket = 0 },
        .{ .name = "Иван", .bucket = 27 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.bucket, try chinese.bucketFor(case.name));
    }

    // Traditional Chinese uses the stroke index, whose labels are Kangxi
    // radicals; a Han name is not redirected through pinyin.
    var traditional = try AlphabeticIndex.init(allocator, "zh-Hant");
    defer traditional.deinit();
    try testing.expectEqualStrings("一", traditional.bucketLabel(1));
    try testing.expect(try traditional.bucketFor("八") != 2);
}
