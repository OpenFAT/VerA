//! The lowered §3.4 parameters -> `Model`: one typed field per parameter at
//! its folded default, the §3.4.7 aliases, the §9.19 given bits
//! (`given_params`, `setGiven`), and `derive`, which recomputes every parameter
//! whose default reads another and the §5.6.5 card-only retention flags.
//! Cites: §3.4, §3.4.6, §3.4.7, §5.6.5, §6.3.4, §9.19.
//!
//! Contents:
//! - `pub fn intFieldType(self: *Gen, p: Lower.ParamInfo) []const u8`
//! - `pub fn emitModel(self: *Gen) Error!void`
//! - `pub fn emitDerive(self: *Gen) Error!void`
//! - `pub fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const kt = @import("kernel_text.zig");
const Gen = codegen.Gen;
const gen_host = @import("host_expr.zig");
const switch_row = @import("switch_row.zig");
const gen_noise = @import("noise.zig");
const gen_unit = @import("unit.zig");
const Analysis = @import("prove").Analysis;
const Lower = @import("ir").Lowered;
const Error = codegen.Error;
const VTy = codegen.VTy;
const gen_file = @import("file.zig");

/// Returns the `Model` field type of a §3.4 integer parameter: the `i64`
/// carrier (an inferred integral one keeps its initializer's bit pattern;
/// an explicit `integer` holds §3.4.1's 32-bit value, and `derive` keeps the
/// low 32 bits of whatever a host writes), or the narrowest of i8/u8/i16/u16
/// that holds its folded §3.4.2 `from` ranges and its default when the card
/// alone writes it. A `derive` target keeps the carrier: a dependent default
/// outside the range must still be stored for `checkRange` to name. A host
/// writes a narrow field with a checked cast (docs/host/device.md).
pub fn intFieldType(self: *Gen, p: Lower.ParamInfo) []const u8 {
    assert(Analysis.tyOfParam(p.ty) == .int);
    if (!p.integer32 or p.is_local or self.an.foldConst(p.default, false) == null) return "i64";
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (p.ranges) |r| {
        if (r.kind != .from) continue;
        const l = r.lo orelse return "i64";
        const h = r.hi orelse return "i64";
        if (r.strings or !std.math.isFinite(l) or !std.math.isFinite(h)) return "i64";
        // Integer ends: an open bound excludes the integer it names.
        lo = @min(lo, if (r.lo_inclusive) @ceil(l) else @floor(l) + 1);
        hi = @max(hi, if (r.hi_inclusive) @floor(h) else @ceil(h) - 1);
    }
    if (lo > hi) return "i64"; // no `from` range, or an empty one
    // §3.4.2 checks the card, not the default: the default must fit too.
    const d: f64 = @floatFromInt(defaultInt(self, p) orelse return "i64");
    lo = @min(lo, d);
    hi = @max(hi, d);
    if (lo >= 0) return if (hi <= std.math.maxInt(u8)) "u8" else if (hi <= std.math.maxInt(u16)) "u16" else "i64";
    if (lo >= std.math.minInt(i8) and hi <= std.math.maxInt(i8)) return "i8";
    if (lo >= std.math.minInt(i16) and hi <= std.math.maxInt(i16)) return "i16";
    return "i64";
}

/// Emits `Model`: one typed field per §3.4 parameter, initialized to its
/// folded spec default, plus alias, `tnom` and retention-flag fields.
pub fn emitModel(self: *Gen) Error!void {
    assert(self.names.p_names.len == self.lowered.params.items.len);
    assert(self.names.a_names.len == self.lowered.aliases.items.len);
    try self.w("/// §3.4 module parameters (spec defaults folded at compile time).\npub const Model = struct {{\n", .{});
    for (self.lowered.params.items, 0..) |p, i| {
        try checkParamDefault(self, p);
        try self.w("    {s}: {s} = {s},\n", .{ self.names.p_names[i], paramFieldType(self, p), try paramDefault(self, p, Analysis.tyOfParam(p.ty)) });
    }
    // §3.4.7 aliasparam: "The aliasparam declaration creates an alternate
    // name ... which can be used to override the value of the parameter", so
    // the alias is part of the model card. It is a second field because Zig
    // has no field aliases; `derive` folds it back onto the original.
    // Its given bit is unconditional: it is the only way to tell "the host
    // overrode the alias" from "the host left it at the default".
    for (self.lowered.aliases.items, 0..) |al, i| {
        const p = self.lowered.params.items[al.param];
        const ty = Analysis.tyOfParam(p.ty);
        try self.w("    {s}: {s} = {s}, // §3.4.7 alias of `{s}`\n", .{
            self.names.a_names[i],
            paramFieldType(self, p),
            try paramDefault(self, p, ty),
            p.name,
        });
    }
    // §9.19 the given flags, one bit each (`given_params` names them): a
    // byte per flag was 514 bytes of bsimcmg's Model row, 65 as bits.
    if (givenCount(self) != 0) try self.w(
        \\    /// §9.19 `$param_given`: bit k is set when the host's card named
        \\    /// `given_params[k]` (`setGiven`). `Model{{}}` has none set; `derive`
        \\    /// reads them and raises an alias's original.
        \\    given__: std.StaticBitSet({d}) = .empty,
        \\
    , .{givenCount(self)});
    // §9.15 the host-published simulation parameters. Model, not Instance:
    // each `.options` entry is one number per run. The initializer is the
    // default, for a host that never writes it.
    for (Lower.host_simparams) |h| if (self.lowered.uses.contains(h.use)) {
        try self.w("    {s}: f64 = {s}, // §9.15 $simparam(\"{s}\"){s} — host-written\n", .{
            h.field, try gen_file.fmtF64(self, self.lowered.simparamValue(h.name).?), h.name, if (h.use == .host_tnom) ", degC" else "",
        });
    };
    // §5.6.5 the card-only retention flag of each collapsible switch branch,
    // which a guarded `jac_const` entry names (`contract.JacWhen`). Not a
    // parameter: `derive` overwrites it. The initializer is the flag at the
    // declared defaults when that folds, else NaN, so a host that skips
    // `derive` does not get a plausible 0.
    for (self.topo.cpairs, 0..) |p, k| {
        if (!p.card) continue;
        const d = if (self.an.foldConst(p.flag, true)) |f| try gen_file.fmtF64(self, f) else kt.nan_lit;
        try self.w("    {s}: f64 = {s}, // §5.6.5 retention flag — `derive` writes it\n", .{ try switch_row.guardField(self, @intCast(k)), d });
    }
    // §9.10 `$temperature`, kelvin: one number per Model row, so every value
    // `setup` derives from it is shared by the instances of that row. A host
    // simulating an instance at its own temperature gives it its own row.
    try self.w("    temperature__: f64 = 300.15, // §9.10 $temperature, kelvin — host-written\n", .{});
    // §9.19 which of the device's ports the host's card connects, bit p for
    // port p in declaration order; all ones (every port connected) unless the
    // host writes it. Read by `$port_connected` in setup, derive and eval, so
    // the host writes it with the card, before `derive`.
    if (self.lowered.uses.contains(.port_mask)) try self.w("    port_connected__: u64 = std.math.maxInt(u64), // §9.19 host-written connection mask\n", .{});
    // §9.15 Table 9-28 through the GPU-safe channel: indices into the host's
    // `contract.host_strings`, 0 ("not written") unless the host writes them,
    // beside the `Instance.cwd`/`analysis_name` slices a CPU host may write.
    if (self.lowered.uses.contains(.host_strings)) try self.w(
        "    cwd_idx__: u32 = 0, // §9.15 $simparam$str(\"cwd\"): index into contract.host_strings — host-written\n" ++
            "    analysis_name_idx__: u32 = 0, // §9.15 $simparam$str(\"analysis_name\"), §4.6.3: likewise\n",
        .{},
    );
    // §4.6.4.3 the row's own sorted copy of the card's noise-table knots
    // (`contract.noiseTable`), so it survives row sharing and copying. Not a
    // parameter: `derive` overwrites it. The initializer is the declared
    // defaults, `noise_tables` flattened, which is what `derive` computes
    // for a card that sets nothing.
    if (gen_noise.hasCardKnots(self)) {
        try self.w("    noise_table_points__: [{d}][2]f64 = .{{", .{gen_noise.cardKnotCount(self)});
        var first = true;
        for (self.noise.tabs) |pts| for (pts) |p| {
            try self.w("{s}.{{ {s}, {s} }}", .{ if (first) " " else ", ", try gen_file.fmtF64(self, p[0]), try gen_file.fmtF64(self, p[1]) });
            first = false;
        };
        try self.w(" }}, // §4.6.4.3 the card's knots, sorted — `derive` writes it\n", .{});
    }
    // The setup roots (`Setup`), LAST so a new parameter does not move them.
    // `su_ok` exists only where it is asserted: Debug, in a program that
    // asked for the contract's checks (`contract.validating`).
    if (self.su.vals.len != 0) try self.w(
        \\    /// The solve-invariant values `setup` fills and `eval` reads.
        \\    su: Setup = .{{}},
        \\    /// Set by `setup`; `eval` asserts it, so a forgotten `setup` panics
        \\    /// (safe builds of a program with `contract.validating`; else `void`).
        \\    su_ok: if (std.debug.runtime_safety and contract.validating) bool else void = if (std.debug.runtime_safety and contract.validating) false else {{}},
        \\
    , .{});
    // Declarations go after the fields (Zig allows none between them).
    try emitGiven(self);
    try self.w("}};\n\n", .{});
}

/// Emits `derive`, which recomputes every parameter whose value is not its
/// own (§6.3.4: "an update of gate_width ... automatically updates
/// gate_cap"). The host writes the model card, calls `derive`, then builds
/// instances. It rewrites a parameter whose default names another parameter
/// unless the host wrote it, and every §3.4.5 localparam unconditionally
/// ("shall not be directly modified"). Declaration order is dependency order
/// (a forward reference is E0314), so one pass suffices. `Model{}` is already
/// the spec default, so a host that overrides nothing need not call it.
pub fn emitDerive(self: *Gen) Error!void {
    assert(self.names.given_bit.len == self.lowered.params.items.len);
    const at = self.out.items.len;
    try self.w(
        \\/// §6.3.4 parameter dependence + §3.4.5 localparam. Call ONCE after
        \\/// writing the model card and before the first solve: the fields below
        \\/// are defined by expressions over other parameters, so they are not
        \\/// valid until the parameters they read have their final values.
        \\pub fn derive(comptime S: type, model: *Model) void {{
        \\
    , .{});
    const at_s = self.out.items.len - "S: type, model: *Model) void {\n".len;
    const body = self.out.items.len;
    // §3.4.7 first: an override written through the alias must be the
    // original's value before a §6.3.4 dependent parameter reads it. The
    // write sets the original too (#76): "the value of the parameter dtemp
    // ... is 5" after `.trise(5)`, so its own given bit (§9.19 `$param_given`,
    // and the §6.3.4 guard below that keeps a default from erasing it) is raised.
    for (self.lowered.aliases.items, 0..) |al, i| {
        const a = self.names.a_names[i];
        const p = self.names.p_names[al.param];
        const ab = self.names.n_given + i;
        if (self.names.p_given[al.param])
            try self.w("    if (model.given__.isSet({d})) {{\n        model.{s} = model.{s};\n        model.given__.set({d});\n    }}\n", .{ ab, p, a, self.names.given_bit[al.param] })
        else
            try self.w("    if (model.given__.isSet({d})) model.{s} = model.{s};\n", .{ ab, p, a });
    }
    // §3.4.1 an explicit `integer` parameter is a 32-bit value, but the host
    // writes the ABI's i64 carrier (4294967297 for 1). Reduce it here, once
    // per card, so every later read (a dependent default below, `setup`,
    // `checkShape`, `eval`) sees the low 32 bits and the hot loop pays nothing.
    // A field the range sized narrower (`intFieldType`) holds 32 bits or fewer.
    for (self.lowered.params.items, 0..) |p, i| {
        if (p.is_local or !p.integer32 or Analysis.tyOfParam(p.ty) != .int) continue;
        if (!std.mem.eql(u8, intFieldType(self, p), "i64")) continue;
        try self.w("    model.{0s} = @as(i32, @truncate(model.{0s}));\n", .{self.names.p_names[i]});
    }
    for (self.lowered.params.items, 0..) |p, i| {
        const ty = Analysis.tyOfParam(p.ty);
        // A string parameter has no arithmetic to redo; a string localparam
        // is left overridable rather than growing a second renderer for it.
        if (ty == .str) continue;
        // `resolve_params = false`: this folds only if the default is
        // self-contained, which is exactly "not derived from a parameter".
        if (self.an.foldConst(p.default, false) != null and !p.is_local) continue;
        // Render in the parameter's numeric domain. A known initializer
        // cannot stand in for a dependency that changes after a host write.
        const e = (if (ty == .int) try gen_host.i64Const(self, p.default, 0) else try gen_host.f64Const(self, p.default, 0, false)) orelse {
            // Defaults with no compile-time value retain W1050's explicit
            // host-supplied-value contract (for example $simparam("gmin")).
            if (!p.is_local and p.folded == null and self.an.foldConst(p.default, true) == null) continue;
            if (self.diags) |bag| try bag.add(.codegen, .E1004, self.lowered.tokenSpan(p.tok), "host derivation of `{s}` uses an unsupported expression; its declared value cannot be frozen after parameter overrides", .{p.name});
            return error.UnsupportedParameterDefault;
        };
        // §6.3.4 gives the default; an explicit host write wins (else a card's
        // `VTH0` over `VTH0 = VTHO` would be erased). Only a localparam is
        // overwritten unconditionally. `plan/names.zig` gave a given bit
        // to every non-local derived parameter.
        if (!p.is_local)
            try self.w("    if (!model.given__.isSet({d})) ", .{self.names.given_bit[i]})
        else
            try self.w("    ", .{});
        switch (ty) {
            .real => try self.w("model.{s} = {s};\n", .{ self.names.p_names[i], e }),
            .int => if (p.integer32)
                try self.w("model.{s} = @as(i32, @truncate({s}));\n", .{ self.names.p_names[i], e })
            else
                try self.w("model.{s} = {s};\n", .{ self.names.p_names[i], e }),
            .str => unreachable,
            .wide => unreachable, // `tyOfParam` types no parameter wide
        }
    }
    if (!try deriveFlags(self)) gen_unit.patchParam(self, at_s, "S".len);
    // §4.6.4.3 the card's noise-table knots, sorted, into the row: LAST, so
    // a knot that is a derived parameter reads its value from above.
    if (gen_noise.hasCardKnots(self)) try self.w("    model.noise_table_points__ = noiseTablePoints(model);\n", .{});
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("}}\n\n", .{});
}

/// Returns the §3.4 field initializer: the parameter's value under the
/// declared defaults, which is what `Model{}` promises. Two folds answer it:
/// `ParamInfo.folded` (`Lower.constEval` over the AST, which sees through a
/// §4.2.12 `?:` that MIR has already turned into a CFG diamond) and
/// `foldConst` over the MIR. Integral defaults prefer the exact AST result.
pub fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8 {
    assert(want != .wide); // `tyOfParam` types no parameter wide.
    if (want == .int) if (p.folded) |k| {
        // An explicit `integer` (§3.4.1) is 32 bits: an integral default
        // keeps its low 32 bits, a real one saturates at the 32-bit bounds
        // (as the 64-bit carrier saturates for an inferred one).
        const value = switch (k) {
            .int => |v| if (p.integer32) @import("kernels").fold.wrap32(v) else v,
            .real => |v| if (p.integer32) std.math.lossyCast(i32, @round(v)) else std.math.lossyCast(i64, @round(v)),
            .str => 0,
        };
        return self.arena.print("{d}", .{value});
    };
    const c = self.an.foldConst(p.default, true);
    if (c == null) if (p.folded) |k| return switch (want) {
        .real => try gen_file.fmtF64(self, k.asReal()),
        // From the i64 side: `folded` kept the integer, so nothing is rounded.
        // A real default on an integer parameter takes the same saturating
        // cast as the fold path below, because `Lower.Const.asInt` casts
        // unguarded.
        .int => try self.arena.print("{d}", .{switch (k) {
            .real => |r| std.math.lossyCast(i64, @round(r)),
            .int, .str => k.asInt(),
        }}),
        .str => switch (k) {
            .str => |s| try self.arena.print("\"{f}\"", .{std.zig.fmtString(s)}),
            else => "\"\"",
        },
        .wide => unreachable, // `tyOfParam` types no parameter wide
    };
    return switch (want) {
        .real => try gen_file.fmtF64(self, c orelse 0.0),
        // ponytail: a default with no AST fold (`p.folded`, which saturates an
        // explicit integer at 32 bits above) clamps to the i64 carrier
        // (`lossyCast`: NaN -> 0) instead of panicking the compiler, as the
        // fold (`fold.Const.asInt`) and the runtime `fi_cast` do; `derive` then
        // keeps an explicit integer's low 32 bits. §4.2.1.1 fixes no overflow
        // rule. Upgrade path: a lowering-time diagnostic on the default's span.
        .int => try self.arena.print("{d}", .{if (c) |k| std.math.lossyCast(i64, @round(k)) else 0}),
        .str => blk: {
            const def = self.mir.valueDef(self.an.rv(p.default));
            break :blk if (def == .str_const)
                try self.arena.print("\"{f}\"", .{std.zig.fmtString(def.str_const)})
            else
                "\"\"";
        },
        .wide => unreachable, // `tyOfParam` types no parameter wide
    };
}

// ---- private ----

/// Returns the `Model` field type of parameter `p` (an alias's is its
/// original's).
fn paramFieldType(self: *Gen, p: Lower.ParamInfo) []const u8 {
    assert(p.name.len != 0);
    return switch (Analysis.tyOfParam(p.ty)) {
        .real => "f64",
        .int => intFieldType(self, p),
        .str => "[]const u8",
        .wide => unreachable, // `tyOfParam` types no parameter wide
    };
}

/// The folded default of an integer parameter, as `paramDefault` prints
/// it, or null when it is not a constant.
fn defaultInt(self: *Gen, p: Lower.ParamInfo) ?i64 {
    assert(Analysis.tyOfParam(p.ty) == .int);
    if (p.folded) |k| return switch (k) {
        .int => |v| if (p.integer32) @import("kernels").fold.wrap32(v) else v,
        .real => |v| if (p.integer32) std.math.lossyCast(i32, @round(v)) else std.math.lossyCast(i64, @round(v)),
        .str => 0,
    };
    const c = self.an.foldConst(p.default, true) orelse return null;
    return std.math.lossyCast(i64, @round(c));
}

/// How many §9.19 given bits `Model.given__` holds: one per flagged
/// parameter, then one per §3.4.7 alias.
fn givenCount(self: *const Gen) usize {
    assert(self.names.n_given <= self.lowered.params.items.len);
    return self.names.n_given + self.lowered.aliases.items.len;
}

/// Emits `Model.given_params` and `Model.setGiven`, the host's side of
/// `given__`, inside the struct so a host holding the `Model` type alone
/// (a generic card writer) reaches them.
fn emitGiven(self: *Gen) Error!void {
    assert(self.names.p_given.len == self.lowered.params.items.len);
    if (givenCount(self) == 0) return;
    try self.w(
        \\    /// The names with a §9.19 `$param_given` bit in `given__`, bit k for
        \\    /// name k: every parameter the model asks about or whose default
        \\    /// `derive` fills, then every §3.4.7 alias. `setGiven` sets one.
        \\    pub const given_params = [_][]const u8{{
        \\
    , .{});
    for (self.lowered.params.items, 0..) |_, i| if (self.names.p_given[i]) try self.w("        \"{s}\",\n", .{self.names.p_names[i]});
    for (self.names.a_names) |a| try self.w("        \"{s}\",\n", .{a});
    try self.w(
        \\    }};
        \\
        \\    /// §9.19 marks `name` (a field's spelling) given: sets its bit. A name
        \\    /// without one is a no-op, since nothing reads it.
        \\    pub fn setGiven(model: *Model, name: []const u8) void {{
        \\        for (given_params, 0..) |n, k| {{
        \\            if (std.mem.eql(u8, n, name)) {{
        \\                model.given__.set(k);
        \\                return;
        \\            }}
        \\        }}
        \\    }}
        \\
    , .{});
}

/// Emits `derive`'s §5.6.5 tail: every card-only retention flag into the
/// `Model` field `emitModel` declared for it, read from the core at x = 0 on a
/// scratch Instance (exact, since a card-only flag reads neither). Must follow
/// the parameter writes it reads. Returns whether it read the core, i.e. named `S`.
fn deriveFlags(self: *Gen) Error!bool {
    assert(self.topo.cpairs.len <= self.names.n_u);
    var any = false;
    for (self.topo.cpairs) |p| any = any or p.card;
    if (!any) return false;
    try self.w(
        \\    // §5.6.5 the published retention flags (`contract.JacWhen`).
        \\    const xr: [n_u]zOf(S, 0) = @splat(S.con(0.0));
        \\    var pin: Instance = .{{}};
        \\
    , .{});
    if (self.su.vals.len != 0) try self.w("    setup(S, model);\n", .{});
    try self.w("    _ = &pin;\n", .{});
    try self.w("    const m = core(S, xr, model, &pin, .{{}}{s});\n", .{self.heldArg(true)});
    for (self.topo.cpairs, 0..) |p, k| {
        if (!p.card) continue;
        const f = self.core.lo_idx[@backingInt(self.an.rv(p.flag))];
        if (self.an.vty[@backingInt(self.an.rv(p.flag))] == .int)
            try self.w("    model.{s} = @floatFromInt(m.f{d});\n", .{ try switch_row.guardField(self, @intCast(k)), f })
        else
            try self.w("    model.{s} = m.f{d}.val();\n", .{ try switch_row.guardField(self, @intCast(k)), f });
    }
    return true;
}

/// Warns W1050 for a parameter whose default nothing in the pipeline
/// evaluates: neither fold in `paramDefault` answers and `derive` cannot
/// render it (a ch9 call such as §9.10 `$temperature` or §9.18 `$simparam`,
/// which is not a §3.4.1 constant_expression). The field's `0` is then the
/// host's to overwrite. A warning, not a refusal, so a model whose default
/// reads a simulator quantity still compiles; `--deny=W1050` makes it strict.
fn checkParamDefault(self: *Gen, p: Lower.ParamInfo) Error!void {
    assert(p.name.len != 0);
    const bag = self.diags orelse return;
    if (!bag.enabled(.W1050)) return;
    if (p.folded != null or self.an.foldConst(p.default, true) != null) return;
    if (try gen_host.f64Const(self, p.default, 0, false) != null) return;
    var d = bag.build(.codegen, .W1050, self.lowered.tokenSpan(p.tok));
    d.msg("`{s}`", .{p.name});
    d.point("this default has no compile-time value, so the field is 0", .{});
    d.help("write the model card field before the first solve, or give `{s}` a constant default", .{p.name});
    try d.emit();
}
