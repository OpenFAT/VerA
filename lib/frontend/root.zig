//! The frontend's public API: Verilog-AMS source text in, AST out
//! (preprocessor, lexer, parser; LRM clauses 2 to 10 and annexes D and E).
//! Depends on `base`, `diag` and `kernels`; `elab`, `analog` and the backends
//! import this layer, never the reverse (`ir` does not import it at all).

/// §2.6.1 integer literals and the IEEE 1364-2005 §5 four-state operations
/// on them: `kernels.Integer`, re-exported for callers that reach it
/// through `frontend`.
pub const Integer = @import("kernels").Integer;
const compat = @import("compat.zig");
/// Token tags and the per-tag facts (token.zig). The old merged namespace
/// with keyword.zig's names, until pass 2 points it at token.zig.
pub const token = compat.token;
/// The annex B keyword table and the §10.6 reserved-word sets.
pub const keyword = @import("keyword.zig");
/// Preprocessed text in, `{tag, start}` token rows out.
pub const lexer = @import("lexer.zig");
/// Token text in, §2.6.2 reals and §2.7 strings out.
pub const token_value = @import("token_value.zig");
/// The old preprocessor namespace (compat.zig), until pass 2.
pub const Preprocessor = compat.Preprocessor;
/// Clause 10 directives and comment stripping: source files in, one text out.
pub const preprocessor = @import("preprocessor.zig");
/// The positional directive events `preprocessor.Output.directives` holds.
pub const directive_events = @import("pp/events.zig");
/// The annex D/E prelude, preprocessed, lexed and parsed once per process.
pub const prelude = @import("pp/prelude.zig");
/// IEEE 1364-2005 §28 decryption envelopes and the key file.
pub const protect = @import("pp/protect.zig");
/// Annex D.1 and D.2 as embedded text.
pub const annex_d = @import("pp/annex_d.zig");
/// Annex E Table E.1's SPICE primitives as modules, and annex D.3.
pub const annex_e = @import("pp/annex_e.zig");
/// The preprocessor's scan state (a struct file), for the tests that drive a
/// step without `process`.
pub const Pp = @import("pp/Pp.zig");
/// The main scan and the byte scans every preprocessor file shares.
pub const pp_scan = @import("pp/scan.zig");
/// §2.4 comment stripping.
pub const pp_comments = @import("pp/comments.zig");
/// Directive dispatch and the directive table.
pub const pp_directive = @import("pp/directive.zig");
/// The old lexer namespace (compat.zig): use `lexer` and `token_value`.
pub const Lexer = compat.Lexer;
/// The AST; `Ast.SourceFile` is the root every later stage reads.
pub const Ast = @import("ast.zig");
/// The parser file; its state type is `Parser.Parser`.
pub const Parser = @import("parser.zig");

/// The §4.2 constant_expression folder every stage shares.
pub const constfold = @import("constfold.zig");

/// SPICE `.MODEL`/`.SUBCKT` card synthesis (annex E.2). The pipeline reaches
/// it through `Preprocessor`; exported so a caller can synthesize without
/// running the preprocessor.
pub const spice_cards = @import("spice_cards.zig");

/// §3.7/§6.5.3 structural `wreal` rules, shared by the elaborator and the
/// digital runner.
pub const wreal = @import("wreal.zig");

/// IEEE 1364-2005 §13.2 library map files.
pub const libmap = @import("libmap.zig");

/// Runs a recursive walk on a stack reserved for its nesting depth, so
/// nesting is bounded by memory: `base.deep_stack`, re-exported for callers
/// that reach it through `frontend`.
pub const deep_stack = @import("base").deep_stack;

test {
    @import("std").testing.refAllDecls(@This());
}
