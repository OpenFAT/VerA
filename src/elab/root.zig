//! Elaboration: a parsed `Ast.SourceFile` → one flattened `Design` (§6.2.2),
//! plus the rule tables lowering reads too. Re-exports only; the files import
//! each other directly. It imports no `ir` file: lowering (`analog`) reads it.
//! `kernels` is a dependency so §9.13 folds use the device's rng
//! (`paramset_dist.zig`); `base` holds the rows it publishes to `Lowered`
//! (`Inserted`, `ParamOverride`, `hier_param.Kind`).
//! Cites: LRM §6 (see each file).
//!
//! Contents:
//! - `pub const elaborate`
//! - `pub const design`
//! - `pub const flatReference`
//! - `pub const unnamedGenScopes`
//! - `pub const spiceCase`
//! - `pub const genvarLoop`
//! - `pub const dist`
//! - `pub const discipline_rules`
//! - `pub const hier_param`
//! - `pub const Ctx`
//! - `pub const Design`
//! - `pub const Error`
//! - `pub const sep`

/// Elaborates `ctx.file` into the `Design` lowering walks (`elaborate.zig`).
pub const elaborate = @import("elaborate.zig").elaborate;

/// The stage's input and output types, rows and handles.
pub const design = @import("design.zig");

/// §6.7 a hierarchical expression → the flat name it denotes.
pub const flatReference = @import("flat_name.zig").flatReference;

/// §6.6.2 the flat prefixes no hierarchical name may open from outside.
pub const unnamedGenScopes = @import("flat_name.zig").unnamedGenScopes;

/// E.2.1 for a netlist card's names.
pub const spiceCase = @import("spice_case.zig").spiceCase;

/// §6.6.1 whether a loop generate scheme ends, which lowering's unroll asks.
pub const genvarLoop = @import("generate.zig").genvarLoop;

/// §9.13 Table 9-10's distributions, one row per source spelling.
pub const dist = @import("dist.zig");

/// §3.6 disciplines and natures and §3.11.1 compatibility, from the AST alone.
pub const discipline_rules = @import("discipline_rules.zig");

/// §6.3.6/§9.18 hierarchical system-parameter names (Table 9-29).
pub const hier_param = @import("hier_param.zig");

/// What `elaborate` reads from the compilation.
pub const Ctx = design.Ctx;

/// What `elaborate` returns.
pub const Design = design.Design;

/// How `elaborate` fails.
pub const Error = design.Error;

/// The §6.7 flat-name separator.
pub const sep = design.sep;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("elaborate.zig");
}
