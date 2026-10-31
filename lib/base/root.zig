//! `base`: the leaf types and tables every tier may import; it imports only
//! std. Re-exports only: each file below holds one transformation.
//!
//! Cites: nothing of its own (each file names its clauses).
//!
//! Contents:
//! - `pub const deep_stack`, the namespace that runs a recursive walk on a
//!   stack reserved for its depth (`run`, `runGuarded`, `exhausted`)
//! - `pub const StrId`, `pub const StringInterner`, the §2.7/§2.8 intern table
//! - `pub const BigArena`, the compilation's arena
//! - `pub const ExprId`, `pub const Type`, `pub const Direction`, the AST
//!   handle and scalar enums that outlive the parse
//! - `pub const Region`, `pub const Timescale`, the positional directive events
//! - `pub const Inserted`, `pub const DisciplineResolution`,
//!   `pub const ParamOverride`, `pub const SystemParam`, the rows elaboration
//!   publishes

/// Runs a recursive walk on a stack reserved for its nesting depth, so
/// nesting is bounded by memory. Every stage that recurses over source
/// nesting (the parser, lowering, the digital engine) shares it.
pub const deep_stack = @import("deep_stack.zig");
/// Handle into a `StringInterner` (`Ast.StrId`, `Mir.StrId`).
pub const StrId = @import("interner.zig").StrId;
/// Identifier and string intern table, ids in insertion order
/// (`SourceFile.strings`, `Mir.strings`).
pub const StringInterner = @import("interner.zig").StringInterner;
/// The compilation arena (`vera.CompileResult.arena`), large blocks passed
/// through to the backing allocator.
pub const BigArena = @import("BigArena.zig");

/// Handle into the AST's expression columns (`Ast.ExprId`).
pub const ExprId = @import("syntax.zig").ExprId;
/// §3.1 scalar data types (`Ast.Type`).
pub const Type = @import("syntax.zig").Type;
/// §6.5.2.2 port and argument direction (`Ast.Direction`).
pub const Direction = @import("syntax.zig").Direction;

/// A positional directive event list's row type, `Region(T)`
/// (`Preprocessor.Region`).
pub const Region = @import("directive.zig").Region;
/// A `timescale's two operands, in seconds (`Preprocessor.Timescale`).
pub const Timescale = @import("directive.zig").Timescale;

/// §7.8.4 one port re-pointed at a connect module (`Elaborate.Inserted`).
pub const Inserted = @import("design.zig").Inserted;
/// §7.4.4 basic or detail discipline resolution (`Elaborate.DisciplineResolution`).
pub const DisciplineResolution = @import("design.zig").DisciplineResolution;
/// §3.4 a `--param name=value` override (`Elaborate.ParamOverride`).
pub const ParamOverride = @import("design.zig").ParamOverride;
/// §9.18 one Table 9-29 hierarchical system parameter (`hier_param.Kind`).
pub const SystemParam = @import("design.zig").SystemParam;

test {
    _ = deep_stack;
    _ = @import("interner.zig");
    _ = BigArena;
    _ = @import("syntax.zig");
    _ = @import("directive.zig");
    _ = @import("design.zig");
}
