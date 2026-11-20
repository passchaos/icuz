//! ICU common data (`.dat`) package reader.
//!
//! A package groups multiple `.res` bundles behind a `CmnD` table of
//! contents. `DataPackage` locates items by full name or by their
//! package-relative suffix and opens them as `ResourceBundle`s.

const std = @import("std");
const res = @import("res.zig");

pub const Error = res.Error;

const toc_header_size = 4;
const toc_entry_size = 8;

pub const DataPackage = struct {
    bytes: []const u8,
    endian: res.Endian,
    header_size: usize,
    toc_offset: usize,
    entry_count: usize,

    pub fn init(bytes: []const u8) Error!DataPackage {
        if (bytes.len < 32) return error.InvalidFormat;
        const endian: res.Endian = if (bytes[8] != 0) .big else .little;
        const header_size = readU16(bytes, 0, endian) orelse
            return error.InvalidFormat;
        if (bytes[2] != 0xda or bytes[3] != 0x27) {
            return error.InvalidFormat;
        }
        if (header_size < 24 or header_size > bytes.len) {
            return error.InvalidFormat;
        }
        const info_size = readU16(bytes, 4, endian) orelse
            return error.InvalidFormat;
        if (info_size < 20) return error.InvalidFormat;
        if (!std.mem.eql(u8, bytes[12..16], "CmnD")) {
            return error.UnsupportedFormat;
        }
        if (bytes[16] != 1) return error.UnsupportedFormat;
        if (bytes[9] != 0) return error.UnsupportedFormat;

        const toc_offset = header_size;
        const entry_count = readU32(bytes, toc_offset, endian) orelse
            return error.InvalidFormat;
        const count_usize: usize = entry_count;
        if (count_usize > (bytes.len - toc_offset) / toc_entry_size) {
            return error.InvalidFormat;
        }
        if (toc_offset + toc_header_size +
            count_usize * toc_entry_size > bytes.len)
        {
            return error.InvalidFormat;
        }

        var previous_data_offset: u32 = 0;
        var index: usize = 0;
        while (index < count_usize) : (index += 1) {
            const entry_offset = toc_offset + toc_header_size +
                index * toc_entry_size;
            const name_offset = readU32(bytes, entry_offset, endian) orelse
                return error.InvalidFormat;
            const data_offset =
                readU32(bytes, entry_offset + 4, endian) orelse
                return error.InvalidFormat;
            if (name_offset >= bytes.len - toc_offset) {
                return error.InvalidFormat;
            }
            if (data_offset > bytes.len - toc_offset) {
                return error.InvalidFormat;
            }
            if (index > 0 and data_offset < previous_data_offset) {
                return error.InvalidFormat;
            }
            previous_data_offset = data_offset;
            var name_end = toc_offset + name_offset;
            while (name_end < bytes.len and bytes[name_end] != 0) {
                name_end += 1;
            }
            if (name_end == bytes.len) return error.InvalidFormat;
        }
        return .{
            .bytes = bytes,
            .endian = endian,
            .header_size = header_size,
            .toc_offset = toc_offset,
            .entry_count = count_usize,
        };
    }

    pub fn count(self: *const DataPackage) usize {
        return self.entry_count;
    }

    pub fn nameAt(self: *const DataPackage, index: usize) ?[]const u8 {
        if (index >= self.entry_count) return null;
        const entry_offset = self.toc_offset + toc_header_size +
            index * toc_entry_size;
        const name_offset = readU32(
            self.bytes,
            entry_offset,
            self.endian,
        ) orelse return null;
        const start = self.toc_offset + @as(usize, name_offset);
        if (start >= self.bytes.len) return null;
        var end = start;
        while (end < self.bytes.len and self.bytes[end] != 0) end += 1;
        if (end == self.bytes.len) return null;
        return self.bytes[start..end];
    }

    pub fn itemAt(self: *const DataPackage, index: usize) ?[]const u8 {
        if (index >= self.entry_count) return null;
        const entry_offset = self.toc_offset + toc_header_size +
            index * toc_entry_size;
        const data_offset = readU32(
            self.bytes,
            entry_offset + 4,
            self.endian,
        ) orelse return null;
        const start = self.toc_offset + @as(usize, data_offset);
        var end = self.bytes.len;
        if (index + 1 < self.entry_count) {
            const next_entry = entry_offset + toc_entry_size;
            const next_offset = readU32(
                self.bytes,
                next_entry + 4,
                self.endian,
            ) orelse return null;
            end = self.toc_offset + @as(usize, next_offset);
        }
        if (start > end or end > self.bytes.len) return null;
        return self.bytes[start..end];
    }

    /// Returns the package name shared by all entries, for example "icudt78l".
    pub fn packageName(self: *const DataPackage) ?[]const u8 {
        const first = self.nameAt(0) orelse return null;
        const slash = std.mem.indexOfScalar(u8, first, '/') orelse return "";
        return first[0..slash];
    }

    fn nameMatches(entry_name: []const u8, name: []const u8) bool {
        if (std.mem.eql(u8, entry_name, name)) return true;
        if (entry_name.len <= name.len) return false;
        if (!std.mem.endsWith(u8, entry_name, name)) return false;
        return entry_name[entry_name.len - name.len - 1] == '/';
    }

    /// Finds an item by full TOC name or by its package-relative suffix.
    pub fn find(self: *const DataPackage, name: []const u8) ?[]const u8 {
        if (self.indexOfExact(name)) |index| return self.itemAt(index);
        var index: usize = 0;
        while (index < self.entry_count) : (index += 1) {
            const entry_name = self.nameAt(index) orelse continue;
            if (nameMatches(entry_name, name)) return self.itemAt(index);
        }
        return null;
    }

    pub fn indexOfExact(
        self: *const DataPackage,
        name: []const u8,
    ) ?usize {
        var start: usize = 0;
        var limit: usize = self.entry_count;
        while (start < limit) {
            const mid = start + (limit - start) / 2;
            const entry_name = self.nameAt(mid) orelse return null;
            switch (std.mem.order(u8, name, entry_name)) {
                .lt => limit = mid,
                .gt => start = mid + 1,
                .eq => return mid,
            }
        }
        return null;
    }

    fn poolNameFor(
        self: *const DataPackage,
        bundle_index: usize,
        buffer: []u8,
    ) ?[]const u8 {
        const full = self.nameAt(bundle_index) orelse return null;
        const slash = std.mem.lastIndexOfScalar(u8, full, '/') orelse
            return "pool.res";
        const prefix_length = slash + 1;
        const suffix = "pool.res";
        if (prefix_length + suffix.len > buffer.len) return null;
        @memcpy(buffer[0..prefix_length], full[0..prefix_length]);
        @memcpy(buffer[prefix_length..][0..suffix.len], suffix);
        return buffer[0 .. prefix_length + suffix.len];
    }

    /// Opens a bundle item, attaching its pool bundle when required.
    pub fn openBundle(
        self: *const DataPackage,
        name: []const u8,
    ) Error!res.ResourceBundle {
        const item = self.find(name) orelse return error.NotFound;
        var bundle = try res.ResourceBundle.init(item);
        if (!bundle.uses_pool_bundle) return bundle;

        const bundle_index = self.indexOfExact(name) orelse
            self.findIndexBySuffix(name) orelse return error.NotFound;
        var pool_buffer: [512]u8 = undefined;
        var pool_item: ?[]const u8 = null;
        if (self.poolNameFor(bundle_index, &pool_buffer)) |pool_name| {
            pool_item = self.find(pool_name);
        }
        if (pool_item == null) pool_item = self.find("pool.res");
        const pool_bytes = pool_item orelse return error.NotFound;
        bundle = try res.ResourceBundle.initWithPool(item, pool_bytes);
        return bundle;
    }

    fn findIndexBySuffix(
        self: *const DataPackage,
        name: []const u8,
    ) ?usize {
        var index: usize = 0;
        while (index < self.entry_count) : (index += 1) {
            const entry_name = self.nameAt(index) orelse continue;
            if (nameMatches(entry_name, name)) return index;
        }
        return null;
    }
};

fn readU16(bytes: []const u8, offset: usize, endian: res.Endian) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], endian);
}

fn readU32(bytes: []const u8, offset: usize, endian: res.Endian) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], endian);
}

fn expectBundleString(
    bundle: *const res.ResourceBundle,
    path: []const u8,
    expected: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const ref = try bundle.getString(path);
    const text = try ref.toUtf8Alloc(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "data package table of contents" {
    const testing = @import("std").testing;
    const bytes = @embedFile("fixtures/icudt_test.dat");
    const package = try DataPackage.init(bytes);

    try testing.expectEqual(@as(usize, 7), package.count());
    try testing.expectEqualStrings("icudt_test", package.packageName().?);
    try testing.expectEqualStrings(
        "icudt_test/en.res",
        package.nameAt(0).?,
    );
    try testing.expect(package.find("root.res") != null);
    try testing.expect(package.find("icudt_test/root.res") != null);
    try testing.expect(package.find("en_US.res") != null);
    try testing.expect(package.find("pooled_root.res") != null);
    try testing.expect(package.find("missing.res") == null);
    try testing.expect(package.itemAt(0).?.len > 32);
    try testing.expectEqualStrings(
        "ResB",
        package.itemAt(0).?[12..16],
    );

    var broken = bytes[0..32].*;
    broken[2] = 0;
    try testing.expectError(error.InvalidFormat, DataPackage.init(&broken));
}

test "data package bundle lookup" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const bytes = @embedFile("fixtures/icudt_test.dat");
    const package = try DataPackage.init(bytes);

    const root = try package.openBundle("root.res");
    try expectBundleString(&root, "greeting", "hello", allocator);
    try testing.expectEqual(@as(i32, 42), try root.getInt("count"));
    try expectBundleString(&root, "aliasClient", "aliased", allocator);

    const en = try package.openBundle("en.res");
    try expectBundleString(&en, "greeting", "hi", allocator);
    try expectBundleString(&en, "extra", "english only", allocator);

    const en_us = try package.openBundle("en_US.res");
    try expectBundleString(&en_us, "greeting", "howdy", allocator);

    const pooled = try package.openBundle("pooled_root.res");
    try expectBundleString(&pooled, "greeting", "hello", allocator);
    try expectBundleString(&pooled, "shared", "common value", allocator);
    try expectBundleString(
        &pooled,
        "nested/deeper/inner",
        "deep",
        allocator,
    );

    try testing.expectError(error.NotFound, package.openBundle("missing"));
}

test "ICU data package conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const package_bytes = @embedFile("fixtures/icudt_test.dat");
    const fixture = @embedFile("dat_conformance.bin");
    const package = try DataPackage.init(package_bytes);

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGN", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const bundle_names = [_][]const u8{
        "root.res",
        "en.res",
        "en_US.res",
        "pooled_root.res",
        "pooled_en.res",
    };
    var bundles: [5]res.ResourceBundle = undefined;
    for (bundle_names, 0..) |name, index| {
        bundles[index] = try package.openBundle(name);
    }

    var cursor: usize = 12;
    var failures: usize = 0;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const bundle_index = fixture[cursor];
        cursor += 1;
        const kind = fixture[cursor];
        cursor += 1;
        const path_length = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        const path = fixture[cursor..][0..path_length];
        cursor += path_length;
        if (bundle_index >= bundles.len) return error.InvalidFixture;
        const bundle = &bundles[bundle_index];

        switch (kind) {
            0 => {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const expected_ref = res.StringRef{
                    .bytes = fixture,
                    .unit_offset = cursor,
                    .len = length,
                    .endian = .little,
                };
                cursor += @as(usize, length) * 2;
                const expected = try expected_ref.toUtf8Alloc(allocator);
                defer allocator.free(expected);
                const actual_ref = bundle.getString(path) catch {
                    failures += 1;
                    continue;
                };
                const actual = try actual_ref.toUtf8Alloc(allocator);
                defer allocator.free(actual);
                if (!std.mem.eql(u8, actual, expected)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "data package string mismatch: bundle {d} path [{s}] got [{s}] want [{s}]\n",
                            .{ bundle_index, path, actual, expected },
                        );
                    }
                }
            },
            1 => {
                const expected = std.mem.readInt(
                    i32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;
                const actual = bundle.getInt(path) catch {
                    failures += 1;
                    continue;
                };
                if (actual != expected) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "data package int mismatch: bundle {d} path [{s}] got {d} want {d}\n",
                            .{ bundle_index, path, actual, expected },
                        );
                    }
                }
            },
            else => return error.InvalidFixture,
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "data package conformance: {d} records passed\n",
        .{record_count},
    );
}
