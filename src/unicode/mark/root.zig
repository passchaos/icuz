//! Unicode mark property lookups.

const general_category = @import("../properties/general_category.zig");

/// Generated General_Category=Mn ranges. Kept public for consumers that want
/// the standalone table; `isNonspacing` uses the O(1) property page table.
pub const nonspacing = @import("nonspacing.zig");

/// Return whether Unicode assigns General_Category=Nonspacing_Mark (Mn).
pub fn isNonspacing(codepoint: u21) bool {
    return general_category.category(codepoint) == .Mn;
}

test {
    _ = nonspacing;
}
