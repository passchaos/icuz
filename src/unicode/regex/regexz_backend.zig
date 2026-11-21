//! Optional regexz execution backend for ICU-syntax patterns.
//!
//! icuz keeps its ICU parser and public API. Patterns whose AST lowers
//! exactly onto regexz's program model run on regexz's linear NFA/DFA/Pike
//! engines; every other construct keeps the local backtracking VM. The
//! lowering is deliberately conservative: a construct is only translated
//! when its ICU semantics match regexz's assertion or instruction exactly.

const std = @import("std");
const build_options = @import("build_options");
const regexz = @import("regexz");
const parser = @import("parser.zig");

const model = regexz.model;
const Node = model.Node;

/// A lowered program plus the arena that owns its node and set memory.
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    program: regexz.Program,
    /// True when the program contains lookaround. ICU lets lookaround read
    /// outside the region, but regexz only sees the region slice, so such
    /// programs are limited to whole-text regions by the runner.
    needs_context: bool = false,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }
};

/// Lower `parsed` into a regexz program. Returns null when the pattern uses
/// a construct that is not translated exactly; callers then keep the local
/// VM. OutOfMemory is propagated.
pub fn lower(
    allocator: std.mem.Allocator,
    parsed: *const parser.Parsed,
) error{OutOfMemory}!?Program {
    if (!build_options.regexz_backend) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const group_nodes = try arena_allocator.alloc(?*const Node, @as(usize, parsed.group_count) + 1);
    @memset(group_nodes, null);
    var builder = Builder{
        .arena = arena_allocator,
        .parsed = parsed,
        .capture_nodes = group_nodes,
    };
    const root = builder.lowerNode(parsed.root) catch |err| switch (err) {
        error.Unsupported => {
            arena.deinit();
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    const nodes = try arena_allocator.alloc(*const Node, group_nodes.len);
    nodes[0] = root;
    for (group_nodes[1..], 1..) |entry, index| {
        nodes[index] = entry orelse root;
    }
    const names = try arena_allocator.alloc(model.GroupName, parsed.names.len);
    for (parsed.names, 0..) |name, index| {
        // The parser's name bytes live in its arena, which the caller frees
        // after lowering; keep an arena-owned copy alongside the program.
        names[index] = .{
            .name = try arena_allocator.dupe(u8, name.name),
            .index = name.index,
        };
    }

    const result = model.ParseResult{
        .root = root,
        .group_names = names,
        .group_nodes = nodes,
        .capture_count = parsed.group_count,
        .extended = builder.extended,
    };
    const program = regexz.compileParsed(arena_allocator, result, .{}) catch {
        arena.deinit();
        return null;
    };
    return .{
        .arena = arena,
        .program = program,
        .needs_context = builder.needs_context,
    };
}

const Builder = struct {
    arena: std.mem.Allocator,
    parsed: *const parser.Parsed,
    capture_nodes: []?*const Node,
    extended: bool = false,
    needs_context: bool = false,
    /// Depth of lookbehind children currently being lowered. ICU tries the
    /// rightmost allowed start first, while regexz scans from the subject
    /// start, so a capture inside a lookbehind could bind a different span.
    lookbehind_depth: u32 = 0,

    const Error = error{ Unsupported, OutOfMemory };

    fn make(self: *Builder, node: Node) Error!*const Node {
        const pointer = try self.arena.create(Node);
        pointer.* = node;
        return pointer;
    }

    fn lowerNode(self: *Builder, node: *const parser.Node) Error!*const Node {
        return switch (node.*) {
            .empty => try self.make(.empty),
            .literal => |literal| try self.lowerLiteral(literal),
            .any => |dot| try self.make(.{ .set = try self.dotSet(dot) }),
            .set => |index| try self.make(.{ .set = try self.convertSet(index) }),
            .concat => |children| try self.lowerConcat(children),
            .alternate => |children| try self.lowerAlternate(children),
            .repeat => |repeat| blk: {
                const child = try self.lowerNode(repeat.child);
                if (repeat.kind == .possessive) self.extended = true;
                break :blk try self.make(.{ .repeat = .{
                    .child = child,
                    .minimum = repeat.min,
                    .maximum = if (repeat.max) |maximum| @as(usize, maximum) else null,
                    .lazy = repeat.kind == .reluctant,
                    .possessive = repeat.kind == .possessive,
                } });
            },
            .capture => |capture| blk: {
                if (self.lookbehind_depth != 0) return error.Unsupported;
                const child = try self.lowerNode(capture.child);
                const pointer = try self.make(.{ .capture = .{
                    .index = capture.index,
                    .name = capture.name,
                    .child = child,
                } });
                self.capture_nodes[capture.index] = pointer;
                break :blk pointer;
            },
            .atomic => |child| blk: {
                self.extended = true;
                break :blk try self.make(.{ .atomic = try self.lowerNode(child) });
            },
            .look => |look| blk: {
                self.extended = true;
                self.needs_context = true;
                const behind = !look.ahead;
                if (behind) self.lookbehind_depth += 1;
                defer if (behind) {
                    self.lookbehind_depth -= 1;
                };
                break :blk try self.make(.{ .lookaround = .{
                    .child = try self.lowerNode(look.child),
                    .negative = !look.positive,
                    .behind = behind,
                } });
            },
            .anchor => |anchor| try self.make(.{
                .assertion = try anchorAssertion(anchor),
            }),
            .backref => |backref| blk: {
                // ICU compares case-insensitive back references with full
                // case folding; regexz's extended engine folds one scalar at
                // a time, so multi-scalar folds such as ß -> ss would not
                // agree. Case-sensitive references lower exactly.
                if (backref.case_insensitive) return error.Unsupported;
                self.extended = true;
                break :blk try self.make(.{ .backref = .{
                    .index = backref.group,
                    .fold = .none,
                } });
            },
            .grapheme => blk: {
                self.extended = true;
                break :blk try self.make(.grapheme);
            },
            .linebreak => error.Unsupported,
        };
    }

    fn lowerLiteral(self: *Builder, literal: parser.Literal) Error!*const Node {
        // Case-insensitive literals need the full simple-fold preimage of
        // every folded scalar; the parser's set closure is not exact for
        // multi-character folds such as ß -> ss, so they stay on the VM.
        if (literal.case_insensitive) return error.Unsupported;
        var iterator = std.unicode.Utf8Iterator{ .bytes = literal.text, .i = 0 };
        var head: ?*const Node = null;
        while (iterator.nextCodepoint()) |codepoint| {
            const single = try self.singleRuneSet(codepoint);
            const node = try self.make(.{ .set = single });
            head = if (head) |previous|
                try self.make(.{ .pair = .{ .left = previous, .right = node } })
            else
                node;
        }
        return head orelse try self.make(.empty);
    }

    fn lowerConcat(self: *Builder, children: []*parser.Node) Error!*const Node {
        if (children.len == 0) return self.make(.empty);
        var node = try self.lowerNode(children[children.len - 1]);
        var index = children.len - 1;
        while (index > 0) {
            index -= 1;
            const left = try self.lowerNode(children[index]);
            node = try self.make(.{ .pair = .{ .left = left, .right = node } });
        }
        return node;
    }

    fn lowerAlternate(self: *Builder, children: []*parser.Node) Error!*const Node {
        if (children.len == 0) return self.make(.empty);
        var node = try self.lowerNode(children[children.len - 1]);
        var index = children.len - 1;
        while (index > 0) {
            index -= 1;
            const left = try self.lowerNode(children[index]);
            node = try self.make(.{ .alternate = .{
                .left = left,
                .right = node,
            } });
        }
        return node;
    }

    fn convertSet(self: *Builder, index: u32) Error!model.Set {
        const source = &self.parsed.sets[index];
        if (source.strings.items.len != 0) return error.Unsupported;
        const ranges = try self.arena.alloc(model.Range, source.ranges.items.len);
        for (source.ranges.items, 0..) |range, range_index| {
            ranges[range_index] = .{ .first = range.first, .last = range.last };
        }
        return makeSet(ranges);
    }

    fn singleRuneSet(self: *Builder, codepoint: u21) Error!model.Set {
        const ranges = try self.arena.alloc(model.Range, 1);
        ranges[0] = .{ .first = codepoint, .last = codepoint };
        return makeSet(ranges);
    }

    /// ICU's dot excludes its line terminators unless DOTALL; UNIX_LINES
    /// narrows that to U+000A. A set expresses this exactly on regexz's rune
    /// consumer.
    fn dotSet(self: *Builder, dot: parser.Dot) Error!model.Set {
        if (dot.dotall) {
            const ranges = try self.arena.alloc(model.Range, 1);
            ranges[0] = .{ .first = 0, .last = 0x10FFFF };
            return makeSet(ranges);
        }
        if (dot.unix_lines) {
            const ranges = try self.arena.alloc(model.Range, 2);
            ranges[0] = .{ .first = 0, .last = '\n' - 1 };
            ranges[1] = .{ .first = '\n' + 1, .last = 0x10FFFF };
            return makeSet(ranges);
        }
        const ranges = try self.arena.alloc(model.Range, 4);
        ranges[0] = .{ .first = 0, .last = 0x09 };
        ranges[1] = .{ .first = 0x0E, .last = 0x84 };
        ranges[2] = .{ .first = 0x86, .last = 0x2027 };
        ranges[3] = .{ .first = 0x202A, .last = 0x10FFFF };
        return makeSet(ranges);
    }
};

fn anchorAssertion(anchor: parser.Anchor) Builder.Error!model.Assertion {
    // Word boundaries and line anchors use ICU-specific definitions that do
    // not map onto regexz's newline and word rules, so they stay on the VM.
    if (anchor.uword) return error.Unsupported;
    return switch (anchor.kind) {
        .input_start => .start_text,
        .input_end => .end_text,
        // ICU's `$` accepts any final line-terminator sequence, including
        // CRLF; regexz's end-text-or-newline follows its single newline
        // convention, so this stays on the VM.
        .input_end_final,
        .line_start,
        .line_end,
        .word,
        .non_word,
        .prev_match_end,
        => error.Unsupported,
    };
}

fn makeSet(ranges: []const model.Range) model.Set {
    var ascii: [2]u64 = .{ 0, 0 };
    var ascii_only = true;
    for (ranges) |range| {
        if (range.last >= 128) ascii_only = false;
        var codepoint = range.first;
        while (codepoint <= range.last and codepoint < 128) : (codepoint += 1) {
            const cp: u21 = @intCast(codepoint);
            ascii[cp >> 6] |= @as(u64, 1) << @intCast(cp & 63);
        }
    }
    return .{ .ranges = ranges, .ascii = ascii, .ascii_only = ascii_only };
}

test "lowering covers plain literals and classes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var offset: usize = 0;
    var parsed = try parser.parse(allocator, "needle", .{}, &offset);
    defer parsed.deinit(allocator);
    var lowered = (try lower(allocator, &parsed)) orelse return error.TestUnexpectedResult;
    defer lowered.deinit();
    try testing.expect(lowered.program.instructions.len > 0);

    var parsed_class = try parser.parse(allocator, "[0-9]{3}-[0-9]{4}", .{}, &offset);
    defer parsed_class.deinit(allocator);
    var lowered_class = (try lower(allocator, &parsed_class)) orelse
        return error.TestUnexpectedResult;
    defer lowered_class.deinit();
    try testing.expect(lowered_class.program.instructions.len > 0);
}

test "case-insensitive literals stay on the VM" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var offset: usize = 0;
    var parsed = try parser.parse(allocator, "(?i)needle", .{}, &offset);
    defer parsed.deinit(allocator);
    try testing.expect((try lower(allocator, &parsed)) == null);
}

test "lookaround lowers with context requirements" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var offset: usize = 0;
    var parsed = try parser.parse(allocator, "(?<=x)abc", .{}, &offset);
    defer parsed.deinit(allocator);
    var lowered = (try lower(allocator, &parsed)) orelse return error.TestUnexpectedResult;
    defer lowered.deinit();
    try testing.expect(lowered.needs_context);
    try testing.expect(lowered.program.extended);
}

test "captures inside lookbehind stay on the VM" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var offset: usize = 0;
    var parsed = try parser.parse(allocator, "(?<=(a|aa))b", .{}, &offset);
    defer parsed.deinit(allocator);
    try testing.expect((try lower(allocator, &parsed)) == null);

    var ahead = try parser.parse(allocator, "(?=(a))a", .{}, &offset);
    defer ahead.deinit(allocator);
    var lowered = (try lower(allocator, &ahead)) orelse return error.TestUnexpectedResult;
    defer lowered.deinit();
    try testing.expect(lowered.needs_context);
}

test "case-insensitive back references stay on the VM" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var offset: usize = 0;
    var parsed = try parser.parse(allocator, "(?i)(a)\\1", .{}, &offset);
    defer parsed.deinit(allocator);
    try testing.expect((try lower(allocator, &parsed)) == null);

    var exact = try parser.parse(allocator, "(a)\\1", .{}, &offset);
    defer exact.deinit(allocator);
    var lowered = (try lower(allocator, &exact)) orelse return error.TestUnexpectedResult;
    defer lowered.deinit();
    try testing.expect(lowered.program.extended);
}
