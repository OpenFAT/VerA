//! A.6.2 the digital `initial` block: its constant assignments in, the
//! value each variable starts every evaluation with out (`Lower.initial_state`),
//! applied at the variable's declaration.
//!
//! Cites: A.2.2.1, §3.2.2, A.6.2, A.6.3, §6.8, §7.2.2, §9.2.
//!
//! Contents:
//! - `pub fn collectInitialState(self: *Lower, module: *const Ast.ModuleDecl) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_sysfunc_context = @import("sysfunc_context.zig");
const Oom = Lower.Oom;

/// Collects a non-mixed module's A.6.2 `initial` blocks as constant initial
/// values.
///
/// The one shape accepted is a body of assignments of constant expressions to
/// module variables. §7.2.2 gives such a target to the discrete context and
/// forbids the continuous one to assign it (E0432), so the block runs once
/// before the analysis and the constant is the variable's value throughout.
/// This records the expression and `lowerModule` installs it as the variable's
/// initial value, where an A.2.2.1 declaration assignment lands.
///
/// Every other body made the module mixed (`isMixed`, `constantShape`) and
/// runs on the kernel. E0433 is what is left: a body `constantShape` admits
/// whose value `constEval` still cannot fold.
pub fn collectInitialState(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    // A mixed module's `initial` blocks run on the kernel, with the rest of
    // its digital half: their writes are discrete inputs, not constants.
    if (self.out.mixed_signal) return;
    for (module.discrete) |blk| {
        // `always` is refused at the keyword (E0205, parser): it re-runs on an
        // event, so it has no constant reading to collect. Reporting its body
        // here as well would be a second diagnostic for one decision.
        if (blk.is_always) continue;
        try collectInitialStmt(self, blk.body);
    }
}

// ---- private ----

fn collectInitialStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    assert(id == .none or @backingInt(id) < self.stmtCount());
    if (id == .none) return;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .empty => {},
        // A.6.3 `seq_block` — transparent. Its own local declarations are not:
        // a name declared inside the block is not the module variable the
        // continuous context reads, so there is nothing to install.
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0)
                try self.err(self.file.stmtTok(id), .E0433, "a local declaration inside an initial block", .{});
            for (b.body) |s| try collectInitialStmt(self, s);
        },
        .assign => |a| {
            const tok = self.file.stmtTok(id);
            if (a.target == .none or ex.tag(a.target) != .ident) {
                // §3.2.2 `bus[i] = …`: the element is representable, but which
                // element is a question about a value, and the arrays this ever
                // applies to are the ones a digital kernel would drive.
                try self.err(tok, .E0433, "the assignment target is not a plain variable name", .{});
                return;
            }
            const name = self.file.str(ex.strOf(a.target));
            if (lower_constfold.constEval(self, a.value) == null) {
                var b = self.errWith(tok, .E0433);
                b.msg("`{s}` is assigned a value that is not constant", .{name});
                b.note(
                    "an initial block runs once, before the analysis, so a value it computes " ++
                        "from anything the analysis produces does not exist yet",
                    .{},
                );
                try b.emit();
                return;
            }
            // Last assignment wins — the body is sequential, so a later one
            // overwrites an earlier one, and both overwrite an A.2.2.1
            // declaration assignment (which happens at elaboration, before this
            // block runs).
            try self.initial_state.put(self.arena, name, .{ .value = a.value, .tok = tok });
        },
        // An analog-only task is §9.2's E0821 (`scanContext`), which names the
        // rule; E0433 on top would blame the initial-block model instead.
        .sys_task => |s| if (!lower_sysfunc_context.isAnalogOnlySysFunc(self.file.str(s.name))) try self.err(
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
        else => try self.err( // else: E0433 names every other statement; a new one is refused, not dropped
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
    }
}

test "collectInitialState: A.6.2 a constant initial installs its value; an undeclared target is E0313" {
    // A body that is not the constant shape is `isMixed`'s (its test, #57).
    const cases = [_]struct { decls: []const u8, want: ?diag.Code }{
        .{ .decls = "  real x;\n  initial x = 2.0;", .want = null },
        // §6.8: a name the module never declared.
        .{ .decls = "  initial zz = 1.0;", .want = .E0313 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(c.decls, "", c.want);
}
