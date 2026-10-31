//! Annex A.1.8 connectrules_declaration (LRM §7.7): tokens from
//! `connectrules` to `endconnectrules` in, one `Ast.ConnectRulesDecl` out,
//! its §7.7.1 insertions and §7.7.2 resolutions unresolved (elaboration
//! checks the names).
//!
//! LRM clauses cited: §7.7, §7.7.1, §7.7.2, §7.7.3, §7.7.4, §7.8.3.
//!
//! Contents:
//! - `pub fn parseConnectRules(self: *Parser) Error!Ast.ConnectRulesDecl`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_inst = @import("inst.zig");
const parse_source = @import("source.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Parses one A.1.8 connectrules_declaration (LRM §7.7):
///
///     connectrules connectrules_identifier ;
///         { connectrules_item }
///     endconnectrules
///     connectrules_item ::= connect_insertion | connect_resolution
///
/// Names are not resolved: the connect module of a §7.7.1 insertion and
/// the disciplines of a §7.7.2 resolution may be declared after the block
/// (A.1.2 puts no order on descriptions), so elaboration checks them
/// (`elab/resolve.zig`, `checkConnectRules`).
pub fn parseConnectRules(self: *Parser) Error!Ast.ConnectRulesDecl {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const main_tok = self.pos;
    self.pos += 1; // 'connectrules'
    const name = try self.expectIdent();
    _ = try self.expect(.semicolon);

    var insertions: std.ArrayList(Ast.ConnectInsertion) = .empty;
    var resolutions: std.ArrayList(Ast.ConnectResolution) = .empty;
    while (!self.eat(.kw_endconnectrules)) {
        try parse_source.outsideDesignElement(self, "connectrules");
        const item_tok = try self.expect(.kw_connect);
        const first = try self.expectIdent();
        // Both item forms open with `connect identifier`. A `,` or
        // `resolveto` after it can only continue a connect_resolution: an
        // insertion puts a mode keyword, `#`, a direction, an identifier or
        // `;` there.
        if (self.peek() == .comma or self.peek() == .kw_resolveto) {
            // A.1.8 connect_resolution, §7.7.2.
            var discs: std.ArrayList(Ast.StrId) = .empty;
            try discs.append(self.arena, first);
            while (self.eat(.comma)) try discs.append(self.arena, try self.expectIdent());
            _ = try self.expect(.kw_resolveto);
            var res: Ast.ConnectResolution = .{ .disciplines = discs.items, .main_tok = item_tok };
            // A.1.8 discipline_identifier_or_exclude. `exclude` is the
            // §3.4.2 value-range keyword spent again (annex B reserves it
            // once), so the tag already exists.
            if (self.eat(.kw_exclude)) res.exclude = true else res.resolved = try self.expectIdent();
            _ = try self.expect(.semicolon);
            try resolutions.append(self.arena, res);
        } else {
            // A.1.8 connect_insertion, §7.7.1, with §7.7.4's mode and
            // §7.7.3's parameter list in their grammar slots.
            var ins: Ast.ConnectInsertion = .{ .module = first, .main_tok = item_tok };
            if (self.eat(.kw_merged)) {
                ins.mode = .merged;
            } else if (self.eat(.kw_split)) {
                ins.mode = .split;
            }
            ins.params = try parse_inst.parseParamValueAssignment(self);
            if (self.peek() != .semicolon) {
                // A.1.8 connect_port_overrides admits four direction
                // pairs (none/none, input/output, output/input,
                // inout/inout), so the first direction fixes the second.
                const a_dir: Ast.Direction = switch (self.peek()) {
                    .kw_input => .input,
                    .kw_output => .output,
                    .kw_inout => .inout,
                    else => .unspecified, // else: no direction keyword
                };
                if (a_dir != .unspecified) self.pos += 1;
                const a_tok = self.pos;
                const a = try self.expectIdent();
                // §7.8.3 connect_mode "can be one of two predefined values,
                // split or merged": a lone word in its slot, with no second
                // discipline after it, is a mode that is neither, not an
                // override that lost its comma.
                if (a_dir == .unspecified and self.peek() == .semicolon)
                    return self.failAt(a_tok, .E0207, "found {s}: a connect_mode is `merged` or `split`", .{self.found(a_tok)});
                _ = try self.expect(.comma);
                const b_dir: Ast.Direction = switch (a_dir) {
                    .unspecified => .unspecified,
                    .input => blk: {
                        _ = try self.expect(.kw_output);
                        break :blk .output;
                    },
                    .output => blk: {
                        _ = try self.expect(.kw_input);
                        break :blk .input;
                    },
                    .inout => blk: {
                        _ = try self.expect(.kw_inout);
                        break :blk .inout;
                    },
                };
                const second = try self.expectIdent();
                ins.overrides = .{ .a_dir = a_dir, .a = a, .b_dir = b_dir, .b = second };
            }
            _ = try self.expect(.semicolon);
            try insertions.append(self.arena, ins);
        }
    }
    return .{
        .name = name,
        .insertions = insertions.items,
        .resolutions = resolutions.items,
        .main_tok = main_tok,
    };
}
