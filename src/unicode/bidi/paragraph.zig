//! UTF-8 paragraph facade and per-line UAX #9 reordering.
//!
//! Resolution is scalar-indexed so public maps remain compact. Line operations
//! take scalar ranges whose boundaries must coincide with decoded UTF-8
//! scalars; callers such as paragraph layout derive those ranges from source
//! byte offsets.

const std = @import("std");

const scalar_value = @import("../scalar/root.zig");
const property_data = @import("data.zig");
const resolver = @import("resolver.zig");
const properties = @import("../properties.zig");

pub const unicode_version = property_data.unicode_version;
pub const Class = property_data.Class;
pub const BaseDirection = resolver.BaseDirection;

/// Attribute-authored UAX #9 formatting applied around one source range.
///
/// These values are equivalent to temporary LRE/RLE/LRO/RLO/PDF or
/// LRI/RLI/FSI/PDI controls, but the controls never enter the caller's UTF-8
/// string or public source coordinates.
pub const RangeMode = enum {
    ltr_embedding,
    rtl_embedding,
    ltr_override,
    rtl_override,
    ltr_isolate,
    rtl_isolate,
    first_strong_isolate,
};

pub const Range = struct {
    byte_start: usize,
    byte_len: usize,
    /// Nested controls in outermost-to-innermost order.
    modes: []const RangeMode,

    pub fn byteEnd(self: Range) usize {
        return self.byte_start + self.byte_len;
    }
};

pub const Scalar = resolver.Scalar;

const block_alignment = resolver.block_alignment;

pub const Paragraph = struct {
    allocator: std.mem.Allocator,
    base_level: u8,
    scalars: []const Scalar,
    classes: []const Class,
    levels: []const u8,
    /// One allocation holding the public arrays when they share storage;
    /// empty when each slice is an independent exact allocation.
    block: []align(block_alignment.toByteUnits()) u8 = &.{},
    owner: Owner = .allocator,

    const Owner = enum { allocator, borrowed };

    pub fn deinit(self: *Paragraph) void {
        if (self.owner == .allocator) {
            if (self.block.len != 0) {
                self.allocator.free(self.block);
            } else {
                self.allocator.free(self.levels);
                self.allocator.free(self.classes);
                self.allocator.free(self.scalars);
            }
        }
        self.* = undefined;
    }

    /// Return a non-owning copy of this resolved paragraph.
    ///
    /// The returned value may be deinitialized safely, but doing so releases
    /// no storage. Its slices remain valid only until the paragraph that owns
    /// them is deinitialized or replaces its backing storage. This is useful
    /// for caches that must retain ownership while lending a short-lived value
    /// to existing paragraph consumers.
    pub fn borrowed(self: Paragraph) Paragraph {
        var view = self;
        view.owner = .borrowed;
        return view;
    }

    pub fn scalarIndexForByte(self: Paragraph, byte_offset: usize) ?usize {
        var low: usize = 0;
        var high = self.scalars.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.scalars[mid].byte_start < byte_offset) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low < self.scalars.len and
            self.scalars[low].byte_start == byte_offset) return low;
        if (low == self.scalars.len and
            (self.scalars.len == 0 or
                byte_offset == self.scalars[self.scalars.len - 1].byte_start +
                    self.scalars[self.scalars.len - 1].byte_len))
        {
            return low;
        }
        return null;
    }

    /// Applies L1 to one visual line without changing paragraph-wide levels.
    pub fn lineLevels(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
    ) ![]u8 {
        return self.lineLevelsRetaining(
            allocator,
            scalar_start,
            scalar_end,
            &.{},
        );
    }

    /// Applies L1 while assigning selected X9 scalars their preceding level.
    ///
    /// Layout uses this only when a normally removed control acquires visual
    /// content (currently a materialized U+00AD discretionary hyphen).
    pub fn lineLevelsRetaining(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
        retained: []const usize,
    ) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        try self.fillLineLevelsRetaining(
            allocator,
            scalar_start,
            scalar_end,
            retained,
            &result,
        );
        return try result.toOwnedSlice(allocator);
    }

    /// Fill reusable caller-owned scratch with this line's effective levels.
    ///
    /// The returned view is `result.items`; it remains borrowed from `result`
    /// only until that list is mutated. This narrow no-X9-retention form lets
    /// direct glyph consumers apply L2 to their own parallel records without
    /// materializing a scalar-index permutation.
    pub fn lineLevelsInto(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
        result: *std.ArrayList(u8),
    ) !void {
        return self.fillLineLevelsRetaining(
            allocator,
            scalar_start,
            scalar_end,
            &.{},
            result,
        );
    }

    fn fillLineLevelsRetaining(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
        retained: []const usize,
        result: *std.ArrayList(u8),
    ) !void {
        if (scalar_start > scalar_end or scalar_end > self.levels.len) {
            return error.InvalidScalarRange;
        }
        result.clearRetainingCapacity();
        try result.appendSlice(
            allocator,
            self.levels[scalar_start..scalar_end],
        );
        resetLineLevels(
            self.classes[scalar_start..scalar_end],
            result.items,
            self.base_level,
        );
        for (retained) |scalar_index| {
            if (scalar_index < scalar_start or scalar_index >= scalar_end) {
                return error.InvalidScalarRange;
            }
            if (result.items[scalar_index - scalar_start] !=
                resolver.removed_level)
            {
                continue;
            }
            result.items[scalar_index - scalar_start] =
                self.inheritedLevel(scalar_index);
        }
    }

    /// Returns scalar indexes in L2 visual order for one resolved line.
    pub fn visualOrder(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
    ) ![]usize {
        return self.visualOrderRetaining(
            allocator,
            scalar_start,
            scalar_end,
            &.{},
        );
    }

    pub fn visualOrderRetaining(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
        retained: []const usize,
    ) ![]usize {
        var levels = std.ArrayList(u8).empty;
        defer levels.deinit(allocator);
        var order = std.ArrayList(usize).empty;
        errdefer order.deinit(allocator);
        try self.visualOrderAndLevelsRetaining(
            allocator,
            scalar_start,
            scalar_end,
            retained,
            &levels,
            &order,
        );
        return try order.toOwnedSlice(allocator);
    }

    /// Compute L1 levels and L2 order together into caller-owned storage.
    ///
    /// Both results derive from exactly the same adjusted levels. Paragraph
    /// layout needs both for direction/mirroring, so exposing the transaction
    /// avoids applying L1 twice and allocating two arrays for every line.
    pub fn visualOrderAndLevelsRetaining(
        self: Paragraph,
        allocator: std.mem.Allocator,
        scalar_start: usize,
        scalar_end: usize,
        retained: []const usize,
        levels: *std.ArrayList(u8),
        order: *std.ArrayList(usize),
    ) !void {
        try self.fillLineLevelsRetaining(
            allocator,
            scalar_start,
            scalar_end,
            retained,
            levels,
        );
        var retained_count: usize = 0;
        for (levels.items) |level| retained_count += @intFromBool(
            level != resolver.removed_level,
        );
        order.clearRetainingCapacity();
        try order.ensureTotalCapacity(allocator, retained_count);
        for (levels.items, 0..) |level, index| {
            if (level == resolver.removed_level) continue;
            order.appendAssumeCapacity(scalar_start + index);
        }
        reorderVisual(
            order.items,
            levels.items,
            scalar_start,
        );
    }

    pub fn fullVisualOrder(
        self: Paragraph,
        allocator: std.mem.Allocator,
    ) ![]usize {
        return self.visualOrder(allocator, 0, self.scalars.len);
    }

    pub fn directionForScalar(self: Paragraph, scalar_index: usize) ?BaseDirection {
        if (scalar_index >= self.levels.len) return null;
        return if (self.levels[scalar_index] & 1 == 0) .ltr else .rtl;
    }

    pub fn visualCodepoint(
        self: Paragraph,
        scalar_index: usize,
    ) ?u21 {
        if (scalar_index >= self.scalars.len) return null;
        const codepoint = self.scalars[scalar_index].codepoint;
        return if (self.levels[scalar_index] & 1 != 0)
            mirroredCodepoint(codepoint)
        else
            codepoint;
    }

    /// ICU `ubidi_writeReordered` options.
    pub const ReorderOptions = struct {
        /// Mirror characters whose level is odd.
        mirroring: bool = false,
        /// Remove bidi controls (LRM/RLM, embeddings, isolates, ZWNJ/ZWJ).
        remove_controls: bool = false,
        /// Keep combining marks after their base character in RTL runs.
        keep_base_combining: bool = false,
        /// Reverse the reordered output (visual RTL instead of visual LTR).
        output_reverse: bool = false,
    };

    /// Reorder `text` (the paragraph's original UTF-8) into visual order,
    /// matching ICU's `ubidi_writeReordered`. Embedding controls and other
    /// X9-removed characters participate in the reordering, as in ICU.
    pub fn reorderAlloc(
        self: Paragraph,
        allocator: std.mem.Allocator,
        text: []const u8,
        options: ReorderOptions,
    ) error{ InvalidUtf8, OutOfMemory }![]u8 {
        const display_levels = try allocator.dupe(u8, self.levels);
        defer allocator.free(display_levels);
        resolver.assignDisplayLevels(
            self.classes,
            display_levels,
            self.base_level,
        );
        return reorderLevelsAlloc(
            allocator,
            text,
            self.scalars,
            display_levels,
            options,
        );
    }

    fn inheritedLevel(self: Paragraph, scalar_index: usize) u8 {
        var previous = scalar_index;
        while (previous > 0) {
            previous -= 1;
            const level = self.levels[previous];
            if (level != resolver.removed_level) return level;
        }
        return self.base_level;
    }
};

/// Reorder UTF-8 text with caller-supplied levels. This is the shared core of
/// `Paragraph.reorderAlloc` and inverse bidi, where levels come from ICU's
/// inverse resolution rather than the UAX #9 direct pass.
pub fn reorderLevelsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    scalars: []const Scalar,
    levels: []const u8,
    options: Paragraph.ReorderOptions,
) error{ InvalidUtf8, OutOfMemory }![]u8 {
    const count = scalars.len;
    const order = try allocator.alloc(usize, count);
    defer allocator.free(order);
    for (order, 0..) |*value, index| value.* = index;
    reorderVisual(order, levels, 0);

    // Units are scalars, or base+mark clusters when keeping combining
    // marks. Output reversal flips unit order, never a cluster's interior.
    var units = std.ArrayList(usize).empty;
    defer units.deinit(allocator);
    if (options.keep_base_combining) {
        const cluster_start = try allocator.alloc(usize, count);
        defer allocator.free(cluster_start);
        const emitted = try allocator.alloc(bool, count);
        defer allocator.free(emitted);
        @memset(emitted, false);
        var current: usize = 0;
        for (scalars, 0..) |scalar, index| {
            if (index == 0 or !isCombiningMark(scalar.codepoint)) {
                current = index;
            }
            cluster_start[index] = current;
        }
        for (order) |index| {
            const start = cluster_start[index];
            if (emitted[start]) continue;
            emitted[start] = true;
            try units.append(allocator, start);
        }
    } else {
        try units.appendSlice(allocator, order);
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);

    var position: usize = 0;
    while (position < units.items.len) : (position += 1) {
        const index = if (options.output_reverse)
            units.items[units.items.len - 1 - position]
        else
            units.items[position];
        try appendScalar(
            scalars,
            allocator,
            text,
            &output,
            index,
            levels[index],
            options,
            true,
        );
        if (!options.keep_base_combining) continue;
        var next = index + 1;
        while (next < count and
            isCombiningMark(scalars[next].codepoint)) : (next += 1)
        {
            try appendScalar(
                scalars,
                allocator,
                text,
                &output,
                next,
                levels[next],
                options,
                false,
            );
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn resolve(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_direction: BaseDirection,
) !Paragraph {
    // One scalar per byte is the upper bound. Every array the paragraph keeps
    // is carved from a single allocation, which removes two allocator calls
    // (and their frees) from the hot path.
    const capacity = text.len;
    const scalar_bytes = capacity * @sizeOf(Scalar);
    const block = try allocator.alignedAlloc(
        u8,
        block_alignment,
        scalar_bytes + 2 * capacity,
    );
    errdefer allocator.free(block);
    const scalars = std.mem.bytesAsSlice(Scalar, block[0..scalar_bytes]);
    const classes = std.mem.bytesAsSlice(
        Class,
        block[scalar_bytes..][0..capacity],
    );
    const levels: []u8 = block[scalar_bytes + capacity ..][0..capacity];

    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const start = cursor;
        const first = text[cursor];
        if (first < 0x80) {
            scalars[count] = .{
                .codepoint = first,
                .byte_start = cursor,
                .byte_len = 1,
            };
            classes[count] = property_data.class(first);
            count += 1;
            cursor += 1;
            continue;
        }
        // Validation is fused into the decode, so the scan does not pay a
        // separate UTF-8 pass.
        const decoded = scalar_value.decodeValidatingPacked(text, cursor);
        if (decoded == scalar_value.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar_value.packedCodepoint(decoded);
        cursor += scalar_value.packedLength(decoded);
        scalars[count] = .{
            .codepoint = codepoint,
            .byte_start = start,
            .byte_len = @intCast(cursor - start),
        };
        classes[count] = property_data.class(codepoint);
        count += 1;
    }

    var scratch = resolver.Scratch.init(allocator);
    defer scratch.deinit();
    const base_level = try scratch.resolve(
        scalars[0..count],
        classes[0..count],
        levels[0..count],
        base_direction,
    );
    return .{
        .allocator = allocator,
        .base_level = base_level,
        .scalars = scalars[0..count],
        .classes = classes[0..count],
        .levels = levels[0..count],
        .block = block,
    };
}

/// Resolve the first-strong paragraph direction without allocating a full
/// paragraph. Characters inside isolates do not select the outer direction.
pub fn direction(text: []const u8) error{InvalidUtf8}!BaseDirection {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var isolate_depth: usize = 0;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        switch (classForCodepoint(codepoint)) {
            .lri, .rli, .fsi => isolate_depth += 1,
            .pdi => if (isolate_depth != 0) {
                isolate_depth -= 1;
            },
            .l => if (isolate_depth == 0) return .ltr,
            .r, .al => if (isolate_depth == 0) return .rtl,
            .b => break,
            else => {},
        }
    }
    return .ltr;
}

test "first-strong paragraph direction ignores isolated content" {
    try std.testing.expectEqual(BaseDirection.rtl, try direction("123 مرحبا"));
    try std.testing.expectEqual(BaseDirection.ltr, try direction("123 hello مرحبا"));
    try std.testing.expectEqual(BaseDirection.ltr, try direction("\u{2067}مرحبا\u{2069} hello"));
    try std.testing.expectError(error.InvalidUtf8, direction("\xff"));
}

/// Resolve UAX #9 with non-overlapping attribute-authored embeddings or
/// overrides while preserving the original scalar and byte coordinate space.
pub fn resolveWithRanges(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_direction: BaseDirection,
    ranges: []const Range,
) !Paragraph {
    if (ranges.len == 0) return resolve(allocator, text, base_direction);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try validateRanges(text, ranges);

    var scalar_list = std.ArrayList(Scalar).empty;
    defer scalar_list.deinit(allocator);
    var expanded_scalars = std.ArrayList(Scalar).empty;
    defer expanded_scalars.deinit(allocator);
    var expanded_classes = std.ArrayList(Class).empty;
    defer expanded_classes.deinit(allocator);
    var source_input_indices = std.ArrayList(usize).empty;
    defer source_input_indices.deinit(allocator);

    var range_index: usize = 0;
    var active: ?Range = null;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const start = cursor;
        const codepoint = decodeValid(text, &cursor);
        if (active) |range| {
            if (range.byteEnd() == start) {
                try appendClosures(
                    &expanded_scalars,
                    &expanded_classes,
                    allocator,
                    range.modes,
                );
                active = null;
            }
        }
        if (range_index < ranges.len and
            ranges[range_index].byte_start == start)
        {
            const range = ranges[range_index];
            try appendOpenings(
                &expanded_scalars,
                &expanded_classes,
                allocator,
                range.modes,
            );
            active = range;
            range_index += 1;
        }
        try scalar_list.append(allocator, .{
            .codepoint = codepoint,
            .byte_start = start,
            .byte_len = @intCast(cursor - start),
        });
        try source_input_indices.append(
            allocator,
            expanded_classes.items.len,
        );
        const class = property_data.class(codepoint);
        try expanded_scalars.append(allocator, .{
            .codepoint = codepoint,
            .byte_start = start,
            .byte_len = @intCast(cursor - start),
        });
        try expanded_classes.append(allocator, class);
        // UAX #9 resets explicit state at a paragraph separator. Reopen an
        // attributed range that continues into the following paragraph.
        if (class == .b) if (active) |range| {
            if (cursor < range.byteEnd()) {
                try appendClosures(
                    &expanded_scalars,
                    &expanded_classes,
                    allocator,
                    range.modes,
                );
                try appendOpenings(
                    &expanded_scalars,
                    &expanded_classes,
                    allocator,
                    range.modes,
                );
            } else active = null;
        };
    }
    if (active) |range| {
        try appendClosures(
            &expanded_scalars,
            &expanded_classes,
            allocator,
            range.modes,
        );
    }
    std.debug.assert(range_index == ranges.len);

    const expanded_levels = try allocator.alloc(
        u8,
        expanded_scalars.items.len,
    );
    defer allocator.free(expanded_levels);
    var scratch = resolver.Scratch.init(allocator);
    defer scratch.deinit();
    const base_level = try scratch.resolve(
        expanded_scalars.items,
        expanded_classes.items,
        expanded_levels,
        base_direction,
    );
    const scalars = try scalar_list.toOwnedSlice(allocator);
    errdefer allocator.free(scalars);
    const classes = try allocator.alloc(Class, scalars.len);
    errdefer allocator.free(classes);
    const levels = try allocator.alloc(u8, scalars.len);
    errdefer allocator.free(levels);
    for (source_input_indices.items, 0..) |input_index, scalar_index| {
        classes[scalar_index] = expanded_classes.items[input_index];
        levels[scalar_index] = expanded_levels[input_index];
    }
    return .{
        .allocator = allocator,
        .base_level = base_level,
        .scalars = scalars,
        .classes = classes,
        .levels = levels,
    };
}

pub fn validateRanges(text: []const u8, ranges: []const Range) !void {
    var previous_end: usize = 0;
    for (ranges) |range| {
        if (range.byte_len == 0 or range.modes.len == 0 or
            range.byte_start < previous_end or
            range.byte_start > text.len or
            range.byte_len > text.len - range.byte_start or
            !isUtf8Boundary(text, range.byte_start) or
            !isUtf8Boundary(text, range.byteEnd()))
        {
            return error.InvalidBidiRange;
        }
        previous_end = range.byteEnd();
    }
}

fn appendOpenings(
    scalars: *std.ArrayList(Scalar),
    classes: *std.ArrayList(Class),
    allocator: std.mem.Allocator,
    modes: []const RangeMode,
) !void {
    for (modes) |mode| {
        try appendFormattingInput(
            scalars,
            classes,
            allocator,
            openingClass(mode),
        );
    }
}

fn appendClosures(
    scalars: *std.ArrayList(Scalar),
    classes: *std.ArrayList(Class),
    allocator: std.mem.Allocator,
    modes: []const RangeMode,
) !void {
    var index = modes.len;
    while (index != 0) {
        index -= 1;
        try appendFormattingInput(
            scalars,
            classes,
            allocator,
            switch (modes[index]) {
                .ltr_isolate, .rtl_isolate, .first_strong_isolate => .pdi,
                else => .pdf,
            },
        );
    }
}

fn appendFormattingInput(
    scalars: *std.ArrayList(Scalar),
    classes: *std.ArrayList(Class),
    allocator: std.mem.Allocator,
    class: Class,
) !void {
    // Formatting controls never carry the `.on` class, so the resolver never
    // reads their placeholder codepoint; only the class participates.
    try scalars.append(allocator, .{
        .codepoint = switch (class) {
            .lre => 0x202a,
            .rle => 0x202b,
            .lri => 0x2066,
            .rli => 0x2067,
            .fsi => 0x2068,
            .pdi => 0x2069,
            .pdf => 0x202c,
            .lro => 0x202d,
            .rlo => 0x202e,
            else => unreachable,
        },
        .byte_start = 0,
        .byte_len = 0,
    });
    try classes.append(allocator, class);
}

fn openingClass(mode: RangeMode) Class {
    return switch (mode) {
        .ltr_embedding => .lre,
        .rtl_embedding => .rle,
        .ltr_override => .lro,
        .rtl_override => .rlo,
        .ltr_isolate => .lri,
        .rtl_isolate => .rli,
        .first_strong_isolate => .fsi,
    };
}

fn isUtf8Boundary(text: []const u8, byte_offset: usize) bool {
    if (byte_offset > text.len) return false;
    if (byte_offset == 0 or byte_offset == text.len) return true;
    return text[byte_offset] & 0xc0 != 0x80;
}

/// Reusable ownership for synchronous paragraph resolution.
///
/// The returned paragraph borrows `scalars`, `classes` and `levels` and
/// remains valid only until the storage is reused. This is intended for
/// layout transactions that consume the resolution synchronously; `resolve`
/// above remains the owning public contract.
pub const Storage = struct {
    allocator: std.mem.Allocator,
    scalars: std.ArrayList(Scalar) = .empty,
    classes: std.ArrayList(Class) = .empty,
    levels: std.ArrayList(u8) = .empty,
    scratch: resolver.Scratch,

    pub fn init(allocator: std.mem.Allocator) Storage {
        return .{
            .allocator = allocator,
            .scratch = .init(allocator),
        };
    }

    pub fn deinit(self: *Storage) void {
        self.scratch.deinit();
        self.levels.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.scalars.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resolve(
        self: *Storage,
        text: []const u8,
        base_direction: BaseDirection,
    ) !Paragraph {
        self.scalars.clearRetainingCapacity();
        self.classes.clearRetainingCapacity();
        try self.scalars.ensureTotalCapacity(self.allocator, text.len);
        try self.classes.ensureTotalCapacity(self.allocator, text.len);
        var cursor: usize = 0;
        while (cursor < text.len) {
            const start = cursor;
            const first = text[cursor];
            if (first < 0x80) {
                self.scalars.appendAssumeCapacity(.{
                    .codepoint = first,
                    .byte_start = cursor,
                    .byte_len = 1,
                });
                self.classes.appendAssumeCapacity(property_data.class(first));
                cursor += 1;
                continue;
            }
            // Validation is fused into the decode, matching the owning path.
            const decoded = scalar_value.decodeValidatingPacked(text, cursor);
            if (decoded == scalar_value.packed_invalid) return error.InvalidUtf8;
            const codepoint = scalar_value.packedCodepoint(decoded);
            cursor += scalar_value.packedLength(decoded);
            self.scalars.appendAssumeCapacity(.{
                .codepoint = codepoint,
                .byte_start = start,
                .byte_len = @intCast(cursor - start),
            });
            self.classes.appendAssumeCapacity(property_data.class(codepoint));
        }
        try self.levels.resize(self.allocator, self.scalars.items.len);

        const base_level = try self.scratch.resolve(
            self.scalars.items,
            self.classes.items,
            self.levels.items,
            base_direction,
        );
        return .{
            .allocator = self.allocator,
            .base_level = base_level,
            .scalars = self.scalars.items,
            .classes = self.classes.items,
            .levels = self.levels.items,
            .owner = .borrowed,
        };
    }
};

pub fn classForCodepoint(codepoint: u21) Class {
    return property_data.class(codepoint);
}

pub fn mirroredCodepoint(codepoint: u21) u21 {
    return property_data.mirrored(codepoint);
}

fn resetLineLevels(
    classes: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    std.debug.assert(classes.len == levels.len);
    var index = classes.len;
    while (index > 0) {
        index -= 1;
        const value = classes[index];
        if (isRemovedByX9(value)) continue;
        if (value == .ws or isIsolateInitiator(value) or value == .pdi) {
            levels[index] = base_level;
            continue;
        }
        break;
    }
}

fn reorderVisual(
    order: []usize,
    levels: []const u8,
    scalar_start: usize,
) void {
    var max_level: u8 = 0;
    var minimum_odd: u8 = 0xff;
    for (levels) |level| {
        if (level == resolver.removed_level) continue;
        max_level = @max(max_level, level);
        if (level & 1 != 0) minimum_odd = @min(minimum_odd, level);
    }
    if (minimum_odd == 0xff) return;

    var level = max_level;
    while (true) : (level -= 1) {
        var cursor: usize = 0;
        while (cursor < order.len) {
            if (levels[order[cursor] - scalar_start] < level) {
                cursor += 1;
                continue;
            }
            const start = cursor;
            while (cursor < order.len and
                levels[order[cursor] - scalar_start] >= level)
            {
                cursor += 1;
            }
            std.mem.reverse(usize, order[start..cursor]);
        }
        if (level == minimum_odd) break;
    }
}

fn isCombiningMark(codepoint: u21) bool {
    return switch (properties.category(codepoint)) {
        .Mn, .Mc, .Me => true,
        else => false,
    };
}

fn isBidiControl(codepoint: u21) bool {
    return codepoint == 0x200C or codepoint == 0x200D or
        codepoint == 0x200E or codepoint == 0x200F or
        (codepoint >= 0x202A and codepoint <= 0x202E) or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
}

fn appendScalar(
    scalars: []const Scalar,
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u8),
    index: usize,
    level: u8,
    options: Paragraph.ReorderOptions,
    allow_mirror: bool,
) error{ InvalidUtf8, OutOfMemory }!void {
    const scalar = scalars[index];
    if (options.remove_controls and isBidiControl(scalar.codepoint)) return;
    if (options.mirroring and allow_mirror and level & 1 != 0) {
        const mirrored = mirroredCodepoint(scalar.codepoint);
        if (mirrored != scalar.codepoint) {
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(mirrored, &buffer) catch
                return error.InvalidUtf8;
            try output.appendSlice(allocator, buffer[0..length]);
            return;
        }
    }
    const end = scalar.byte_start + scalar.byte_len;
    if (end > text.len) return error.InvalidUtf8;
    try output.appendSlice(allocator, text[scalar.byte_start..end]);
}

fn isRemovedByX9(value: Class) bool {
    return switch (value) {
        .rle, .lre, .rlo, .lro, .pdf, .bn => true,
        else => false,
    };
}

fn isIsolateInitiator(value: Class) bool {
    return value == .lri or value == .rli or value == .fsi;
}

fn decodeValid(text: []const u8, cursor: *usize) u21 {
    const start = cursor.*;
    const first = text[start];
    if (first < 0x80) {
        cursor.* = start + 1;
        return first;
    }
    const second = text[start + 1];
    if (first < 0xe0) {
        cursor.* = start + 2;
        return (@as(u21, first & 0x1f) << 6) |
            @as(u21, second & 0x3f);
    }
    const third = text[start + 2];
    if (first < 0xf0) {
        cursor.* = start + 3;
        return (@as(u21, first & 0x0f) << 12) |
            (@as(u21, second & 0x3f) << 6) |
            @as(u21, third & 0x3f);
    }
    const fourth = text[start + 3];
    cursor.* = start + 4;
    return (@as(u21, first & 0x07) << 18) |
        (@as(u21, second & 0x3f) << 12) |
        (@as(u21, third & 0x3f) << 6) |
        @as(u21, fourth & 0x3f);
}

test "attributed bidi ranges preserve source coordinates and override levels" {
    const text = "A123B";
    var paragraph = try resolveWithRanges(
        std.testing.allocator,
        text,
        .ltr,
        &.{.{
            .byte_start = 1,
            .byte_len = 3,
            .modes = &.{.rtl_override},
        }},
    );
    defer paragraph.deinit();

    try std.testing.expectEqual(@as(usize, text.len), paragraph.scalars.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 1, 1, 0 }, paragraph.levels);
    for (paragraph.scalars, 0..) |scalar, index| {
        try std.testing.expectEqual(index, scalar.byte_start);
        try std.testing.expectEqual(@as(u3, 1), scalar.byte_len);
    }
    const order = try paragraph.fullVisualOrder(std.testing.allocator);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 3, 2, 1, 4 },
        order,
    );
}

test "attributed bidi modes match equivalent explicit UAX controls" {
    const cases = [_]struct {
        mode: RangeMode,
        explicit: []const u8,
    }{
        .{ .mode = .ltr_embedding, .explicit = "A\u{202a}12\u{202c}B" },
        .{ .mode = .rtl_embedding, .explicit = "A\u{202b}12\u{202c}B" },
        .{ .mode = .ltr_override, .explicit = "A\u{202d}12\u{202c}B" },
        .{ .mode = .rtl_override, .explicit = "A\u{202e}12\u{202c}B" },
        .{ .mode = .ltr_isolate, .explicit = "A\u{2066}12\u{2069}B" },
        .{ .mode = .rtl_isolate, .explicit = "A\u{2067}12\u{2069}B" },
        .{ .mode = .first_strong_isolate, .explicit = "A\u{2068}12\u{2069}B" },
    };
    for (cases) |case| {
        var ranged = try resolveWithRanges(
            std.testing.allocator,
            "A12B",
            .ltr,
            &.{.{
                .byte_start = 1,
                .byte_len = 2,
                .modes = &.{case.mode},
            }},
        );
        defer ranged.deinit();
        var explicit = try resolve(
            std.testing.allocator,
            case.explicit,
            .ltr,
        );
        defer explicit.deinit();
        try std.testing.expectEqualSlices(u8, ranged.levels, &.{
            explicit.levels[0],
            explicit.levels[2],
            explicit.levels[3],
            explicit.levels[5],
        });
    }
}

test "nested attributed isolate closes before its outer embedding" {
    var ranged = try resolveWithRanges(
        std.testing.allocator,
        "A12B",
        .ltr,
        &.{.{
            .byte_start = 1,
            .byte_len = 2,
            .modes = &.{ .rtl_embedding, .ltr_isolate },
        }},
    );
    defer ranged.deinit();
    var explicit = try resolve(
        std.testing.allocator,
        "A\u{202b}\u{2066}12\u{2069}\u{202c}B",
        .ltr,
    );
    defer explicit.deinit();
    try std.testing.expectEqualSlices(u8, ranged.levels, &.{
        explicit.levels[0],
        explicit.levels[3],
        explicit.levels[4],
        explicit.levels[7],
    });
}

test "attributed bidi ranges reopen after paragraph separators" {
    const text = "A\n12";
    var paragraph = try resolveWithRanges(
        std.testing.allocator,
        text,
        .ltr,
        &.{.{
            .byte_start = 0,
            .byte_len = text.len,
            .modes = &.{.rtl_override},
        }},
    );
    defer paragraph.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1 }, paragraph.levels);
}

test "attributed bidi ranges apply nested controls outside in" {
    var paragraph = try resolveWithRanges(
        std.testing.allocator,
        "A12B",
        .ltr,
        &.{.{
            .byte_start = 1,
            .byte_len = 2,
            .modes = &.{ .rtl_embedding, .ltr_override },
        }},
    );
    defer paragraph.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 2, 0 }, paragraph.levels);
}

test "attributed bidi ranges validate ordered UTF-8 source boundaries" {
    const text = "AéB";
    try std.testing.expectError(error.InvalidBidiRange, resolveWithRanges(
        std.testing.allocator,
        text,
        .ltr,
        &.{.{ .byte_start = 2, .byte_len = 1, .modes = &.{.ltr_embedding} }},
    ));
    try std.testing.expectError(error.InvalidBidiRange, resolveWithRanges(
        std.testing.allocator,
        text,
        .ltr,
        &.{
            .{ .byte_start = 1, .byte_len = 2, .modes = &.{.ltr_embedding} },
            .{ .byte_start = 2, .byte_len = 2, .modes = &.{.rtl_embedding} },
        },
    ));
}

test "paragraph levels reorder each line independently" {
    var paragraph = try resolve(
        std.testing.allocator,
        "abc אבג xyz",
        .ltr,
    );
    defer paragraph.deinit();
    const order = try paragraph.visualOrder(
        std.testing.allocator,
        0,
        paragraph.scalars.len,
    );
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 2, 3, 6, 5, 4, 7, 8, 9, 10 },
        order,
    );
}

test "reusable paragraph resolution matches owning resolution" {
    const text = "abc \u{2067}אבג 12\u{2069}";
    var owned = try resolve(std.testing.allocator, text, .auto);
    defer owned.deinit();
    var storage = Storage.init(std.testing.allocator);
    defer storage.deinit();
    var borrowed = try storage.resolve(text, .auto);
    defer borrowed.deinit();
    try std.testing.expectEqual(Paragraph.Owner.borrowed, borrowed.owner);
    try std.testing.expectEqual(owned.base_level, borrowed.base_level);
    try std.testing.expectEqualSlices(Class, owned.classes, borrowed.classes);
    try std.testing.expectEqualSlices(u8, owned.levels, borrowed.levels);
    try std.testing.expectEqual(owned.scalars.len, borrowed.scalars.len);
    for (owned.scalars, borrowed.scalars) |expected, actual| {
        try std.testing.expectEqualDeep(expected, actual);
    }
}

test "combined line transaction matches separate levels and order" {
    var paragraph = try resolve(
        std.testing.allocator,
        "abc \u{202e}(12)\u{202c} \u{00ad}אבג",
        .ltr,
    );
    defer paragraph.deinit();
    const retained_scalar = paragraph.scalarIndexForByte(
        std.mem.indexOf(u8, "abc \u{202e}(12)\u{202c} \u{00ad}אבג", "\u{00ad}").?,
    ).?;
    const retained = [_]usize{retained_scalar};
    const expected_levels = try paragraph.lineLevelsRetaining(
        std.testing.allocator,
        0,
        paragraph.scalars.len,
        &retained,
    );
    defer std.testing.allocator.free(expected_levels);
    const expected_order = try paragraph.visualOrderRetaining(
        std.testing.allocator,
        0,
        paragraph.scalars.len,
        &retained,
    );
    defer std.testing.allocator.free(expected_order);

    var levels = std.ArrayList(u8).empty;
    defer levels.deinit(std.testing.allocator);
    var order = std.ArrayList(usize).empty;
    defer order.deinit(std.testing.allocator);
    try paragraph.visualOrderAndLevelsRetaining(
        std.testing.allocator,
        0,
        paragraph.scalars.len,
        &retained,
        &levels,
        &order,
    );
    try std.testing.expectEqualSlices(u8, expected_levels, levels.items);
    try std.testing.expectEqualSlices(usize, expected_order, order.items);
}

test "ICU writeReordered conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("reorder_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJRD", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const base_level = fixture[cursor];
        const option_bits = fixture[cursor + 1];
        const input_len = std.mem.readInt(
            u16,
            fixture[cursor + 2 ..][0..2],
            .little,
        );
        const output_len = std.mem.readInt(
            u16,
            fixture[cursor + 4 ..][0..2],
            .little,
        );
        cursor += 6;
        const input = fixture[cursor..][0..input_len];
        cursor += input_len;
        const expected = fixture[cursor..][0..output_len];
        cursor += output_len;

        var paragraph = try resolve(
            allocator,
            input,
            if (base_level == 0) .ltr else .rtl,
        );
        defer paragraph.deinit();
        const actual = try paragraph.reorderAlloc(
            allocator,
            input,
            .{
                .mirroring = option_bits & 2 != 0,
                .remove_controls = option_bits & 8 != 0,
                .keep_base_combining = option_bits & 1 != 0,
                .output_reverse = option_bits & 16 != 0,
            },
        );
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "reorder mismatch: {s} base={d} options={x} got={s} want={s}\n",
                    .{ input, base_level, option_bits, actual, expected },
                );
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "bidi reorder conformance: {}/{} passed\n",
        .{ case_count - failures, case_count },
    );
}
