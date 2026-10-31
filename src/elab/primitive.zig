//! Annex E primitives: an instance of a Table E.1 primitive and its
//! attributes → E.3.2.1's `port_discipline` judged and read, and a
//! primitive's `V`/`I` respelled as the access functions of the discipline
//! its net resolved to (E.3.2).
//! Cites: LRM §2.9, E.3.2, E.3.2.1.
//!
//! Contents:
//! - `pub fn checkPortDiscipline(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance) design.Error!void`
//! - `pub fn portDisciplineAttr(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance, conn: Ast.PortConn) ?Ast.StrId`
//! - `pub fn primitiveAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId) Ast.StrId`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const constfold = @import("frontend").constfold;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const lookup = @import("lookup.zig");
const fold = @import("fold.zig");
const discipline = @import("discipline_rules.zig");

/// Checks every E.3.2.1 `port_discipline` attribute on `inst` (E0358).
/// "The value shall be of type string and the
/// value must be a valid discipline of domain continuous. This attribute
/// shall only apply to analog primitives or the ports of analog primitives;
/// for other modules as well as the ports of all other modules it shall be
/// ignored." So it is judged here, on an instance `isPrimitive` answered
/// yes for, and nowhere else.
///
/// `module.attrs` holds every attr_spec of the instantiating module without
/// its target (`Parser.skipAttributes`), so the target is recovered from the
/// token stream: the first token after the attribute-instance run an
/// attr_spec sits in is the item it decorates, and that item is this
/// instantiation (its module identifier, with no `;` before the instance
/// name) or one of its port connections.
pub fn checkPortDiscipline(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance) design.Error!void {
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.ctx.file.str(a.name), "port_discipline")) continue;
        if (!decorates(self, decoratedTok(self, a.main_tok), inst)) continue;
        // §2.9: a valueless attr_spec has the value 1, which is not a string.
        const c = if (a.value == .none)
            constfold.Const{ .int = 1 }
        else
            // Not constant: lowering's E0357 (§2.9) owns that answer.
            constfold.fold(self.ctx.file, a.value, fold.ParamEnv{ .self = self, .local = true }) orelse continue;
        const want = switch (c) {
            .str => |sv| sv,
            else => {
                try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline requires a string naming a continuous discipline", .{});
                continue;
            },
        };
        const d = discipline.declOf(self.ctx.file, self.ctx.file.strings.find(want) orelse .none) orelse {
            try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline names an undeclared discipline `{s}`", .{want});
            continue;
        };
        if (discipline.domainOf(d) != .continuous)
            try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline requires a continuous discipline; `{s}` is not one", .{want});
    }
}

/// E.3.2's first source for one port of a primitive instance: the
/// `port_discipline` on its connection, else the one on the instance ("It
/// shall only apply to either the analog primitive itself or the port to which
/// it is attached"; E.3.2.1's `motor1` example overrides the instance's per
/// port). Null when neither carries a valid one; `checkPortDiscipline`
/// reports an invalid one.
pub fn portDisciplineAttr(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance, conn: Ast.PortConn) ?Ast.StrId {
    var on_inst: ?Ast.StrId = null;
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.ctx.file.str(a.name), "port_discipline")) continue;
        const t = decoratedTok(self, a.main_tok);
        if (!decorates(self, t, inst)) continue;
        if (a.value == .none) continue;
        const c = constfold.fold(self.ctx.file, a.value, fold.ParamEnv{ .self = self, .local = true }) orelse continue;
        if (c != .str) continue;
        const name = self.ctx.file.strings.find(c.str) orelse continue;
        const d = discipline.declOf(self.ctx.file, name) orelse continue;
        if (discipline.domainOf(d) != .continuous) continue;
        if (t == conn.main_tok) return name;
        for (inst.ports) |p| {
            if (p.main_tok == t) break;
        } else on_inst = name;
    }
    return on_inst;
}

/// Returns the access function a shipped primitive's `V` or `I` means on the
/// net its port was connected to (E.3.2).
///
/// Table E.1's Behavior column writes V and I for every row, but E.3.2 lets a
/// primitive "be used in any design, including mixed disciplines" (E.3.2.1's
/// `vcvs` with a `rotational_omega` control pair). So V is the port pair's
/// potential and I its flow, spelled with the §3.6.1.2 access function of the
/// discipline the net resolved to. The discipline is read from the net,
/// where `walkInstances` binds E.3.2's three sources in order.
///
/// Limits: an unconnected primitive port carrying the attribute keeps the
/// prelude's `electrical`, and a primitive cloned before a later level
/// resolves its net keeps V/I. Applies to prelude bodies only
/// (`Unit.primitive`); a user module's `V` means V.
pub fn primitiveAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId) Ast.StrId {
    const which: Ast.PotentialOrFlow = blk: {
        const a_ = self.ctx.file.str(access);
        if (std.mem.eql(u8, a_, "V")) break :blk .potential;
        if (std.mem.eql(u8, a_, "I")) break :blk .flow;
        return access; // not one of the table's two spellings
    };
    const name = lookup.netRefName(self, net) orelse return access;
    const disc = self.res.disc_of.get(name) orelse .none;
    if (disc == .none) return access; // §3.6.5 implicit, or resolved later
    return discipline.accessOf(self.ctx.file, disc, which) orelse access;
}

// ---- private ----

/// The first token after the run of `(* ... *)` instances that token `t`
/// (an attr_name) is inside. §2.9 forbids nesting, so the first `*)` closes.
fn decoratedTok(self: *Flatten, t: u32) u32 {
    const n: u32 = @intCast(self.ctx.tok_starts.len);
    var i = t;
    while (i < n) {
        while (i < n and !std.mem.eql(u8, tokText(self, i), "*)")) i += 1;
        i += 1;
        if (i >= n or !std.mem.eql(u8, tokText(self, i), "(*")) return i;
    }
    return i;
}

/// Is token `t` the start of `inst`'s instantiation or of one of its port
/// connections? A.4.1 attaches `{ attribute_instance }` to both.
fn decorates(self: *Flatten, t: u32, inst: *const Ast.Instance) bool {
    for (inst.ports) |c| if (c.main_tok == t) return true;
    if (t >= inst.main_tok or !std.mem.eql(u8, tokText(self, t), self.ctx.file.str(inst.module))) return false;
    // `resistor r1(a, b), r2(c, d);` shares one attribute list; a `;` between
    // means `t` began an earlier statement.
    var i = t + 1;
    while (i < inst.main_tok) : (i += 1) if (std.mem.eql(u8, tokText(self, i), ";")) return false;
    return true;
}

/// The source text of token `t`.
fn tokText(self: *Flatten, t: u32) []const u8 {
    const sp = Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, t);
    return self.ctx.src[sp.start..sp.end];
}
