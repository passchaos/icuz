//! ICU `ubiditransform`-compatible logical/visual conversion.
//!
//! Supports the 14 direct and inverse schemes. The two runs-only schemes
//! (`Logical LTR -> Logical RTL` and the reverse) return `error.Unsupported`.

const std = @import("std");
const paragraph = @import("paragraph.zig");
const resolver = @import("resolver.zig");
const property_data = @import("data.zig");
const shape = @import("../shape/root.zig");

pub const Error = error{
    InvalidArgument,
    InvalidUtf8,
    OutOfMemory,
};

pub const BaseLevel = enum { ltr, rtl, default_ltr, default_rtl };
pub const Order = enum { logical, visual };
pub const Mirroring = enum { off, on };

const Action = enum {
    shape,
    resolve,
    reorder,
    reverse,
    mirror,
    set_inverse,
    set_runs_only,
};

const Scheme = struct {
    in_level: u8,
    in_order: Order,
    out_level: u8,
    out_order: Order,
    digits_dir: shape.TextDirection,
    letters_dir: shape.TextDirection,
    base_level: u8,
    actions: []const Action,
};

const logical = shape.TextDirection.logical;
const visual = shape.TextDirection.visual_ltr;

const schemes = [_]Scheme{
    .{ .in_level = 0, .in_order = .logical, .out_level = 0, .out_order = .visual, .digits_dir = logical, .letters_dir = logical, .base_level = 0, .actions = &.{ .shape, .resolve, .reorder } },
    .{ .in_level = 1, .in_order = .logical, .out_level = 0, .out_order = .visual, .digits_dir = logical, .letters_dir = visual, .base_level = 1, .actions = &.{ .resolve, .reorder, .shape } },
    .{ .in_level = 0, .in_order = .logical, .out_level = 1, .out_order = .visual, .digits_dir = logical, .letters_dir = logical, .base_level = 0, .actions = &.{ .shape, .resolve, .reorder, .reverse } },
    .{ .in_level = 1, .in_order = .logical, .out_level = 1, .out_order = .visual, .digits_dir = logical, .letters_dir = visual, .base_level = 1, .actions = &.{ .resolve, .reorder, .shape, .reverse } },
    .{ .in_level = 0, .in_order = .visual, .out_level = 1, .out_order = .logical, .digits_dir = logical, .letters_dir = visual, .base_level = 1, .actions = &.{ .shape, .set_inverse, .resolve, .reorder } },
    .{ .in_level = 1, .in_order = .visual, .out_level = 1, .out_order = .logical, .digits_dir = logical, .letters_dir = visual, .base_level = 1, .actions = &.{ .reverse, .shape, .set_inverse, .resolve, .reorder } },
    .{ .in_level = 0, .in_order = .visual, .out_level = 0, .out_order = .logical, .digits_dir = logical, .letters_dir = logical, .base_level = 0, .actions = &.{ .set_inverse, .resolve, .reorder, .shape } },
    .{ .in_level = 1, .in_order = .visual, .out_level = 0, .out_order = .logical, .digits_dir = logical, .letters_dir = logical, .base_level = 0, .actions = &.{ .reverse, .set_inverse, .resolve, .reorder, .shape } },
    .{ .in_level = 0, .in_order = .logical, .out_level = 1, .out_order = .logical, .digits_dir = logical, .letters_dir = logical, .base_level = 0, .actions = &.{ .shape, .resolve, .mirror, .set_runs_only, .resolve, .reorder } },
    .{ .in_level = 1, .in_order = .logical, .out_level = 0, .out_order = .logical, .digits_dir = logical, .letters_dir = logical, .base_level = 1, .actions = &.{ .resolve, .mirror, .set_runs_only, .resolve, .reorder, .shape } },
    .{ .in_level = 0, .in_order = .visual, .out_level = 1, .out_order = .visual, .digits_dir = logical, .letters_dir = visual, .base_level = 0, .actions = &.{ .shape, .set_inverse, .resolve, .mirror, .reverse } },
    .{ .in_level = 1, .in_order = .visual, .out_level = 0, .out_order = .visual, .digits_dir = logical, .letters_dir = visual, .base_level = 0, .actions = &.{ .reverse, .shape, .set_inverse, .resolve, .mirror } },
    .{ .in_level = 0, .in_order = .logical, .out_level = 0, .out_order = .logical, .digits_dir = logical, .letters_dir = logical, .base_level = 0, .actions = &.{ .resolve, .mirror, .shape } },
    .{ .in_level = 1, .in_order = .logical, .out_level = 1, .out_order = .logical, .digits_dir = visual, .letters_dir = logical, .base_level = 1, .actions = &.{ .resolve, .mirror, .shape } },
    .{ .in_level = 0, .in_order = .visual, .out_level = 0, .out_order = .visual, .digits_dir = logical, .letters_dir = visual, .base_level = 0, .actions = &.{ .resolve, .mirror, .shape } },
    .{ .in_level = 1, .in_order = .visual, .out_level = 1, .out_order = .visual, .digits_dir = logical, .letters_dir = visual, .base_level = 0, .actions = &.{ .reverse, .resolve, .mirror, .shape, .reverse } },
};

/// ICU `ubidi_getBaseDirection`: the first strong L/R/AL anywhere in the
/// text. Unlike paragraph direction resolution, isolate content is not
/// skipped.
fn firstStrong(text: []const u8) Error!?u8 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        switch (property_data.class(codepoint)) {
            .l => return 0,
            .r, .al => return 1,
            .b => break,
            else => {},
        }
    }
    return null;
}

fn resolveBaseLevel(text: []const u8, level: BaseLevel) Error!u8 {
    return switch (level) {
        .ltr => 0,
        .rtl => 1,
        .default_ltr => (try firstStrong(text)) orelse 0,
        .default_rtl => (try firstStrong(text)) orelse 1,
    };
}

const Resolved = struct {
    allocator: std.mem.Allocator,
    inverse: bool,
    paragraph: ?paragraph.Paragraph = null,
    scalars: []const paragraph.Scalar = &.{},
    classes: ?[]Class = null,
    levels: []const u8 = &.{},
    base_level: u8 = 0,

    const Class = property_data.Class;

    fn deinit(self: *Resolved) void {
        if (self.paragraph) |*value| value.deinit();
        if (self.classes) |classes| self.allocator.free(classes);
        if (self.inverse) {
            self.allocator.free(self.scalars);
            self.allocator.free(self.levels);
        }
        self.* = undefined;
    }
};

fn resolveDirect(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_level: u8,
) Error!Resolved {
    const resolved = paragraph.resolve(
        allocator,
        text,
        if (base_level == 0) .ltr else .rtl,
    ) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidUtf8,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{
        .allocator = allocator,
        .inverse = false,
        .paragraph = resolved,
        .scalars = resolved.scalars,
        .levels = resolved.levels,
        .base_level = base_level,
    };
}

fn resolveInverse(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_level: u8,
) Error!Resolved {
    var scalars = std.ArrayList(paragraph.Scalar).empty;
    errdefer scalars.deinit(allocator);
    var classes = std.ArrayList(Resolved.Class).empty;
    errdefer classes.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < text.len) {
        const start = cursor;
        const length = std.unicode.utf8ByteSequenceLength(
            text[cursor],
        ) catch return error.InvalidUtf8;
        if (cursor + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(
            text[cursor..][0..length],
        ) catch return error.InvalidUtf8;
        try scalars.append(allocator, .{
            .codepoint = codepoint,
            .byte_start = start,
            .byte_len = @intCast(length),
        });
        try classes.append(allocator, property_data.class(codepoint));
        cursor += length;
    }

    const levels = try allocator.alloc(u8, scalars.items.len);
    errdefer allocator.free(levels);
    resolver.resolveInverse(classes.items, levels, base_level);
    const scalar_slice = try scalars.toOwnedSlice(allocator);
    errdefer allocator.free(scalar_slice);
    const class_slice = try classes.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .inverse = true,
        .scalars = scalar_slice,
        .classes = class_slice,
        .levels = levels,
        .base_level = base_level,
    };
}

fn shapeText(
    allocator: std.mem.Allocator,
    text: []const u8,
    raw_options: u32,
    digits_dir: shape.TextDirection,
    letters_dir: shape.TextDirection,
) Error![]u8 {
    const options = shape.Options.fromRaw(raw_options);
    if (options.digits == .noop and options.letters == .noop) {
        return allocator.dupe(u8, text);
    }
    if (digits_dir == letters_dir) {
        var combined = options;
        combined.text_direction = digits_dir;
        return shapeArabic(allocator, text, combined);
    }

    var stage = try allocator.dupe(u8, text);
    errdefer allocator.free(stage);
    if (options.digits != .noop) {
        var digit_options = options;
        digit_options.letters = .noop;
        digit_options.text_direction = digits_dir;
        const next = try shapeArabic(allocator, stage, digit_options);
        allocator.free(stage);
        stage = next;
    }
    if (options.letters != .noop) {
        var letter_options = options;
        letter_options.digits = .noop;
        letter_options.text_direction = letters_dir;
        const next = try shapeArabic(allocator, stage, letter_options);
        allocator.free(stage);
        stage = next;
    }
    return stage;
}

fn shapeArabic(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: shape.Options,
) Error![]u8 {
    return shape.shapeArabicAlloc(allocator, text, options) catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidUtf8,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
}

fn reverseText(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(
            text[cursor],
        ) catch return error.InvalidUtf8;
        if (cursor + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(
            text[cursor..][0..length],
        ) catch return error.InvalidUtf8;
        try codepoints.append(allocator, codepoint);
        cursor += length;
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);
    var index = codepoints.items.len;
    while (index > 0) {
        index -= 1;
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            codepoints.items[index],
            &buffer,
        ) catch return error.InvalidUtf8;
        try output.appendSlice(allocator, buffer[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

fn mirrorText(
    allocator: std.mem.Allocator,
    text: []const u8,
    scalars: []const paragraph.Scalar,
    levels: []const u8,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);
    for (scalars, 0..) |scalar, index| {
        const codepoint = if (levels[index] & 1 != 0)
            paragraph.mirroredCodepoint(scalar.codepoint)
        else
            scalar.codepoint;
        if (codepoint != scalar.codepoint) {
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint, &buffer) catch
                return error.InvalidUtf8;
            try output.appendSlice(allocator, buffer[0..length]);
        } else {
            const end = scalar.byte_start + scalar.byte_len;
            if (end > text.len) return error.InvalidUtf8;
            try output.appendSlice(allocator, text[scalar.byte_start..end]);
        }
    }
    return output.toOwnedSlice(allocator);
}

/// ICU `ubiditransform_transform`: convert between logical and visual order.
///
/// `shaping_options` carries ICU `U_SHAPE_*` bits (letters, digits, tashkeel,
/// lam-alef, and tail handling). All 16 ICU reordering schemes are supported.
pub fn transformAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    in_para_level: BaseLevel,
    in_order: Order,
    out_para_level: BaseLevel,
    out_order: Order,
    mirroring: Mirroring,
    shaping_options: u32,
) Error![]u8 {
    const in_level = try resolveBaseLevel(text, in_para_level);
    const out_level = switch (out_para_level) {
        .ltr => 0,
        .rtl => 1,
        .default_ltr, .default_rtl => in_level,
    };

    var scheme: ?*const Scheme = null;
    for (&schemes) |*candidate| {
        if (candidate.in_level == in_level and
            candidate.out_level == out_level and
            candidate.in_order == in_order and
            candidate.out_order == out_order)
        {
            scheme = candidate;
            break;
        }
    }
    const active = scheme orelse return error.InvalidArgument;

    var current = try allocator.dupe(u8, text);
    errdefer allocator.free(current);
    var resolved: ?Resolved = null;
    defer if (resolved) |*value| value.deinit();
    var inverse = false;
    var base_override: ?u8 = null;
    var mirror_applied = false;

    for (active.actions) |action| {
        switch (action) {
            .shape => {
                const next = try shapeText(
                    allocator,
                    current,
                    shaping_options,
                    active.digits_dir,
                    active.letters_dir,
                );
                allocator.free(current);
                current = next;
            },
            .resolve => {
                if (resolved) |*value| value.deinit();
                const base_level = base_override orelse active.base_level;
                resolved = try if (inverse)
                    resolveInverse(allocator, current, base_level)
                else
                    resolveDirect(allocator, current, base_level);
            },
            .reorder => {
                const value = if (resolved) |*item|
                    item
                else
                    return error.InvalidArgument;
                const use_mirror = mirroring == .on and !mirror_applied;
                const next = if (value.paragraph) |direct|
                    direct.reorderAlloc(allocator, current, .{
                        .mirroring = use_mirror,
                    }) catch |err| switch (err) {
                        error.InvalidUtf8 => return error.InvalidUtf8,
                        error.OutOfMemory => return error.OutOfMemory,
                    }
                else
                    paragraph.reorderLevelsAlloc(
                        allocator,
                        current,
                        value.scalars,
                        value.levels,
                        .{ .mirroring = use_mirror },
                    ) catch |err| switch (err) {
                        error.InvalidUtf8 => return error.InvalidUtf8,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                allocator.free(current);
                current = next;
            },
            .reverse => {
                const next = try reverseText(allocator, current);
                allocator.free(current);
                current = next;
            },
            .mirror => {
                if (mirroring == .off) continue;
                const value = if (resolved) |*item|
                    item
                else
                    return error.InvalidArgument;
                const next = try mirrorText(
                    allocator,
                    current,
                    value.scalars,
                    value.levels,
                );
                allocator.free(current);
                current = next;
            },
            .set_inverse => inverse = true,
            .set_runs_only => {
                if (resolved) |*value| value.deinit();
                resolved = null;
                var fresh = try resolveDirect(
                    allocator,
                    current,
                    active.base_level,
                );
                defer fresh.deinit();
                const value = if (fresh.paragraph) |direct|
                    direct.reorderAlloc(allocator, current, .{
                        .mirroring = false,
                    }) catch |err| switch (err) {
                        error.InvalidUtf8 => return error.InvalidUtf8,
                        error.OutOfMemory => return error.OutOfMemory,
                    }
                else
                    paragraph.reorderLevelsAlloc(
                        allocator,
                        current,
                        fresh.scalars,
                        fresh.levels,
                        .{ .mirroring = false },
                    ) catch |err| switch (err) {
                        error.InvalidUtf8 => return error.InvalidUtf8,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                allocator.free(current);
                current = value;
                inverse = true;
                base_override = active.base_level ^ 1;
                mirror_applied = true;
            },
        }
    }
    return current;
}

test "bidi transform direct and inverse" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const logical_hebrew = "\u{05d0}\u{05d1}\u{05d2}";
    const visual_text = try transformAlloc(
        allocator,
        logical_hebrew,
        .ltr,
        .logical,
        .ltr,
        .visual,
        .off,
        0,
    );
    defer allocator.free(visual_text);
    try testing.expectEqualStrings("\u{05d2}\u{05d1}\u{05d0}", visual_text);

    const logical_text = try transformAlloc(
        allocator,
        visual_text,
        .ltr,
        .visual,
        .ltr,
        .logical,
        .off,
        0,
    );
    defer allocator.free(logical_text);
    try testing.expectEqualStrings(logical_hebrew, logical_text);

    const mixed = try transformAlloc(
        allocator,
        "abc \u{05d0}\u{05d1}\u{05d2} def",
        .default_ltr,
        .logical,
        .default_ltr,
        .visual,
        .off,
        0,
    );
    defer allocator.free(mixed);
    try testing.expectEqualStrings("abc \u{05d2}\u{05d1}\u{05d0} def", mixed);

    const runs_only = try transformAlloc(
        allocator,
        "abc \u{05d0}\u{05d1}\u{05d2} def",
        .ltr,
        .logical,
        .rtl,
        .logical,
        .off,
        0,
    );
    defer allocator.free(runs_only);
    try testing.expectEqualStrings(
        "def \u{05d0}\u{05d1}\u{05d2} abc",
        runs_only,
    );
}

test "ICU ubiditransform conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("transform_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJTF", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const in_level_byte = fixture[cursor];
        const out_level_byte = fixture[cursor + 1];
        const in_order_byte = fixture[cursor + 2];
        const out_order_byte = fixture[cursor + 3];
        const mirroring_byte = fixture[cursor + 4];
        const shaping = std.mem.readInt(
            u32,
            fixture[cursor + 5 ..][0..4],
            .little,
        );
        const input_len = std.mem.readInt(
            u16,
            fixture[cursor + 9 ..][0..2],
            .little,
        );
        const output_len = std.mem.readInt(
            u16,
            fixture[cursor + 11 ..][0..2],
            .little,
        );
        cursor += 13;
        const input = fixture[cursor..][0..input_len];
        cursor += input_len;
        const expected = fixture[cursor..][0..output_len];
        cursor += output_len;

        const in_level = levelFromByte(in_level_byte) orelse
            return error.InvalidFixture;
        const out_level = levelFromByte(out_level_byte) orelse
            return error.InvalidFixture;
        const in_order: Order = if (in_order_byte == 0) .logical else .visual;
        const out_order: Order = if (out_order_byte == 0) .logical else .visual;
        const mirroring: Mirroring = if (mirroring_byte == 0) .off else .on;

        const actual = transformAlloc(
            allocator,
            input,
            in_level,
            in_order,
            out_level,
            out_order,
            mirroring,
            shaping,
        ) catch |err| {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "transform error: {s} levels={d}/{d} orders={d}/{d} err={s}\n",
                    .{
                        input,
                        in_level_byte,
                        out_level_byte,
                        in_order_byte,
                        out_order_byte,
                        @errorName(err),
                    },
                );
            }
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "transform mismatch: {s} levels={d}/{d} orders={d}/{d} mirror={d} shape={x} got={s} want={s}\n",
                    .{
                        input,
                        in_level_byte,
                        out_level_byte,
                        in_order_byte,
                        out_order_byte,
                        mirroring_byte,
                        shaping,
                        actual,
                        expected,
                    },
                );
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "ubiditransform conformance: {}/{} cases passed\n",
        .{ case_count - failures, case_count },
    );
}

fn levelFromByte(value: u8) ?BaseLevel {
    return switch (value) {
        0 => .ltr,
        1 => .rtl,
        0xFE => .default_ltr,
        0xFF => .default_rtl,
        else => null,
    };
}
