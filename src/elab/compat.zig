//! Pass-1 shim, delete in pass 2: the old `Elaborate` namespace over the new
//! files, so the modules that import `elab` keep building (and the golden
//! snapshot can prove the rewrite changed no output byte) while their
//! migration is pending. `elaborate` here is the new `elaborate.elaborate`
//! followed by `widen`, which spells every interned row back as the bytes
//! the old `Design` held. Every mapping is listed in the api file.
//! Cites: none (VerA's own API history).
//!
//! Contents:
//! - `pub const flatReference`
//! - `pub const unnamedGenScopes`
//! - `pub const spiceCase`
//! - `pub const genvarLoop`
//! - `pub const Ctx`
//! - `pub const Error`
//! - `pub const sep`
//! - `pub const ParamsetDefparam`
//! - `pub const SystemCheck`
//! - `pub const Inserted`
//! - `pub const DisciplineResolution`
//! - `pub const ParamOverride`
//! - `pub const Design = struct`
//! - `pub const UnitPath = struct`
//! - `pub const NameSite = struct`
//! - `pub const PortAmmeter = struct`
//! - `pub const PsOutput = struct`
//! - `pub const PortWidth = struct`
//! - `pub const SignalDiscipline = struct`
//! - `pub const PortConcat = struct`
//! - `pub const NetPart = struct`
//! - `pub fn elaborate(ctx: Ctx) Error!Design`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
pub const flatReference = @import("flat_name.zig").flatReference;
pub const unnamedGenScopes = @import("flat_name.zig").unnamedGenScopes;
pub const spiceCase = @import("spice_case.zig").spiceCase;
pub const genvarLoop = @import("generate.zig").genvarLoop;

pub const Ctx = design.Ctx;

pub const Error = design.Error;

pub const sep = design.sep;

pub const ParamsetDefparam = design.ParamsetDefparam;

pub const SystemCheck = design.SystemCheck;

pub const Inserted = design.Inserted;

pub const DisciplineResolution = design.DisciplineResolution;

pub const ParamOverride = design.ParamOverride;

/// The old `Design`: every flat name as bytes, units as rows.
pub const Design = struct {
    top: *const Ast.ModuleDecl,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    port_disciplines: std.StringHashMapUnmanaged([]const u8) = .empty,
    implicit_nets: []const NameSite = &.{},
    unconnected_inputs: []const NameSite = &.{},
    units: []const UnitPath = &.{},
    inserts: []const Inserted = &.{},
    port_concats: []const PortConcat = &.{},
    port_widths: []const PortWidth = &.{},
    signal_disciplines: []const SignalDiscipline = &.{},
    attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
    local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
    ps_hidden: []const []const u8 = &.{},
    port_vars: []const Ast.StrId = &.{},
    port_ammeters: []const PortAmmeter = &.{},
    ps_outputs: []const PsOutput = &.{},
    paramset_defparams: []const ParamsetDefparam = &.{},
    selection_params: []const Ast.StrId = &.{},
    system_checks: []const SystemCheck = &.{},
};

/// The old `design.Unit` row, with the declaration by pointer.
pub const UnitPath = struct { module: []const u8, path: []const u8, decl: *const Ast.ModuleDecl };

/// The old `design.NameSite`.
pub const NameSite = struct { name: []const u8, main_tok: u32 };

/// The old `design.PortAmmeter`.
pub const PortAmmeter = struct { internal: []const u8, bound: []const u8 };

/// The old `design.PsOutput`.
pub const PsOutput = struct { report: []const u8, flat: []const u8 };

/// The old `design.PortWidth`.
pub const PortWidth = struct { net: []const u8, range: ?Ast.Dim, main_tok: u32 };

/// The old `design.SignalDiscipline`.
pub const SignalDiscipline = struct { net: []const u8, discipline: []const u8 };

/// The old `design.PortConcat`, its parts a slice of its own.
pub const PortConcat = struct { name: []const u8, range: ?Ast.Dim, parts: []const NetPart, main_tok: u32 };

/// The old `design.NetPart`.
pub const NetPart = struct {
    net: []const u8,
    sel: enum { whole, bit, range, up, down } = .whole,
    a: i64 = 0,
    b: i64 = 0,
};

/// `elaborate.elaborate`, its `Design` widened to the old shape in
/// `ctx.arena`.
pub fn elaborate(ctx: Ctx) Error!Design {
    const d = try @import("elaborate.zig").elaborate(ctx);
    return widen(ctx.arena, ctx.file, d);
}

// ---- private ----

fn widen(arena: std.mem.Allocator, file: *const Ast.SourceFile, d: design.Design) Error!Design {
    var out: Design = .{
        .top = d.top,
        .inserts = d.inserts,
        .attribute_disciplines = d.attribute_disciplines,
        .local_accesses = d.local_accesses,
        .ps_hidden = d.ps_hidden,
        .port_vars = d.port_vars,
        .paramset_defparams = d.paramset_defparams,
        .selection_params = d.selection_params,
        .system_checks = d.system_checks,
    };
    out.names = try spelledMap(arena, file, d.names);
    out.port_disciplines = try spelledMap(arena, file, d.port_disciplines);
    out.implicit_nets = try sites(arena, file, d.implicit_nets);
    out.unconnected_inputs = try sites(arena, file, d.unconnected_inputs);

    const units = try arena.alloc(UnitPath, d.units.len);
    for (units, d.units.items(.module), d.units.items(.path), d.units.items(.decl)) |*u, m, p, decl|
        u.* = .{ .module = file.str(m), .path = p, .decl = decl.get(file) };
    out.units = units;

    const concats = try arena.alloc(PortConcat, d.port_concats.len);
    for (concats, d.port_concats) |*c, pc| {
        const src = pc.parts.of(d.net_parts);
        const parts = try arena.alloc(NetPart, src.len);
        for (parts, src) |*o, np| o.* = .{ .net = file.str(np.net), .sel = @fromBackingInt(@intCast(@backingInt(np.sel))), .a = np.a, .b = np.b };
        c.* = .{ .name = file.str(pc.name), .range = pc.range, .parts = parts, .main_tok = pc.main_tok };
    }
    out.port_concats = concats;

    const widths = try arena.alloc(PortWidth, d.port_widths.len);
    for (widths, d.port_widths) |*w, pw| w.* = .{ .net = file.str(pw.net), .range = pw.range, .main_tok = pw.main_tok };
    out.port_widths = widths;

    const discs = try arena.alloc(SignalDiscipline, d.signal_disciplines.len);
    for (discs, d.signal_disciplines) |*o, sd| o.* = .{ .net = file.str(sd.net), .discipline = file.str(sd.discipline) };
    out.signal_disciplines = discs;

    const ammeters = try arena.alloc(PortAmmeter, d.port_ammeters.len);
    for (ammeters, d.port_ammeters) |*o, am| o.* = .{ .internal = file.str(am.internal), .bound = file.str(am.bound) };
    out.port_ammeters = ammeters;

    const outputs = try arena.alloc(PsOutput, d.ps_outputs.len);
    for (outputs, d.ps_outputs) |*o, po| o.* = .{ .report = po.report, .flat = file.str(po.flat) };
    out.ps_outputs = outputs;

    assert(out.units.len == d.units.len);
    assert(out.names.count() == d.names.count());
    return out;
}

fn spelledMap(arena: std.mem.Allocator, file: *const Ast.SourceFile, m: std.StringHashMapUnmanaged(Ast.StrId)) Error!std.StringHashMapUnmanaged([]const u8) {
    var out: std.StringHashMapUnmanaged([]const u8) = .empty;
    try out.ensureTotalCapacity(arena, m.count());
    var it = m.iterator();
    while (it.next()) |e| out.putAssumeCapacity(e.key_ptr.*, file.str(e.value_ptr.*));
    return out;
}

fn sites(arena: std.mem.Allocator, file: *const Ast.SourceFile, in: []const design.NameSite) Error![]const NameSite {
    const out = try arena.alloc(NameSite, in.len);
    for (out, in) |*o, s| o.* = .{ .name = file.str(s.name), .main_tok = s.main_tok };
    return out;
}
