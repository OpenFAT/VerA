//! IR: the SSA MIR and the tables lowering hands every later stage, as types
//! and their column functions. Re-exports only; the files import each other
//! directly. Lowering is `analog`'s and the passes over the MIR are `prove`'s:
//! both import this module, so it imports neither. It imports no frontend or
//! elaboration module either: the AST types `Lowered` carries are `base`'s,
//! and the AST itself stays with `vera.CompileResult`. `kernels` holds the
//! value folds it reads.
//!
//! Cites: §4.5, §5.10.3, §9.15, §9.17 (through the files it re-exports).
//!
//! Contents:
//! - `pub const Mir`, `pub const op`, `pub const Lowered`, `pub const simparam`, `pub const names`

/// SSA instruction set every stage after lowering reads.
pub const Mir = @import("Mir.zig");
/// §4.5 / §5.10.3 / §9.17 the stateful operator set, `OpKind`.
pub const op = @import("op.zig");
/// What lowering hands every later stage, and the row types of its tables.
pub const Lowered = @import("Lowered.zig");
/// §9.15 simulation parameters: where each name's value comes from.
pub const simparam = @import("simparam.zig");
/// Stable emitted names, the canonical unit order, and the one speller of
/// each field name two stages share (`__1b`, `__w<k>`, `__xz`, `__held__`).
pub const names = @import("names.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
