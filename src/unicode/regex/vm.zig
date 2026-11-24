//! Backtracking virtual machine for compiled ICU regular expressions.
//!
//! Matching operates on UTF-8 byte offsets. Every position stored in a
//! capture is a byte offset; the public API converts to UTF-16 code-unit
//! offsets when callers need ICU-compatible indices.

const std = @import("std");
const regexz = @import("regexz");
const regexz_backend = @import("regexz_backend.zig");
const compiler = @import("compiler.zig");
const parser = @import("parser.zig");
const set_mod = @import("../set.zig");
const properties = @import("../properties.zig");
const trie = @import("../properties/trie.zig");
const case_data = @import("../case/data.zig");
const grapheme = @import("../grapheme/iterator.zig");
const word = @import("../word/iterator.zig");

pub const Error = error{
    MatchLimit,
    OutOfMemory,
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    transparent_bounds: bool = false,
    anchoring_bounds: bool = true,
    max_steps: usize = 10_000_000,
    max_backtrack: usize = 1_000_000,
};

const no_position = std.math.maxInt(usize);
const max_look_depth = 64;

const Frame = struct {
    pc: u32,
    pos: usize,
    journal_len: usize,
    atomic_len: usize,
};

const JournalKind = enum { capture, counter, progress };

const Journal = struct {
    kind: JournalKind,
    index: u32,
    old: usize,
};

/// Per-matcher regexz workspaces. The compiled program itself lives in
/// `Regex`, so matchers stay independent and reusable. Each engine is
/// created on first use: boolean matching needs only the linear workspace,
/// while searching needs the capture-aware one.
const BackendState = struct {
    workspace: ?regexz.Workspace = null,
    /// `ReplaceWorkspace` is ~28 KiB; boxing it keeps `Runner` (and every
    /// `Matcher` returned by value) small enough to copy cheaply.
    search: ?*regexz.ReplaceWorkspace = null,
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    program: []const compiler.Inst,
    sets: []const set_mod.Set,
    exact: []const u8,
    folded: []const u21,
    flags: parser.Flags,
    text: []const u8,
    first_byte_bitmap: ?[4]u64,
    literal_prefix: ?[]const u8,
    folded_prefix: ?compiler.FoldedPrefix,
    required_literal: ?[]const u8,
    full_literal: ?[]const u8,
    literal_alternatives: ?[]const compiler.LiteralAlt,
    backend: ?*const regexz_backend.Program,
    backend_state: ?BackendState,

    region_start: usize,
    region_end: usize,
    anchor_start: usize,
    anchor_end: usize,
    look_start: usize,
    look_end: usize,
    active_limit: usize,
    transparent_bounds: bool = false,
    anchoring_bounds: bool = true,

    captures: []usize,
    counters: []u32,
    progress: []usize,
    fold_scratch: std.ArrayList(u21),

    last_match_end: usize = 0,
    had_match: bool = false,
    exhausted: bool = false,
    hit_end: bool = false,
    require_end: bool = false,

    steps: usize = 0,
    max_steps: usize,
    max_backtrack: usize,
    depth: u32 = 0,

    backtrack: std.ArrayList(Frame) = .empty,
    journal: std.ArrayList(Journal) = .empty,
    atomic_marks: std.ArrayList(usize) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        program: []const compiler.Inst,
        sets: []const set_mod.Set,
        exact: []const u8,
        folded: []const u21,
        flags: parser.Flags,
        text: []const u8,
        group_count: u16,
        first_byte_bitmap: ?[4]u64,
        literal_prefix: ?[]const u8,
        folded_prefix: ?compiler.FoldedPrefix,
        required_literal: ?[]const u8,
        full_literal: ?[]const u8,
        literal_alternatives: ?[]const compiler.LiteralAlt,
        backend: ?*const regexz_backend.Program,
        options: Options,
    ) error{OutOfMemory}!Runner {
        const capture_slots = (@as(usize, group_count) + 1) * 2;
        const captures = try allocator.alloc(usize, capture_slots);
        errdefer allocator.free(captures);
        const counters = try allocator.alloc(u32, program_counter_count(program));
        errdefer allocator.free(counters);
        const progress = try allocator.alloc(usize, program_progress_count(program));
        errdefer allocator.free(progress);

        const backend_state: ?BackendState = if (backend != null) .{} else null;

        var runner = Runner{
            .allocator = allocator,
            .program = program,
            .sets = sets,
            .exact = exact,
            .folded = folded,
            .flags = flags,
            .text = text,
            .first_byte_bitmap = first_byte_bitmap,
            .literal_prefix = literal_prefix,
            .folded_prefix = folded_prefix,
            .required_literal = required_literal,
            .full_literal = full_literal,
            .literal_alternatives = literal_alternatives,
            .backend = backend,
            .backend_state = backend_state,
            .region_start = 0,
            .region_end = text.len,
            .anchor_start = 0,
            .anchor_end = text.len,
            .look_start = 0,
            .look_end = text.len,
            .active_limit = text.len,
            .captures = captures,
            .counters = counters,
            .progress = progress,
            .fold_scratch = .empty,
            .max_steps = options.max_steps,
            .max_backtrack = options.max_backtrack,
            .transparent_bounds = options.transparent_bounds,
            .anchoring_bounds = options.anchoring_bounds,
        };
        runner.setBounds(options.transparent_bounds, options.anchoring_bounds);
        runner.clearState();
        return runner;
    }

    pub fn deinit(self: *Runner) void {
        if (self.backend_state) |*state| {
            if (state.workspace) |*workspace| workspace.deinit();
            if (state.search) |search| {
                search.deinit();
                self.allocator.destroy(search);
            }
        }
        self.allocator.free(self.captures);
        self.allocator.free(self.counters);
        self.allocator.free(self.progress);
        self.fold_scratch.deinit(self.allocator);
        self.backtrack.deinit(self.allocator);
        self.journal.deinit(self.allocator);
        self.atomic_marks.deinit(self.allocator);
    }

    pub fn reset(self: *Runner, text: []const u8) void {
        self.text = text;
        self.region_start = 0;
        self.region_end = text.len;
        self.active_limit = text.len;
        self.setBounds(self.transparent_bounds, self.anchoring_bounds);
        self.clearState();
    }

    pub fn setRegion(self: *Runner, start: usize, end: usize) void {
        self.region_start = snapForward(self.text, @min(start, self.text.len));
        self.region_end = snapBackward(self.text, @min(end, self.text.len));
        if (self.region_end < self.region_start) {
            self.region_end = self.region_start;
        }
        self.active_limit = self.region_end;
        self.setBounds(self.transparent_bounds, self.anchoring_bounds);
        self.clearState();
    }

    pub fn setBounds(
        self: *Runner,
        transparent: bool,
        anchoring: bool,
    ) void {
        self.transparent_bounds = transparent;
        self.anchoring_bounds = anchoring;
        self.anchor_start = if (anchoring) self.region_start else 0;
        self.anchor_end = if (anchoring) self.region_end else self.text.len;
        self.look_start = if (transparent) 0 else self.region_start;
        self.look_end = if (transparent) self.text.len else self.region_end;
    }

    fn clearState(self: *Runner) void {
        for (self.captures) |*slot| slot.* = no_position;
        for (self.counters) |*counter| counter.* = 0;
        for (self.progress) |*slot| slot.* = 0;
        self.last_match_end = 0;
        self.had_match = false;
        self.exhausted = false;
        self.hit_end = false;
        self.require_end = false;
        self.steps = 0;
        self.depth = 0;
        self.backtrack.clearRetainingCapacity();
        self.journal.clearRetainingCapacity();
        self.atomic_marks.clearRetainingCapacity();
    }

    fn beginOperation(self: *Runner) void {
        for (self.captures) |*slot| slot.* = no_position;
        for (self.counters) |*counter| counter.* = 0;
        for (self.progress) |*slot| slot.* = 0;
        self.hit_end = false;
        self.require_end = false;
        self.steps = 0;
        self.depth = 0;
        self.backtrack.clearRetainingCapacity();
        self.journal.clearRetainingCapacity();
        self.atomic_marks.clearRetainingCapacity();
    }

    pub fn matches(self: *Runner) Error!bool {
        self.beginOperation();
        self.had_match = false;
        self.exhausted = false;
        // A bare literal is a whole-region equality test; skip the backend.
        if (self.full_literal) |literal| {
            const region = self.text[self.region_start..self.region_end];
            if (literal.len == region.len and std.mem.eql(u8, literal, region)) {
                self.captures[0] = self.region_start;
                self.captures[1] = self.region_end;
                self.last_match_end = self.region_end;
                self.had_match = true;
                self.hit_end = true;
                self.require_end = true;
                return true;
            }
            return false;
        }
        // A full match needs capture recovery, which regexz only exposes for
        // searches; group-free patterns can use its linear boolean engine.
        if (self.backendActive() and self.captures.len == 2) {
            if (try self.backendMatches()) |result| return result;
        }
        if (self.literal_alternatives) |alternatives| {
            const region = self.text[self.region_start..self.region_end];
            for (alternatives) |alternative| {
                const literal = self.exact[alternative.offset..][0..alternative.len];
                if (literal.len == region.len and std.mem.eql(u8, literal, region)) {
                    self.captures[0] = self.region_start;
                    self.captures[1] = self.region_end;
                    self.last_match_end = self.region_end;
                    self.had_match = true;
                    self.hit_end = true;
                    self.require_end = true;
                    return true;
                }
            }
            return false;
        }
        if (!self.matchPrechecks(self.region_start)) return false;
        const match_pc: u32 = @intCast(self.program.len - 1);
        const result = try self.execRange(0, match_pc, self.region_start, self.region_end);
        if (result) |end| {
            self.last_match_end = end;
            self.had_match = true;
            self.hit_end = true;
            self.require_end = true;
            return true;
        }
        return false;
    }

    pub fn lookingAt(self: *Runner) Error!bool {
        self.beginOperation();
        self.had_match = false;
        self.exhausted = false;
        // A bare literal is a prefix equality test; skip the backend.
        if (self.full_literal) |literal| {
            if (self.region_start + literal.len <= self.region_end and
                std.mem.eql(u8, literal, self.text[self.region_start..][0..literal.len]))
            {
                self.captures[0] = self.region_start;
                self.captures[1] = self.region_start + literal.len;
                self.last_match_end = self.region_start + literal.len;
                self.had_match = true;
                return true;
            }
            return false;
        }
        if (self.backendActive()) {
            if (try self.backendLookingAt()) |result| return result;
        }
        if (self.literal_alternatives) |alternatives| {
            for (alternatives) |alternative| {
                const literal = self.exact[alternative.offset..][0..alternative.len];
                if (self.region_start + literal.len <= self.region_end and
                    std.mem.eql(u8, literal, self.text[self.region_start..][0..literal.len]))
                {
                    self.captures[0] = self.region_start;
                    self.captures[1] = self.region_start + literal.len;
                    self.last_match_end = self.region_start + literal.len;
                    self.had_match = true;
                    return true;
                }
            }
            return false;
        }
        if (!self.matchPrechecks(self.region_start)) return false;
        const match_pc: u32 = @intCast(self.program.len - 1);
        const result = try self.execRange(0, match_pc, self.region_start, null);
        if (result) |end| {
            self.last_match_end = end;
            self.had_match = true;
            return true;
        }
        return false;
    }

    pub fn findAt(self: *Runner, start: usize) Error!bool {
        self.had_match = false;
        return self.searchFrom(start);
    }

    pub fn findNext(self: *Runner) Error!bool {
        if (self.exhausted) return false;
        if (!self.had_match) return self.searchFrom(self.region_start);
        const start = self.last_match_end;
        const previous_start = self.groupSpan(0) orelse return self.searchFrom(self.region_start);
        if (start > previous_start.start) {
            return self.searchFrom(start);
        }
        const decoded = nextScalar(self.text, start) orelse {
            self.exhausted = true;
            return false;
        };
        return self.searchFrom(decoded.next);
    }

    fn matchPrechecks(self: *Runner, start: usize) bool {
        if (start > self.region_end) return false;
        const remaining = self.text[start..self.region_end];
        if (self.literal_prefix) |prefix| {
            if (remaining.len < prefix.len or
                !std.mem.eql(u8, remaining[0..prefix.len], prefix))
            {
                return false;
            }
        }
        if (self.required_literal) |literal| {
            const found = std.mem.indexOfPos(u8, self.text, start, literal) orelse
                return false;
            if (found + literal.len > self.region_end) return false;
        }
        if (self.first_byte_bitmap) |bits| {
            if (remaining.len == 0) return false;
            const byte = remaining[0];
            if (byte >= 0x80) return false;
            const bits_word = bits[byte >> 6];
            if ((bits_word >> @intCast(byte & 63)) & 1 == 0) return false;
        }
        return true;
    }

    fn searchFrom(self: *Runner, start: usize) Error!bool {
        if (self.backendActive()) {
            if (try self.backendSearch(start)) |result| return result;
        }
        self.beginOperation();
        self.exhausted = false;
        var position = snapForward(self.text, @max(start, self.region_start));
        position = @min(position, self.region_end);
        const match_pc: u32 = @intCast(self.program.len - 1);

        if (self.literal_alternatives) |alternatives| {
            var best_start: ?usize = null;
            var best_length: usize = 0;
            for (alternatives) |alternative| {
                const literal = self.exact[alternative.offset..][0..alternative.len];
                const found = std.mem.indexOfPos(u8, self.text, position, literal) orelse continue;
                if (found + literal.len > self.region_end) continue;
                if (best_start == null or found < best_start.?) {
                    best_start = found;
                    best_length = literal.len;
                }
            }
            const found = best_start orelse {
                self.had_match = false;
                self.exhausted = true;
                return false;
            };
            self.captures[0] = found;
            self.captures[1] = found + best_length;
            self.last_match_end = found + best_length;
            self.had_match = true;
            return true;
        }

        if (self.full_literal) |literal| {
            const found = std.mem.indexOfPos(u8, self.text, position, literal) orelse {
                self.had_match = false;
                self.exhausted = true;
                return false;
            };
            if (found + literal.len > self.region_end) {
                self.had_match = false;
                self.exhausted = true;
                return false;
            }
            self.captures[0] = found;
            self.captures[1] = found + literal.len;
            self.last_match_end = found + literal.len;
            self.had_match = true;
            return true;
        }

        if (self.required_literal) |literal| {
            const found = std.mem.indexOfPos(u8, self.text, position, literal);
            if (found == null or found.? + literal.len > self.region_end) {
                self.had_match = false;
                self.exhausted = true;
                return false;
            }
        }

        if (self.literal_prefix) |prefix| {
            var search = position;
            while (search <= self.region_end) {
                const found = std.mem.indexOfPos(u8, self.text, search, prefix) orelse break;
                if (found + prefix.len > self.region_end) break;
                if (try self.execRange(0, match_pc, found, null)) |end| {
                    self.last_match_end = end;
                    self.had_match = true;
                    return true;
                }
                search = found + 1;
            }
            self.had_match = false;
            self.exhausted = true;
            return false;
        }

        if (self.folded_prefix) |prefix| {
            if (try self.searchFoldedPrefix(prefix, position)) |result| return result;
        }

        while (position <= self.region_end) {
            if (self.first_byte_bitmap) |bits| {
                if (!skipToCandidate(self.text, &position, self.region_end, bits)) break;
            }
            if (try self.execRange(0, match_pc, position, null)) |end| {
                self.last_match_end = end;
                self.had_match = true;
                return true;
            }
            const decoded = nextScalar(self.text, position) orelse break;
            position = decoded.next;
        }
        self.had_match = false;
        self.exhausted = true;
        return false;
    }

    /// Scan for the ASCII preimages of a folded prefix's first scalar and
    /// run the VM only at those candidates. Returns null when the scalar can
    /// also come from a non-ASCII or multi-scalar fold, where a byte scan
    /// would miss valid starts.
    fn searchFoldedPrefix(
        self: *Runner,
        prefix: compiler.FoldedPrefix,
        start: usize,
    ) Error!?bool {
        const bytes = foldedCandidateBytes(prefix.first) orelse return null;
        const match_pc: u32 = @intCast(self.program.len - 1);
        const haystack = self.text[0..self.region_end];
        var first_position: ?usize = std.mem.findScalarPos(u8, haystack, start, bytes[0]);
        var second_position: ?usize = if (bytes[0] != bytes[1])
            std.mem.findScalarPos(u8, haystack, start, bytes[1])
        else
            null;

        while (true) {
            var candidate: usize = undefined;
            if (first_position) |first| {
                candidate = if (second_position) |second| @min(first, second) else first;
            } else if (second_position) |second| {
                candidate = second;
            } else break;

            if (try self.execRange(0, match_pc, candidate, null)) |end| {
                self.last_match_end = end;
                self.had_match = true;
                return true;
            }
            if (first_position) |first| {
                if (first == candidate) {
                    first_position = std.mem.findScalarPos(u8, haystack, candidate + 1, bytes[0]);
                }
            }
            if (second_position) |second| {
                if (second == candidate) {
                    second_position = std.mem.findScalarPos(u8, haystack, candidate + 1, bytes[1]);
                }
            }
        }
        self.had_match = false;
        self.exhausted = true;
        return false;
    }

    /// The regexz engine may only stand in for the VM when ICU's opaque,
    /// anchoring region bounds are in effect: the region is then exactly the
    /// subject slice handed to regexz. Lookaround can read outside the
    /// region even with opaque bounds, so those programs additionally need a
    /// region that spans the whole subject.
    fn backendActive(self: *const Runner) bool {
        const backend = self.backend orelse return false;
        if (self.backend_state == null or
            self.transparent_bounds or !self.anchoring_bounds)
        {
            return false;
        }
        if (backend.needs_context and
            (self.region_start != 0 or self.region_end != self.text.len))
        {
            return false;
        }
        return true;
    }

    fn ensureBackendWorkspace(self: *Runner) error{OutOfMemory}!*regexz.Workspace {
        const state = &self.backend_state.?;
        if (state.workspace == null) {
            state.workspace = try regexz.Workspace.init(
                self.allocator,
                self.backend.?.program,
            );
        }
        return &state.workspace.?;
    }

    fn ensureBackendSearch(self: *Runner) error{OutOfMemory}!*regexz.ReplaceWorkspace {
        const state = &self.backend_state.?;
        if (state.search == null) {
            const search = try self.allocator.create(regexz.ReplaceWorkspace);
            errdefer self.allocator.destroy(search);
            search.* = try regexz.ReplaceWorkspace.init(
                self.allocator,
                self.backend.?.program,
                .{},
            );
            state.search = search;
        }
        return state.search.?;
    }

    fn backendMatches(self: *Runner) Error!?bool {
        const backend = self.backend.?;
        const region = self.text[self.region_start..self.region_end];
        const matched = if (backend.program.extended)
            (try self.ensureBackendSearch()).fullMatch(region) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            }
        else
            (try self.ensureBackendWorkspace()).matchesBorrowed(&backend.program, region);
        if (matched) {
            self.captures[0] = self.region_start;
            self.captures[1] = self.region_end;
            self.last_match_end = self.region_end;
            self.had_match = true;
            self.hit_end = true;
            self.require_end = true;
        }
        return matched;
    }

    fn backendLookingAt(self: *Runner) Error!?bool {
        const found = self.backendSearchFromRegion(0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const match = found orelse return false;
        if (match.start != 0) {
            self.had_match = false;
            return false;
        }
        self.recordBackendMatch(match);
        return true;
    }

    fn backendSearch(self: *Runner, start: usize) Error!?bool {
        const position = snapForward(self.text, @max(start, self.region_start));
        if (position > self.region_end) {
            self.beginOperation();
            self.had_match = false;
            self.exhausted = true;
            return false;
        }
        const found = self.backendSearchFromRegion(position - self.region_start) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        self.beginOperation();
        self.exhausted = false;
        const match = found orelse {
            self.had_match = false;
            self.exhausted = true;
            return false;
        };
        self.recordBackendMatch(match);
        return true;
    }

    fn backendSearchFromRegion(
        self: *Runner,
        start: usize,
    ) regexz.Error!?regexz.Match {
        const search = self.ensureBackendSearch() catch
            return error.OutOfMemory;
        const region = self.text[self.region_start..self.region_end];
        return search.find(region, start);
    }

    fn recordBackendMatch(self: *Runner, match: regexz.Match) void {
        const base = self.region_start;
        for (self.captures, 0..) |*slot, index| {
            const value = if (index < match.slots.len)
                match.slots[index]
            else
                no_position;
            slot.* = if (value == no_position) no_position else value + base;
        }
        self.captures[0] = match.start + base;
        self.captures[1] = match.end + base;
        self.last_match_end = match.end + base;
        self.had_match = true;
        self.hit_end = match.end + base >= self.region_end;
        self.require_end = self.hit_end;
    }

    pub fn groupSpan(self: *const Runner, group_index: u16) ?Span {
        const index = @as(usize, group_index) * 2;
        if (index + 1 >= self.captures.len) return null;
        const start = self.captures[index];
        const end = self.captures[index + 1];
        if (start == no_position or end == no_position or end < start) return null;
        return .{ .start = start, .end = end };
    }

    pub fn group(self: *const Runner, group_index: u16) ?[]const u8 {
        const span = self.groupSpan(group_index) orelse return null;
        return self.text[span.start..span.end];
    }

    fn execRange(
        self: *Runner,
        start_pc: u32,
        end_pc: u32,
        start_pos: usize,
        required_end: ?usize,
    ) Error!?usize {
        if (self.depth >= max_look_depth) return error.MatchLimit;
        self.depth += 1;
        defer self.depth -= 1;

        const bt_base = self.backtrack.items.len;
        const journal_base = self.journal.items.len;
        const atomic_base = self.atomic_marks.items.len;

        var pc = start_pc;
        var pos = start_pos;

        while (true) {
            self.steps += 1;
            if (self.steps > self.max_steps) return error.MatchLimit;

            if (pc == end_pc) {
                if (required_end) |end| {
                    if (pos != end) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                }
                self.backtrack.shrinkRetainingCapacity(bt_base);
                self.atomic_marks.shrinkRetainingCapacity(atomic_base);
                return pos;
            }

            const inst = self.program[pc];
            switch (inst) {
                .char => |expected| {
                    if (pos >= self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    if (expected <= 0x7f and self.text[pos] == expected) {
                        pos += 1;
                        pc += 1;
                        continue;
                    }
                    const decoded = nextScalar(self.text, pos) orelse {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    };
                    if (decoded.cp != expected) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos = decoded.next;
                    pc += 1;
                },
                .char_ci => |expected| {
                    if (pos >= self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    if (self.text[pos] < 0x80) {
                        if (expected <= 0x7f and asciiFold(self.text[pos]) == expected) {
                            pos += 1;
                            pc += 1;
                            continue;
                        }
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    const decoded = nextScalar(self.text, pos) orelse {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    };
                    const folded = foldScalar(decoded.cp);
                    if (folded.len != 1 or folded.items[0] != expected) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos = decoded.next;
                    pc += 1;
                },
                .string => |ref| {
                    const length: usize = ref.len;
                    if (pos + length > self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    const pattern = self.exact[ref.offset..][0..length];
                    if (!std.mem.eql(u8, self.text[pos..][0..length], pattern)) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos += length;
                    pc += 1;
                },
                .string_ci => |ref| {
                    const pattern = self.folded[ref.offset..][0..ref.len];
                    if (try self.matchFolded(pattern, pos)) |next| {
                        pos = next;
                        pc += 1;
                    } else if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                        return null;
                    }
                },
                .set => |index| {
                    if (pos >= self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    const byte = self.text[pos];
                    if (byte < 0x80) {
                        if (!self.sets[index].contains(byte)) {
                            if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                                return null;
                            }
                            continue;
                        }
                        pos += 1;
                        pc += 1;
                        continue;
                    }
                    const decoded = nextScalar(self.text, pos) orelse {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    };
                    if (!self.sets[index].contains(decoded.cp)) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos = decoded.next;
                    pc += 1;
                },
                .any => |dot| {
                    if (pos >= self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    const byte = self.text[pos];
                    if (byte < 0x80) {
                        const blocked = if (dot.dotall)
                            false
                        else if (dot.unix_lines)
                            byte == '\n'
                        else
                            isLineTerminator(byte);
                        if (blocked) {
                            if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                                return null;
                            }
                            continue;
                        }
                        pos += 1;
                        pc += 1;
                        continue;
                    }
                    const decoded = nextScalar(self.text, pos) orelse {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    };
                    const blocked = if (dot.dotall)
                        false
                    else if (dot.unix_lines)
                        decoded.cp == '\n'
                    else
                        isLineTerminator(decoded.cp);
                    if (blocked) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos = decoded.next;
                    pc += 1;
                },
                .split => |split| {
                    try self.pushFrame(split.second, pos);
                    pc = split.first;
                },
                .jmp => |target| pc = target,
                .save_start => |group_index| {
                    try self.saveCapture(@as(usize, group_index) * 2, pos);
                    pc += 1;
                },
                .save_end => |group_index| {
                    try self.saveCapture(@as(usize, group_index) * 2 + 1, pos);
                    pc += 1;
                },
                .anchor => |anchor| {
                    if (self.anchorMatches(anchor, pos)) {
                        pc += 1;
                    } else if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                        return null;
                    }
                },
                .backref => |backref| {
                    if (try self.matchBackref(backref, pos)) |next| {
                        pos = next;
                        pc += 1;
                    } else if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                        return null;
                    }
                },
                .grapheme => {
                    if (pos >= self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    const next = nextGraphemeBoundary(self.text, pos, self.active_limit);
                    if (next <= pos) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos = next;
                    pc += 1;
                },
                .linebreak => {
                    if (pos >= self.active_limit) {
                        self.hit_end = true;
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    const decoded = nextScalar(self.text, pos) orelse {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    };
                    if (!isLineTerminator(decoded.cp)) {
                        if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                            return null;
                        }
                        continue;
                    }
                    pos = decoded.next;
                    if (decoded.cp == '\r' and pos < self.active_limit) {
                        if (nextScalar(self.text, pos)) |next| {
                            if (next.cp == '\n') pos = next.next;
                        }
                    }
                    pc += 1;
                },
                .atomic_start => {
                    try self.atomic_marks.append(self.allocator, self.backtrack.items.len);
                    pc += 1;
                },
                .atomic_end => {
                    if (self.atomic_marks.items.len > atomic_base) {
                        const height = self.atomic_marks.items[self.atomic_marks.items.len - 1];
                        self.atomic_marks.items.len -= 1;
                        if (self.backtrack.items.len > height) {
                            self.backtrack.items.len = height;
                        }
                    }
                    pc += 1;
                },
                .repeat_init => |counter| {
                    try self.setCounter(counter, 0);
                    pc += 1;
                },
                .repeat_inc => |counter| {
                    const value = self.counters[counter];
                    try self.setCounter(counter, value +% 1);
                    pc += 1;
                },
                .repeat_decide => |decide| {
                    const count = self.counters[decide.counter];
                    if (count < decide.min) {
                        pc = decide.body;
                    } else if (count >= decide.max) {
                        pc = decide.exit;
                    } else if (decide.greedy) {
                        try self.pushFrame(decide.exit, pos);
                        pc = decide.body;
                    } else {
                        try self.pushFrame(decide.body, pos);
                        pc = decide.exit;
                    }
                },
                .progress_save => |slot| {
                    try self.setProgress(slot, pos);
                    pc += 1;
                },
                .progress_check_exit => |check| {
                    if (self.progress[check.slot] == pos) {
                        pc = check.exit;
                    } else {
                        pc += 1;
                    }
                },
                .look => |look| {
                    if (try self.runLook(look, pos)) {
                        pc = look.after;
                    } else if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                        return null;
                    }
                },
                .look_match, .match => {
                    // Markers are never executed; they delimit sub-programs.
                    if (!try self.backtrackTo(bt_base, journal_base, atomic_base, &pc, &pos)) {
                        return null;
                    }
                },
            }
        }
    }

    fn runLook(self: *Runner, look: compiler.LookInfo, pos: usize) Error!bool {
        const match_pc = look.after - 1;
        const journal_base = self.journal.items.len;
        const bt_base = self.backtrack.items.len;
        const atomic_base = self.atomic_marks.items.len;

        if (look.ahead) {
            const result = try self.execRange(look.body, match_pc, pos, null);
            if (look.positive) {
                return result != null;
            }
            if (result == null) return true;
            self.undo(journal_base);
            self.backtrack.shrinkRetainingCapacity(bt_base);
            self.atomic_marks.shrinkRetainingCapacity(atomic_base);
            return false;
        }

        const saved_limit = self.active_limit;
        self.active_limit = pos;
        defer self.active_limit = saved_limit;

        const min_len: u64 = look.min_len;
        const max_len: u64 = look.max_len;
        var candidate = backScalars(self.text, pos, min_len, 0);
        var extra: u64 = 0;
        while (true) {
            const result = try self.execRange(look.body, match_pc, candidate, pos);
            if (result != null) {
                if (look.positive) return true;
                self.undo(journal_base);
                self.backtrack.shrinkRetainingCapacity(bt_base);
                self.atomic_marks.shrinkRetainingCapacity(atomic_base);
                return false;
            }
            if (candidate == 0) break;
            if (extra >= max_len - min_len) break;
            const previous = prevScalar(self.text, candidate) orelse break;
            candidate = previous.start;
            extra += 1;
        }
        return !look.positive;
    }

    fn matchFolded(self: *Runner, pattern: []const u21, start: usize) Error!?usize {
        var pattern_index: usize = 0;
        var pos = start;
        while (pattern_index < pattern.len) {
            if (pos >= self.active_limit) {
                self.hit_end = true;
                return null;
            }
            if (self.text[pos] < 0x80) {
                if (pattern[pattern_index] == asciiFold(self.text[pos])) {
                    pattern_index += 1;
                    pos += 1;
                    continue;
                }
                return null;
            }
            const decoded = nextScalar(self.text, pos) orelse {
                self.hit_end = true;
                return null;
            };
            const folded = foldScalar(decoded.cp);
            if (folded.len > pattern.len - pattern_index) return null;
            var index: usize = 0;
            while (index < folded.len) : (index += 1) {
                if (folded.items[index] != pattern[pattern_index]) return null;
                pattern_index += 1;
            }
            pos = decoded.next;
        }
        return pos;
    }

    fn matchBackref(
        self: *Runner,
        backref: compiler.BackrefInfo,
        start: usize,
    ) Error!?usize {
        const span = self.groupSpan(backref.group) orelse return null;
        if (!backref.case_insensitive) {
            const length = span.end - span.start;
            if (start + length > self.active_limit) {
                self.hit_end = true;
                return null;
            }
            if (!std.mem.eql(
                u8,
                self.text[span.start..span.end],
                self.text[start..][0..length],
            )) return null;
            return start + length;
        }

        self.fold_scratch.clearRetainingCapacity();
        try foldInto(self.allocator, self.text[span.start..span.end], &self.fold_scratch);
        return self.matchFolded(self.fold_scratch.items, start);
    }

    fn anchorMatches(self: *Runner, anchor: parser.Anchor, pos: usize) bool {
        switch (anchor.kind) {
            .input_start => return pos == self.anchor_start,
            .input_end => {
                if (pos == self.anchor_end) {
                    self.hit_end = true;
                    self.require_end = true;
                    return true;
                }
                return false;
            },
            .input_end_final => {
                if (self.endFinalMatches(pos, anchor.unix_lines)) {
                    self.hit_end = true;
                    self.require_end = true;
                    return true;
                }
                return false;
            },
            .line_start => return self.lineStartMatches(pos),
            .line_end => {
                const matched = self.lineEndMatches(pos);
                if (matched and pos >= self.anchor_end) {
                    self.hit_end = true;
                    self.require_end = true;
                }
                return matched;
            },
            .word => return self.wordBoundary(pos, anchor.uword),
            .non_word => return !self.wordBoundary(pos, anchor.uword),
            .prev_match_end => {
                const target = if (self.had_match) self.last_match_end else self.region_start;
                return pos == target;
            },
        }
    }

    fn lineStartMatches(self: *Runner, pos: usize) bool {
        if (pos == self.anchor_start) return true;
        if (pos >= self.anchor_end) return false;
        const previous = prevScalar(self.text, pos) orelse return false;
        if (self.flags.unix_lines) return previous.cp == '\n';
        return isLineTerminator(previous.cp);
    }

    fn lineEndMatches(self: *Runner, pos: usize) bool {
        if (pos >= self.anchor_end) return true;
        const decoded = nextScalar(self.text, pos) orelse return false;
        if (self.flags.unix_lines) return decoded.cp == '\n';
        if (!isLineTerminator(decoded.cp)) return false;
        if (decoded.cp == '\n' and pos > self.anchor_start) {
            if (prevScalar(self.text, pos)) |previous| {
                if (previous.cp == '\r') return false;
            }
        }
        return true;
    }

    fn endFinalMatches(self: *Runner, pos: usize, unix_lines: bool) bool {
        if (pos >= self.anchor_end) return true;
        const decoded = nextScalar(self.text, pos) orelse return true;
        if (unix_lines) {
            return decoded.cp == '\n' and decoded.next >= self.anchor_end;
        }
        if (decoded.next >= self.anchor_end) {
            if (!isLineTerminator(decoded.cp)) return false;
            if (decoded.cp == '\n' and pos > self.anchor_start) {
                if (prevScalar(self.text, pos)) |previous| {
                    if (previous.cp == '\r') return false;
                }
            }
            return true;
        }
        if (decoded.cp == '\r') {
            if (nextScalar(self.text, decoded.next)) |next| {
                if (next.cp == '\n' and next.next >= self.anchor_end) return true;
            }
        }
        return false;
    }

    fn wordBoundary(self: *Runner, pos: usize, unicode_word: bool) bool {
        if (unicode_word) return self.unicodeWordBoundary(pos);

        if (pos >= self.look_end) self.hit_end = true;
        var current_is_word = false;
        if (pos < self.look_end) {
            if (self.text[pos] < 0x80) {
                current_is_word = asciiWord(self.text[pos]);
            } else {
                const decoded = nextScalar(self.text, pos) orelse return false;
                if (properties.isGraphemeExtend(decoded.cp) or
                    properties.category(decoded.cp) == .Cf)
                {
                    return false;
                }
                current_is_word = isWordScalar(decoded.cp);
            }
        }

        var previous_is_word = false;
        var cursor = pos;
        while (cursor > self.look_start) {
            if (self.text[cursor - 1] < 0x80) {
                previous_is_word = asciiWord(self.text[cursor - 1]);
                break;
            }
            const previous = prevScalar(self.text, cursor) orelse break;
            cursor = previous.start;
            if (properties.isGraphemeExtend(previous.cp) or
                properties.category(previous.cp) == .Cf)
            {
                continue;
            }
            previous_is_word = isWordScalar(previous.cp);
            break;
        }
        return current_is_word != previous_is_word;
    }

    fn unicodeWordBoundary(self: *Runner, pos: usize) bool {
        if (pos >= self.look_end) {
            self.hit_end = true;
            return true;
        }
        var iterator = word.Iterator{ .text = self.text[self.look_start..self.look_end] };
        while (iterator.next()) |segment| {
            const start = self.look_start + segment.byte_start;
            const end = start + segment.byte_len;
            if (pos == start) return true;
            if (pos < start) return false;
            if (pos == end) return true;
            if (pos < end) return false;
        }
        return pos == self.look_end;
    }

    fn pushFrame(self: *Runner, pc: u32, pos: usize) Error!void {
        if (self.backtrack.items.len >= self.max_backtrack) return error.MatchLimit;
        try self.backtrack.append(self.allocator, .{
            .pc = pc,
            .pos = pos,
            .journal_len = self.journal.items.len,
            .atomic_len = self.atomic_marks.items.len,
        });
    }

    fn backtrackTo(
        self: *Runner,
        bt_base: usize,
        journal_base: usize,
        atomic_base: usize,
        pc: *u32,
        pos: *usize,
    ) Error!bool {
        while (self.backtrack.items.len > bt_base) {
            const frame = self.backtrack.items[self.backtrack.items.len - 1];
            self.backtrack.items.len -= 1;
            self.undo(frame.journal_len);
            self.atomic_marks.shrinkRetainingCapacity(frame.atomic_len);
            pc.* = frame.pc;
            pos.* = frame.pos;
            return true;
        }
        self.undo(journal_base);
        self.atomic_marks.shrinkRetainingCapacity(atomic_base);
        return false;
    }

    fn undo(self: *Runner, journal_len: usize) void {
        var index = self.journal.items.len;
        while (index > journal_len) {
            index -= 1;
            const entry = self.journal.items[index];
            switch (entry.kind) {
                .capture => self.captures[entry.index] = entry.old,
                .counter => self.counters[entry.index] = @intCast(entry.old),
                .progress => self.progress[entry.index] = entry.old,
            }
        }
        self.journal.shrinkRetainingCapacity(journal_len);
    }

    fn saveCapture(self: *Runner, index: usize, value: usize) Error!void {
        try self.journal.append(self.allocator, .{
            .kind = .capture,
            .index = @intCast(index),
            .old = self.captures[index],
        });
        self.captures[index] = value;
    }

    fn setCounter(self: *Runner, index: u16, value: u32) Error!void {
        try self.journal.append(self.allocator, .{
            .kind = .counter,
            .index = index,
            .old = self.counters[index],
        });
        self.counters[index] = value;
    }

    fn setProgress(self: *Runner, index: u16, value: usize) Error!void {
        try self.journal.append(self.allocator, .{
            .kind = .progress,
            .index = index,
            .old = self.progress[index],
        });
        self.progress[index] = value;
    }
};

const Decoded = struct {
    cp: u21,
    next: usize,
};

fn nextScalar(text: []const u8, pos: usize) ?Decoded {
    if (pos >= text.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + length > text.len) return null;
    const cp = std.unicode.utf8Decode(text[pos..][0..length]) catch return null;
    return .{ .cp = cp, .next = pos + length };
}

const Previous = struct {
    cp: u21,
    start: usize,
};

fn prevScalar(text: []const u8, pos: usize) ?Previous {
    if (pos == 0 or pos > text.len) return null;
    var start = pos - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    const cp = std.unicode.utf8Decode(text[start..pos]) catch return null;
    return .{ .cp = cp, .start = start };
}

fn asciiFold(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn asciiWord(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '_';
}

/// ICU's `\w`: Alphabetic plus the mark, decimal-digit and connector
/// punctuation categories, plus the two join controls.
fn isWordScalar(codepoint: u21) bool {
    if (codepoint == 0x200c or codepoint == 0x200d) return true;
    const value = trie.value(codepoint);
    return (value & alphabetic_bit) != 0 or
        ((@as(u64, 1) << @as(u6, @intCast(value & 0x1f))) & word_category_mask) != 0;
}

const alphabetic_bit: u64 = @as(u64, 1) << @intFromEnum(
    properties.BinaryProperty.alphabetic,
);
const word_category_mask: u64 = properties.categoryMask(.Mn) |
    properties.categoryMask(.Mc) |
    properties.categoryMask(.Me) |
    properties.categoryMask(.Nd) |
    properties.categoryMask(.Pc);

const Folded = struct {
    items: [4]u21 = undefined,
    len: u3 = 0,
};

fn foldScalar(codepoint: u21) Folded {
    var result = Folded{};
    if (case_data.fullFold(codepoint)) |components| {
        for (components) |component| {
            result.items[result.len] = component;
            result.len += 1;
        }
    } else {
        result.items[0] = case_data.simpleFold(codepoint);
        result.len = 1;
    }
    return result;
}

fn foldInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u21),
) Error!void {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const folded = foldScalar(codepoint);
        try output.appendSlice(allocator, folded.items[0..folded.len]);
    }
}

fn backScalars(text: []const u8, pos: usize, count: u64, floor: usize) usize {
    var cursor = pos;
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const previous = prevScalar(text, cursor) orelse break;
        if (previous.start < floor) break;
        cursor = previous.start;
    }
    return cursor;
}

fn nextGraphemeBoundary(text: []const u8, pos: usize, limit: usize) usize {
    var breaker = grapheme.ScalarBreaker.init();
    var cursor = pos;
    const first = nextScalar(text, cursor) orelse return cursor;
    _ = breaker.push(first.cp);
    cursor = first.next;
    while (cursor < limit) {
        const decoded = nextScalar(text, cursor) orelse break;
        if (breaker.push(decoded.cp)) break;
        cursor = decoded.next;
    }
    return @min(cursor, limit);
}

fn foldedCandidateBytes(first: u21) ?[2]u8 {
    if (first >= 0x80) return null;
    const lower: u8 = @intCast(std.ascii.toLower(@intCast(first)));
    switch (lower) {
        // These folded scalars can also begin a non-ASCII or multi-scalar
        // full fold, so a plain byte scan would miss valid input starts:
        // ẚ -> aʾ, ﬀ/ﬁ/ﬂ/ﬃ/ﬄ -> f..., ẖ -> ẖ, İ -> i̇, ǰ -> ǰ,
        // K (Kelvin) -> k, ß/ẞ/ﬅ/ﬆ -> s..., ẗ -> ẗ, ẘ -> ẘ, ẙ -> ẙ.
        'a', 'f', 'h', 'i', 'j', 'k', 's', 't', 'w', 'y' => return null,
        else => {},
    }
    if (std.ascii.isAlphabetic(lower)) {
        return .{ lower, lower - ('a' - 'A') };
    }
    return .{ lower, lower };
}

fn skipToCandidate(
    text: []const u8,
    position: *usize,
    limit: usize,
    bits: [4]u64,
) bool {
    while (position.* < limit) {
        const byte = text[position.*];
        if (byte < 0x80) {
            const bits_word = bits[byte >> 6];
            if ((bits_word >> @intCast(byte & 63)) & 1 != 0) return true;
            position.* += 1;
        } else {
            const decoded = nextScalar(text, position.*) orelse return false;
            position.* = decoded.next;
        }
    }
    return false;
}

fn snapForward(text: []const u8, position: usize) usize {
    var cursor = @min(position, text.len);
    while (cursor < text.len and (text[cursor] & 0xc0) == 0x80) : (cursor += 1) {}
    return cursor;
}

fn snapBackward(text: []const u8, position: usize) usize {
    var cursor = @min(position, text.len);
    while (cursor > 0 and cursor < text.len and (text[cursor] & 0xc0) == 0x80) {
        cursor -= 1;
    }
    return cursor;
}

pub fn isLineTerminator(codepoint: u21) bool {
    return codepoint == 0x0a or codepoint == 0x0b or codepoint == 0x0c or
        codepoint == 0x0d or codepoint == 0x85 or codepoint == 0x2028 or
        codepoint == 0x2029;
}

fn program_counter_count(program: []const compiler.Inst) usize {
    var count: usize = 0;
    for (program) |inst| {
        switch (inst) {
            .repeat_init, .repeat_inc => |counter| {
                const value = @as(usize, counter) + 1;
                if (value > count) count = value;
            },
            .repeat_decide => |decide| {
                const value = @as(usize, decide.counter) + 1;
                if (value > count) count = value;
            },
            else => {},
        }
    }
    return count;
}

fn program_progress_count(program: []const compiler.Inst) usize {
    var count: usize = 0;
    for (program) |inst| {
        switch (inst) {
            .progress_save => |slot| {
                const value = @as(usize, slot) + 1;
                if (value > count) count = value;
            },
            .progress_check_exit => |check| {
                const value = @as(usize, check.slot) + 1;
                if (value > count) count = value;
            },
            else => {},
        }
    }
    return count;
}
