//! What a VPI application (`src/vpi`) asks of a running interpreter: a
//! retained expression's value, a constant select's index, an attribute's
//! value, a sequential UDP's state put, and a timing check's site (its
//! limits are `tchk.putLimits`, aliased on `Run` beside these). Free
//! functions over `*Run`, aliased on `Run` because `src/vpi` calls them as
//! methods.
//! Clauses: IEEE 1364-2005 §3.8, §15, §26.6.11, §26.6.19, §27.32;
//! VAMS §2.9, §12.30.
//!
//! Contents:
//! - `pub const VpiValue = union(enum)`
//! - `pub const Host = struct`
//! - `pub fn vpiEval(r: *Run, a: std.mem.Allocator, instance: u32, e: Ast.ExprId) Error!VpiValue`
//! - `pub fn vpiConstantIndex(r: *Run, a: std.mem.Allocator, scope: u32, e: Ast.ExprId) Error!?i64`
//! - `pub fn vpiPutUdp(r: *Run, at: u32, bit: Int.Bit) Error!void`
//! - `pub fn vpiAttributeValue(r: *Run, a: std.mem.Allocator, scope: u32, e: Ast.ExprId) Error!VpiValue`
//! - `pub fn tchkSite(r: *const Run, check: u32) struct { scope: u32, tok: u32 }`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const root = @import("root.zig");
const UserSystf = root.UserSystf;
const StmtSite = root.StmtSite;
const StmtHook = root.StmtHook;
const DoneHook = root.DoneHook;
const Run = root.Run;
const Error = root.Error;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const exec = @import("exec.zig");
const resolution = @import("resolution.zig");
const no_transition = @import("net.zig").no_transition;
const setBit = @import("net.zig").setBit;

/// A value a VPI application reads: a real's double, else the 4-state bits.
pub const VpiValue = union(enum) { bits: Int.Literal, real: f64 };

/// A VPI application's attachments to a run: its system tasks and functions,
/// the statement and `force`/`assign` callbacks it registered, and the
/// value-change and error hooks. The engine calls them; only src/vpi sets them.
pub const Host = struct {
    /// `Options.systf`.
    systf: ?UserSystf = null,
    /// Every statement's sites in compile order, outer before inner, while
    /// `Options.stmt_sites`; null otherwise.
    stmt_sites: ?std.ArrayList(StmtSite) = null,
    /// Set while a host has statement callbacks. A run recording statement
    /// sites checks it before each instruction, including after a calltf
    /// registers the first callback during a process run.
    stmt_hook: ?StmtHook = null,
    /// `DoneHook`'s statements while `Options.stmt_sites`: each one's last
    /// instruction, to the site it starts at.
    done_sites: std.AutoHashMapUnmanaged(u32, StmtSite) = .empty,
    /// The host's `DoneHook` (VPI's, set when it binds the run).
    done_hook: ?DoneHook = null,
    /// An `assign`/`force` `done_hook` will report: its process's first pc
    /// (an `override_eval`) to the statement's last pc.
    done_pending: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Called after a `.vpi`-watched slot changed value and its waiters were
    /// woken. The VPI installs it; nothing else in the engine reads it.
    change: ?*const fn (r: *Run, slot: u32) void = null,
    /// Called after a run-time error the run survives (IEEE 1364-2005
    /// §17.2.9's terminated `$readmem` load, VD-134). The VPI installs it
    /// (VAMS 12.31.4 cbError); nothing in the engine reads it.
    error_hook: ?*const fn (r: *Run) void = null,
};

/// IEEE 1364-2005 §26.6.19(e): evaluate a retained VPI expression in
/// its original scope, when its value is requested. Arguments to user
/// systfs can denote non-values (scopes, arrays, named events), so their
/// value typing is deferred until this request too. Function bodies
/// were compiled during elaboration; `checkExpr` prepares the call and
/// its operands without executing them. The result's storage is `a`'s.
/// The scope is the one `vpi_expr_scopes` recorded for (`instance`,
/// `e`), else `instance`; `scope` is restored on return.
pub fn vpiEval(r: *Run, a: std.mem.Allocator, instance: u32, e: Ast.ExprId) Error!VpiValue {
    assert(e != .none);
    const saved = r.scope;
    defer r.scope = saved;
    r.scope = r.hier.vpi_expr_scopes.get(.{ instance, @backingInt(e) }) orelse instance;
    try compile.checkExpr(r, e);
    if (compile.typeOf(r, e).real) return .{ .real = try evaluate.evalReal(r, a, e) };
    return .{ .bits = try evaluate.eval(r, a, e, 0) };
}

/// §26.6.11: a constant event select denotes the persistent declared
/// element. Canonicalizing it must never evaluate a variable index or an
/// application's function (whose value is only requested at run time).
pub fn vpiConstantIndex(r: *Run, a: std.mem.Allocator, scope: u32, e: Ast.ExprId) Error!?i64 {
    assert(scope < r.hier.scopes.items.len);
    assert(e != .none);
    const saved = r.scope;
    defer r.scope = saved;
    r.scope = scope;
    if (!compile.constantExpression(r, e)) return null;
    return switch (try vpiEval(r, a, scope, e)) {
        .bits => |v| evaluate.indexInt(v),
        .real => null,
    };
}

/// IEEE 1364-2005 §27.32 / VAMS §12.30: "Sequential UDPs shall be set to
/// the indicated value with no delay regardless of any delay on the
/// primitive instance." Driver `at` (a sequential UDP's) takes `bit` as
/// its state and output now; a transition its delay held back is
/// cancelled, and the net re-resolves.
pub fn vpiPutUdp(r: *Run, at: u32, bit: Int.Bit) Error!void {
    const d = &r.drivers[at];
    const u = d.source.udp;
    u.state = bit;
    u.started = true;
    if (d.transition != no_transition) {
        const st = &r.transitions.items[d.transition];
        if (st.in_flight) |h| try exec.cancel(r, h);
        st.in_flight = null;
    }
    setBit(d.current, u.out_bit orelse 0, bit);
    d.or_z = false;
    try resolution.resolve(r, d.net);
}

/// IEEE §3.8 / AMS §2.9: attribute values are constant expressions in
/// the decorated element's lexical scope, after parameter elaboration.
pub fn vpiAttributeValue(r: *Run, a: std.mem.Allocator, scope: u32, e: Ast.ExprId) Error!VpiValue {
    assert(scope < r.hier.scopes.items.len);
    assert(e != .none);
    const saved = r.scope;
    defer r.scope = saved;
    r.scope = scope;
    if (!compile.attributeConstantExpression(r, e)) return r.exprFail(e, "§3.8: an attribute value must be a constant expression");
    const folding = r.folding_constant;
    r.folding_constant = true;
    defer r.folding_constant = folding;
    return vpiEval(r, a, scope, e);
}

/// The instance scope and command token of timing check `check` (a
/// `Run.checks.hook` argument), which a host's object for it carries.
pub fn tchkSite(r: *const Run, check: u32) struct { scope: u32, tok: u32 } {
    const c = r.checks.rows.items[check];
    return .{ .scope = c.scope, .tok = c.tok };
}
