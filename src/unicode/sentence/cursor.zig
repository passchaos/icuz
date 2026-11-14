//! Forward-only Unicode 17 sentence segmentation over an immutable scalar cursor.

const scalar_cursor = @import("../scalar/cursor.zig");
const rules = @import("rules.zig");
const Segment = @import("iterator.zig").Segment;

/// Two forward-only cursors retain SB8 lookahead without source materialization.
/// Cached decision intervals survive returned segments, bounding total scalar
/// reads by twice the input length. No allocation or arbitrary reset is needed.
pub fn SentenceCursorIterator(comptime Cursor: type) type {
    return struct {
        const Self = @This();
        const Reader = scalar_cursor.Reader(Cursor);
        pub const Error = Reader.Error;

        main: Reader,
        lookahead: Reader,
        failure: ?Error = null,
        pending: ?scalar_cursor.Scalar = null,
        lower_scan_end: usize = 0,
        lower_scan_result: bool = false,
        lookahead_eof: bool = false,

        pub fn init(cursor: Cursor) Error!Self {
            const main = try Reader.init(cursor);
            return .{ .main = main, .lookahead = try main.fork() };
        }

        pub fn next(self: *Self) Error!?Segment {
            if (self.failure) |err| return err;
            return self.advance() catch |err| {
                self.failure = err;
                return err;
            };
        }

        fn advance(self: *Self) Error!?Segment {
            const first = self.pending orelse (try self.main.next() orelse return null);
            self.pending = null;
            var state = rules.BoundaryState{};
            state.consume(rules.classForCodepoint(first.codepoint));
            var end = first.byte_end;
            while (try self.main.next()) |current| {
                const class = rules.classForCodepoint(current.codepoint);
                if (try self.breaksAt(current.byte_start, class, state)) {
                    self.pending = current;
                    break;
                }
                state.consume(class);
                end = current.byte_end;
            }
            return .{ .byte_start = first.byte_start, .byte_len = end - first.byte_start };
        }

        fn breaksAt(self: *Self, offset: usize, current: rules.Class, state: rules.BoundaryState) Error!bool {
            if (rules.immediateBreak(current, state)) |decision| return decision;
            const lower_follows = if (state.terminator) |terminator|
                terminator.class == .a_term and try self.lowerFollows(offset)
            else
                false;
            return rules.contextualBreak(current, state, lower_follows);
        }

        fn lowerFollows(self: *Self, offset: usize) Error!bool {
            if (offset <= self.lower_scan_end) return self.lower_scan_result;
            if (self.lookahead_eof) return false;
            while (try self.lookahead.next()) |scalar| {
                if (scalar.byte_start < offset) continue;
                const class = rules.classForCodepoint(scalar.codepoint);
                if (class == .lower or class == .other_letter or class == .upper or rules.isParagraphSeparator(class)) {
                    self.lower_scan_end = scalar.byte_start;
                    self.lower_scan_result = class == .lower;
                    return self.lower_scan_result;
                }
            }
            self.lower_scan_end = self.lookahead.domain_end;
            self.lower_scan_result = false;
            self.lookahead_eof = true;
            return false;
        }
    };
}

test {
    _ = @import("cursor_tests.zig");
}
