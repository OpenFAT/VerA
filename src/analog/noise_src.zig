//! §4.6.4 noise generators: an expression in, the small-signal sources it
//! declares (`NoiseSrc`, deduplicated by generator identity) out, including
//! those a variable carries from an earlier assignment (§4.6.4.6).
//!
//! Cites: §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.2, §4.6.4.3, §4.6.4.4, §4.6.4.6,
//! A.8.2.
//!
//! Contents:
//! - `pub fn noteVarNoise(self: *Lower, name: []const u8, value: Ast.ExprId) Oom!void`
//! - `pub fn noiseSrcsOf(self: *const Lower, e: Ast.ExprId, out: *std.ArrayList(NoiseSrc)) error`
//! - `pub fn addNoiseSrc(arena: std.mem.Allocator, out: *std.ArrayList(NoiseSrc), s: NoiseSrc) error`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const Oom = Lower.Oom;
const NoiseKind = Lower.NoiseKind;
const NoiseSrc = Lower.NoiseSrc;

/// §4.6.4: remembers that variable `name` now carries the noise sources of
/// `value`, so a later `I(a,b) <+ n;` still exports their generators. Called
/// after `value` is lowered, by an assignment and by a declaration
/// initializer (`real n = white_noise(pwr);`) alike.
pub fn noteVarNoise(self: *Lower, name: []const u8, value: Ast.ExprId) Oom!void {
    assert(value == .none or self.exprValid(value));
    assert(name.len != 0);
    var srcs: std.ArrayList(NoiseSrc) = .empty;
    try noiseSrcsOf(self, value, &srcs);
    if (srcs.items.len == 0) return;
    const g = try self.var_noise.getOrPut(self.arena, name);
    if (g.found_existing) {
        // Union by identity: re-lowering a loop body or a second
        // assignment through the same call is still one generator.
        for (g.value_ptr.*) |src| try addNoiseSrc(self.arena, &srcs, src);
    }
    g.value_ptr.* = srcs.items;
}

/// Appends every §4.6.4 small-signal source in `e` to `out`, in first-appearance
/// order, deduplicated by generator identity (`id`). A full walk, not the first
/// hit: one expression can declare several generators. Two textually separate
/// calls stay two generators (§4.6.4.6: "each noise function generates noise
/// which is uncorrelated"); a variable read in both arms of a ?: counts once.
/// Allocates into `self.arena`.
pub fn noiseSrcsOf(self: *const Lower, e: Ast.ExprId, out: *std.ArrayList(NoiseSrc)) error{OutOfMemory}!void {
    assert(e == .none or self.exprValid(e));
    assert(out.items.len <= self.file.exprs.len()); // one generator per noise call at most
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .noise_call => {
            const n = self.file.strings.get(ex.strOf(e));
            // §4.6.3 ac_stim shares the small-signal grammar but is a
            // stimulus, not a noise source. It is collected on the same walk
            // and separated by `kind` in codegen, which gives it §4.6.4.6's
            // "assigned to a variable first" path too. The §4.6.4.3/.4 tables
            // are generators and carry their PSD in `NoiseSrc.table`.
            const kind: NoiseKind = if (std.mem.eql(u8, n, "white_noise"))
                .thermal // §4.6.4.1
            else if (std.mem.eql(u8, n, "flicker_noise"))
                .flicker // §4.6.4.2
            else if (std.mem.eql(u8, n, "noise_table"))
                .table // §4.6.4.3
            else if (std.mem.eql(u8, n, "noise_table_log"))
                .table_log // §4.6.4.4
            else if (std.mem.eql(u8, n, "ac_stim"))
                .ac_stim // §4.6.3
            else
                return;
            const psd = self.noise_psd.get(@backingInt(e)) orelse
                if (kind == .ac_stim) [2]Mir.Value{ .f_one, .f_zero } // §4.6.3 mag 1, phase 0
                else [2]Mir.Value{ .f_zero, .f_one };
            try addNoiseSrc(self.arena, out, .{
                .kind = kind,
                .id = @backingInt(e),
                .pwr = psd[0],
                .exp = psd[1],
                .table = self.noise_tab.get(@backingInt(e)) orelse &.{},
                .tok = ex.mainTok(e),
                .name = if (kind == .ac_stim) acAnalysisName(self, e) else noiseName(self, e),
            });
        },
        // §4.6.4.6's own spelling: the source was assigned to a variable and
        // the contribution names the variable. The shared `id` keeps two such
        // uses one generator.
        .ident => {
            const srcs = self.var_noise.get(self.file.str(ex.strOf(e))) orelse return;
            for (srcs) |s| try addNoiseSrc(self.arena, out, s);
        },
        // Both arms of a ?: count: the walk collects the set of declared
        // generators, whichever arm the solve takes.
        else => { // else: every other tag holds generators only through its children
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try noiseSrcsOf(self, c, out);
        },
    }
}

/// Append one generator unless its identity is already in the list.
pub fn addNoiseSrc(arena: std.mem.Allocator, out: *std.ArrayList(NoiseSrc), s: NoiseSrc) error{OutOfMemory}!void {
    for (out.items) |x| if (x.id == s.id) return;
    const len = out.items.len;
    try out.append(arena, s);
    assert(out.items.len == len + 1);
}

// ---- private ----

/// §4.6.4.1/.2/.3 the optional `name`, read straight off the AST: the label is
/// a string literal, so the call node still carries it.
///
/// The name is the trailing string argument of a call with more than one,
/// the rule all three forms share: `white_noise(pwr, name)`,
/// `flicker_noise(pwr, exp, name)`, `noise_table(input, name)`. The arity test
/// keeps §4.6.4.3's one-argument `noise_table("file.tbl")` a filename.
fn noiseName(self: *const Lower, e: Ast.ExprId) []const u8 {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .noise_call);
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) return "";
    const last = args[args.len - 1];
    if (last == .none or ex.tag(last) != .str_literal) return "";
    return self.file.str(ex.strOf(last));
}

/// §4.6.3 `ac_stim`'s LEADING string argument — the analysis the stimulus is
/// active in. A.8.2 puts the quotation marks inside the production
/// (`ac_stim ( [ " analysis_identifier " …`), so a literal is the only spelling
/// there is; "ac" is the clause's own default for the absent one.
///
/// The opposite end of the call from `noiseName`: §4.6.4's label is trailing
/// and optional, §4.6.3's analysis name is leading.
fn acAnalysisName(self: *const Lower, e: Ast.ExprId) []const u8 {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .noise_call);
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len == 0 or args[0] == .none or ex.tag(args[0]) != .str_literal) return "ac";
    return self.file.str(ex.strOf(args[0]));
}

test addNoiseSrc {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(NoiseSrc) = .empty;
    defer out.deinit(gpa);
    try addNoiseSrc(gpa, &out, .{ .kind = .thermal, .id = 3 });
    try addNoiseSrc(gpa, &out, .{ .kind = .flicker, .id = 9 });
    // §4.6.4.6: the same generator reached twice is one source.
    try addNoiseSrc(gpa, &out, .{ .kind = .thermal, .id = 3 });
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 3), out.items[0].id);
    try std.testing.expectEqual(@as(u32, 9), out.items[1].id);
}
