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
        if (text.len >= 35) {
            // Reject a malformed initial scalar without crossing the
            // out-of-line scanner boundary. Reuse its validated length.
            var prefix: usize = 0;
            if (text[0] >= 0x80) {
                if (!scalar.isMultibyteLead(text[0])) return false;
                prefix = scalar.sequenceLen(text, 0);
                if (prefix == 0) return false;
            }
            return avx2.isValid(text, prefix);
        }
    }
    if (text.len < 32) {
        const prefix = scalar.asciiSpanWords(text);
        if (prefix == text.len) return true;
        const tail = text[prefix..];
        if (comptime avx2.supported) {
            if (prefix == 0 and tail.len >= 24) {
                if (!scalar.isMultibyteLead(tail[0])) return false;
                return avx2.isValidShort(tail);
            }
        }
        return scalarValid(tail);
    }
    if (text.len == 32) {
        const prefix = scalar.asciiSpan(text);
        if (prefix == text.len) return true;
        if (comptime avx2.supported) {
            if (prefix == 0) {
                if (!scalar.isMultibyteLead(text[0])) return false;
                return avx2.isValidShort(text);
            }
        }
        return scalarValid(text[prefix..]);
    }
    return vector.isValid(text);
}

test {
    _ = @import("validation/tests.zig");
}
