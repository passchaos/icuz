//! Byte-literal search for the regex VM fast paths.
//!
//! `std.mem.indexOfPos` runs Boyer-Moore-Horspool, which rebuilds a 256-entry
//! skip table on every call. A matcher invokes it once per match, so for the
//! short literals and short gaps typical of regex workloads the per-call
//! preprocessing costs more than the scan itself. Scanning for the first byte
//! with the standard library's vectorized scalar search and verifying with
//! `eql` does no setup at all.

const std = @import("std");

/// First occurrence of `needle` in `haystack` at or after `start`.
pub fn indexOf(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (start <= haystack.len) start else null;
    if (needle.len == 1) {
        return std.mem.indexOfScalarPos(u8, haystack, start, needle[0]);
    }
    var offset = start;
    while (std.mem.indexOfScalarPos(u8, haystack, offset, needle[0])) |found| {
        if (needle.len <= haystack.len - found and
            std.mem.eql(u8, haystack[found..][0..needle.len], needle))
        {
            return found;
        }
        offset = found + 1;
    }
    return null;
}

test "indexOf matches std.mem.indexOfPos" {
    const cases = [_]struct { haystack: []const u8, needle: []const u8 }{
        .{ .haystack = "", .needle = "" },
        .{ .haystack = "", .needle = "a" },
        .{ .haystack = "abcabc", .needle = "" },
        .{ .haystack = "abcabc", .needle = "a" },
        .{ .haystack = "abcabc", .needle = "bc" },
        .{ .haystack = "abcabc", .needle = "abc" },
        .{ .haystack = "abcabc", .needle = "cab" },
        .{ .haystack = "abcabc", .needle = "cba" },
        .{ .haystack = "aaaaab", .needle = "aaab" },
        .{ .haystack = "some text before needle and after needle " ** 8, .needle = "needle" },
        .{ .haystack = "日本語のテキスト", .needle = "語の" },
    };
    for (cases) |case| {
        var start: usize = 0;
        while (start <= case.haystack.len) : (start += 1) {
            try std.testing.expectEqual(
                std.mem.indexOfPos(u8, case.haystack, start, case.needle),
                indexOf(case.haystack, start, case.needle),
            );
        }
    }
}
