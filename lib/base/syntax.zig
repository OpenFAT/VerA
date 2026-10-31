//! The AST handle and scalar enums that outlive the parse: the frontend's
//! `Ast` aliases them, and `Lowered` carries them (a parameter's type, a
//! port's direction, the expression a D2A event term is keyed by) without
//! importing the frontend. Declarations only: nothing here transforms data.
//!
//! Cites: VAMS-2023 §3.1, §3.2, §3.3, §3.4.1, §4.7.2.3, §6.5.2.2, A.1.3,
//! A.1.4, A.2.1.1, annex A.8.
//!
//! Contents:
//! - `pub const ExprId = enum(u32) { none = maxInt(u32), _ }`
//! - `pub const Type = enum(u8) { real, integer, string, unspecified }`
//! - `pub const Direction = enum(u8) { unspecified, input, output, inout }`

const std = @import("std");
const assert = std.debug.assert;

/// Handle into the AST's expression columns (annex A.8's expression grammar).
/// `.none` is the absent expression (no default, no index).
pub const ExprId = enum(u32) { none = std.math.maxInt(u32), _ };

/// A scalar data type (§3.1, §3.2, §3.3, §3.4.1). `realtime` collapses to
/// `.real` and `time` to `.integer` (A.2.1.1 parameter_type): the analog
/// kernel draws no distinction. `.unspecified` is `parameter p = <expr>;`
/// with no type keyword, whose type §3.4.1 derives from the default
/// expression; lowering resolves it, so codegen never sees it.
pub const Type = enum(u8) { real, integer, string, unspecified };

/// A port's or a function argument's direction (§6.5.2.2 ports, §4.7.2.3
/// function `output`/`inout` arguments). `.unspecified` is a port named in
/// `list_of_ports` whose direction arrives later in a `port_declaration`
/// (A.1.3, A.1.4).
pub const Direction = enum(u8) { unspecified, input, output, inout };

comptime {
    // Every AST and `Lowered` row that holds one of these is sized by them.
    assert(@sizeOf(ExprId) == 4);
    assert(@sizeOf(Type) == 1);
    assert(@sizeOf(Direction) == 1);
}
