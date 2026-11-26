//! UTF-8 validation with scalar short-input checks and vector windows.
//!
//! The vector path checks continuation placement, overlong sequences,
//! surrogate encodings, and the U+10FFFF limit. It carries continuation masks
//! between windows and never loads outside the supplied slice.

const scalar = @import("validation/scalar.zig");
const vector = @import("validation/vector.zig");
const avx2 = @import("validation/avx2.zig");

pub const asciiOnly = scalar.asciiOnly;
pub const scalarValid = scalar.scalarValid;
pub fn isValid(text: []const u8) bool {
    if (comptime avx2.supported) {
        if (text.len >= 128) return avx2.isValid(text);
    }
    return vector.isValid(text);
}

test {
    _ = @import("validation/tests.zig");
}
