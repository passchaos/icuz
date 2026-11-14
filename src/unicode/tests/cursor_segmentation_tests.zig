//! Minimal source root for native fragmented-cursor segmentation verification.

test {
    _ = @import("../scalar/cursor.zig");
    _ = @import("../word/cursor.zig");
    _ = @import("../sentence/cursor.zig");
}
