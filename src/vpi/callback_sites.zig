//! The cbStmt and cbDisable sites: a statement or module handle -> the
//! (engine pc, statement row) pairs its registration fires at; and the
//! engine's statement hook, rebuilt from the live cbStmt registrations.
//! Cites: IEEE 1364-2005 §27.33.1.1 Table 27-6, §27.33.1.3; VAMS-2023 §12.34.
//!
//! Contents:
//! - `pub fn sites(obj: abi.vpiHandle) ?[]const Site`
//! - `pub fn sizeHooks(r: *const digital.Run) error{OutOfMemory}!void`
//! - `pub fn rehook() void`
//! - `pub fn resetHooks() void`

const std = @import("std");
const digital = @import("sim").digital;
const gpa = std.heap.smp_allocator;
const abi = @import("abi.zig");
const callback = @import("callback.zig");
const callback_fire = @import("callback_fire.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const ObjId = schema.ObjId;
const Site = callback.Site;

/// The pcs a live cbStmt fires at, which the engine checks (`StmtHook`).
var hooked: std.bit_set.Dynamic = .{};

/// `obj`'s sites: a statement's own, or every statement's of a module
/// instance. Null, with the error recorded, for anything else; the caller
/// owns the slice (`gpa`). Asserts that each site is one of the attached
/// run's and names a row of the model.
pub fn sites(obj: abi.vpiHandle) ?[]const Site {
    const o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", "vpi_register_cb: cbStmt needs a statement or module handle in obj", .{});
        return null;
    };
    const one = o.stmt != .none and o.vtype != user.vpiNullStmt;
    if (!one and o.kind != .module) {
        status.fail("NOTSTMT", "vpi_register_cb: `{s}` is neither a statement Table 27-6 lists nor a module", .{o.full});
        return null;
    }
    const r = run.attached() orelse {
        status.fail("NOENGINE", "vpi_register_cb: no digital run executes statements", .{});
        return null;
    };
    const engine_sites = r.host.stmt_sites orelse {
        status.fail("NOSITES", "vpi_register_cb: this run records no statement sites", .{});
        return null;
    };
    const d = &session.design.?;
    const scope = if (one) o.owner.get().? else o.scope;
    std.debug.assert(scope < d.scopes.len);
    // The statement objects this registration covers, by AST statement.
    var covered: std.AutoHashMapUnmanaged(@import("frontend").Ast.StmtId, ObjId) = .empty;
    defer covered.deinit(gpa);
    if (one) {
        covered.put(gpa, o.stmt, d.idOf(o)) catch return oomSites();
    } else for (d.objects, 0..) |s, i| {
        if (s.kind != .code or s.owner.get() != scope or s.stmt == .none or s.vtype == user.vpiNullStmt) continue;
        covered.put(gpa, s.stmt, .at(i)) catch return oomSites();
    }
    var out: std.ArrayList(Site) = .empty;
    const eng = d.scopes[scope].engine;
    for (engine_sites.items) |st| {
        if (st.scope != eng) continue;
        const at = covered.get(st.stmt) orelse continue;
        std.debug.assert(st.pc < r.program.code.items.len);
        out.append(gpa, .{ .pc = st.pc, .obj = at }) catch {
            out.deinit(gpa);
            return oomSites();
        };
    }
    std.debug.assert(out.items.len <= engine_sites.items.len);
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return oomSites();
    };
}

/// Sizes `hooked` to `r`'s program, before `r` is attached
/// (`session.openDigital`), so `rehook` never allocates: `vpi_remove_cb` has
/// no failure to report but a bad handle (§12.34). Asserts that no run is
/// attached yet.
pub fn sizeHooks(r: *const digital.Run) error{OutOfMemory}!void {
    std.debug.assert(run.attached() == null);
    try hooked.resize(gpa, r.program.code.items.len, false);
    std.debug.assert(hooked.bit_length == r.program.code.items.len);
}

/// Rebuilds `hooked` from the live cbStmt callbacks, and installs the hook
/// on the engine while any is live. Asserts that `sizeHooks` sized it to the
/// attached program, whose length a reset keeps (it elaborates the same
/// source again), and that the hook is installed exactly when a pc is set.
pub fn rehook() void {
    const r = run.attached() orelse return;
    std.debug.assert(hooked.bit_length == r.program.code.items.len);
    hooked.unsetAll();
    for (callback.cbs.items) |cb| {
        if (cb.dead or cb.reason != user.cbStmt) continue;
        for (cb.sites) |st| hooked.set(st.pc);
    }
    r.host.stmt_hook = if (hooked.findFirstSet() != null) .{ .at = &hooked, .fire = callback_fire.fireStmt } else null;
    std.debug.assert((r.host.stmt_hook != null) == (hooked.findFirstSet() != null));
}

/// Frees `hooked`, with the registry it was sized for (`callback.reset`).
/// Asserts that no registration is left to fire.
pub fn resetHooks() void {
    std.debug.assert(callback.cbs.items.len == 0);
    hooked.deinit(gpa);
    hooked = .{};
    std.debug.assert(hooked.bit_length == 0);
}

// ---- private ----

/// `sites`' out-of-memory refusal. Asserts that it is recorded.
fn oomSites() ?[]const Site {
    std.debug.assert(session.design != null);
    status.fail("NOMEM", "vpi_register_cb: out of memory", .{});
    std.debug.assert(status.vpi_chk_error(null) == user.vpiError);
    return null;
}
