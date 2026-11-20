//! ICU-compatible region data (`uregion`).
//!
//! Regions cover ISO 3166 territories, UN M.49 macroregions, CLDR groupings,
//! and deprecated codes. Lookup accepts canonical codes, alpha-3 aliases,
//! numeric strings, and numeric codes; deprecated regions with a single
//! preferred replacement canonicalize to that replacement, matching ICU.

const std = @import("std");

pub const RegionType = enum(u8) {
    unknown = 0,
    territory = 1,
    world = 2,
    continent = 3,
    subcontinent = 4,
    grouping = 5,
    deprecated = 6,
};

const data = @embedFile("region_data.bin");
const magic = "CJR0";
const header_len = 24;
const region_record_len = 20;
const alias_record_len = 8;
const numeric_record_len = 4;

const header = parseHeader();

pub const Region = struct {
    index: u16,

    pub fn code(self: Region) []const u8 {
        const base = header.regions_offset + @as(usize, self.index) * region_record_len;
        const offset = readU32(base);
        const length = data[base + 4];
        return data[header.strings_offset + offset ..][0..length];
    }

    pub fn regionType(self: Region) RegionType {
        const base = header.regions_offset + @as(usize, self.index) * region_record_len;
        return @enumFromInt(data[base + 5]);
    }

    /// UN M.49 numeric code, or -1 when the region has none.
    pub fn numericCode(self: Region) i32 {
        const base = header.regions_offset + @as(usize, self.index) * region_record_len;
        return readI16(base + 6);
    }

    pub fn containing(self: Region) ?Region {
        const base = header.regions_offset + @as(usize, self.index) * region_record_len;
        const parent = readU16(base + 8);
        if (parent == 0xffff) return null;
        return .{ .index = parent };
    }

    /// Walk up the containment chain until a region of `kind` is found.
    /// Grouping, deprecated, and unknown types never match.
    pub fn containingOfType(self: Region, kind: RegionType) ?Region {
        if (kind == .grouping or kind == .deprecated or kind == .unknown) {
            return null;
        }
        var current = self.containing();
        while (current) |region| {
            if (region.regionType() == kind) return region;
            current = region.containing();
        }
        return null;
    }

    /// True when `other` is a descendant of this region. A region does not
    /// contain itself, matching ICU's `uregion_contains`.
    pub fn contains(self: Region, other: Region) bool {
        return containsIndex(self.index, other.index, 0);
    }

    pub fn childrenAlloc(
        self: Region,
        allocator: std.mem.Allocator,
    ) ![]Region {
        const base = header.regions_offset + @as(usize, self.index) * region_record_len;
        const start = readU16(base + 10);
        const length = readU16(base + 12);
        const result = try allocator.alloc(Region, length);
        for (result, 0..) |*region, index| {
            region.* = .{ .index = readU16(header.children_offset + (@as(usize, start) + index) * 2) };
        }
        return result;
    }

    pub fn childrenOfTypeAlloc(
        self: Region,
        allocator: std.mem.Allocator,
        kind: RegionType,
    ) ![]Region {
        const all = try self.childrenAlloc(allocator);
        defer allocator.free(all);
        var count: usize = 0;
        for (all) |region| {
            if (region.regionType() == kind) count += 1;
        }
        const result = try allocator.alloc(Region, count);
        var index: usize = 0;
        for (all) |region| {
            if (region.regionType() == kind) {
                result[index] = region;
                index += 1;
            }
        }
        return result;
    }

    /// Preferred replacements for a deprecated region; empty otherwise.
    pub fn preferredValuesAlloc(
        self: Region,
        allocator: std.mem.Allocator,
    ) ![]Region {
        const base = header.regions_offset + @as(usize, self.index) * region_record_len;
        const start = readU16(base + 14);
        const length = readU16(base + 16);
        const result = try allocator.alloc(Region, length);
        for (result, 0..) |*region, index| {
            region.* = .{ .index = readU16(header.preferred_offset + (@as(usize, start) + index) * 2) };
        }
        return result;
    }
};

pub fn areEqual(a: Region, b: Region) bool {
    return a.index == b.index;
}

pub fn fromCode(code: []const u8) ?Region {
    if (code.len == 0 or code.len > 8) return null;
    if (findRegion(code)) |region| {
        return canonical(region);
    }
    if (findAlias(code)) |region| {
        return canonical(region);
    }
    return null;
}

pub fn fromNumericCode(code: i32) ?Region {
    if (code <= 0 or code > std.math.maxInt(u16)) return null;
    const numeric: u16 = @intCast(code);
    var low: usize = 0;
    var high = header.numeric_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = header.numeric_offset + middle * numeric_record_len;
        const value = readU16(base);
        if (numeric < value) {
            high = middle;
        } else if (numeric > value) {
            low = middle + 1;
        } else {
            const target = readU16(base + 2);
            return canonical(.{ .index = target });
        }
    }

    var buffer: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{numeric}) catch return null;
    if (findAlias(text)) |region| return canonical(region);
    return null;
}

pub fn availableAlloc(
    allocator: std.mem.Allocator,
    kind: RegionType,
) ![]Region {
    var count: usize = 0;
    for (0..header.region_count) |index| {
        if (regionTypeAt(index) == kind) count += 1;
    }
    const result = try allocator.alloc(Region, count);
    var cursor: usize = 0;
    for (0..header.region_count) |index| {
        if (regionTypeAt(index) == kind) {
            result[cursor] = .{ .index = @intCast(index) };
            cursor += 1;
        }
    }
    return result;
}

fn canonical(region: Region) Region {
    if (region.regionType() != .deprecated) return region;
    const base = header.regions_offset + @as(usize, region.index) * region_record_len;
    if (readU16(base + 16) != 1) return region;
    const target = readU16(header.preferred_offset + @as(usize, readU16(base + 14)) * 2);
    return .{ .index = target };
}

fn containsIndex(self: u16, target: u16, depth: u32) bool {
    if (depth > 8) return false;
    const base = header.regions_offset + @as(usize, self) * region_record_len;
    const start = readU16(base + 10);
    const length = readU16(base + 12);
    for (0..length) |offset| {
        const child = readU16(header.children_offset + (@as(usize, start) + offset) * 2);
        if (child == target) return true;
        if (containsIndex(child, target, depth + 1)) return true;
    }
    return false;
}

fn findRegion(code: []const u8) ?Region {
    var low: usize = 0;
    var high = header.region_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = regionCodeAt(middle);
        const order = std.mem.order(u8, candidate, code);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return .{ .index = @intCast(middle) },
        }
    }
    return null;
}

fn findAlias(code: []const u8) ?Region {
    var low: usize = 0;
    var high = header.alias_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = header.aliases_offset + middle * alias_record_len;
        const offset = readU32(base);
        const length = data[base + 4];
        const candidate = data[header.strings_offset + offset ..][0..length];
        const order = std.mem.order(u8, candidate, code);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return .{ .index = readU16(base + 6) },
        }
    }
    return null;
}

fn regionCodeAt(index: usize) []const u8 {
    const base = header.regions_offset + index * region_record_len;
    const offset = readU32(base);
    const length = data[base + 4];
    return data[header.strings_offset + offset ..][0..length];
}

fn regionTypeAt(index: usize) RegionType {
    const base = header.regions_offset + index * region_record_len;
    return @enumFromInt(data[base + 5]);
}

const Header = struct {
    region_count: usize,
    alias_count: usize,
    numeric_count: usize,
    regions_offset: usize,
    aliases_offset: usize,
    numeric_offset: usize,
    children_offset: usize,
    preferred_offset: usize,
    strings_offset: usize,
};

fn parseHeader() Header {
    if (!std.mem.eql(u8, data[0..4], magic)) @compileError("invalid region data magic");
    const region_count = readU16Const(8);
    const alias_count = readU16Const(10);
    const numeric_count = readU16Const(12);
    const string_len = readU16Const(14);
    const children_count = readU32Const(16);
    const preferred_count = readU32Const(20);
    const regions_offset = header_len;
    const aliases_offset = regions_offset + region_count * region_record_len;
    const numeric_offset = aliases_offset + alias_count * alias_record_len;
    const children_offset = numeric_offset + numeric_count * numeric_record_len;
    const preferred_offset = children_offset + children_count * 2;
    const strings_offset = preferred_offset + preferred_count * 2;
    if (strings_offset + string_len != data.len) {
        @compileError("invalid region data layout");
    }
    return .{
        .region_count = region_count,
        .alias_count = alias_count,
        .numeric_count = numeric_count,
        .regions_offset = regions_offset,
        .aliases_offset = aliases_offset,
        .numeric_offset = numeric_offset,
        .children_offset = children_offset,
        .preferred_offset = preferred_offset,
        .strings_offset = strings_offset,
    };
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readI16(offset: usize) i16 {
    return std.mem.readInt(i16, data[offset..][0..2], .little);
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

test "region lookup and types" {
    const testing = std.testing;
    const world = fromCode("001").?;
    try testing.expectEqual(RegionType.world, world.regionType());
    try testing.expectEqual(@as(i32, 1), world.numericCode());

    const us = fromCode("US").?;
    try testing.expectEqualStrings("US", us.code());
    try testing.expectEqual(RegionType.territory, us.regionType());
    try testing.expectEqual(@as(i32, 840), us.numericCode());
    try testing.expectEqualStrings("021", us.containing().?.code());
    try testing.expectEqualStrings("019", us.containingOfType(.continent).?.code());

    const eu = fromCode("EU").?;
    try testing.expectEqual(RegionType.grouping, eu.regionType());
    try testing.expect(fromCode("QU").?.index == eu.index);
    try testing.expect(fromCode("QUU").?.index == eu.index);
    try testing.expect(fromCode("840").?.index == us.index);
    try testing.expect(fromCode("USA").?.index == us.index);
    try testing.expect(fromCode("us") == null);
    try testing.expect(fromCode("AA") == null);

    const an = fromCode("AN").?;
    try testing.expectEqual(RegionType.deprecated, an.regionType());
    try testing.expectEqualStrings("AN", an.code());
    try testing.expect(fromNumericCode(530).?.index == an.index);

    try testing.expect(fromNumericCode(840).?.index == us.index);
    try testing.expect(fromNumericCode(967).?.index == eu.index);
    try testing.expect(fromNumericCode(999).?.code()[0] == 'Z');
    try testing.expect(fromNumericCode(0) == null);
}

test "region containment and children" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const world = fromCode("001").?;
    const africa = fromCode("002").?;
    const us = fromCode("US").?;
    const eu = fromCode("EU").?;

    try testing.expect(world.contains(us));
    try testing.expect(world.contains(africa));
    try testing.expect(!us.contains(world));
    try testing.expect(!us.contains(us));
    try testing.expect(eu.contains(us) == false);
    try testing.expect(eu.contains(fromCode("AT").?));

    const children = try world.childrenAlloc(allocator);
    defer allocator.free(children);
    try testing.expectEqual(@as(usize, 5), children.len);
    try testing.expectEqualStrings("019", children[0].code());

    const african_children = try africa.childrenAlloc(allocator);
    defer allocator.free(african_children);
    try testing.expectEqual(@as(usize, 5), african_children.len);

    const groupings = try world.childrenOfTypeAlloc(allocator, .grouping);
    defer allocator.free(groupings);
    try testing.expectEqual(@as(usize, 0), groupings.len);

    const available = try availableAlloc(allocator, .grouping);
    defer allocator.free(available);
    try testing.expectEqual(@as(usize, 6), available.len);
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

    fn readI32(self: *Fixture) !i32 {
        if (self.index + 4 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(i32, self.data[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    fn string(self: *Fixture) ![]const u8 {
        const length = try self.readU16();
        if (self.index + length > self.data.len) return error.Truncated;
        const value = self.data[self.index..][0..length];
        self.index += length;
        return value;
    }
};

fn expectRegion(expected_ok: bool, code: []const u8, kind: u8, numeric: i32, parent: []const u8, actual: ?Region) !void {
    if (!expected_ok) {
        try std.testing.expect(actual == null);
        return;
    }
    const region = actual orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(code, region.code());
    try std.testing.expectEqual(@as(RegionType, @enumFromInt(kind)), region.regionType());
    try std.testing.expectEqual(numeric, region.numericCode());
    if (parent.len == 0) {
        try std.testing.expect(region.containing() == null);
    } else {
        try std.testing.expectEqualStrings(parent, region.containing().?.code());
    }
}

fn expectCodeList(expected: []const []const u8, actual: []const Region) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |code, region| {
        try std.testing.expectEqualStrings(code, region.code());
    }
}

test "region ICU conformance fixture" {
    const fixture_data = @embedFile("region_conformance.bin");
    try std.testing.expectEqualSlices(u8, "CJRC", fixture_data[0..4]);
    var fixture = Fixture{ .data = fixture_data, .index = 8 };
    const case_count = std.mem.readInt(u32, fixture.data[fixture.index..][0..4], .little);
    fixture.index += 4;
    const allocator = std.testing.allocator;

    var passed: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const kind = try fixture.readU8();
        switch (kind) {
            0 => {
                const code = try fixture.string();
                const ok = (try fixture.readU8()) != 0;
                var expected_code: []const u8 = "";
                var expected_kind: u8 = 0;
                var expected_numeric: i32 = -1;
                var expected_parent: []const u8 = "";
                if (ok) {
                    expected_code = try fixture.string();
                    expected_kind = try fixture.readU8();
                    expected_numeric = try fixture.readI32();
                    expected_parent = try fixture.string();
                }
                const actual = fromCode(code);
                try expectRegion(ok, expected_code, expected_kind, expected_numeric, expected_parent, actual);
            },
            1 => {
                const value = try fixture.readI32();
                const ok = (try fixture.readU8()) != 0;
                var expected_code: []const u8 = "";
                var expected_kind: u8 = 0;
                var expected_numeric: i32 = -1;
                var expected_parent: []const u8 = "";
                if (ok) {
                    expected_code = try fixture.string();
                    expected_kind = try fixture.readU8();
                    expected_numeric = try fixture.readI32();
                    expected_parent = try fixture.string();
                }
                try expectRegion(ok, expected_code, expected_kind, expected_numeric, expected_parent, fromNumericCode(value));
            },
            2 => {
                const type_value = try fixture.readU8();
                const count = try fixture.readU16();
                const expected = try allocator.alloc([]const u8, count);
                defer allocator.free(expected);
                for (expected) |*code| code.* = try fixture.string();
                const actual = try availableAlloc(allocator, @enumFromInt(type_value));
                defer allocator.free(actual);
                try std.testing.expectEqual(@as(usize, count), actual.len);
                for (expected) |code| {
                    var found = false;
                    for (actual) |region| {
                        if (std.mem.eql(u8, code, region.code())) {
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);
                }
            },
            3 => {
                const code = try fixture.string();
                const count = try fixture.readU16();
                const expected = try allocator.alloc([]const u8, count);
                defer allocator.free(expected);
                for (expected) |*child| child.* = try fixture.string();
                const region = fromCode(code).?;
                const actual = try region.childrenAlloc(allocator);
                defer allocator.free(actual);
                try expectCodeList(expected, actual);
            },
            5 => {
                const code = try fixture.string();
                const count = try fixture.readU16();
                const expected = try allocator.alloc([]const u8, count);
                defer allocator.free(expected);
                for (expected) |*target| target.* = try fixture.string();
                const region = fromCode(code).?;
                const actual = try region.preferredValuesAlloc(allocator);
                defer allocator.free(actual);
                try expectCodeList(expected, actual);
            },
            4 => {
                const pair = try fixture.string();
                const expected = (try fixture.readU8()) != 0;
                const separator = std.mem.indexOfScalar(u8, pair, '|').?;
                const first = fromCode(pair[0..separator]).?;
                const second = fromCode(pair[separator + 1 ..]).?;
                try std.testing.expectEqual(expected, first.contains(second));
            },
            else => return error.UnknownCaseKind,
        }
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), fixture_data.len - fixture.index);
    std.debug.print("region conformance: {}/{} passed\n", .{ passed, case_count });
}
