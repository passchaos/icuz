//! Locale-fallback resource bundle set.
//!
//! `BundleSet` mirrors ICU's `ures_open` lookup chain: an exact locale, its
//! parent locales, and root. Missing keys fall back per path, `/LOCALE/`
//! aliases resolve against the requested locale's chain, and `bundle/path`
//! aliases switch to the named bundle's own chain.

const std = @import("std");
const res = @import("res.zig");

pub const Error = res.Error;

pub const Source = struct {
    locale: []const u8,
    bytes: []const u8,
    pool_bytes: ?[]const u8 = null,
};

const Entry = struct {
    locale: []u8,
    bundle: *res.ResourceBundle,
};

pub const BundleSet = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn init(
        allocator: std.mem.Allocator,
        sources: []const Source,
    ) !BundleSet {
        const entries = try allocator.alloc(Entry, sources.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                allocator.destroy(entry.bundle);
                allocator.free(entry.locale);
            }
            allocator.free(entries);
        }
        for (sources, 0..) |source, index| {
            const bundle = try allocator.create(res.ResourceBundle);
            bundle.* = if (source.pool_bytes) |pool_bytes|
                try res.ResourceBundle.initWithPool(source.bytes, pool_bytes)
            else
                try res.ResourceBundle.init(source.bytes);
            const locale = try allocator.dupe(u8, source.locale);
            entries[index] = .{ .locale = locale, .bundle = bundle };
            initialized += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *BundleSet) void {
        for (self.entries) |entry| {
            self.allocator.destroy(entry.bundle);
            self.allocator.free(entry.locale);
        }
        self.allocator.free(self.entries);
        self.* = .{ .allocator = self.allocator, .entries = &.{} };
    }

    fn localeEquals(left: []const u8, right: []const u8) bool {
        if (left.len != right.len) return false;
        for (left, right) |a, b| {
            const ca = if (a == '-') '_' else a;
            const cb = if (b == '-') '_' else b;
            if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
        }
        return true;
    }

    fn findEntry(self: *const BundleSet, locale: []const u8) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (localeEquals(entry.locale, locale)) return index;
        }
        return null;
    }

    fn parentLocale(locale: []const u8) []const u8 {
        var index = locale.len;
        while (index > 0) {
            index -= 1;
            if (locale[index] == '_' or locale[index] == '-') {
                return locale[0..index];
            }
        }
        return locale[0..0];
    }

    fn buildChain(
        self: *const BundleSet,
        locale: []const u8,
        buffer: []usize,
    ) Error![]usize {
        var length: usize = 0;
        var found_any = false;
        var current = locale;
        while (true) {
            if (self.findEntry(current)) |index| {
                if (length == buffer.len) return error.InvalidPath;
                buffer[length] = index;
                length += 1;
                found_any = true;
                if (self.entries[index].bundle.no_fallback) break;
            }
            if (current.len == 0) break;
            current = parentLocale(current);
        }
        if (!found_any) {
            if (self.findEntry("")) |index| {
                buffer[0] = index;
                length = 1;
            }
        }
        if (length == 0) return error.NotFound;
        return buffer[0..length];
    }

    fn aliasAscii(alias: res.StringRef, buffer: []u8) ?[]const u8 {
        if (alias.len > buffer.len) return null;
        for (0..alias.len) |index| {
            const unit = alias.at(index) orelse return null;
            if (unit > 0x7f) return null;
            buffer[index] = @intCast(unit);
        }
        return buffer[0..alias.len];
    }

    fn resolveValue(
        self: *const BundleSet,
        value: res.Value,
        requested_chain: []const usize,
        depth: usize,
    ) Error!res.Value {
        if (depth > 16) return error.InvalidAlias;
        return switch (value) {
            .alias => |alias| self.resolveAlias(alias, requested_chain, depth + 1),
            else => value,
        };
    }

    fn resolveAlias(
        self: *const BundleSet,
        alias: res.StringRef,
        requested_chain: []const usize,
        depth: usize,
    ) Error!res.Value {
        if (depth > 16) return error.InvalidAlias;
        var buffer: [512]u8 = undefined;
        const text = aliasAscii(alias, &buffer) orelse
            return error.InvalidAlias;
        if (text.len == 0) return error.InvalidAlias;

        var target = text;
        var chain_buffer: [32]usize = undefined;
        var target_chain: []const usize = requested_chain;
        if (std.mem.startsWith(u8, target, "/LOCALE/")) {
            target = target["/LOCALE/".len..];
        } else if (target[0] == '/') {
            target = target[1..];
        } else {
            const slash = std.mem.indexOfScalar(u8, target, '/');
            const bundle_name = if (slash) |index| target[0..index] else target;
            const target_index = self.findEntry(bundle_name) orelse
                (if (std.ascii.eqlIgnoreCase(bundle_name, "root"))
                    self.findEntry("")
                else
                    null) orelse
                return error.ExternalAlias;
            target_chain = try self.buildChain(
                self.entries[target_index].locale,
                &chain_buffer,
            );
            target = if (slash) |index| target[index + 1 ..] else "";
        }
        return self.findInChain(target_chain, target, requested_chain, depth + 1);
    }

    fn navigate(
        self: *const BundleSet,
        chain: []const usize,
        start: usize,
        path: []const u8,
        requested_chain: []const usize,
        depth: usize,
    ) Error!res.Value {
        var value = self.entries[chain[start]].bundle.root();
        var iterator = std.mem.splitScalar(u8, path, '/');
        while (iterator.next()) |segment| {
            if (segment.len == 0) continue;
            value = try self.resolveValue(value, requested_chain, depth);
            switch (value) {
                .table => |table| {
                    value = table.get(segment) orelse return error.NotFound;
                },
                .array => |array| {
                    const index = std.fmt.parseInt(usize, segment, 10) catch
                        return error.InvalidPath;
                    value = array.at(index) orelse return error.NotFound;
                },
                else => return error.TypeMismatch,
            }
        }
        return self.resolveValue(value, requested_chain, depth);
    }

    fn findInChain(
        self: *const BundleSet,
        chain: []const usize,
        path: []const u8,
        requested_chain: []const usize,
        depth: usize,
    ) Error!res.Value {
        for (chain, 0..) |_, start| {
            if (self.navigate(
                chain,
                start,
                path,
                requested_chain,
                depth,
            )) |value| {
                return value;
            } else |err| switch (err) {
                error.NotFound => continue,
                else => return err,
            }
        }
        return error.NotFound;
    }

    /// Looks up `path` for `locale`, using ICU-style parent and root fallback.
    pub fn find(
        self: *const BundleSet,
        locale: []const u8,
        path: []const u8,
    ) Error!res.Value {
        var chain_buffer: [32]usize = undefined;
        const chain = try self.buildChain(locale, &chain_buffer);
        return self.findInChain(chain, path, chain, 0);
    }

    pub fn getString(
        self: *const BundleSet,
        locale: []const u8,
        path: []const u8,
    ) Error!res.StringRef {
        return switch (try self.find(locale, path)) {
            .string => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getInt(
        self: *const BundleSet,
        locale: []const u8,
        path: []const u8,
    ) Error!i32 {
        return switch (try self.find(locale, path)) {
            .int => |value| value,
            .uint => |value| @bitCast(value),
            else => error.TypeMismatch,
        };
    }

    pub fn getUInt(
        self: *const BundleSet,
        locale: []const u8,
        path: []const u8,
    ) Error!u32 {
        return switch (try self.find(locale, path)) {
            .int => |value| @bitCast(value),
            .uint => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getTable(
        self: *const BundleSet,
        locale: []const u8,
        path: []const u8,
    ) Error!res.Table {
        return switch (try self.find(locale, path)) {
            .table => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getArray(
        self: *const BundleSet,
        locale: []const u8,
        path: []const u8,
    ) Error!res.Array {
        return switch (try self.find(locale, path)) {
            .array => |value| value,
            else => error.TypeMismatch,
        };
    }
};

fn expectSetString(
    set: *const BundleSet,
    locale: []const u8,
    path: []const u8,
    expected: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const ref = try set.getString(locale, path);
    const text = try ref.toUtf8Alloc(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "resource bundle set locale fallback" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const sources = [_]Source{
        .{ .locale = "", .bytes = @embedFile("fixtures/root.res") },
        .{ .locale = "en", .bytes = @embedFile("fixtures/en.res") },
        .{ .locale = "en_US", .bytes = @embedFile("fixtures/en_US.res") },
    };
    var set = try BundleSet.init(allocator, &sources);
    defer set.deinit();

    try expectSetString(&set, "en_US", "greeting", "howdy", allocator);
    try expectSetString(&set, "en_US", "extra", "english only", allocator);
    try expectSetString(&set, "en_US", "shared", "common value", allocator);
    try expectSetString(
        &set,
        "en_US",
        "nested/deeper/inner",
        "deep",
        allocator,
    );
    try testing.expectEqual(@as(i32, 42), try set.getInt("en_US", "count"));
    try expectSetString(&set, "en_GB", "greeting", "hi", allocator);
    try testing.expectEqual(@as(i32, 42), try set.getInt("en_GB", "count"));
    try expectSetString(&set, "fr", "greeting", "hello", allocator);
    try testing.expectError(error.NotFound, set.find("fr", "missing"));
}

test "resource bundle set aliases and fallback" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const sources = [_]Source{
        .{ .locale = "", .bytes = @embedFile("fixtures/root.res") },
        .{ .locale = "en", .bytes = @embedFile("fixtures/en.res") },
        .{ .locale = "en_US", .bytes = @embedFile("fixtures/en_US.res") },
    };
    var set = try BundleSet.init(allocator, &sources);
    defer set.deinit();

    try expectSetString(&set, "en", "aliasClient", "english aliased", allocator);
    try expectSetString(
        &set,
        "en_US",
        "aliasClient",
        "english aliased",
        allocator,
    );
    try expectSetString(&set, "", "aliasClient", "aliased", allocator);
    try expectSetString(&set, "", "bundleAlias", "hi", allocator);
    try expectSetString(&set, "", "directAlias", "english only", allocator);
    try expectSetString(&set, "", "nestedAlias", "english aliased", allocator);
    try expectSetString(&set, "", "aliasChain", "aliased", allocator);
    try expectSetString(
        &set,
        "en_US",
        "aliasChain",
        "english aliased",
        allocator,
    );
    try expectSetString(&set, "en", "crossRoot", "aliased", allocator);
    try testing.expectEqual(
        @as(i32, 42),
        try set.getInt("", "enCountAlias"),
    );
}

test "ICU resource bundle set conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("res_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGM", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const sources = [_]Source{
        .{ .locale = "", .bytes = @embedFile("fixtures/root.res") },
        .{ .locale = "en", .bytes = @embedFile("fixtures/en.res") },
        .{ .locale = "en_US", .bytes = @embedFile("fixtures/en_US.res") },
    };
    var set = try BundleSet.init(allocator, &sources);
    defer set.deinit();

    var cursor: usize = 12;
    var failures: usize = 0;
    var compared: usize = 0;
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

        if (bundle_index < 6) {
            res.skipConformancePayload(fixture, &cursor, kind);
            continue;
        }
        const locale: []const u8 = switch (bundle_index) {
            6 => "en_US",
            7 => "en",
            8 => "",
            else => return error.InvalidFixture,
        };

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
                const actual_ref = set.getString(locale, path) catch {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bundle set string missing: locale [{s}] path [{s}]\n",
                            .{ locale, path },
                        );
                    }
                    continue;
                };
                const actual = try actual_ref.toUtf8Alloc(allocator);
                defer allocator.free(actual);
                if (!std.mem.eql(u8, actual, expected)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bundle set string mismatch: locale [{s}] path [{s}] got [{s}] want [{s}]\n",
                            .{ locale, path, actual, expected },
                        );
                    }
                }
                compared += 1;
            },
            1 => {
                const expected = std.mem.readInt(
                    i32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;
                const actual = set.getInt(locale, path) catch {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bundle set int missing: locale [{s}] path [{s}]\n",
                            .{ locale, path },
                        );
                    }
                    continue;
                };
                if (actual != expected) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "bundle set int mismatch: locale [{s}] path [{s}] got {d} want {d}\n",
                            .{ locale, path, actual, expected },
                        );
                    }
                }
                compared += 1;
            },
            else => res.skipConformancePayload(fixture, &cursor, kind),
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expect(compared > 0);
    std.debug.print(
        "resource bundle set conformance: {d} records passed\n",
        .{compared},
    );
}
