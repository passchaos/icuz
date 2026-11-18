//! icuz — Unicode Character Database and UAX algorithms for Zig.
//!
//! The public surface is intentionally organized by Unicode algorithm family.
//! Data is embedded and versioned; consumers should use the namespaces below
//! rather than importing generated tables directly.

pub const unicode_version = [3]u8{ 17, 0, 0 };

/// Standard Unicode aggregate. This is the compatibility entry point for
/// consumers that want the historical flat surface.
pub const unicode = @import("unicode/root.zig");

pub const properties = @import("unicode/properties.zig");
pub const normalization = @import("unicode/normalization/root.zig");
pub const case = @import("unicode/case/root.zig");
pub const name = @import("unicode/name.zig");
pub const set = @import("unicode/set.zig");
pub const utf16 = @import("unicode/utf16.zig");
pub const collation = @import("unicode/collation/root.zig");
pub const idna = @import("unicode/idna.zig");
pub const plural = @import("unicode/format/plurals.zig");
pub const number = @import("unicode/format/number.zig");
pub const date = @import("unicode/format/dates.zig");
pub const message = @import("unicode/format/message.zig");
pub const list = @import("unicode/format/list.zig");
pub const relative = @import("unicode/format/relative.zig");
pub const units = @import("unicode/format/units.zig");
pub const charset = @import("unicode/charset.zig");
pub const transliterate = @import("unicode/transliterate.zig");
pub const bidi = @import("unicode/bidi/paragraph.zig");
pub const script = @import("unicode/script/root.zig");
pub const script_extensions = @import("unicode/script_extensions/root.zig");
pub const joining = @import("unicode/joining.zig");
pub const vertical = @import("unicode/vertical/root.zig");
pub const mark = @import("unicode/mark/root.zig");
pub const scalar = @import("unicode/scalar/root.zig");
pub const scalar_cursor = @import("unicode/scalar/cursor.zig");
pub const grapheme = @import("unicode/grapheme/iterator.zig");
pub const word = @import("unicode/word/iterator.zig");
pub const word_cursor = @import("unicode/word/cursor.zig");
pub const sentence = @import("unicode/sentence/iterator.zig");
pub const sentence_cursor = @import("unicode/sentence/cursor.zig");
pub const line_break = @import("unicode/line_break/root.zig");

pub const canonical = struct {
    pub const combining_class = @import("unicode/canonical/combining_class.zig");
    pub const decomposition = @import("unicode/canonical/decomposition.zig");
};

test {
    _ = unicode;
    _ = @import("unicode/tests/cursor_segmentation_tests.zig");
}
