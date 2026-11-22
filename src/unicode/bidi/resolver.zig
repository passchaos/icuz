//! Unicode 17 bidirectional paragraph resolution (UAX #9).
//!
//! This module resolves one scalar-indexed paragraph. UTF-8 decoding, public
//! byte mappings, and per-line L1/L2 reordering live in the facade so the core
//! algorithm can also consume the property-only `BidiTest.txt` fixture.

const std = @import("std");

const property_data = @import("data.zig");

pub const Class = property_data.Class;
pub const max_explicit_level: u8 = 125;
pub const removed_level: u8 = 0xff;

pub const BaseDirection = enum {
    ltr,
    rtl,
    auto,
};

/// One decoded scalar of the paragraph under resolution. The resolver only
/// reads `codepoint`; the byte fields carry source coordinates for the owning
/// paragraph facade.
pub const Scalar = struct {
    codepoint: u21,
    byte_start: usize,
    byte_len: u3,
};

const Override = enum {
    neutral,
    ltr,
    rtl,
};

const StackEntry = struct {
    level: u8,
    override: Override,
    isolate: bool,
};

const Run = struct {
    level: u8,
    start: usize,
    end: usize,
    sos: Class = .on,
    eos: Class = .on,
    starts_with_pdi: bool = false,
    ends_with_isolate: bool = false,
    in_sequence: bool = false,
    next: ?usize = null,
};

const BracketPair = struct {
    open: usize,
    close: usize,
};

pub const block_alignment = std.mem.Alignment.fromByteUnits(@alignOf(usize));

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    /// One allocation holding every per-scalar working array: sequence
    /// indices, level runs, resolved types and per-sequence types. Splitting
    /// these into separate allocations made allocator locks the dominant cost
    /// of resolving short paragraphs.
    block: []align(block_alignment.toByteUnits()) u8 = &.{},
    capacity: usize = 0,
    indices_storage: []usize = &.{},
    runs_storage: []Run = &.{},
    types_storage: []Class = &.{},
    sequence_storage: []Class = &.{},
    /// Views over the paragraph currently being resolved.
    scalars: []const Scalar = &.{},
    initial_types: []const Class = &.{},
    types: []Class = &.{},
    levels: []u8 = &.{},
    indices: []usize = &.{},
    sequence_types: []Class = &.{},
    runs: []Run = &.{},
    indices_len: usize = 0,
    sequence_len: usize = 0,
    runs_len: usize = 0,
    has_bracket: bool = false,
    bracket_pairs: std.ArrayList(BracketPair) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scratch) void {
        self.bracket_pairs.deinit(self.allocator);
        self.allocator.free(self.block);
        self.* = undefined;
    }

    /// Resolve one paragraph. `classes` holds the original `Bidi_Class` of
    /// every scalar and is left untouched; `levels` receives the result.
    pub fn resolve(
        self: *Scratch,
        scalars: []const Scalar,
        classes: []const Class,
        levels: []u8,
        base_direction: BaseDirection,
    ) std.mem.Allocator.Error!u8 {
        std.debug.assert(classes.len == scalars.len);
        std.debug.assert(levels.len == scalars.len);
        self.scalars = scalars;
        self.initial_types = classes;
        self.levels = levels;
        self.indices_len = 0;
        self.sequence_len = 0;
        self.runs_len = 0;
        self.bracket_pairs.clearRetainingCapacity();
        try self.ensureCapacity(scalars.len);
        self.types = self.types_storage[0..scalars.len];
        self.indices = self.indices_storage[0..scalars.len];
        self.sequence_types = self.sequence_storage[0..scalars.len];

        // One table-driven flag accumulation records every property the
        // follow-up passes need, so they can skip whole scans of plain text.
        var flags: u8 = 0;
        for (classes, 0..) |class, index| {
            self.types[index] = class;
            levels[index] = 0;
            flags |= fill_flags[@intFromEnum(class)];
        }

        if (flags & FillFlags.fsi != 0) resolveFirstStrongIsolates(self.types);
        const base_level: u8 = switch (base_direction) {
            .ltr => 0,
            .rtl => 1,
            .auto => defaultLevel(self.types),
        };
        if (scalars.len == 0) return base_level;
        if (base_level == 0 and flags & FillFlags.impure == 0) {
            // Levels were initialized to zero above.
            return base_level;
        }

        // Paired brackets always carry the initial `.on` class, so only those
        // scalars need the sparse bracket lookup. Text without any bracket
        // skips the N0 pass entirely.
        self.has_bracket = false;
        if (flags & FillFlags.on != 0) {
            for (classes, scalars) |class, scalar| {
                if (class != .on) continue;
                if (property_data.bracket(scalar.codepoint) != null) {
                    self.has_bracket = true;
                    break;
                }
            }
        }

        if (flags & FillFlags.explicit != 0) {
            resolveExplicit(self.types, levels, base_level);
        } else if (base_level != 0) {
            // Without formatting characters the stack never changes, so every
            // scalar keeps the paragraph level.
            @memset(levels, base_level);
        }
        if (flags & FillFlags.structured == 0) {
            // Without formatting or isolate controls every scalar keeps one
            // level, so the paragraph is a single level run and a single
            // isolating run sequence over all scalars. Resolving it in place
            // skips the run scan and the per-sequence type copy.
            const sos = typeFromLevel(base_level);
            self.sequence_types = self.types;
            self.sequence_len = scalars.len;
            self.indices_len = scalars.len;
            for (self.indices, 0..) |*slot, index| slot.* = index;
            resolveWeak(self.types, sos, sos);
            try self.resolveNeutral(base_level, sos, sos);
            resolveImplicit(
                self.sequence_types[0..self.sequence_len],
                self.indices[0..self.indices_len],
                levels,
                base_level,
            );
        } else {
            // Level runs never exceed the scalar count plus one, so the single
            // block reserved above covers every run.
            self.runs = self.runs_storage[0 .. scalars.len + 1];
            self.resolveRuns(base_level);
            for (self.runs[0..self.runs_len], 0..) |run, run_index| {
                if (run.in_sequence) continue;
                try self.resolveSequence(run_index);
            }
        }
        // L1 resets paragraph/segment separators and the trailing formatting
        // context that immediately precedes them. The conformance suites expect
        // this line-ready form rather than raw X/I levels.
        if (flags & FillFlags.separator != 0) {
            resetSeparatorLevels(self.initial_types, levels, base_level);
        }
        resetTrailingLevels(self.initial_types, levels, base_level);
        if (flags & FillFlags.removed != 0) {
            for (self.initial_types, 0..) |value, index| {
                if (isRemovedByX9(value)) levels[index] = removed_level;
            }
        }
        return base_level;
    }

    fn ensureCapacity(self: *Scratch, scalar_count: usize) !void {
        if (self.capacity >= scalar_count or scalar_count == 0) return;
        const indices_bytes = scalar_count * @sizeOf(usize);
        const runs_bytes = (scalar_count + 1) * @sizeOf(Run);
        const types_offset = indices_bytes + runs_bytes;
        const sequence_offset = types_offset + scalar_count;
        const block = try self.allocator.alignedAlloc(
            u8,
            block_alignment,
            sequence_offset + scalar_count,
        );
        self.allocator.free(self.block);
        self.block = block;
        self.capacity = scalar_count;
        self.indices_storage = std.mem.bytesAsSlice(
            usize,
            block[0..indices_bytes],
        );
        const runs_bytes_slice: []align(block_alignment.toByteUnits()) u8 =
            @alignCast(block[indices_bytes..][0..runs_bytes]);
        self.runs_storage = std.mem.bytesAsSlice(Run, runs_bytes_slice);
        self.types_storage = std.mem.bytesAsSlice(
            Class,
            block[types_offset..][0..scalar_count],
        );
        self.sequence_storage = std.mem.bytesAsSlice(
            Class,
            block[sequence_offset..][0..scalar_count],
        );
    }

    fn resolveRuns(self: *Scratch, base_level: u8) void {
        const types = self.types;
        const levels = self.levels;
        var start: usize = 0;
        while (start < types.len and isRemovedByX9(types[start])) : (start += 1) {}
        if (start == types.len) return;

        var run_start = start;
        var level = levels[start];
        var cursor = start + 1;
        while (cursor < types.len) : (cursor += 1) {
            if (isRemovedByX9(types[cursor])) continue;
            if (levels[cursor] == level) continue;
            self.runs[self.runs_len] = .{
                .level = level,
                .start = run_start,
                .end = cursor,
            };
            self.runs_len += 1;
            run_start = cursor;
            level = levels[cursor];
        }
        self.runs[self.runs_len] = .{
            .level = level,
            .start = run_start,
            .end = types.len,
        };
        self.runs_len += 1;

        for (self.runs[0..self.runs_len]) |*run| {
            while (run.start < run.end and isRemovedByX9(types[run.start])) {
                run.start += 1;
            }
            while (run.end > run.start and isRemovedByX9(types[run.end - 1])) {
                run.end -= 1;
            }
            if (run.start == run.end) continue;
            run.starts_with_pdi = types[run.start] == .pdi;

            var previous_level = base_level;
            var index = run.start;
            while (index > 0) {
                index -= 1;
                if (isRemovedByX9(types[index])) continue;
                previous_level = levels[index];
                break;
            }
            run.sos = typeFromLevel(@max(previous_level, run.level));

            if (isIsolateInitiator(self.initial_types[run.end - 1])) {
                run.ends_with_isolate = true;
                run.eos = typeFromLevel(@max(base_level, run.level));
            } else {
                var next_level = base_level;
                index = run.end;
                while (index < types.len) : (index += 1) {
                    if (isRemovedByX9(types[index])) continue;
                    next_level = levels[index];
                    break;
                }
                run.eos = typeFromLevel(@max(next_level, run.level));
            }
        }

        linkIsolatingRuns(self.runs[0..self.runs_len]);
    }

    fn resolveSequence(
        self: *Scratch,
        first_run_index: usize,
    ) std.mem.Allocator.Error!void {
        self.indices_len = 0;
        self.sequence_len = 0;
        var run_index = first_run_index;
        const sequence_level = self.runs[first_run_index].level;
        const sos = self.runs[first_run_index].sos;
        var eos = sos;
        while (true) {
            const run = self.runs[run_index];
            var index = run.start;
            while (index < run.end) : (index += 1) {
                if (isRemovedByX9(self.types[index])) continue;
                self.indices[self.indices_len] = index;
                self.indices_len += 1;
                self.sequence_types[self.sequence_len] = self.types[index];
                self.sequence_len += 1;
            }
            eos = run.eos;
            run_index = run.next orelse break;
        }
        if (self.indices_len == 0) return;

        resolveWeak(self.sequence_types[0..self.sequence_len], sos, eos);
        try self.resolveNeutral(sequence_level, sos, eos);
        resolveImplicit(
            self.sequence_types[0..self.sequence_len],
            self.indices[0..self.indices_len],
            self.levels,
            sequence_level,
        );
    }

    fn resolveNeutral(
        self: *Scratch,
        sequence_level: u8,
        sos: Class,
        eos: Class,
    ) std.mem.Allocator.Error!void {
        if (self.has_bracket) try self.resolveBrackets(sequence_level, sos);
        const types = self.sequence_types[0..self.sequence_len];
        const embedding = typeFromLevel(sequence_level);
        var previous = sos;
        var cursor: usize = 0;
        while (cursor < types.len) {
            if (!isNeutralOrIsolate(types[cursor])) {
                previous = types[cursor];
                cursor += 1;
                continue;
            }
            const start = cursor;
            while (cursor < types.len and isNeutralOrIsolate(types[cursor])) {
                cursor += 1;
            }
            const next = if (cursor == types.len) eos else types[cursor];
            const leading = strongForNeutral(previous);
            const trailing = strongForNeutral(next);
            const resolved = if (leading == trailing) leading else embedding;
            @memset(types[start..cursor], resolved);
            previous = resolved;
        }
    }

    fn resolveBrackets(
        self: *Scratch,
        sequence_level: u8,
        sos: Class,
    ) std.mem.Allocator.Error!void {
        self.bracket_pairs.clearRetainingCapacity();
        var stack_opening: [63]u21 = undefined;
        var stack_position: [63]usize = undefined;
        var depth: usize = 0;
        for (self.indices[0..self.indices_len], 0..) |input_index, sequence_index| {
            if (self.sequence_types[sequence_index] != .on) continue;
            const bracket = property_data.bracket(
                self.scalars[input_index].codepoint,
            ) orelse continue;
            if (bracket.is_open) {
                if (depth == stack_opening.len) break;
                stack_opening[depth] = bracket.opening;
                stack_position[depth] = sequence_index;
                depth += 1;
                continue;
            }
            var stack_index = depth;
            while (stack_index > 0) {
                stack_index -= 1;
                if (stack_opening[stack_index] != bracket.opening) continue;
                try self.bracket_pairs.append(self.allocator, .{
                    .open = stack_position[stack_index],
                    .close = sequence_index,
                });
                depth = stack_index;
                break;
            }
        }
        if (self.bracket_pairs.items.len == 0) return;
        std.sort.heap(
            BracketPair,
            self.bracket_pairs.items,
            {},
            bracketPairLessThan,
        );

        const types = self.sequence_types[0..self.sequence_len];
        const embedding = typeFromLevel(sequence_level);
        for (self.bracket_pairs.items) |pair| {
            var pair_direction: Class = .on;
            for (types[pair.open + 1 .. pair.close]) |value| {
                const direction = strongForBracket(value);
                if (direction == .on) continue;
                pair_direction = direction;
                if (direction == embedding) break;
            }
            if (pair_direction == .on) continue;
            if (pair_direction != embedding) {
                pair_direction = sos;
                var index = pair.open;
                while (index > 0) {
                    index -= 1;
                    const direction = strongForBracket(types[index]);
                    if (direction == .on) continue;
                    pair_direction = direction;
                    break;
                }
                if (pair_direction == embedding or pair_direction == .on) {
                    pair_direction = embedding;
                }
            }
            types[pair.open] = pair_direction;
            types[pair.close] = pair_direction;
            applyFollowingNsm(
                types,
                self.initial_types,
                self.indices[0..self.indices_len],
                pair.open + 1,
                pair_direction,
            );
            applyFollowingNsm(
                types,
                self.initial_types,
                self.indices[0..self.indices_len],
                pair.close + 1,
                pair_direction,
            );
        }
    }
};

/// Link level runs into isolating run sequences in one reverse pass. The
/// nearest later PDI-starting run at the same level is exactly the first match
/// prescribed by BD13. Retaining that candidate per level avoids repeatedly
/// scanning the same suffix for deeply nested isolates.
fn linkIsolatingRuns(runs: []Run) void {
    // Only levels that actually start a PDI are read, so a small presence
    // bitmap replaces initializing the full 126-entry optional array.
    var next_pdi_by_level: [max_explicit_level + 1]usize = undefined;
    var has_next: [max_explicit_level + 1]bool = @splat(false);
    var run_index = runs.len;
    while (run_index != 0) {
        run_index -= 1;
        const run = &runs[run_index];
        if (run.ends_with_isolate and has_next[run.level]) {
            const next_index = next_pdi_by_level[run.level];
            run.next = next_index;
            runs[next_index].in_sequence = true;
        }
        if (run.starts_with_pdi) {
            next_pdi_by_level[run.level] = run_index;
            has_next[run.level] = true;
        }
    }
}

fn resolveFirstStrongIsolates(types: []Class) void {
    for (types, 0..) |*value, index| {
        if (value.* != .fsi) continue;
        value.* = if (firstStrongUntilPdi(types[index + 1 ..]) == 1)
            .rli
        else
            .lri;
    }
}

fn firstStrongUntilPdi(types: []const Class) u8 {
    var isolate_depth: usize = 0;
    for (types) |value| {
        switch (value) {
            .lri, .rli, .fsi => isolate_depth += 1,
            .pdi => {
                if (isolate_depth == 0) return 0;
                isolate_depth -= 1;
            },
            .l => if (isolate_depth == 0) return 0,
            .r, .al => if (isolate_depth == 0) return 1,
            else => {},
        }
    }
    return 0;
}

fn defaultLevel(types: []const Class) u8 {
    var isolate_depth: usize = 0;
    for (types) |value| {
        switch (value) {
            .lri, .rli, .fsi => isolate_depth += 1,
            .pdi => if (isolate_depth != 0) {
                isolate_depth -= 1;
            },
            .l => if (isolate_depth == 0) return 0,
            .r, .al => if (isolate_depth == 0) return 1,
            else => {},
        }
    }
    return 0;
}

/// Per-class bits accumulated while filling the working type array. One
/// table load and OR per scalar replaces several follow-up scans.
const FillFlags = struct {
    const explicit: u8 = 1 << 0;
    const fsi: u8 = 1 << 1;
    const separator: u8 = 1 << 2;
    const removed: u8 = 1 << 3;
    const impure: u8 = 1 << 4;
    /// Formatting, isolate or BN controls that split level runs.
    const structured: u8 = 1 << 5;
    /// At least one scalar has the `.on` class.
    const on: u8 = 1 << 6;
};

const fill_flags = buildFillFlags();

fn buildFillFlags() [@typeInfo(Class).@"enum".fields.len]u8 {
    var table = [_]u8{0} ** @typeInfo(Class).@"enum".fields.len;
    for (&table, 0..) |*bits, index| {
        const value: Class = @enumFromInt(index);
        var flags: u8 = 0;
        if (@intFromEnum(value) >= @intFromEnum(Class.lre)) {
            flags |= FillFlags.explicit;
        }
        if (value == .fsi) flags |= FillFlags.fsi;
        if (value == .b or value == .s) flags |= FillFlags.separator;
        if (isRemovedByX9(value)) flags |= FillFlags.removed;
        if (!isPureLtrClass(value)) flags |= FillFlags.impure;
        if (value == .bn or
            @intFromEnum(value) >= @intFromEnum(Class.lre))
        {
            flags |= FillFlags.structured;
        }
        if (value == .on) flags |= FillFlags.on;
        bits.* = flags;
    }
    return table;
}

fn isPureLtrClass(value: Class) bool {
    return switch (value) {
        .r,
        .al,
        .an,
        .rle,
        .rlo,
        .rli,
        .lre,
        .lro,
        .lri,
        .fsi,
        .pdf,
        .pdi,
        .bn,
        => false,
        else => true,
    };
}

fn resolveExplicit(types: []Class, levels: []u8, base_level: u8) void {
    var stack: [max_explicit_level + 1]StackEntry = undefined;
    var depth: usize = 1;
    stack[0] = .{ .level = base_level, .override = .neutral, .isolate = false };
    var overflow_isolates: usize = 0;
    var overflow_embeddings: usize = 0;
    var valid_isolates: usize = 0;

    for (types, 0..) |*value, index| {
        const original = value.*;
        switch (original) {
            .rle, .lre, .rlo, .lro, .rli, .lri => {
                const current = stack[depth - 1];
                levels[index] = current.level;
                const isolate = isIsolateInitiator(original);
                if (isolate) applyOverride(value, current.override);
                const rtl = original == .rle or original == .rlo or original == .rli;
                const new_level = if (rtl)
                    nextOdd(current.level)
                else
                    nextEven(current.level);
                if (new_level <= max_explicit_level and
                    overflow_isolates == 0 and overflow_embeddings == 0)
                {
                    if (isolate) valid_isolates += 1;
                    stack[depth] = .{
                        .level = new_level,
                        .override = switch (original) {
                            .lro => .ltr,
                            .rlo => .rtl,
                            else => .neutral,
                        },
                        .isolate = isolate,
                    };
                    depth += 1;
                } else if (isolate) {
                    overflow_isolates += 1;
                } else if (overflow_isolates == 0) {
                    overflow_embeddings += 1;
                }
            },
            .pdi => {
                if (overflow_isolates != 0) {
                    overflow_isolates -= 1;
                } else if (valid_isolates != 0) {
                    overflow_embeddings = 0;
                    while (depth > 1 and !stack[depth - 1].isolate) {
                        depth -= 1;
                    }
                    if (depth > 1) depth -= 1;
                    valid_isolates -= 1;
                }
                levels[index] = stack[depth - 1].level;
                applyOverride(value, stack[depth - 1].override);
            },
            .pdf => {
                levels[index] = stack[depth - 1].level;
                if (overflow_isolates != 0) {
                    // PDF inside an overflow isolate has no effect.
                } else if (overflow_embeddings != 0) {
                    overflow_embeddings -= 1;
                } else if (!stack[depth - 1].isolate and depth >= 2) {
                    depth -= 1;
                }
            },
            .b => {
                depth = 1;
                overflow_isolates = 0;
                overflow_embeddings = 0;
                valid_isolates = 0;
                levels[index] = base_level;
            },
            .bn => {},
            else => {
                levels[index] = stack[depth - 1].level;
                applyOverride(value, stack[depth - 1].override);
            },
        }
    }
}

/// Assign ICU-compatible levels to characters removed by X9 so callers can
/// reorder the original text, including embedding controls. `levels` must
/// already contain the resolved levels from `resolve`; only the removed
/// entries are replaced. ICU gives embedding controls the previous character
/// level and then propagates each BN from the next character.
pub fn assignDisplayLevels(
    classes: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    var stack: [max_explicit_level + 2]StackEntry = undefined;
    var depth: usize = 1;
    stack[0] = .{ .level = base_level, .override = .neutral, .isolate = false };
    var embedding: u8 = base_level;
    var previous: u8 = base_level;
    var overflow_isolates: usize = 0;
    var overflow_embeddings: usize = 0;
    var valid_isolates: usize = 0;

    for (classes, 0..) |class, index| {
        switch (class) {
            .lre, .rle, .lro, .rlo => {
                levels[index] = previous;
                const new_level = if (class == .lre or class == .lro)
                    nextEven(embedding)
                else
                    nextOdd(embedding);
                if (new_level <= max_explicit_level and
                    overflow_isolates == 0 and overflow_embeddings == 0)
                {
                    embedding = new_level;
                    stack[depth] = .{
                        .level = new_level,
                        .override = .neutral,
                        .isolate = false,
                    };
                    depth += 1;
                } else if (overflow_isolates == 0) {
                    overflow_embeddings += 1;
                }
            },
            .pdf => {
                levels[index] = previous;
                if (overflow_isolates != 0) {
                    // PDF inside an overflow isolate has no effect.
                } else if (overflow_embeddings != 0) {
                    overflow_embeddings -= 1;
                } else if (depth > 1 and !stack[depth - 1].isolate) {
                    depth -= 1;
                    embedding = stack[depth].level;
                }
            },
            .bn => levels[index] = previous,
            .lri, .rli, .fsi => {
                const isolate_class: Class = if (class == .fsi)
                    if (firstStrongUntilPdi(classes[index + 1 ..]) == 1)
                        .rli
                    else
                        .lri
                else
                    class;
                previous = embedding;
                const new_level = if (isolate_class == .rli)
                    nextOdd(embedding)
                else
                    nextEven(embedding);
                if (new_level <= max_explicit_level and
                    overflow_isolates == 0 and overflow_embeddings == 0)
                {
                    valid_isolates += 1;
                    embedding = new_level;
                    stack[depth] = .{
                        .level = new_level,
                        .override = .neutral,
                        .isolate = true,
                    };
                    depth += 1;
                } else {
                    overflow_isolates += 1;
                }
            },
            .pdi => {
                if (overflow_isolates != 0) {
                    overflow_isolates -= 1;
                } else if (valid_isolates != 0) {
                    overflow_embeddings = 0;
                    while (depth > 1 and !stack[depth - 1].isolate) depth -= 1;
                    if (depth > 1) depth -= 1;
                    valid_isolates -= 1;
                }
                embedding = stack[depth - 1].level;
                previous = embedding;
            },
            .b => {
                depth = 1;
                overflow_isolates = 0;
                overflow_embeddings = 0;
                valid_isolates = 0;
                embedding = base_level;
                previous = base_level;
            },
            else => previous = embedding,
        }
    }

    adjustRemovedLevels(classes, levels, base_level);
}

fn isMaskWs(value: Class) bool {
    return switch (value) {
        .b,
        .s,
        .ws,
        .bn,
        .lre,
        .rle,
        .lro,
        .rlo,
        .pdf,
        .lri,
        .rli,
        .fsi,
        .pdi,
        => true,
        else => false,
    };
}

/// ICU's `adjustWSLevels` for the characters removed by X9: trailing
/// whitespace/controls reset to the paragraph level, and remaining controls
/// inherit the level of the next character until a paragraph separator.
fn adjustRemovedLevels(
    classes: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    var index = classes.len;
    while (index > 0) {
        while (index > 0) {
            index -= 1;
            if (!isMaskWs(classes[index])) break;
            levels[index] = base_level;
        }
        while (index > 0) {
            index -= 1;
            const class = classes[index];
            if (isRemovedByX9(class)) {
                levels[index] = levels[index + 1];
            } else if (class == .b or class == .s) {
                levels[index] = base_level;
                break;
            }
        }
    }
}

// ICU inverse bidi implicit resolution (UBIDI_REORDER_INVERSE_LIKE_DIRECT).
// The tables below are transcribed from ICU's ubidi.cpp. `pc` encodes a
// property-state-table cell (5-bit state, action in the high bits) and `lc`
// a level-state-table cell (4-bit state, action in the high bits).

fn pc(action: u8, state: u8) u8 {
    return state + action * 32;
}

fn lc(action: u8, state: u8) u8 {
    return state + action * 16;
}

const inverse_tab_l_default = [6][8]u8{
    .{ 0, 1, 0, 2, 0, 0, 0, 0 },
    .{ 0, 1, 3, 3, lc(1, 4), lc(1, 4), 0, 1 },
    .{ 0, 1, 0, 2, lc(1, 5), lc(1, 5), 0, 2 },
    .{ 0, 1, 3, 3, lc(1, 4), lc(1, 4), 0, 2 },
    .{ 0, lc(2, 1), lc(3, 3), lc(3, 3), 4, 4, 0, 0 },
    .{ 0, lc(2, 1), 0, lc(3, 2), 5, 5, 0, 0 },
};

const inverse_tab_r_like_direct = [7][8]u8{
    .{ 1, 0, 2, 2, 0, 0, 0, 0 },
    .{ 1, 0, 1, 2, lc(1, 3), lc(1, 3), 0, 1 },
    .{ 1, 0, 2, 2, 0, 0, 0, 1 },
    .{ lc(2, 1), lc(3, 0), 6, 4, 3, 3, lc(3, 0), 0 },
    .{ lc(2, 1), lc(3, 0), 6, 4, 5, 5, lc(3, 0), 3 },
    .{ lc(2, 1), lc(3, 0), 6, 4, 5, 5, lc(3, 0), 2 },
    .{ lc(2, 1), lc(3, 0), 6, 4, 3, 3, lc(3, 0), 1 },
};

const inverse_act0 = [5]u8{ 0, 1, 2, 3, 4 };
const inverse_act1 = [4]u8{ 0, 1, 13, 14 };

const inverse_props = [24][16]u8{
    .{ 1, 2, 4, 5, 7, 15, 17, 7, 9, 7, 0, 7, 3, 18, 21, 4 },
    .{ 1, pc(1, 2), pc(1, 4), pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(1, 7), pc(1, 9), pc(1, 7), 1, 1, pc(1, 3), pc(1, 18), pc(1, 21), 0 },
    .{ pc(1, 1), 2, pc(1, 4), pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(1, 7), pc(1, 9), pc(1, 7), 2, 2, pc(1, 3), pc(1, 18), pc(1, 21), 1 },
    .{ pc(1, 1), pc(1, 2), pc(1, 6), pc(1, 6), pc(1, 8), pc(1, 16), pc(1, 17), pc(1, 8), pc(1, 8), pc(1, 8), 3, 3, 3, pc(1, 18), pc(1, 21), 1 },
    .{ pc(1, 1), pc(1, 2), 4, pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(2, 10), 11, pc(2, 10), 4, 4, pc(1, 3), 18, 21, 2 },
    .{ pc(1, 1), pc(1, 2), pc(1, 4), 5, pc(1, 7), pc(1, 15), pc(1, 17), pc(1, 7), pc(1, 9), pc(2, 12), 5, 5, pc(1, 3), pc(1, 18), pc(1, 21), 3 },
    .{ pc(1, 1), pc(1, 2), 6, 6, pc(1, 8), pc(1, 16), pc(1, 17), pc(1, 8), pc(1, 8), pc(2, 13), 6, 6, pc(1, 3), 18, 21, 3 },
    .{ pc(1, 1), pc(1, 2), pc(1, 4), pc(1, 5), 7, pc(1, 15), pc(1, 17), 7, pc(2, 14), 7, 7, 7, pc(1, 3), pc(1, 18), pc(1, 21), 4 },
    .{ pc(1, 1), pc(1, 2), pc(1, 6), pc(1, 6), 8, pc(1, 16), pc(1, 17), 8, 8, 8, 8, 8, pc(1, 3), pc(1, 18), pc(1, 21), 4 },
    .{ pc(1, 1), pc(1, 2), 4, pc(1, 5), 7, pc(1, 15), pc(1, 17), 7, 9, 7, 9, 9, pc(1, 3), 18, 21, 4 },
    .{ pc(3, 1), pc(3, 2), 4, pc(3, 5), pc(4, 7), pc(3, 15), pc(3, 17), pc(4, 7), pc(4, 14), pc(4, 7), 10, pc(4, 7), pc(3, 3), 18, 21, 2 },
    .{ pc(1, 1), pc(1, 2), 4, pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(1, 7), 11, pc(1, 7), 11, 11, pc(1, 3), 18, 21, 2 },
    .{ pc(3, 1), pc(3, 2), pc(3, 4), 5, pc(4, 7), pc(3, 15), pc(3, 17), pc(4, 7), pc(4, 14), pc(4, 7), 12, pc(4, 7), pc(3, 3), pc(3, 18), pc(3, 21), 3 },
    .{ pc(3, 1), pc(3, 2), 6, 6, pc(4, 8), pc(3, 16), pc(3, 17), pc(4, 8), pc(4, 8), pc(4, 8), 13, pc(4, 8), pc(3, 3), 18, 21, 3 },
    .{ pc(1, 1), pc(1, 2), pc(4, 4), pc(1, 5), 7, pc(1, 15), pc(1, 17), 7, 14, 7, 14, 14, pc(1, 3), pc(4, 18), pc(4, 21), 4 },
    .{ pc(1, 1), pc(1, 2), pc(1, 4), pc(1, 5), pc(1, 7), 15, pc(1, 17), pc(1, 7), pc(1, 9), pc(1, 7), 15, pc(1, 7), pc(1, 3), pc(1, 18), pc(1, 21), 5 },
    .{ pc(1, 1), pc(1, 2), pc(1, 6), pc(1, 6), pc(1, 8), 16, pc(1, 17), pc(1, 8), pc(1, 8), pc(1, 8), 16, pc(1, 8), pc(1, 3), pc(1, 18), pc(1, 21), 5 },
    .{ pc(1, 1), pc(1, 2), pc(1, 4), pc(1, 5), pc(1, 7), pc(1, 15), 17, pc(1, 7), pc(1, 9), pc(1, 7), 17, pc(1, 7), pc(1, 3), pc(1, 18), pc(1, 21), 6 },
    .{ pc(1, 1), pc(1, 2), 18, pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(2, 19), 20, pc(2, 19), 18, 18, pc(1, 3), 18, 21, 0 },
    .{ pc(3, 1), pc(3, 2), 18, pc(3, 5), pc(4, 7), pc(3, 15), pc(3, 17), pc(4, 7), pc(4, 14), pc(4, 7), 19, pc(4, 7), pc(3, 3), 18, 21, 0 },
    .{ pc(1, 1), pc(1, 2), 18, pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(1, 7), 20, pc(1, 7), 20, 20, pc(1, 3), 18, 21, 0 },
    .{ pc(1, 1), pc(1, 2), 21, pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(2, 22), 23, pc(2, 22), 21, 21, pc(1, 3), 18, 21, 3 },
    .{ pc(3, 1), pc(3, 2), 21, pc(3, 5), pc(4, 7), pc(3, 15), pc(3, 17), pc(4, 7), pc(4, 14), pc(4, 7), 22, pc(4, 7), pc(3, 3), 18, 21, 3 },
    .{ pc(1, 1), pc(1, 2), 21, pc(1, 5), pc(1, 7), pc(1, 15), pc(1, 17), pc(1, 7), 23, pc(1, 7), 23, 23, pc(1, 3), 18, 21, 3 },
};

fn inverseGroup(class: Class) u8 {
    return switch (class) {
        .l => 0,
        .r => 1,
        .en => 2,
        .an => 3,
        .ws, .on, .lri, .rli, .fsi, .pdi => 4,
        .s => 5,
        .b => 6,
        .es => 7,
        .et => 8,
        .cs => 9,
        .lre, .lro, .rle, .rlo, .pdf, .bn => 10,
        .nsm => 11,
        .al => 12,
    };
}

const InverseState = struct {
    imp_tab: []const [8]u8,
    imp_act: []const u8,
    state: u8 = 0,
    start_on: i64 = -1,
    run_level: u8,
};

fn setLevelRange(
    levels: []u8,
    start: usize,
    limit: usize,
    level: u8,
) void {
    if (start >= limit or start >= levels.len) return;
    @memset(levels[start..@min(limit, levels.len)], level);
}

fn processInverseSequence(
    levels: []u8,
    state: *InverseState,
    prop: u8,
    start_input: usize,
    limit: usize,
) void {
    const start0 = start_input;
    const old_state = state.state;
    const cell = state.imp_tab[old_state][prop];
    state.state = cell & 0x0f;
    const action = state.imp_act[cell >> 4];
    const add_level = state.imp_tab[state.state][7];
    var start = start_input;

    switch (action) {
        0 => {},
        1 => state.start_on = @intCast(start0),
        2 => if (state.start_on >= 0) {
            start = @intCast(state.start_on);
        },
        3 => if (state.start_on >= 0) {
            setLevelRange(
                levels,
                @intCast(state.start_on),
                start0,
                state.run_level + 1,
            );
        },
        13 => {
            const level = state.run_level;
            var k: i64 = @as(i64, @intCast(start0)) - 1;
            while (k >= state.start_on) : (k -= 1) {
                if (levels[@intCast(k)] == level + 3) {
                    while (k >= state.start_on and
                        levels[@intCast(k)] == level + 3)
                    {
                        levels[@intCast(k)] -= 2;
                        k -= 1;
                    }
                    while (k >= state.start_on and
                        levels[@intCast(k)] == level)
                    {
                        k -= 1;
                    }
                }
                if (k < state.start_on) break;
                if (levels[@intCast(k)] == level + 2) {
                    levels[@intCast(k)] = level;
                    continue;
                }
                levels[@intCast(k)] = level + 1;
            }
        },
        14 => {
            const level = state.run_level + 1;
            var k: i64 = @as(i64, @intCast(start0)) - 1;
            while (k >= state.start_on) : (k -= 1) {
                if (levels[@intCast(k)] > level) levels[@intCast(k)] -= 2;
            }
        },
        else => {},
    }

    if (add_level != 0 or start < start0) {
        setLevelRange(
            levels,
            start,
            limit,
            state.run_level + add_level,
        );
    }
}

/// Resolve a paragraph for ICU's inverse (visual to logical) bidi mode.
///
/// `levels` receives the levels ICU uses for `ubidi_writeReordered` in
/// `UBIDI_REORDER_INVERSE_LIKE_DIRECT` mode. Explicit embeddings are ignored
/// by ICU's inverse algorithm; they participate as BN at the paragraph level.
fn inverseTextIsMixed(classes: []const Class, base_level: u8) bool {
    var has_rtl = base_level & 1 != 0;
    var has_ltr = base_level & 1 == 0;
    var has_an = false;
    var has_possible_n = false;
    for (classes) |class| {
        switch (class) {
            .r, .al, .rle, .rlo, .rli => has_rtl = true,
            .l, .en, .an, .lre, .lro, .lri => has_ltr = true,
            else => {},
        }
        switch (class) {
            .an => has_an = true,
            .on,
            .cs,
            .es,
            .et,
            .b,
            .s,
            .ws,
            .bn,
            .lre,
            .rle,
            .lro,
            .rlo,
            .pdf,
            .lri,
            .rli,
            .fsi,
            .pdi,
            => has_possible_n = true,
            else => {},
        }
    }
    const ltr = !has_rtl and !(has_an and has_possible_n);
    const rtl = !ltr and !has_ltr;
    return !(ltr or rtl);
}

/// Resolve a paragraph for ICU's inverse (visual to logical) bidi mode.
///
/// `levels` receives the levels ICU uses for `ubidi_writeReordered` in
/// `UBIDI_REORDER_INVERSE_LIKE_DIRECT` mode. Explicit embeddings are ignored
/// by ICU's inverse algorithm; they participate as BN at the paragraph level.
pub fn resolveInverse(
    classes: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    @memset(levels, base_level);
    if (!inverseTextIsMixed(classes, base_level)) return;

    var last_arabic: ?usize = null;
    for (classes, 0..) |class, index| {
        if (class == .al) last_arabic = index;
    }
    const inverse_rtl = (base_level & 1 != 0) and
        last_arabic != null and last_arabic.? > 0;

    const sor: u8 = base_level & 1;
    var state_imp: u8 = if (classes.len > 0 and classes[0] == .nsm)
        1 + sor
    else
        0;
    const imp_tab: []const [8]u8 = if (base_level & 1 == 0)
        inverse_tab_l_default[0..]
    else
        inverse_tab_r_like_direct[0..];
    const imp_act: []const u8 = if (base_level & 1 == 0)
        inverse_act0[0..]
    else
        inverse_act1[0..];
    var state = InverseState{
        .imp_tab = imp_tab,
        .imp_act = imp_act,
        .run_level = base_level,
    };
    processInverseSequence(levels, &state, sor, 0, 0);

    var start1: usize = 0;
    var start2: usize = 0;
    var next_strong_pos: usize = 0;
    var next_strong_class: Class = .r;

    var index: usize = 0;
    while (index <= classes.len) : (index += 1) {
        var prop: u8 = sor;
        if (index == classes.len) {
            var cursor = classes.len;
            while (cursor > 0) {
                cursor -= 1;
                const class = classes[cursor];
                if (isRemovedByX9(class)) continue;
                if (class == .lri or class == .rli) {
                    processInverseSequence(
                        levels,
                        &state,
                        sor,
                        classes.len,
                        classes.len,
                    );
                    resetParagraphLevels(classes, levels, base_level);
                    adjustRemovedLevels(classes, levels, base_level);
                    return;
                }
                break;
            }
        } else {
            var class = classes[index];
            if (inverse_rtl) {
                if (class == .al) {
                    class = .r;
                } else if (class == .en) {
                    if (next_strong_pos <= index) {
                        next_strong_class = .r;
                        next_strong_pos = classes.len;
                        var probe = index + 1;
                        while (probe < classes.len) : (probe += 1) {
                            const candidate = classes[probe];
                            if (candidate == .l or candidate == .r or
                                candidate == .al)
                            {
                                next_strong_class = candidate;
                                next_strong_pos = probe;
                                break;
                            }
                        }
                    }
                    if (next_strong_class == .al) class = .an;
                }
            }
            prop = inverseGroup(class);
        }

        const old_state = state_imp;
        const cell = inverse_props[old_state][prop];
        state_imp = cell & 0x1f;
        var action = cell >> 5;
        if (index == classes.len and action == 0) action = 1;
        if (action != 0) {
            const resolved = inverse_props[old_state][15];
            switch (action) {
                1 => {
                    processInverseSequence(
                        levels,
                        &state,
                        resolved,
                        start1,
                        index,
                    );
                    start1 = index;
                },
                2 => start2 = index,
                3 => {
                    processInverseSequence(
                        levels,
                        &state,
                        resolved,
                        start1,
                        start2,
                    );
                    processInverseSequence(levels, &state, 4, start2, index);
                    start1 = index;
                },
                4 => {
                    processInverseSequence(
                        levels,
                        &state,
                        resolved,
                        start1,
                        start2,
                    );
                    start1 = start2;
                    start2 = index;
                },
                else => {},
            }
        }
    }

    processInverseSequence(levels, &state, sor, classes.len, classes.len);
    resetParagraphLevels(classes, levels, base_level);
    adjustRemovedLevels(classes, levels, base_level);
}

/// Per-class dispatch bits for the weak-type pass, which visits every scalar
/// of a sequence and would otherwise run a chain of enum comparisons.
const WeakFlags = struct {
    const nsm: u8 = 1 << 0;
    const isolate_formatting: u8 = 1 << 1;
    const strong_initial: u8 = 1 << 2;
    const es_or_cs: u8 = 1 << 3;
    const et: u8 = 1 << 4;
    const weak: u8 = 1 << 5;
    const en: u8 = 1 << 6;
    const al: u8 = 1 << 7;
};

const weak_flags = buildWeakFlags();

fn buildWeakFlags() [@typeInfo(Class).@"enum".fields.len]u8 {
    var table = [_]u8{0} ** @typeInfo(Class).@"enum".fields.len;
    for (&table, 0..) |*flags, index| {
        const value: Class = @enumFromInt(index);
        var bits: u8 = 0;
        if (value == .nsm) bits |= WeakFlags.nsm;
        if (isIsolateFormatting(value)) bits |= WeakFlags.isolate_formatting;
        if (isStrongInitial(value)) bits |= WeakFlags.strong_initial;
        if (value == .es or value == .cs) bits |= WeakFlags.es_or_cs;
        if (value == .et) bits |= WeakFlags.et;
        if (value == .es or value == .et or value == .cs or value == .en) {
            bits |= WeakFlags.weak;
        }
        if (value == .en) bits |= WeakFlags.en;
        if (value == .al) bits |= WeakFlags.al;
        flags.* = bits;
    }
    return table;
}

fn resolveWeak(types: []Class, sos: Class, eos: Class) void {
    var previous = sos;
    var previous_strong = sos;
    var saw_et = false;
    var saw_weak = false;
    for (types, 0..) |*value, index| {
        var current = value.*;
        const flags = weak_flags[@intFromEnum(current)];
        if (flags & WeakFlags.nsm != 0) {
            current = switch (previous) {
                .lri, .rli, .fsi, .pdi => .on,
                else => previous,
            };
            value.* = current;
        } else {
            if (flags & WeakFlags.isolate_formatting != 0) {
                previous = .on;
                continue;
            }
            if (flags & WeakFlags.en != 0 and previous_strong == .al) {
                current = .an;
                value.* = current;
            } else if (flags & WeakFlags.strong_initial != 0) {
                previous_strong = current;
                if (flags & WeakFlags.al != 0) {
                    current = .r;
                    value.* = current;
                }
            } else if (flags & WeakFlags.es_or_cs != 0 and
                index + 1 < types.len)
            {
                var next = types[index + 1];
                if (next == .en and previous_strong == .al) next = .an;
                if (previous == .en and next == .en) {
                    current = .en;
                    value.* = current;
                } else if (current == .cs and previous == .an and next == .an) {
                    current = .an;
                    value.* = current;
                }
            }
            previous = current;
        }
        if (flags & WeakFlags.et != 0) saw_et = true;
        if (flags & WeakFlags.weak != 0) saw_weak = true;
    }

    // Most prose sequences contain no European separators, terminators, or
    // numbers; skip the two follow-up passes unless the first pass saw one.
    if (saw_et) {
        var cursor: usize = 0;
        while (cursor < types.len) {
            if (types[cursor] != .et) {
                cursor += 1;
                continue;
            }
            const start = cursor;
            while (cursor < types.len and types[cursor] == .et) : (cursor += 1) {}
            const before = if (start == 0) sos else types[start - 1];
            const after = if (cursor == types.len) eos else types[cursor];
            if (before == .en or after == .en) @memset(types[start..cursor], .en);
        }
    }
    if (!saw_weak) return;

    previous_strong = sos;
    for (types) |*value| {
        switch (value.*) {
            .es, .et, .cs => value.* = .on,
            .en => {
                if (previous_strong == .l) value.* = .l;
            },
            .l, .r => previous_strong = value.*,
            else => {},
        }
    }
}

fn resolveImplicit(
    types: []const Class,
    indices: []const usize,
    levels: []u8,
    sequence_level: u8,
) void {
    for (types, indices) |value, index| {
        if (sequence_level & 1 == 0) {
            levels[index] = sequence_level + switch (value) {
                .r => @as(u8, 1),
                .l => @as(u8, 0),
                else => @as(u8, 2),
            };
        } else {
            levels[index] = sequence_level + if (value == .r) @as(u8, 0) else 1;
        }
    }
}

fn resetParagraphLevels(
    initial_types: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    resetSeparatorLevels(initial_types, levels, base_level);
    resetTrailingLevels(initial_types, levels, base_level);
}

fn resetSeparatorLevels(
    initial_types: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    for (initial_types, 0..) |value, index| {
        if (value != .b and value != .s) continue;
        levels[index] = base_level;
        var previous = index;
        while (previous > 0) {
            previous -= 1;
            const candidate = initial_types[previous];
            if (isRemovedByX9(candidate)) continue;
            if (candidate == .ws or isIsolateInitiator(candidate) or
                candidate == .pdi)
            {
                levels[previous] = base_level;
                continue;
            }
            break;
        }
    }
}

fn resetTrailingLevels(
    initial_types: []const Class,
    levels: []u8,
    base_level: u8,
) void {
    var index = initial_types.len;
    while (index > 0) {
        index -= 1;
        const value = initial_types[index];
        if (isRemovedByX9(value)) continue;
        if (value == .ws or isIsolateInitiator(value) or value == .pdi) {
            levels[index] = base_level;
            continue;
        }
        break;
    }
}

fn applyFollowingNsm(
    types: []Class,
    initial_types: []const Class,
    indices: []const usize,
    start: usize,
    direction: Class,
) void {
    var index = start;
    while (index < types.len and initial_types[indices[index]] == .nsm) : (index += 1) {
        types[index] = direction;
    }
}

fn bracketPairLessThan(_: void, lhs: BracketPair, rhs: BracketPair) bool {
    return lhs.open < rhs.open;
}

fn applyOverride(value: *Class, override: Override) void {
    value.* = switch (override) {
        .neutral => value.*,
        .ltr => .l,
        .rtl => .r,
    };
}

fn nextOdd(level: u8) u8 {
    return (level + 1) | 1;
}

fn nextEven(level: u8) u8 {
    return (level + 2) & ~@as(u8, 1);
}

fn typeFromLevel(level: u8) Class {
    return if (level & 1 == 0) .l else .r;
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

fn isIsolateFormatting(value: Class) bool {
    return isIsolateInitiator(value) or value == .pdi;
}

fn isStrongInitial(value: Class) bool {
    return value == .l or value == .r or value == .al;
}

fn isNeutralOrIsolate(value: Class) bool {
    return switch (value) {
        .b, .s, .ws, .on, .lri, .rli, .fsi, .pdi => true,
        else => false,
    };
}

fn strongForNeutral(value: Class) Class {
    return switch (value) {
        .en, .an => .r,
        else => value,
    };
}

fn strongForBracket(value: Class) Class {
    return switch (value) {
        .en, .an, .al, .r => .r,
        .l => .l,
        else => .on,
    };
}

test {
    try @import("conformance_test.zig").run();
}

test "isolating run links select nearest following PDI at the same level" {
    var runs = [_]Run{
        .{ .level = 0, .start = 0, .end = 1, .ends_with_isolate = true },
        .{ .level = 1, .start = 1, .end = 2, .ends_with_isolate = true },
        // This PDI has the wrong level for both pending isolate runs.
        .{ .level = 2, .start = 2, .end = 3, .starts_with_pdi = true },
        .{ .level = 1, .start = 3, .end = 4, .starts_with_pdi = true },
        .{ .level = 0, .start = 4, .end = 5, .starts_with_pdi = true },
        // An unmatched isolate must remain a sequence root.
        .{ .level = 3, .start = 5, .end = 6, .ends_with_isolate = true },
    };

    linkIsolatingRuns(&runs);

    try std.testing.expectEqual(@as(?usize, 4), runs[0].next);
    try std.testing.expectEqual(@as(?usize, 3), runs[1].next);
    try std.testing.expectEqual(@as(?usize, null), runs[5].next);
    try std.testing.expect(runs[3].in_sequence);
    try std.testing.expect(runs[4].in_sequence);
    try std.testing.expect(!runs[2].in_sequence);
}

test "isolating run links prefer nearest PDI and handle level limit" {
    var runs = [_]Run{
        .{ .level = max_explicit_level, .start = 0, .end = 1, .ends_with_isolate = true },
        .{ .level = max_explicit_level, .start = 1, .end = 2, .starts_with_pdi = true, .ends_with_isolate = true },
        .{ .level = max_explicit_level, .start = 2, .end = 3, .starts_with_pdi = true },
    };

    linkIsolatingRuns(&runs);

    try std.testing.expectEqual(@as(?usize, 1), runs[0].next);
    try std.testing.expectEqual(@as(?usize, 2), runs[1].next);
    try std.testing.expect(runs[1].in_sequence);
    try std.testing.expect(runs[2].in_sequence);
}

test "ICU inverse bidi levels conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("inverse_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJIW", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const base_level = fixture[cursor];
        const input_len = std.mem.readInt(
            u16,
            fixture[cursor + 1 ..][0..2],
            .little,
        );
        const level_count = std.mem.readInt(
            u16,
            fixture[cursor + 3 ..][0..2],
            .little,
        );
        cursor += 5;
        const input = fixture[cursor..][0..input_len];
        cursor += input_len;
        const expected = fixture[cursor..][0..level_count];
        cursor += level_count;

        var classes = std.ArrayList(Class).empty;
        defer classes.deinit(allocator);
        var offset: usize = 0;
        while (offset < input.len) {
            const length = std.unicode.utf8ByteSequenceLength(
                input[offset],
            ) catch return error.InvalidFixture;
            if (offset + length > input.len) return error.InvalidFixture;
            const codepoint = std.unicode.utf8Decode(
                input[offset..][0..length],
            ) catch return error.InvalidFixture;
            try classes.append(allocator, property_data.class(codepoint));
            offset += length;
        }
        if (classes.items.len != level_count) return error.InvalidFixture;

        const levels = try allocator.alloc(u8, classes.items.len);
        defer allocator.free(levels);
        resolveInverse(classes.items, levels, base_level);
        if (!std.mem.eql(u8, levels, expected)) {
            failures += 1;
            if (failures <= 10) {
                std.debug.print(
                    "inverse level mismatch: {s} base={d} got={any} want={any}\n",
                    .{ input, base_level, levels, expected },
                );
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "inverse bidi levels: {}/{} cases passed\n",
        .{ case_count - failures, case_count },
    );
}
