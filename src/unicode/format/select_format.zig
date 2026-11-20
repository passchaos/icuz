//! ICU `SelectFormat`-compatible keyword selection.

const std = @import("std");
const branch_pattern = @import("branch_pattern.zig");

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
};

pub const SelectFormat = struct {
    allocator: std.mem.Allocator,
    pattern: []u8 = &.{},
    branches: []branch_pattern.Branch = &.{},

    pub fn init(allocator: std.mem.Allocator) SelectFormat {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SelectFormat) void {
        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        if (self.branches.len != 0) self.allocator.free(self.branches);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn applyPattern(self: *SelectFormat, pattern: []const u8) Error!void {
        const owned = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned);
        const branches = try branch_pattern.parseBranches(self.allocator, owned);
        errdefer self.allocator.free(branches);
        var has_other = false;
        for (branches) |branch| {
            if (std.mem.eql(u8, branch.key, "other")) has_other = true;
        }
        if (!has_other) return error.InvalidPattern;

        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        if (self.branches.len != 0) self.allocator.free(self.branches);
        self.pattern = owned;
        self.branches = branches;
    }

    pub fn toPattern(self: *const SelectFormat) []const u8 {
        return self.pattern;
    }

    pub fn formatAlloc(
        self: *const SelectFormat,
        allocator: std.mem.Allocator,
        keyword: []const u8,
    ) Error![]u8 {
        if (keyword.len == 0) return allocator.dupe(u8, "");
        var other: ?[]const u8 = null;
        for (self.branches) |branch| {
            if (std.mem.eql(u8, branch.key, keyword)) {
                return allocator.dupe(u8, branch.message);
            }
            if (std.mem.eql(u8, branch.key, "other")) {
                other = branch.message;
            }
        }
        return allocator.dupe(u8, other orelse return error.InvalidPattern);
    }
};

test "SelectFormat selection" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var format = SelectFormat.init(allocator);
    defer format.deinit();
    try format.applyPattern("female {She} male {He} other {They}");
    const she = try format.formatAlloc(allocator, "female");
    defer allocator.free(she);
    try testing.expectEqualStrings("She", she);
    const he = try format.formatAlloc(allocator, "male");
    defer allocator.free(he);
    try testing.expectEqualStrings("He", he);
    const they = try format.formatAlloc(allocator, "unknown");
    defer allocator.free(they);
    try testing.expectEqualStrings("They", they);

    try testing.expectError(
        error.InvalidPattern,
        format.applyPattern("a {X} b {Y}"),
    );
}
