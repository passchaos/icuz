//! Normalizer2 boundary, inert, and incremental append helpers.
//!
//! The boundary flags come from a generated CJNB table that records the
//! (isInert, hasBoundaryBefore, hasBoundaryAfter) tuple for every scalar and
//! normalization form whose tuple differs from the all-true default. The
//! table is generated from PyICU's Normalizer2 API.

const std = @import("std");
const root = @import("root.zig");
const data = @import("data.zig");

pub const Form = data.Form;

const blob = @embedFile("boundary_data.bin");
const header_len = 12;
const entry_len = 8;
const entry_count = std.mem.readInt(u32, blob[8..12], .little);

comptime {
    if (blob.len < header_len or
        !std.mem.eql(u8, blob[0..4], "CJNB") or blob[4] != 1)
    {
        @compileError("invalid Normalizer2 boundary data");
    }
    if (header_len + @as(usize, entry_count) * entry_len != blob.len) {
        @compileError("invalid Normalizer2 boundary data lengths");
    }
}

/// True when the scalar has no normalization interactions in `form`.
pub inline fn isInert(codepoint: u21, form: Form) bool {
    return flagsFor(codepoint, form) & 1 != 0;
}

/// True when normalization of text starting with `codepoint` cannot interact
/// with the preceding scalar.
pub inline fn hasBoundaryBefore(codepoint: u21, form: Form) bool {
    return flagsFor(codepoint, form) & 2 != 0;
}

/// True when normalization of text ending with `codepoint` cannot interact
/// with the following scalar.
pub inline fn hasBoundaryAfter(codepoint: u21, form: Form) bool {
    return flagsFor(codepoint, form) & 4 != 0;
}

fn flagsFor(codepoint: u21, form: Form) u8 {
    const form_index: u8 = @intFromEnum(form);
    var low: usize = 0;
    var high: usize = entry_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = header_len + middle * entry_len;
        const entry_cp = std.mem.readInt(u32, blob[base..][0..4], .little);
        if (codepoint < entry_cp) {
            high = middle;
            continue;
        }
        if (codepoint > entry_cp) {
            low = middle + 1;
            continue;
        }
        const entry_form = blob[base + 4];
        if (form_index < entry_form) {
            high = middle;
        } else if (form_index > entry_form) {
            low = middle + 1;
        } else {
            return blob[base + 5];
        }
    }
    return 7;
}

/// Append the normalized `second` string to the already-normalized `first`
/// string without recomposing the boundary, like ICU's `Normalizer2.append`.
pub fn appendAlloc(
    allocator: std.mem.Allocator,
    first: []const u8,
    second: []const u8,
    form: Form,
) root.Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, first);
    _ = try root.normalizeFormInto(allocator, second, form, &output);
    return output.toOwnedSlice(allocator);
}

/// Append `second` to `first` and normalize the boundary as well, like ICU's
/// `Normalizer2.normalizeSecondAndAppend`.
pub fn normalizeSecondAndAppendAlloc(
    allocator: std.mem.Allocator,
    first: []const u8,
    second: []const u8,
    form: Form,
) root.Error![]u8 {
    const combined = try std.mem.concat(allocator, u8, &.{ first, second });
    defer allocator.free(combined);
    if (try root.normalizeFormAlloc(allocator, combined, form)) |normalized| {
        return normalized;
    }
    return allocator.dupe(u8, combined);
}

test "normalizer2 boundary and inert flags" {
    const testing = @import("std").testing;
    try testing.expect(!isInert('a', .nfc));
    try testing.expect(isInert('a', .nfd));
    try testing.expect(!hasBoundaryBefore(0x0301, .nfc));
    try testing.expect(!hasBoundaryAfter(0x0301, .nfc));
    try testing.expect(isInert(0x1f600, .nfc));
    try testing.expect(!isInert(0xac00, .nfd));
    try testing.expect(!hasBoundaryAfter(0xac00, .nfc));
}

test "normalizer2 incremental append" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const appended = try appendAlloc(allocator, "a", "\u{0301}", .nfc);
    defer allocator.free(appended);
    try testing.expectEqualStrings("a\u{0301}", appended);

    const composed = try normalizeSecondAndAppendAlloc(
        allocator,
        "a",
        "\u{0301}",
        .nfc,
    );
    defer allocator.free(composed);
    try testing.expectEqualStrings("\u{00e1}", composed);
}
