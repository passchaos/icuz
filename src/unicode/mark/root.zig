//! Unicode mark property lookups.
//!
//! `nonspacing.zig` is generated from General_Category=Nonspacing_Mark (Mn).

pub const nonspacing = @import("nonspacing.zig");
pub const isNonspacing = nonspacing.contains;
