//! Annex A.1.2 module_declaration and A.1.4 module_item (LRM §6.2, Clause 3):
//! tokens from `module`, `macromodule` or `connectmodule` to `endmodule` in,
//! one `Ast.ModuleDecl` out. The items accumulate in a `Body` (one list per
//! kind, in source order) that becomes the declaration's slices at
//! `endmodule`; a generate block collects its own `Body` the same way
//! (`generate.zig`). Each item is dispatched to the file that owns its grammar.
//!
//! LRM clauses cited: §2.9, §3.4, §3.5, §3.7, §3.12, §4.7, §5.2, §5.10.4,
//! §6.2, §6.3, §6.3.1, §6.5, §6.6, §7.6, §10.6.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_generate = @import("generate.zig");
const parse_inst = @import("inst.zig");
const parse_specify = @import("specify.zig");
const parse_function = @import("function.zig");
const parse_hier = @import("hier.zig");
const parse_net = @import("net.zig");
const parse_stmt = @import("stmt.zig");
const parse_udp = @import("udp.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Accumulators for one module body. Arena-owned; each list's `.items`
/// becomes a `ModuleDecl` slice, in source order.
pub const Body = struct {
    /// Append with `addPort`, which keeps `port_index`.
    ports: std.ArrayList(Ast.Port) = .empty,
    /// The first `ports` index of each port name: a body declaration finds
    /// its header port in O(1) (`parse_net.findPort`), not by a scan that
    /// made a module's port declarations quadratic in its ports.
    port_index: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty,
    /// The header is A.1.3's `list_of_port_declarations`, whose ports "shall
    /// not be redeclared within the body of the module" (§6.2).
    ansi: bool = false,
    params: std.ArrayList(Ast.ParamDecl) = .empty,
    aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
    vars: std.ArrayList(Ast.VarDecl) = .empty,
    nets: std.ArrayList(Ast.NetDecl) = .empty,
    branches: std.ArrayList(Ast.BranchDecl) = .empty,
    instances: std.ArrayList(Ast.Instance) = .empty, // §6.2.2
    defparams: std.ArrayList(Ast.Defparam) = .empty, // §6.3.1
    genvars: std.ArrayList(Ast.StrId) = .empty,
    events: std.ArrayList(Ast.EventDecl) = .empty, // §5.10.4
    functions: std.ArrayList(Ast.FuncDecl) = .empty,
    analog: std.ArrayList(Ast.AnalogBlock) = .empty,
    discrete: std.ArrayList(Ast.DiscreteBlock) = .empty, // A.6.2, §7.2.2
    assigns: std.ArrayList(Ast.ContAssign) = .empty, // A.6.1
    gates: std.ArrayList(Ast.GateInst) = .empty, // A.3.1
    pulls: std.ArrayList(Ast.PullInst) = .empty, // A.3.1, §7.8
    tasks: std.ArrayList(Ast.Subroutine) = .empty, // IEEE 1364-2005 §10
    switches: std.ArrayList(Ast.SwitchInst) = .empty, // A.3.1, §7.6
    paths: std.ArrayList(Ast.SpecPath) = .empty, // A.7.2
    timing_checks: std.ArrayList(Ast.TimingCheck) = .empty, // A.7.5
    /// §6.6.1/§6.6.2 every named generate block of the module, with the
    /// generate construct it belongs to. Not part of `ModuleDecl`: nothing
    /// downstream reaches a generate scope by name (§6.6.3 hierarchical
    /// names are unimplemented), so only `checkGenBlockNames` reads it.
    gen_blocks: std.ArrayList(GenBlock) = .empty,
    /// A.4.2 every loop generate's index variable, checked to be a genvar
    /// at the end of the module, when every `genvar` declaration (hoisted
    /// out of nested blocks) is in `genvars`.
    gen_loops: std.ArrayList(GenBlock) = .empty,
    /// §6.6.3 "Each generate construct in a given scope is assigned a number.
    /// The number is 1 for the construct that appears textually first in that
    /// scope and increases by 1 for each subsequent construct." This scope's
    /// count so far; a generate block's own `Body` starts again at zero.
    gen_count: u32 = 0,
    /// The unnamed generate blocks of this scope still waiting for their
    /// `genblk<n>`: the clash rule needs every declaration of the scope, and a
    /// declaration may follow the construct (`parse_generate.nameGenBlocks`).
    gen_auto: std.ArrayList(GenAuto) = .empty,
};

/// One unnamed generate block and the number of its construct.
const GenAuto = struct { stmt: Ast.StmtId, n: u32 };

/// One `begin : name` from the `generate_block` production, whose name
/// declares a scope rather than a §5.3.2 statement label. Collected here
/// because no later stage can tell the two `begin`s apart.
const GenBlock = struct {
    name: Ast.StrId,
    tok: u32,
    /// `Parser.gen_construct` at the time: the outermost enclosing
    /// construct, so two arms of one `if`/`case` share it.
    construct: u32,
};

comptime {
    // Rows of `Body.gen_auto` / `.gen_blocks` / `.gen_loops`: u32 handles only.
    std.debug.assert(@sizeOf(GenAuto) == 8);
    std.debug.assert(@sizeOf(GenBlock) == 12);
}

// -----------------------------------------------------------------------
// A.1.2 module_declaration, LRM §6.2
// -----------------------------------------------------------------------

/// Parses one `module`, `macromodule` or `connectmodule` through `endmodule`
/// (LRM §6.2): the header's parameter port list and ports (§6.5), then the
/// module items.
///
/// Takes every attribute in `self.attrs`, including those collected before
/// the `module` keyword, and clears the list.
pub fn parseModule(self: *Parser) Error!Ast.ModuleDecl {
    const main_tok = self.pos;
    const is_connect = self.peek() == .kw_connectmodule;
    self.pos += 1; // 'module' | 'macromodule' | 'connectmodule'
    const name = try self.expectIdent();

    const saved_connect = self.in_connect_module;
    self.in_connect_module = is_connect;
    defer self.in_connect_module = saved_connect;

    var b: Body = .{};
    // A.1.3 `module_parameter_port_list ::= # ( parameter_declaration
    // { , parameter_declaration } )`. §6.2: "The optional list of parameter
    // definitions shall specify an ordered list of the parameters for the
    // module." A header parameter is an ordinary §3.4 parameter, so it goes
    // into the append-only `b.params` ahead of the body's, in source order.
    //
    // `parseParamDecl` already consumes the commas inside one declaration
    // (`parameter real a = 1, b = 2`) and A.1.3 separates declarations with
    // the same comma, so keep reading while `parameter` or `localparam`
    // follows the comma the inner loop stopped at.
    if (self.peek() == .hash) {
        self.pos += 1;
        _ = try self.expect(.lparen);
        const first = self.pos;
        var local: ?u32 = null;
        while (self.peek() == .kw_parameter or self.peek() == .kw_localparam) {
            if (self.peek() == .kw_localparam and local == null) local = self.pos;
            try parse_decl.parseParamDecl(self, &b.params);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
        if (local) |tok| return self.failAt(tok, .E0246, "a module parameter header requires `parameter`, not `localparam`", .{});
        if (b.params.items.len == 0) return self.failAt(first, .E0246, "an empty module parameter header has no parameter declaration", .{});
    }
    const header_params = b.params.items.len;
    if (self.peek() == .lparen) try parsePortList(self, &b);
    _ = try self.expect(.semicolon);
    try parseModuleItems(self, &b, .kw_endmodule);
    _ = try self.expect(.kw_endmodule);
    try parse_specify.checkPaths(self, &b);
    // IEEE 1364-2005 §4.10.1, inherited by §1.1: "If any param_assignments
    // appear in a module_parameter_port_list, then any param_assignments that
    // appear in the module become local parameters and shall not be
    // overridden by any method." §3.4.5's localparam is exactly that.
    if (header_params != 0) for (b.params.items[header_params..]) |*p| {
        p.is_local = true;
    };
    // IEEE 1364-2005 §12.3.3: one declaration covers every port reference
    // to its name (`(a, a)`, `(a[7:4], a[3:0])`), which the body folded
    // into the first.
    for (b.ports.items, 0..) |*p, i| {
        const first = b.port_index.get(p.name).?;
        if (first == i) continue;
        const q = b.ports.items[first];
        p.direction = q.direction;
        p.discipline = q.discipline;
        p.range = q.range;
        p.type_range = q.type_range;
        p.kind = q.kind;
        p.is_signed = q.is_signed;
    }
    try parse_generate.checkGenBlockNames(self, &b);
    try parse_generate.nameGenBlocks(self, &b);
    const attrs = try self.arena.dupe(Ast.NatureAttr, self.attrs.items);
    self.attrs.clearRetainingCapacity();

    return .{
        .name = name,
        .main_tok = main_tok,
        .ports = b.ports.items,
        .params = b.params.items,
        .aliasparams = b.aliasparams.items,
        .vars = b.vars.items,
        .nets = b.nets.items,
        .branches = b.branches.items,
        .instances = b.instances.items,
        .defparams = b.defparams.items,
        .genvars = b.genvars.items,
        .events = b.events.items,
        .functions = b.functions.items,
        .analog = b.analog.items,
        .discrete = b.discrete.items,
        .assigns = b.assigns.items,
        .gates = b.gates.items,
        .pulls = b.pulls.items,
        .tasks = b.tasks.items,
        .switches = b.switches.items,
        .paths = b.paths.items,
        .timing_checks = b.timing_checks.items,
        // §2.9: every attr_spec seen since the last module. Attributes
        // before the `module` keyword (Syntax 2-7 puts a slot there) were
        // collected by `parseSourceFile` and belong to this module too, which is
        // why the list is cleared at the end and not at the start.
        .attrs = attrs,
        .is_connect = is_connect,
    };
}

/// Parses A.1.3 list_of_ports or list_of_port_declarations (§6.5) into
/// `b.ports`. Both styles fall out of one loop: a direction keyword starts a
/// new declaration whose direction, discipline and range stick to the
/// following comma-separated names.
///
/// A.1.3 `port_expression ::= port_reference | { port_reference
/// { , port_reference } }` (§6.5.1: a port may be "a vector net formed as a
/// result of the concatenation operator") appends one `Ast.Port` per
/// port_reference.
fn parsePortList(self: *Parser, b: *Body) Error!void {
    _ = try self.expect(.lparen);
    if (self.eat(.rparen)) return;
    var dir: Ast.Direction = .unspecified;
    var disc: Ast.StrId = .none;
    var range: ?Ast.Dim = null;
    var signed = false;
    var var_storage: ?@FieldType(Ast.VarDecl, "storage") = null;
    // A list_of_ports entry has been read: the list is not A.1.3's
    // list_of_port_declarations, so no port_declaration may follow.
    var plain = false;
    var attr_tok: ?u32 = null;
    while (true) {
        try self.skipAttributes();
        if (parse_net.portDirection(self.peek())) |d| {
            attr_tok = self.pos;
            if (plain) return self.failAt(self.pos, .E0207, "found {s}: a port_declaration cannot follow a list_of_ports port (A.1.3)", .{self.found(self.pos)});
            dir = d;
            b.ansi = true;
            self.pos += 1;
            var kind: Ast.NetKind = .wire;
            disc = try parse_net.optPortType(self, &kind, &signed);
            // IEEE 1364-2005 §12.3.4: "The same syntax for input, inout, and
            // output declarations is used in the module header", so
            // A.2.1.2's variable arms (`output reg q`) are legal here too.
            var_storage = try parse_net.optVarStorage(self, dir);
            if (var_storage != null) signed = self.eat(.kw_signed);
            // A.1.3 `inout [ range ] port_identifier {, port_identifier}`:
            // the range belongs to the declaration (§6.5.2
            // "electrical [3:0] a, b" declares two 4-bit ports).
            range = try parse_decl.optDim(self);
        }
        // A.1.3 `port ::= [ port_expression ]`: an empty port_expression is a
        // null port, a header position nothing inside connects to (§6.5.1:
        // "The port expression is optional").
        if (dir == .unspecified and (self.peek() == .comma or self.peek() == .rparen)) {
            try addPort(self, b, .{ .name = try nullPortName(self, b), .main_tok = self.pos });
            plain = true;
            if (!self.eat(.comma)) break;
            continue;
        }
        // A.1.3 `port ::= [ port_expression ] | . port_identifier (
        // [ port_expression ] )`. The second alternative gives the port an
        // external name distinct from the internal nets it connects to, and
        // with no port_expression (`.a()`) it connects to none of them.
        var external: Ast.StrId = .none;
        var close_named = false;
        if (self.eat(.dot)) {
            const tok = self.pos;
            external = try self.expectIdent();
            _ = try self.expect(.lparen);
            close_named = true;
            if (dir == .unspecified and self.eat(.rparen)) {
                try addPort(self, b, .{ .name = try nullPortName(self, b), .external_name = external, .main_tok = tok });
                plain = true;
                if (!self.eat(.comma)) break;
                continue;
            }
        }
        // ponytail: a concatenated port becomes N terminals, not one N-bit
        // terminal, the same model §3.6.3 vector ports get (`electrical
        // [1:0] p` is two terminals). The consecutive entries carry the
        // external port's width and member order.
        const concat = self.eat(.lbrace);
        const first = b.ports.items.len;
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            if (attr_tok) |decl| try self.copyAttributes(decl, tok);
            if (var_storage) |storage| try parse_net.varPort(self, b, storage, name, range, signed, tok);
            // A.1.3 `port_reference ::= port_identifier [ [
            // constant_range_expression ] ]`, the list-of-ports form only.
            var select: ?Ast.Dim = null;
            if (self.digital and !b.ansi and self.eat(.lbracket)) {
                const msb = try parse_expr.parseExpr(self);
                const lsb = if (self.eat(.colon)) try parse_expr.parseExpr(self) else msb;
                _ = try self.expect(.rbracket);
                select = .{ .msb = msb, .lsb = lsb };
            }
            try addPort(self, b, .{
                .name = name,
                .direction = dir,
                .discipline = disc,
                .range = range,
                .external_name = external,
                .concat_rest = b.ports.items.len != first,
                .is_signed = signed,
                .select = select,
                .main_tok = tok,
            });
            if (!concat or !self.eat(.comma)) break;
        }
        if (concat) _ = try self.expect(.rbrace);
        if (close_named) _ = try self.expect(.rparen);
        if (dir == .unspecified) plain = true;
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rparen);
}

/// Appends `p` to `b.ports` and, if its name is new, to `b.port_index`.
/// On OOM neither table grows.
pub fn addPort(self: *Parser, b: *Body, p: Ast.Port) error{OutOfMemory}!void {
    try b.ports.ensureUnusedCapacity(self.arena, 1);
    const slot = try b.port_index.getOrPut(self.arena, p.name);
    if (!slot.found_existing) slot.value_ptr.* = @intCast(b.ports.items.len);
    b.ports.appendAssumeCapacity(p);
}

/// The internal name of a null port, the next `b.ports` entry. A digital
/// parse leaves it `.none`, which `sim/digital/elab.zig` skips. The analog
/// pipeline keys every port by name and keeps it as a terminal (the host
/// binds terminals by position), so it gets a name no source text can
/// spell: an escaped identifier ends at white space, and a tab is no `.`
/// that `internTok` turns into a space. Nothing inside refers to it, so a
/// parent's actual reaches no node of the child, and on the top-level device
/// the terminal touches nothing.
fn nullPortName(self: *Parser, b: *const Body) Error!Ast.StrId {
    if (self.digital) return .none;
    return self.file.intern(self.arena, try self.arena.print("\tnull{d}", .{b.ports.items.len + 1}));
}

// -----------------------------------------------------------------------
// A.1.4 module_item, LRM §6.2 and Clause 3
// -----------------------------------------------------------------------

/// Parses module items into `b` until `end`, `endmodule` or end of file,
/// recovering at the next statement after each failed item.
fn parseModuleItems(self: *Parser, b: *Body, end: token.Tag) Error!void {
    // An item, or `recoverStatement`'s one token at least.
    var before: u32 = undefined;
    while (true) : (std.debug.assert(self.pos > before)) {
        const attr_at = self.pos;
        try self.skipAttributes();
        const t = self.peek();
        if (t == end or t == .eof or t == .kw_endmodule) return self.attributesEnd(attr_at);
        before = self.pos;
        parseModuleItem(self, b) catch |e| {
            if (e == error.OutOfMemory) return e;
            self.recoverStatement(before);
        };
    }
}

/// Parses one A.1.4 module_item into `b`. A token that begins no item is
/// E0240.
pub fn parseModuleItem(self: *Parser, b: *Body) Error!void {
    const tok = self.pos;
    const tag = self.peek();
    const outer_item = self.item_tok;
    self.item_tok = tok;
    defer self.item_tok = outer_item;
    // The lengths, not a copy of `b`: an item only appends to these lists.
    var before: [attributed_lists.len]usize = undefined;
    inline for (attributed_lists, 0..) |field, i| before[i] = @field(b.*, field).items.len;
    try parseModuleItemBody(self, b);
    if (tag == .kw_generate) return; // the region's items own their own prefixes
    // §2.9 Example 5: a declaration's prefix belongs to every item in its
    // list, including comma-separated instances and continuous assignments.
    inline for (attributed_lists, 0..) |field, i| {
        for (@field(b.*, field).items[before[i]..]) |item| try self.copyAttributes(tok, item.main_tok);
    }
}

/// The `Body` lists whose rows a module item's §2.9 attribute prefix reaches.
const attributed_lists = .{ "ports", "params", "vars", "nets", "instances", "defparams", "events", "functions", "analog", "discrete", "assigns", "gates", "pulls", "tasks", "switches", "paths", "timing_checks" };

fn parseModuleItemBody(self: *Parser, b: *Body) Error!void {
    // Under a 1364 language a keyword the §10.6 set frees, followed by a name
    // or a `#`, is a name opening an instance or a declaration (IEEE 1364-2005
    // annex B reserves no Verilog-AMS word, so `connect u(a, b);` instantiates
    // `connect`). Under Verilog-AMS the construct wins: §10.6's own example
    // keeps `analog I(sin, n) <+ ...` under "1364-2005".
    const freed = @backingInt(self.language) < @backingInt(token.KeywordSet.vams_2_3) and
        token.isKeyword(self.peek()) and self.identLike(self.pos) and
        (self.identLike(self.pos + 1) or self.peekAt(1) == .hash);
    if (!freed) try self.refuseAms();
    if (self.verilog_a) if (self.digitalItem()) |w| try self.refuseDigital(self.pos, w);
    switch (if (freed) .identifier else self.peek()) {
        // §10.6: "can only be specified outside of a design element".
        .dir_begin_keywords, .dir_end_keywords => return self.failAt(
            self.pos,
            .E0202,
            "{s} inside a module",
            .{token.Tag.lexeme(self.peek()).?},
        ),
        // IEEE 1364 §19.6: "It shall be illegal for the `resetall directive
        // to be specified within a module or UDP declaration."
        .dir_resetall => return self.failAt(self.pos, .E0236, "", .{}),
        // IEEE 1364 §19.2 `default_nettype "can be used only outside of module
        // definitions"; §19.9's pair "shall be specified ... outside of the
        // module declarations".
        .dir_outside_module => return self.failAt(self.pos, .E0202, "`{s} inside a module", .{self.tokenText(self.pos)[1..]}),
        // A.4.2 loop_generate_construct / conditional_generate_construct.
        // §6.6: "Use of generate regions is optional. There is no semantic
        // difference in the module when a generate region is used", and the
        // clause's rcline2 example writes a bare `for` at module scope, so
        // these are not gated on having seen `generate`. Syntax 6-8 makes
        // the body a generate_block of module items, not statements, so
        // they do not go through `parseStmt`.
        .kw_for => try parse_generate.parseGenerate(self, b, .kw_for),
        .kw_if => try parse_generate.parseGenerate(self, b, .kw_if),
        // Syntax 6-8 case_generate_construct, like `for` and `if` above: a
        // statement is no module item, so a `case` here is a generate
        // construct inside a generate region or not (IEEE 1364-2005 A.1.4).
        .kw_case => try parse_generate.parseGenerate(self, b, .kw_case),
        // Not an item: a generate_block is only ever the body of the two
        // above (E0221). Kept as its own arm so the diagnostic can cite
        // Syntax 6-8 rather than blaming the analog subset.
        .kw_begin => return self.failAt(self.pos, .E0221, "found {s}", .{self.found(self.pos)}),
        // §3.4 parameter / localparam (A.2.1.1)
        .kw_parameter, .kw_localparam => {
            // §6.6: a generate block "may not contain port declarations,
            // parameter declarations, specify blocks, or specparam
            // declarations", and Syntax 6-8's `module_or_generate_item`
            // admits `local_parameter_declaration` only. `localparam` is
            // therefore not gated: it carries no override the elaborator
            // would need before the block exists (§6.3).
            if (self.gen_depth > 0 and self.peek() == .kw_parameter)
                return self.failAt(self.pos, .E0229, "", .{});
            try parse_decl.parseParamDecl(self, &b.params);
            _ = try self.expect(.semicolon);
        },
        // §6.3.1 parameter_override (A.1.4). `defparam
        // list_of_defparam_assignments ;`, each assignment a hierarchical
        // parameter identifier and a constant expression.
        //
        // Nothing is resolved here: the path names a parameter of an
        // instance, which does not exist until elaboration, and §6.3.1's
        // "shall be a constant expression" is over the declaring module's
        // parameters. `elab/elaborate.zig` checks both, and reports a path
        // that names nothing (E0907).
        .kw_defparam => {
            self.pos += 1;
            while (true) {
                const tok = self.pos;
                // `true`: A.9.3 admits `u[0].g`, the parameter of one
                // element of an instance array, a flat name elaboration
                // mints.
                var indices: std.ArrayList(Ast.ExprId) = .empty;
                const path = try parse_hier.parseDottedPath(self, true, if (self.digital) &indices else null);
                _ = try self.expect(.assign_eq);
                // A.2.4 `defparam_assignment ::= hierarchical_parameter_identifier
                // = constant_mintypmax_expression`.
                const value = try parse_expr.parseMinTypMax(self);
                try b.defparams.append(self.arena, .{
                    .path = path,
                    .value = value,
                    .indices = indices.items,
                    .main_tok = tok,
                });
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        },
        // §3.4.6 aliasparam (A.2.1.1)
        .kw_aliasparam => try b.aliasparams.append(self.arena, try parse_decl.parseAliasparam(self)),
        // §3.2/§3.3 variable declarations (A.2.1.3)
        .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
            try parse_decl.parseVarDecl(self, &b.vars);
            _ = try self.expect(.semicolon);
        },
        // §3.5 genvar (A.4.2)
        .kw_genvar => {
            self.pos += 1;
            while (true) {
                try b.genvars.append(self.arena, try self.expectIdent());
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        },
        // A.2.1.3 `event_declaration ::= event list_of_event_identifiers ;`
        // (§5.10.4). Named events are part of the Verilog-A subset: §5.10
        // lists them as one of the three kinds of analog event, and annex
        // C.7 excludes only digital behavior and events.
        .kw_event => {
            self.pos += 1;
            while (true) {
                try b.events.append(self.arena, try parse_decl.parseEventDecl(self));
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        },
        // §3.12 branch declaration (A.2.1.3)
        .kw_branch => try parse_net.parseBranchDecl(self, b),
        // §3.6.4 ground declaration (A.2.1.3 net_declaration)
        .kw_ground => {
            self.pos += 1;
            const disc = try parse_net.optDiscipline(self);
            try parse_net.parseNetNames(self, b, disc, .wire, true, .{}, false);
        },
        // §6.5.2 non-ANSI port declarations. §6.6: a generate block "may
        // not contain port declarations", and a region holds only
        // module_or_generate_items, which have none (E0229, as `parameter`).
        .kw_input, .kw_output, .kw_inout => {
            if (self.gen_depth > 0) return self.failAt(self.pos, .E0229, "a port declaration", .{});
            try parse_net.parsePortDecl(self, b);
        },
        // A.2.1.3 net_declaration with an explicit net type
        .kw_wire,
        .kw_tri,
        .kw_tri0,
        .kw_tri1,
        .kw_triand,
        .kw_trior,
        .kw_trireg,
        .kw_wand,
        .kw_wor,
        .kw_uwire,
        .kw_supply0,
        .kw_supply1,
        => {
            const kind = parse_net.netKind(self.peek()).?;
            self.pos += 1;
            // A.2.1.3 puts an optional bracket right after the net type:
            // `charge_strength` on the `trireg` arms (§3.8 default
            // `medium`), `drive_strength` on the
            // list_of_net_decl_assignments arms. A.2.2.2's drive strengths
            // are all pairs and A.2.2.1's charge strengths one word, so a
            // comma after the first strength word tells them apart.
            // Anything else goes to `parseChargeStrength`, whose
            // diagnostics say what went wrong.
            //
            // IEEE 1364-2005 §7.10: "the strengths default to strong1 and
            // strong0", so no bracket reads the same as
            // `(strong1, strong0)` and needs no flag.
            var st: Ast.NetStrength = .{};
            if (self.peek() == .lparen) {
                if (parse_net.strengthWord(self, self.pos + 1) != null and self.peekAt(2) == .comma) {
                    try parse_net.parseDriveStrength(self, &st.strength0, &st.strength1);
                    st.drive = true;
                } else st.charge = try parse_net.parseChargeStrength(self, kind);
            }
            // IEEE 1364-2005 §4.3.2's advisory `vectored | scalared`, which
            // Syntax 4-1 admits only in the alternatives that carry a range.
            const advisory = self.pos;
            const advised = self.eat(.kw_scalared) or self.eat(.kw_vectored);
            // A.2.1.3's net_declaration names one net_type. `optPortType`
            // reads a port declaration's `[ net_type | wreal ]` after the
            // discipline, which this arm has already consumed.
            const after_disc = self.pos + @intFromBool(self.peek() == .identifier and self.identLike(self.pos + 1));
            if (parse_net.netKind(self.tags[after_disc]) != null or self.reservedIs(after_disc, "wreal"))
                return self.failAt(after_disc, .E0207, "found {s}: A.2.1.3's net_declaration names one net_type", .{self.found(after_disc)});
            var signed = false;
            var ignored: Ast.NetKind = .wire;
            const disc = try parse_net.optPortType(self, &ignored, &signed);
            if (advised and self.peek() != .lbracket)
                return self.failAt(advisory, .E0207, "§4.3.2: scalared and vectored are only legal on a vector net, which declares a range", .{});
            try parse_net.parseNetNames(self, b, disc, kind, false, st, signed);
        },
        // A.6.1 `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
        // list_of_net_assignments ;`, a module item of every module (A.1.4).
        // Whether the net it drives can be executed is lowering's question
        // (`Lower.checkDiscreteContext`), not the grammar's.
        .kw_assign => {
            self.pos += 1;
            // A.8.5 `net_lvalue` begins with an identifier or a `{`, never a
            // `(`, so the parenthesis is unambiguously A.2.2.2's.
            var s0: Ast.Strength = .strong;
            var s1: Ast.Strength = .strong;
            if (self.peek() == .lparen) try parse_net.parseDriveStrength(self, &s0, &s1);
            const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_net.parseDelay3(self) else .{};
            while (true) {
                const tok = self.pos;
                const target = try parse_expr.parseExpr(self);
                _ = try self.expect(.assign_eq);
                const value = try parse_expr.parseExpr(self);
                try b.assigns.append(self.arena, .{ .target = target, .value = value, .strength0 = s0, .strength1 = s1, .delay = delay, .main_tok = tok });
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        },
        .kw_reg => {
            const first = b.vars.items.len;
            try parse_decl.parseRegDecl(self, &b.vars);
            // A `reg` that names a header port declares that port's
            // discipline, as a net declaration does (`parseNetNames`).
            for (b.vars.items[first..]) |v| if (v.discipline != .none) if (parse_net.findPort(b, v.name)) |p| {
                if (p.discipline == .none) p.discipline = v.discipline;
            };
        },
        // A.3.1 `gate_instantiation ::= … | pass_switchtype
        // pass_switch_instance { , pass_switch_instance } ;`: the two
        // A.3.4 switch spellings with tags of their own. The other eight
        // reach `parseSwitch` through the `.kw_reserved` arm below.
        .kw_tran, .kw_rtran => try parse_inst.parseSwitch(self, b),
        // A.3.1 `gate_instantiation`: the twelve A.3.4 gate types that
        // compute a logic value.
        .kw_and, .kw_nand, .kw_or, .kw_nor, .kw_xor, .kw_xnor, .kw_buf, .kw_not, .kw_bufif0, .kw_bufif1, .kw_notif0, .kw_notif1 => try parse_inst.parseGates(self, b),
        // A.6.2 `initial_construct` / `always_construct`, §7.2.2's discrete
        // context.
        .kw_initial, .kw_always => try parse_inst.parseDiscrete(self, b),
        // §5.2 analog construct / §4.7.1 analog function
        .kw_analog => try parseAnalog(self, b),
        // §4.7: "Each function can be an analog user-defined function or a
        // digital function (as defined in IEEE Std 1364 Verilog)." So a bare
        // `function` is a legal module item in any module; what §7.3.7
        // forbids is the call from the analog context, which `lowerUserCall`
        // refuses (E0436).
        //
        // A digital parse reads the 1364 declaration itself (packed ranges,
        // `automatic`, `reg` formals), which the analog function grammar
        // cannot carry.
        .kw_function => if (self.digital) try parse_function.parseSubroutine(self, b, true) else try parse_function.parseFuncDecl(self, b, self.pos, false),
        // A.4.2 generate_region, transparent per §6.6's "there is no
        // semantic difference": the items inside are plain module items and
        // the region introduces no scope. §6.6: "Generate regions do not
        // nest, and they may only occur directly within a module".
        // `gen_depth` counts construct bodies too, so a `generate` inside an
        // if-generate's block is refused by the same test (E0228).
        .kw_generate => {
            // Reported, then parsed anyway: the region has no scope, so
            // reading the inner one as if the keywords were absent is exact
            // recovery and keeps the stray `endgenerate` from becoming a
            // second error.
            if (self.gen_depth > 0) try self.report(self.pos, .E0228, "", .{});
            self.pos += 1;
            self.gen_depth += 1;
            defer self.gen_depth -= 1;
            // `generate generate ...` nests as deep as the input, each one a
            // native level that reaches no `enter`: `descend` counts it and
            // moves to a fresh stack segment when this one is full.
            try self.descend(parseModuleItems, .{ self, b, @as(token.Tag, .kw_endgenerate) });
            _ = try self.expect(.kw_endgenerate);
        },
        // A.2.1.3 `discipline_identifier list_of_net_identifiers ;`
        // vs A.4.1 module_instantiation: both start with an identifier.
        .identifier, .escaped_identifier => {
            // A `#` can only be a parameter_value_assignment, and
            // `identifier identifier` followed by `(` or `[` can only be a
            // module_instance: A.2.1.3's net declaration puts its optional
            // range before the name list (`electrical [0:3] bus;`, which is
            // the `lbracket` case one line below), never after it, so no net
            // declaration reaches a `[` in that position.
            //
            // `#` followed by anything but `(` is A.5.4's `delay2` (`#5`),
            // which A.4.1's `parameter_value_assignment ::= # ( … )` never is.
            if ((self.peekAt(1) == .hash and self.peekAt(2) == .lparen) or
                (self.identLike(self.pos + 1) and
                    (self.peekAt(2) == .lparen or self.peekAt(2) == .lbracket)))
                return parse_inst.parseInstantiation(self, b);
            if (self.peekAt(1) == .hash) return parse_udp.parseUdpInst(self, b);
            // A.5.4 `udp_instantiation`, whose `udp_instance` makes
            // `name_of_udp_instance` optional where A.4.1's `module_instance
            // ::= name_of_module_instance ( … )` does not. So an identifier
            // followed directly by `(` derives from A.5.4 and from nothing
            // else at module scope, and one token settles it.
            if (self.peekAt(1) == .lparen) return parse_udp.parseUdpInst(self, b);
            // `discipline [range] names ;`. A range after the name is
            // refused by the name list ("expected identifier").
            // A.2.1.3's `hierarchical_net_identifier` may open with `$root.`
            // (A.9.3), an Annex F.2.1 out-of-context declaration.
            const rooted = self.peekAt(1) == .system_identifier and self.peekAt(2) == .dot and
                std.mem.eql(u8, self.tokenText(self.pos + 1), "$root");
            if (!self.identLike(self.pos + 1) and self.peekAt(1) != .lbracket and !rooted) {
                return parse_inst.notAModuleItem(self);
            }
            const disc = try self.internTok(self.pos);
            self.pos += 1;
            try parse_net.parseNetNames(self, b, disc, .wire, false, .{}, false);
        },
        // Annex B reserves 1364 spellings that have no tag of their own:
        // `specify`, `specparam`, `primitive`, `pulldown` and the rest all
        // lex to `.kw_reserved`, which keeps them unusable as identifiers.
        // The spelling is therefore the dispatch.
        .kw_reserved => {
            const w = self.tokenText(self.pos);
            // §6.6: a generate block "may not contain ... specify blocks, or
            // specparam declarations" (E0229). The block is reported and then
            // parsed in full, so its own mistakes are still found and the
            // `endspecify` is not left to resynchronize on; the paths it
            // records die with the generate block's `Body`.
            if (std.mem.eql(u8, w, "specify")) {
                if (self.gen_depth > 0) try self.report(self.pos, .E0229, "a specify block", .{});
                return parse_specify.parseSpecifyBlock(self, b);
            }
            // A.2.1.1 `specparam_declaration ::= specparam [ range ]
            // list_of_specparam_assignments ;`, reached both as a module
            // item (Syntax 6-1's `non_port_module_item`) and as an A.7.1
            // `specify_item`. This is the module-item half.
            if (std.mem.eql(u8, w, "specparam")) {
                if (self.gen_depth > 0) return self.failAt(self.pos, .E0229, "a specparam declaration", .{});
                return parse_specify.parseSpecparamDecl(self, &b.params);
            }
            // A.2.7 `task_declaration`, IEEE 1364-2005 §10.2: a module item
            // of every module (A.1.4), enabled only from §7.2.2's discrete
            // context (A.6.4 has no analog `task_enable`), so its body is
            // parsed with that context's statement forms. The mixed-signal
            // kernel runs it; the analog compile only reads what it writes.
            if (std.mem.eql(u8, w, "task")) {
                const saved = self.in_discrete;
                self.in_discrete = true;
                defer self.in_discrete = saved;
                return parse_function.parseSubroutine(self, b, false);
            }
            // A.3.1's last two arms. They have no tags of their own because
            // A.3.2 gives them a strength set no other gate takes.
            if (std.mem.eql(u8, w, "pulldown") or std.mem.eql(u8, w, "pullup"))
                return parse_inst.parsePullGate(self, b);
            // A.3.1's cmos/mos/pass-enable switch arms: A.3.4's eight
            // remaining `*_switchtype` spellings.
            if (parse_inst.switch_arms.has(w)) return parse_inst.parseSwitch(self, b);
            // A.2.1.3's two `wreal` arms: §3.7's real net, which the annex
            // gives arms of its own rather than a `net_type`.
            if (std.mem.eql(u8, w, "wreal")) return parse_net.parseWrealDecl(self, b);
            return parse_inst.unsupportedItem(self);
        },
        // §6.2.2: module definitions do not nest. Reported where it stands
        // (E0240), then the nested definition is skipped whole, so its
        // `endmodule` does not close the module around it and leave that
        // one's own `endmodule` as a stray top-level token (E0201).
        .kw_module, .kw_macromodule, .kw_connectmodule => {
            try self.report(self.pos, .E0240, "found {s}", .{self.found(self.pos)});
            var depth: u32 = 0;
            while (true) : (self.pos += 1) switch (self.peek()) {
                .eof => return,
                .kw_module, .kw_macromodule, .kw_connectmodule => depth += 1,
                .kw_endmodule => {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        return;
                    }
                },
                else => {}, // else: every other token is inside the nested definition
            };
        },
        else => return parse_inst.notAModuleItem(self), // else: begins no A.1.4 module_item: E0240
    }
}

/// Parses an A.6.2 `analog [initial]` construct into `b.analog`, or an
/// `analog function` declaration into `b.functions`. Cursor on `analog`.
fn parseAnalog(self: *Parser, b: *Body) Error!void {
    const main_tok = self.pos;
    self.pos += 1; // 'analog'
    if (self.peek() == .kw_function) return parse_function.parseFuncDecl(self, b, main_tok, true);
    // §5.2.1 `analog initial analog_function_statement`
    const is_initial = self.eat(.kw_initial);
    const saved = self.analog_expr;
    self.analog_expr = true;
    defer self.analog_expr = saved;
    const body = try parse_stmt.parseStmtNoNull(self); // A.6.2 takes one analog_statement
    try b.analog.append(self.arena, .{
        .is_initial = is_initial,
        .body = body,
        .main_tok = main_tok,
    });
}
