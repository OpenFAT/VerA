//! Subroutines: annex A.2.6 analog_function_declaration (§4.7.1) and IEEE
//! 1364-2005 A.2.6/A.2.7 digital function and task declarations (§10.2,
//! §10.4) -> `Ast.FuncDecl` rows of `Body.functions` and `Ast.Subroutine`
//! rows of `Body.tasks`. The body statements go through `stmt.zig`.
//!
//! LRM clauses cited: §4.7, §4.7.1, §4.7.2.3; IEEE 1364-2005 §10.2, §10.2.1,
//! §10.4.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_module = @import("module.zig");
const parse_net = @import("net.zig");
const parse_stmt = @import("stmt.zig");
const parse_expr = @import("expr.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.2.6 analog_function_declaration: LRM §4.7.1
// -----------------------------------------------------------------------

/// LRM §4.7.1: `analog function [type] name ; items stmt endfunction`, cursor
/// on `function`. Argument types come from a matching variable declaration
/// (`input x; real x;`, A.2.6); a type on the direction (`input real x;`) is
/// E0291, and a `;` among the items E0219. Reports E0224 for no formals and
/// E0225 for an untyped one, then carries on.
///
/// A function without `analog` (an analog parse's digital function, §4.7)
/// takes A.2.6's `function_declaration` header and A.2.7's `tf_*_declaration`
/// formals, as `parseSubroutine` reads them: `automatic`, `[ signed ]
/// [ range ]`, `realtime`, `time`, `reg` formals, and an untyped formal, which
/// A.2.7's `input [ reg ] [ signed ] [ range ]` makes a 1-bit `reg` (so no
/// E0225). Only the type's class is kept: the analog compile refuses a call
/// to it (E0436), and the mixed-signal kernel runs it from its own digital
/// parse.
pub fn parseFuncDecl(self: *Parser, b: *parse_module.Body, main_tok: u32, is_analog: bool) Error!void {
    self.pos += 1; // 'function'
    const ret_ty: Ast.Type = if (!is_analog) digital: {
        if (self.reservedIs(self.pos, "automatic")) self.pos += 1;
        if (self.peek() == .kw_string) {
            self.pos += 1;
            break :digital .string;
        }
        if (!tfTypeAhead(self)) break :digital .real;
        break :digital (try tfPortType(self)).ty;
    } else switch (self.peek()) {
        .kw_integer => .integer,
        .kw_real => .real,
        .kw_string => .string,
        else => .real, // else: no type keyword, so §4.7.1's `real` default
    };
    if (is_analog and (self.peek() == .kw_integer or self.peek() == .kw_real or self.peek() == .kw_string)) {
        self.pos += 1;
    }
    try self.warnOwnMathFn();
    const name = try self.expectIdent();

    var args: std.ArrayList(Ast.FuncArg) = .empty;
    // A.2.6's ANSI spelling, `function_identifier ( tf_port_list ) ;`, beside
    // the non-ANSI one where the ports are declared in the body. The two are
    // not meant to be mixed, but nothing enforces it: the body loop reads a
    // stray `input` as one more argument, and the LRM names no diagnostic.
    if (self.eat(.lparen)) {
        while (self.peek() != .rparen and self.peek() != .eof) {
            try self.skipAttributes();
            const dir = switch (self.peek()) {
                .kw_input, .kw_output, .kw_inout => blk: {
                    const d = parse_net.portDirection(self.peek()).?;
                    // A.2.6 `function_port_list`: `tf_input_declaration`s only.
                    if (!is_analog) try inputOnly(self, d);
                    self.pos += 1;
                    break :blk d;
                },
                else => Ast.Direction.input, // else: no direction keyword, so A.2.7's `input` default
            };
            try analogFormals(self, &args, dir, false, is_analog);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }
    _ = try self.expect(.semicolon);

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var body: std.ArrayList(Ast.StmtId) = .empty;

    // §4.7.1's two body restrictions are checked at the syntax that
    // violates them (`begin :` and `return ;`), not by a walk afterwards,
    // so the diagnostic lands on the offending token. Analog functions do
    // not nest (A.2.6 has no analog_function_declaration inside a function
    // body), so a plain save/restore is the whole scope discipline.
    const saved_in_fn = self.in_analog_fn;
    self.in_analog_fn = is_analog;
    defer self.in_analog_fn = saved_in_fn;

    // Every arm that loops consumed: a declaration, a statement, or
    // `recoverStatement`'s one token at least.
    var item_at: u32 = undefined;
    while (true) : (std.debug.assert(self.pos > item_at)) {
        item_at = self.pos;
        try self.skipAttributes();
        // A.2.8 block_item_declaration's `reg_declaration`, a digital
        // function's local (A.2.6 `function_item_declaration`).
        if (!is_analog and self.peek() == .kw_reg) {
            try parse_decl.parseRegDecl(self, &vars);
            continue;
        }
        switch (self.peek()) {
            .eof, .kw_endfunction => {
                try self.attributesEnd(item_at);
                break;
            },
            .kw_input, .kw_output, .kw_inout => {
                const dir = parse_net.portDirection(self.peek()).?;
                if (!is_analog) try inputOnly(self, dir);
                self.pos += 1;
                try analogFormals(self, &args, dir, true, is_analog);
                _ = try self.expect(.semicolon);
            },
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                const first = vars.items.len;
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
                // A variable that re-declares an argument only types it, and
                // per §4.7.1 Example 3 (`inout [0:1]a; real a[0:1];`) may carry
                // the shape instead of the direction. Whichever has it wins.
                var i = vars.items.len;
                while (i > first) {
                    i -= 1;
                    for (args.items) |*a| {
                        if (a.name != vars.items[i].name) continue;
                        if (a.ty == .unspecified) a.ty = vars.items[i].ty;
                        if (a.dims.len == 0) a.dims = vars.items[i].dims;
                        _ = vars.orderedRemove(i);
                        break;
                    }
                }
            },
            else => { // else: not a declaration, so the function body's statement
                const before = self.pos;
                const saved_expr = self.analog_expr;
                self.analog_expr = is_analog;
                defer self.analog_expr = saved_expr;
                // A.2.6 has no null item and A.6.4's analog_function_statement
                // no null alternative, so a bare `;` here is E0219.
                const s = (if (is_analog) parse_stmt.parseStmtNoNull(self) else parse_stmt.parseStmt(self)) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    self.recoverStatement(before);
                    continue;
                };
                try body.append(self.arena, s);
            },
        }
    }
    _ = try self.expect(.kw_endfunction);

    // Syntax 4-5's `{ analog_function_item_declaration }` puts no order on the
    // items, so `real x; input x;` types the formal as well: a variable
    // declared before its direction is matched here, as one after it is above.
    var vi = vars.items.len;
    while (vi > 0) {
        vi -= 1;
        for (args.items) |*a| {
            if (a.name != vars.items[vi].name) continue;
            if (a.ty == .unspecified) a.ty = vars.items[vi].ty;
            if (a.dims.len == 0) a.dims = vars.items[vi].dims;
            _ = vars.orderedRemove(vi);
            break;
        }
    }

    // §4.7.1 bullet list: "shall have at least one formal argument declared".
    if (args.items.len == 0) {
        try self.report(main_tok, .E0224, "`{s}` has an empty formal list", .{self.file.str(name)});
    }
    // §4.7.1 bullet list: "all formal arguments shall have an associated
    // block item declaration specifying the data type of the argument".
    // A formal still `.unspecified` got neither, so it is E0225. It is typed
    // `.real` after the diagnostic only to keep the rest of the parse
    // well-typed; the compile has already failed.
    for (args.items) |*a| if (a.ty == .unspecified) {
        if (!is_analog) {
            a.ty = .integer; // A.2.7 `input [ reg ] ...`: a 1-bit `reg`
            continue;
        }
        var d = self.failWith(a.main_tok, .E0225);
        d.msg("formal `{s}` of `{s}` has no data type declaration", .{
            self.file.str(a.name), self.file.str(name),
        });
        d.help("add `real {s};` to the function body", .{self.file.str(a.name)});
        try d.emit();
        a.ty = .real;
    };
    const body_id: Ast.StmtId = if (body.items.len == 1)
        body.items[0]
    else
        try self.file.addStmt(self.arena, .{ .block = .{ .body = body.items } }, main_tok);

    try b.functions.append(self.arena, .{
        .is_analog = is_analog,
        .name = name,
        .ret_ty = ret_ty,
        .args = args.items,
        .params = params.items,
        .vars = vars.items,
        .body = body_id,
        .main_tok = main_tok,
    });
}

/// A.2.6 `function_item_declaration ::= block_item_declaration | {
/// attribute_instance } tf_input_declaration ;` and `function_port_list`: a
/// function without `analog` declares inputs only (IEEE 1364-2005 §10.4.1),
/// so its `output`/`inout`, cursor on the keyword, is E0207. The digital
/// engine refuses the same text by §10.4.4 (E1100).
fn inputOnly(self: *Parser, dir: Ast.Direction) error{OutOfMemory}!void {
    if (dir == .input) return;
    try self.report(self.pos, .E0207, "found {s}: A.2.6 gives a function `input` formals only; an `analog function` or a task takes `{s}`", .{ self.found(self.pos), @tagName(dir) });
}

/// A function formal after its direction: `input real x` (A.2.7
/// task_port_type, a digital function's only; an analog function's is E0291
/// but for A.2.1.2's `output output_variable_type`) or bare `input x`, then
/// A.2.6 `input [ range ] list_of_ports`: one range, before the names, shared
/// by all of them
/// (§4.7.2.3 `output [0:1] out;`, §4.7.1 Example 3 `inout [0:1]a;`).
/// `list` reads `, name` onward, as a body declaration does; a port-list
/// entry names one formal.
///
/// After a discipline, A.2.1.2's `output [ discipline_identifier ] reg
/// [ signed ] [ range ]` and A.2.7's `tf_*_declaration` write `reg [ signed ]`:
/// read, and no data type for an analog function (§4.7.1 types a formal by a
/// block item declaration: E0225). A digital function's formal takes
/// `tfPortType`'s A.2.7 types, its range a packed width, not dimensions.
fn analogFormals(self: *Parser, args: *std.ArrayList(Ast.FuncArg), dir: Ast.Direction, list: bool, is_analog: bool) Error!void {
    var ty = parse_decl.varType(self.peek()) orelse .unspecified;
    // A.2.6's analog_function_item_declaration takes A.2.1.2's port
    // declarations, which carry no data type: §4.7.1 types a formal by a
    // block item declaration. `output integer`/`output time` is the one
    // typed arm (`output output_variable_type`). Reported, then read as
    // before, so the body still parses.
    if (is_analog and ty != .unspecified and !(dir == .output and (self.peek() == .kw_integer or self.peek() == .kw_time)))
        try self.report(self.pos, .E0291, "`{s} {s}`", .{ @tagName(dir), self.tokenText(self.pos) });
    if (ty != .unspecified) self.pos += 1 else _ = try parse_net.optDiscipline(self);
    var dims: []const Ast.Dim = &.{};
    if (ty == .unspecified and !is_analog) {
        if (tfTypeAhead(self)) ty = (try tfPortType(self)).ty;
    } else {
        if (ty == .unspecified and self.eat(.kw_reg)) _ = self.eat(.kw_signed);
        dims = try parse_decl.parseDims(self);
    }
    while (true) {
        const at = self.pos;
        try args.append(self.arena, .{
            .name = try self.expectIdent(),
            .ty = ty,
            .direction = dir,
            .dims = dims,
            .main_tok = at,
        });
        if (!list or !self.eat(.comma)) break;
    }
}

// -----------------------------------------------------------------------
// IEEE 1364-2005 A.2.6/A.2.7 function and task declarations, digital parse
// -----------------------------------------------------------------------

/// IEEE 1364-2005 §10.2/§10.4, A.2.6 and A.2.7, for a digital parse:
///
///     task [ automatic ] name [ ( tf_port_list ) ] ; { tf_item } statement endtask
///     function [ automatic ] [ function_range_or_type ] name
///         [ ( tf_port_list ) ] ; { function_item } statement endfunction
///
/// A formal's direction sticks to the names after it until another one is
/// written, in the port list and in a body declaration alike.
pub fn parseSubroutine(self: *Parser, b: *parse_module.Body, is_function: bool) Error!void {
    const main_tok = self.pos;
    self.pos += 1; // `task` / `function`
    const automatic = self.reservedIs(self.pos, "automatic");
    if (automatic) self.pos += 1;
    var result: Ast.VarDecl = if (is_function) tfType(self) else .{ .name = .none, .ty = .integer };
    if (is_function and result.storage == .reg and result.packed_range == null and self.peek() == .lbracket) result.packed_range = try parse_decl.parseDim(self);
    const name_tok = self.pos;
    try self.warnOwnMathFn();
    const name = try self.expectIdent();
    result.name = name;
    result.main_tok = name_tok;
    var ports: std.ArrayList(Ast.TfPort) = .empty;
    if (self.eat(.lparen)) {
        var dir: Ast.Direction = .input;
        var ty: Ast.VarDecl = .{ .name = .none, .ty = .integer, .storage = .reg, .is_signed = false };
        var attr_tok: ?u32 = null;
        while (self.peek() != .rparen and self.peek() != .eof) {
            try self.skipAttributes();
            if (parse_net.portDirection(self.peek())) |d| {
                attr_tok = self.pos;
                dir = d;
                self.pos += 1;
                ty = try tfPortType(self);
            } else if (ports.items.len == 0) {
                // A.2.6/A.2.7: the list opens with a tf_input/output/inout_declaration;
                // only the names after it inherit its direction. IEEE 1800's
                // default `input` is not 1364's. Reported, then read as an
                // input, so the declaration's body is not misparsed after it.
                try self.report(self.pos, .E0207, "found {s}: a task or function port list opens with input, output or inout", .{self.found(self.pos)});
            }
            const formal = try tfFormal(self, dir, ty);
            if (attr_tok) |decl| try self.copyAttributes(decl, formal.v.main_tok);
            try ports.append(self.arena, formal);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }
    _ = try self.expect(.semicolon);
    const ansi_ports = ports.items.len;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var events: std.ArrayList(Ast.EventDecl) = .empty;
    const end_word = if (is_function) "endfunction" else "endtask";
    var item_at: u32 = undefined;
    while (true) : (std.debug.assert(self.pos > item_at)) {
        item_at = self.pos;
        try self.skipAttributes();
        if (parse_net.portDirection(self.peek())) |d| {
            const decl_tok = self.pos;
            self.pos += 1;
            const typed = switch (self.peek()) {
                .kw_reg, .kw_integer, .kw_time, .kw_real, .kw_realtime => true,
                else => false, // else: a bare direction, `signed` or a range
            };
            const ty = try tfPortType(self);
            while (true) {
                var formal = try tfFormal(self, d, ty);
                formal.redecl.typed = typed;
                try self.copyAttributes(decl_tok, formal.v.main_tok);
                try ports.append(self.arena, formal);
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
            continue;
        }
        switch (self.peek()) {
            .kw_reg, .kw_integer, .kw_time, .kw_real, .kw_realtime => try parseBlockVars(self, &vars),
            // A.2.8 block_item_declaration's constant and event arms.
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_event => {
                const decl_tok = self.pos;
                self.pos += 1;
                while (true) {
                    const event = try parse_decl.parseEventDecl(self);
                    try self.copyAttributes(decl_tok, event.main_tok);
                    try events.append(self.arena, event);
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            else => { // else: the first token that declares nothing begins the body
                // A.2.6/A.2.7 make the body one `statement`, so a closer here
                // means the prefix just read attaches to nothing (#50). A
                // prefix on the first statement stays read: `parseStmt`
                // binds it to the statement at the cursor.
                if (self.peek() == .eof or self.peek() == .kw_endfunction or self.reservedIs(self.pos, end_word))
                    try self.attributesEnd(item_at);
                break;
            },
        }
    }
    // IEEE 1364-2005 §10.2.1: a body port's type and range may come from a
    // variable declaration of the same name (`output o; reg [7:0] o;`,
    // `input x; real x;`). One object, so the variable folds into the port.
    // A header (ANSI) port is fully declared there and keeps any clash.
    var i = vars.items.len;
    while (i > 0) {
        i -= 1;
        for (ports.items[ansi_ports..]) |*p| {
            if (p.v.name != vars.items[i].name) continue;
            var v = vars.items[i];
            // §12.3.3's checks need both declarations: the elaborator
            // judges them (`Ast.TfPort.Redecl`).
            if (p.redecl.count == 0) {
                p.redecl.port_range = p.v.packed_range;
                p.redecl.var_range = v.packed_range;
                p.redecl.tok = v.main_tok;
            }
            p.redecl.count += 1;
            v.main_tok = p.v.main_tok;
            if (v.packed_range == null) v.packed_range = p.v.packed_range;
            p.v = v;
            _ = vars.orderedRemove(i);
            break;
        }
    }
    var body: std.ArrayList(Ast.StmtId) = .empty;
    var stmt_at: u32 = undefined;
    while (!subroutineCloser(self, end_word, self.pos)) : (std.debug.assert(self.pos > stmt_at)) {
        stmt_at = self.pos;
        // §2.9: a prefix followed by the closer prefixes nothing (#66), as
        // the declaration loop above reports for one read there (#50).
        const past = self.pastAttributes();
        if (past != stmt_at and subroutineCloser(self, end_word, past)) {
            try self.skipAttributes();
            try self.attributesEnd(stmt_at);
            break;
        }
        try body.append(self.arena, try parse_stmt.parseStmt(self));
    }
    if (self.peek() == .kw_endfunction or self.reservedIs(self.pos, end_word)) {
        self.pos += 1;
    } else return self.failAt(self.pos, .E0207, "found {s}: no `{s}` closes the declaration", .{ self.found(self.pos), end_word });
    const body_id: Ast.StmtId = if (body.items.len == 1)
        body.items[0]
    else
        try self.file.addStmt(self.arena, .{ .block = .{ .body = body.items } }, main_tok);
    try b.tasks.append(self.arena, .{
        .name = name,
        .is_function = is_function,
        .automatic = automatic,
        .result = result,
        .ports = ports.items,
        .vars = vars.items,
        .params = params.items,
        .events = events.items,
        .body = body_id,
        .main_tok = main_tok,
    });
}

/// Whether token `i` closes a digital function or task body: `endfunction`,
/// `end_word`, or end of file.
fn subroutineCloser(self: *const Parser, end_word: []const u8, i: u32) bool {
    return self.tags[i] == .eof or self.tags[i] == .kw_endfunction or self.reservedIs(i, end_word);
}

/// One A.2.8 `block_item_declaration` of variables (`reg`, `integer`,
/// `time`, `real`, `realtime`), cursor on the keyword, through its `;`.
fn parseBlockVars(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
    const decl_tok = self.pos;
    const ty = try tfPortType(self);
    while (true) {
        var v = ty;
        v.main_tok = self.pos;
        v.name = try self.expectIdent();
        try self.copyAttributes(decl_tok, v.main_tok);
        v.dims = try parse_decl.parseDims(self);
        if (self.eat(.assign_eq)) v.init = try parse_expr.parseExpr(self);
        try out.append(self.arena, v);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

fn tfFormal(self: *Parser, dir: Ast.Direction, ty: Ast.VarDecl) Error!Ast.TfPort {
    var v = ty;
    v.main_tok = self.pos;
    v.name = try self.expectIdent();
    return .{ .direction = dir, .v = v };
}

/// A.2.7's formal and block-item types: `[ reg ] [ signed ] [ range ]`,
/// `integer`, `time`, `real` or `realtime`. A bare direction is a 1-bit
/// unsigned `reg` (IEEE 1364-2005 §10.2.1).
fn tfPortType(self: *Parser) Error!Ast.VarDecl {
    var v = tfType(self);
    if (v.storage == .reg and self.peek() == .lbracket) v.packed_range = try parse_decl.parseDim(self);
    return v;
}

/// Whether an A.2.7 `[ reg ] [ signed ] [ range ]` or `task_port_type`
/// begins at the cursor, so `tfPortType` reads a written type and not the
/// bare-direction default.
fn tfTypeAhead(self: *const Parser) bool {
    return switch (self.peek()) {
        .kw_reg, .kw_signed, .lbracket, .kw_integer, .kw_time, .kw_real, .kw_realtime => true,
        else => false, // else: no type is written here
    };
}

/// The keyword half of `tfPortType`, which a function's result shares.
fn tfType(self: *Parser) Ast.VarDecl {
    switch (self.peek()) {
        .kw_integer => {
            self.pos += 1;
            return .{ .name = .none, .ty = .integer, .storage = .variable, .is_signed = true };
        },
        .kw_time => {
            self.pos += 1;
            return .{ .name = .none, .ty = .integer, .storage = .time, .is_signed = false };
        },
        .kw_real, .kw_realtime => {
            self.pos += 1;
            return .{ .name = .none, .ty = .real };
        },
        else => { // else: `[ reg ] [ signed ] [ range ]`, every keyword optional
            _ = self.eat(.kw_reg);
            return .{ .name = .none, .ty = .integer, .storage = .reg, .is_signed = self.eat(.kw_signed) };
        },
    }
}
