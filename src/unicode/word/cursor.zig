//! Forward-only Unicode 17 word segmentation over an immutable scalar cursor.

const scalar_cursor = @import("../scalar/cursor.zig");
const rules = @import("rules.zig");
const Segment = @import("iterator.zig").Segment;

/// Cursor follows the contract documented by `text.segmentation.Scalar`.
/// Main traversal and significant lookahead each read a scalar at most once.
/// The iterator allocates nothing and returns borrowed-source offsets by value.
pub fn WordCursorIterator(comptime Cursor: type) type {
    return struct {
        const Self = @This();
        const Reader = scalar_cursor.Reader(Cursor);
        pub const Error = Reader.Error;

        main: Reader,
        lookahead: Reader,
        failure: ?Error = null,
        pending: ?scalar_cursor.Scalar = null,
        next_significant: ?scalar_cursor.Scalar = null,
        lookahead_eof: bool = false,
        previous_actual: rules.Properties = rules.properties(0),
        last_significant: ?rules.Class = null,
        previous_significant: rules.Class = .other,
        regional_indicator_odd: bool = false,

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
            const first_properties = rules.properties(first.codepoint);
            self.consume(first_properties);
            var is_word = first_properties.word_anchor;
            var end = first.byte_end;
            while (try self.main.next()) |current| {
                const current_properties = rules.properties(current.codepoint);
                if (try self.breaksAt(current, current_properties)) {
                    self.pending = current;
                    break;
                }
                self.consume(current_properties);
                is_word = is_word or current_properties.word_anchor;
                end = current.byte_end;
            }
            return .{ .byte_start = first.byte_start, .byte_len = end - first.byte_start, .is_word = is_word };
        }

        fn consume(self: *Self, properties: rules.Properties) void {
            self.previous_actual = properties;
            if (rules.isIgnored(properties.class)) return;
            self.previous_significant = self.last_significant orelse .other;
            self.last_significant = properties.class;
            self.regional_indicator_odd = if (properties.class == .regional_indicator)
                !self.regional_indicator_odd
            else
                false;
        }

        fn breaksAt(self: *Self, scalar: scalar_cursor.Scalar, current: rules.Properties) Error!bool {
            if (rules.adjacentBreak(self.previous_actual, current)) |decision| return decision;
            const previous = self.last_significant orelse return true;
            const next_class = if (rules.needsLookahead(previous, current.class))
                try self.nextSignificant(scalar.byte_end)
            else
                rules.Class.other;
            return rules.significantBreak(previous, self.previous_significant, current.class, next_class, self.regional_indicator_odd);
        }

        fn nextSignificant(self: *Self, offset: usize) Error!rules.Class {
            if (self.next_significant) |cached| {
                if (cached.byte_start >= offset) return rules.properties(cached.codepoint).class;
                self.next_significant = null;
            }
            if (self.lookahead_eof) return .other;
            while (try self.lookahead.next()) |scalar| {
                if (scalar.byte_start < offset) continue;
                const class = rules.properties(scalar.codepoint).class;
                if (rules.isIgnored(class)) continue;
                self.next_significant = scalar;
                return class;
            }
            self.lookahead_eof = true;
            return .other;
        }
    };
}

test {
    _ = @import("cursor_tests.zig");
}
