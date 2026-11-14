//! UAX #14 line-break properties and iterator.

pub const iterator = @import("iterator.zig");
pub const properties = @import("properties.zig");

pub const unicode_version = iterator.unicode_version;
pub const BreakClass = iterator.BreakClass;
pub const BreakKind = iterator.BreakKind;
pub const Break = iterator.Break;
pub const Error = iterator.Error;
pub const Iterator = iterator.Iterator;

pub const breaks = iterator.breaks;
pub const breaksAssumeValid = iterator.breaksAssumeValid;
pub const classForCodepoint = iterator.classForCodepoint;

pub const lookup = properties.lookup;
pub const GeneralCategory = properties.GeneralCategory;
pub const Properties = properties.Properties;
