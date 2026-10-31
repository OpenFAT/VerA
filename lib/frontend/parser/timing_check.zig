//! IEEE 1364-2005 §15 timing checks inside a specify block: a
//! `$setup(...)`-style call's tokens in, one `Ast.TimingCheck` appended to
//! the module's `Body` out, each argument refused by its Syntax 15-x clause
//! when the check's arity, event or notifier slot does not hold it.
//! Cites: IEEE 1364-2005 §15.1-§15.5, Syntax 15-1 to 15-13, A.7.5.1-A.7.5.3.
//!
//! Contents:
//! - `pub const timing_checks = std.StaticStringMap(struct`
//! - `pub fn parseTimingCheck(self: *Parser, b: *parse_module.Body) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const Error = parser.Error;
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const Ast = @import("../ast.zig");

/// A.7.5.1's twelve `system_timing_check` commands and their argument
/// counts `{ mandatory, mandatory + optional }`, counted off A.7.5.1: e.g.
/// `$setup ( data_event , reference_event , timing_check_limit
/// [ , [ notifier ] ] ) ;` is 3 and 4.
pub const timing_checks = std.StaticStringMap(struct { u8, u8 }).initComptime(.{
    .{ "$setup", .{ 3, 4 } },
    .{ "$hold", .{ 3, 4 } },
    .{ "$setuphold", .{ 4, 9 } },
    .{ "$recovery", .{ 3, 4 } },
    .{ "$removal", .{ 3, 4 } },
    .{ "$recrem", .{ 4, 9 } },
    .{ "$skew", .{ 3, 4 } },
    .{ "$timeskew", .{ 3, 6 } },
    .{ "$fullskew", .{ 4, 7 } },
    .{ "$period", .{ 2, 3 } },
    .{ "$width", .{ 2, 4 } },
    .{ "$nochange", .{ 4, 5 } },
});

/// The widest `timing_checks` arity.
const max_timing_args = blk: {
    var m: u8 = 0;
    for (timing_checks.values()) |a| m = @max(m, a[1]);
    break :blk m;
};

/// The two commands whose first argument is a `controlled_reference_event`.
const controlled_first = std.StaticStringMap(void).initComptime(.{ .{"$period"}, .{"$width"} });

const MinTypMaxArg = enum { no, yes, select };

/// Parses one A.7.5.1 `system_timing_check` into `b.timing_checks`. A.7.1
/// admits no other system task in a specify block, so a name not in
/// `timing_checks` is E0207, as is a wrong argument count.
pub fn parseTimingCheck(self: *Parser, b: *parse_module.Body) Error!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    // Past the widest arity the count is refused below, so those slots are
    // only counted.
    var args: [max_timing_args]Ast.ExprId = undefined;
    var edges: [max_timing_args]Ast.SpecEdge = undefined;
    var masks: [max_timing_args]u8 = undefined;
    var conds: [max_timing_args]Ast.ExprId = undefined;
    const arity = timing_checks.get(self.tokenText(tok)) orelse return self.failAt(
        tok,
        .E0207,
        "found {s}: A.7.1 admits only A.7.5.1's twelve timing checks inside a specify block",
        .{self.found(tok)},
    );
    self.pos += 1;
    _ = try self.expect(.lparen);
    var n: u8 = 0;
    if (self.peek() != .rparen) while (true) {
        // A.7.5.1 writes the optional arguments `[ , [ notifier ] ]`, the
        // comma outside the inner bracket, so a slot may be present and
        // empty. That is why an argument is counted before it is read.
        n +|= 1;
        const arg = self.pos;
        var slot: Ast.ExprId = .none;
        var ev: Ast.SpecEdge = .none;
        var mask: u8 = 0;
        var cond: Ast.ExprId = .none;
        const controlled = self.peek() != .comma and self.peek() != .rparen and
            try parseTimingCheckArg(self, &slot, &ev, &mask, &cond, mintypmaxArg(self.tokenText(tok), n));
        if (n <= max_timing_args) {
            args[n - 1] = slot;
            edges[n - 1] = ev;
            masks[n - 1] = mask;
            conds[n - 1] = cond;
        }
        // A.7.5.2: only `reference_event`, `data_event` and
        // `controlled_reference_event` are `timing_check_event`s. Every
        // command's are its first one (`$period`, `$width`) or two; the
        // limits, flags, offsets and notifier after them are expressions
        // and identifiers that take no event control and no `&&&`.
        if (n > eventArgs(self.tokenText(tok)) and (ev != .none or cond != .none)) return self.failAt(
            arg,
            .E0207,
            "found {s}: argument {d} of `{s}` is not an event, so it takes no event control or `&&&` condition (A.7.5.2)",
            .{ self.found(arg), n, self.tokenText(tok) },
        );
        // A.7.5.1's mandatory arguments are not bracketed, so none of them
        // may be left empty (only `[ , [ notifier ] ]` and its kin may).
        if (n <= arity[0] and slot == .none) return self.failAt(
            arg,
            .E0207,
            "found {s}: argument {d} of `{s}` is required (A.7.5.1)",
            .{ self.found(arg), n, self.tokenText(tok) },
        );
        // A.7.5.1 `$width ( controlled_reference_event , timing_check_limit
        // [ , threshold [ , notifier ] ] )` brackets neither of its two
        // optional arguments on its own, and §15.3.4: "If the notifier is
        // present, a non-null value for the threshold shall also be
        // present", calling `$width ( negedge clr, lim, , notif );` illegal.
        if (n > arity[0] and slot == .none and std.mem.eql(u8, self.tokenText(tok), "$width")) return self.failAt(
            arg,
            .E0207,
            "found {s}: `$width`'s threshold and notifier are not null arguments (A.7.5.1, §15.3.4)",
            .{self.found(arg)},
        );
        // A.7.5.1: `$period` and `$width` open with a
        // `controlled_reference_event`, and A.7.5.3's
        // `controlled_timing_check_event` makes its event control
        // mandatory, unlike `timing_check_event`'s bracketed one.
        if (n == 1 and !controlled and controlled_first.has(self.tokenText(tok))) return self.failAt(
            arg,
            .E0207,
            "`{s}` timing check requires an event control (posedge, negedge or edge) on its reference event (A.7.5.3 controlled_timing_check_event)",
            .{self.tokenText(tok)},
        );
        // A.7.5.2 `notifier ::= variable_identifier`, the reg a violation
        // toggles. A.7.5.1 puts it first among the optional arguments of
        // every command, except `$width`, whose optional `threshold` comes
        // before it.
        const notifier: u8 = if (std.mem.eql(u8, self.tokenText(tok), "$width")) 4 else arity[0] + 1;
        if (n == notifier and self.pos != arg and
            !(self.pos == arg + 1 and (self.tags[arg] == .identifier or self.tags[arg] == .escaped_identifier)))
            return self.failAt(arg, .E0207, "found {s}: the notifier argument of `{s}` names a variable (A.7.5.2 notifier ::= variable_identifier)", .{ self.found(arg), self.tokenText(tok) });
        if (!self.eat(.comma)) break;
    };
    _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    if (n < arity[0] or n > arity[1]) return self.failAt(
        tok,
        .E0207,
        "`{s}` takes {d} to {d} arguments, not {d}",
        .{ self.tokenText(tok), arity[0], arity[1], n },
    );
    try b.timing_checks.append(self.arena, .{
        .name = try self.internTok(tok),
        .args = try self.arena.dupe(Ast.ExprId, args[0..n]),
        .edges = try self.arena.dupe(Ast.SpecEdge, edges[0..n]),
        .masks = try self.arena.dupe(u8, masks[0..n]),
        .conds = try self.arena.dupe(Ast.ExprId, conds[0..n]),
        .main_tok = tok,
    });
}

// ---- private ----

/// How many of a command's leading arguments are A.7.5.2 events: one for
/// the `controlled_reference_event` commands, two (reference and data) for
/// the rest.
fn eventArgs(name: []const u8) u8 {
    return if (controlled_first.has(name)) 1 else 2;
}

/// Parses one argument of an A.7.5.1 command into `slot` and `ev`, and
/// returns whether it had an event control. A.7.5.2's argument productions
/// are all `expression` except the two event slots, which A.7.5.3 gives a
/// prefix and a suffix:
///
///     timing_check_event ::= [ timing_check_event_control ]
///             specify_terminal_descriptor [ &&& timing_check_condition ]
///     timing_check_event_control ::= posedge | negedge | edge_control_specifier
///
/// Every argument accepts that union; `parseTimingCheck` enforces the
/// mandatory control of a `controlled_reference_event` (`$period`,
/// `$width`) and refuses one on an argument that is no event. `mask` is the
/// control's `TimingCheck.masks` entry, `cond` its `&&&` condition.
fn parseTimingCheckArg(self: *Parser, slot: *Ast.ExprId, ev: *Ast.SpecEdge, mask: *u8, cond: *Ast.ExprId, mtm: MinTypMaxArg) Error!bool {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    ev.* = if (self.eat(.kw_posedge)) .posedge else if (self.eat(.kw_negedge)) .negedge else .none;
    mask.* = switch (ev.*) {
        .posedge => Ast.TimingCheck.posedge_mask,
        .negedge => Ast.TimingCheck.negedge_mask,
        .none, .edge => 0,
    };
    var controlled = ev.* != .none;
    if (!controlled and self.reservedIs(self.pos, "edge")) {
        controlled = true;
        ev.* = .edge;
        // A.7.5.3 `edge_control_specifier ::= edge [ edge_descriptor
        // { , edge_descriptor } ]`. The descriptors are two-character
        // symbols (`01`, `z1`, `0x`) that lex as numbers or identifiers
        // depending on their characters, so each is read as the characters
        // of its tokens up to the next `,` or `]`.
        self.pos += 1;
        // The brackets are the production's own (§15.4: "the keyword edge
        // followed by a square-bracketed list"), so a bare `edge clk`
        // names no transition and is refused.
        _ = try self.expect(.lbracket);
        while (true) {
            const at = self.pos;
            var d: [3]u8 = undefined;
            var n: usize = 0;
            while (self.peek() != .comma and self.peek() != .rbracket) : (self.pos += 1) {
                if (self.peek() == .eof) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
                for (self.tokenText(self.pos)) |c| {
                    if (n < d.len) d[n] = std.ascii.toLower(c);
                    n += 1;
                }
            }
            if (n != 2 or !edgeDescriptor(d[0], d[1])) return self.failAt(at, .E0207, "found {s}, not an A.7.5.3 edge descriptor (01, 10, or 0 or 1 paired with x or z)", .{self.found(at)});
            mask.* |= Ast.TimingCheck.transition(d[0], d[1]);
            if (self.eat(.rbracket)) break;
            self.pos += 1; // `,`
        }
    }
    slot.* = switch (mtm) {
        .no => try parse_expr.parseExpr(self),
        .yes => try parse_expr.parseMinTypMax(self),
        // `terminal_identifier [ constant_mintypmax_expression ]`.
        .select => if (self.identLike(self.pos) and self.peekAt(1) == .lbracket) sel: {
            const base = try parse_expr.parsePrimary(self);
            const at = try self.expect(.lbracket);
            const i = try parse_expr.parseMinTypMax(self);
            _ = try self.expect(.rbracket);
            break :sel try self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = at, .lhs = base, .rhs = i });
        } else try parse_expr.parseExpr(self),
    };
    // A.7.5.3's `&&&`, which is three tokens' worth of `&` in a stream that
    // has no tag for it.
    cond.* = if (self.eatSymbol("&&&")) try parse_expr.parseExpr(self) else .none;
    return controlled;
}

/// Which A.7.5.2 argument productions are `mintypmax_expression`: the
/// stamptime and checktime conditions (6th, 7th) of `$setuphold` and
/// `$recrem`, whose delayed reference and data (8th, 9th) take one as their
/// select, and `$nochange`'s two edge offsets (3rd, 4th). The rest are
/// `expression` or narrower.
fn mintypmaxArg(name: []const u8, n: u8) MinTypMaxArg {
    if (std.mem.eql(u8, name, "$nochange")) return if (n == 3 or n == 4) .yes else .no;
    if (!std.mem.eql(u8, name, "$setuphold") and !std.mem.eql(u8, name, "$recrem")) return .no;
    return switch (n) {
        6, 7 => .yes,
        8, 9 => .select,
        else => .no,
    };
}

/// A.7.5.3 `edge_descriptor ::= 01 | 10 | z_or_x zero_or_one | zero_or_one
/// z_or_x`, its two characters lower-cased.
fn edgeDescriptor(a: u8, b: u8) bool {
    const a01 = a == '0' or a == '1';
    const b01 = b == '0' or b == '1';
    const axz = a == 'x' or a == 'z';
    const bxz = b == 'x' or b == 'z';
    return (a01 and b01 and a != b) or (axz and b01) or (a01 and bxz);
}
