//! A device type in, why its required declarations or entry points break the
//! contract (or null) out: one rule per group of `validate`'s checks on the
//! decls a host calls, in the order `validate` runs them.
//! Cites: VAMS-2023 §6.2 (an optional port list), §9.4/§9.5/§9.7 (the
//! display phase), §9.4.1/§9.5.9 (`$debug`, `$fdebug`), §9.17.3 (limiting),
//! §4.6.2 and §5.10 (held state), §5.6.1.2/§4.5.2 (`acceptQ`), §9.15
//! (iteration state).
//!
//! Contents:
//! - `pub fn requiredError(comptime D: type) ?[]const u8`
//! - `pub fn unknownsError(comptime D: type) ?[]const u8`
//! - `pub fn modelInstanceError(comptime D: type) ?[]const u8`
//! - `pub fn residualError(comptime D: type) ?[]const u8`
//! - `pub fn displayError(comptime D: type) ?[]const u8`
//! - `pub fn permissionsError(comptime D: type) ?[]const u8`
//! - `pub fn limitError(comptime D: type) ?[]const u8`
//! - `pub fn derivReadsRuleError(comptime D: type) ?[]const u8`
//! - `pub fn seedCollapseError(comptime D: type) ?[]const u8`
//! - `pub fn stateError(comptime D: type) ?[]const u8`
//! - `pub fn setupError(comptime D: type) ?[]const u8`
//! - `pub fn iterationError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const display_records = @import("display_records.zig");
const host_callbacks = @import("host_callbacks.zig");
const masks = @import("masks.zig");
const shape = @import("validate_shape.zig");
const sim_state = @import("sim_state.zig");
const Mask = masks.Mask;
const nU = masks.nU;

/// The decls every device has: `U`, `num_ports`, `Model`, `Instance` and
/// `eval`. Checked first, so a missing one reads as a contract violation
/// rather than a raw "no member named ..." error.
pub fn requiredError(comptime D: type) ?[]const u8 {
    const required = [_][]const u8{ "U", "num_ports", "Model", "Instance", "eval" };
    for (required) |decl| {
        if (!@hasDecl(D, decl))
            return @typeName(D) ++ ": contract requires `pub " ++ decl ++ "`";
    }
    return null;
}

/// `U` is a dense enum and the ports are a prefix of it. Zero ports is
/// legal: §6.2 makes the port list optional, and a portless module still
/// contributes its private equations. Asserts that `D` has `U`.
pub fn unknownsError(comptime D: type) ?[]const u8 {
    assert(@hasDecl(D, "U"));
    const name = @typeName(D);
    if (@typeInfo(D.U) != .@"enum" or !shape.isDenseEnum(D.U))
        return name ++ ".U must be a dense enum with an unsigned tag and values 0..n-1";
    const np: usize = D.num_ports;
    if (np > nU(D))
        return name ++ ".num_ports must be <= |U|";
    return null;
}

/// `Model` and `Instance` are defaulted structs of value fields, and
/// `mutable_eval` is a `bool`.
pub fn modelInstanceError(comptime D: type) ?[]const u8 {
    if (shape.defaultedStructError(D, "Model")) |m| return m;
    if (shape.defaultedStructError(D, "Instance")) |m| return m;
    if (@hasDecl(D, "mutable_eval") and @TypeOf(D.mutable_eval) != bool)
        return @typeName(D) ++ ".mutable_eval must be bool";
    return null;
}

/// `eval`, `q` and `evalQ` have the generic shape (arity and the comptime
/// first parameter; instantiation checks the rest), and `evalQ`, which fuses
/// `eval` and `q`, comes with a `q`.
pub fn residualError(comptime D: type) ?[]const u8 {
    if (shape.genericFnError(D, "eval", "Rows(D, S)")) |m| return m;
    if (@hasDecl(D, "q")) if (shape.genericFnError(D, "q", "Sites(D, S)")) |m| return m;
    if (@hasDecl(D, "evalQ")) {
        if (!@hasDecl(D, "q"))
            return @typeName(D) ++ ".evalQ without q: the fused entry point needs a reactive half";
        if (shape.genericFnError(D, "evalQ", "struct { res: Rows(D, S), q: Sites(D, S) }")) |m| return m;
    }
    return null;
}

/// §9.4/§9.5 the display phase: `display` is `eval`'s generic shape
/// returning void (§9.7 `$finish`/`$stop`/`$fatal` inside it exit the
/// process, because both clauses tie the task to the accepted point, which
/// is when a host calls it); `displayPass` comes with it (§9.4.1/§9.5.9);
/// `file_io` is a `FileIo`; `say_sites` and `say` come together; and
/// `status_sites` comes with its two `Instance` fields.
pub fn displayError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "display")) {
        if (shape.genericFnError(D, "display", "void")) |m| return m;
    }
    if (@hasDecl(D, "displayPass")) {
        if (!@hasDecl(D, "display")) return name ++ ": displayPass comes with display";
        if (shape.genericError(D, "displayPass", 6, "fn (comptime S: type, *const [n_u]S.V, *const Model, InstancePtr, SimState, comptime SayPass) void")) |m| return m;
    }
    if (@hasDecl(D, "file_io") and @TypeOf(D.file_io) != host_callbacks.FileIo)
        return name ++ ".file_io must be a contract.FileIo";
    // §9.4 the output channel: the site table and the entry point that
    // records into a host's `Say`, one without the other being of no use.
    if (@hasDecl(D, "say_sites") != @hasDecl(D, "say"))
        return name ++ ": say_sites and say come together";
    if (@hasDecl(D, "say")) {
        if (shape.arrayError(D, "say_sites", display_records.SaySite)) |m| return m;
        if (shape.genericError(D, "say", 6, "fn (comptime S: type, *const [n_u]S.V, *const Model, InstancePtr, SimState, *contract.Say) void")) |m| return m;
    }
    if (@hasDecl(D, "status_sites")) {
        if (@typeInfo(@TypeOf(D.status_sites)) != .array or @typeInfo(@TypeOf(D.status_sites)).array.child != display_records.StatusSite)
            return name ++ ".status_sites must be an array of contract.StatusSite";
        if (@FieldType(D.Instance, "vera_status__") != u32 or @FieldType(D.Instance, "vera_status_args__") != [4]f64)
            return name ++ ".status_sites needs Instance.vera_status__: u32 and vera_status_args__: [4]f64";
    }
    return null;
}

/// `jac_f32` (a permission, not a shape: the lane width is the host's to
/// choose) is a `bool`, and `jac_f32_host`, a request laid on it, is refused
/// without it rather than ignored by a host that reads only one of the two.
pub fn permissionsError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "jac_f32") and @TypeOf(D.jac_f32) != bool)
        return name ++ ".jac_f32 must be a bool";
    if (@hasDecl(D, "jac_f32_host")) {
        if (@TypeOf(D.jac_f32_host) != bool)
            return name ++ ".jac_f32_host must be a bool";
        if (D.jac_f32_host and !(@hasDecl(D, "jac_f32") and D.jac_f32))
            return name ++ ".jac_f32_host = true without jac_f32 = true";
    }
    return null;
}

/// §9.17.3 limiting and SPICE MODEINITJCT seeding, both on the instance's
/// private limited image, never the shared x. `seed` is non-null only on
/// `limit_writes` lanes. `old` is the previous iterate's limited point: the
/// image on `limit_writes` once seed or limit has run, x_old elsewhere. A
/// host that masks ports loses only that clamp, which §9.17.3 permits. The
/// masks come with a `limit`, and `writes ⊆ reads`: every corrected unknown
/// is one the clamp read.
pub fn limitError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "limit"))
        if (shape.genericError(D, "limit", 6, "fn (comptime S: type, *const Model, *const Instance, cur: [n_u]f64, old: [n_u]f64, SimState) LimitResult(n_u)")) |m| return m;
    for ([_][]const u8{ "limit_reads", "limit_writes" }) |m| {
        if (!@hasDecl(D, m)) continue;
        if (!@hasDecl(D, "limit")) return name ++ "." ++ m ++ " without a `limit`";
        if (@TypeOf(@field(D, m)) != Mask(D)) return name ++ "." ++ m ++ " must be a " ++ @typeName(Mask(D)) ++ " mask over U (contract.Mask)";
    }
    if (@hasDecl(D, "limit_writes") and (masks.limitWrites(D) & ~masks.limitReads(D)) != 0)
        return name ++ ".limit_writes has a bit limit_reads does not";
    return null;
}

/// `masks.derivReadsError` at `D`'s own |U|.
pub fn derivReadsRuleError(comptime D: type) ?[]const u8 {
    return masks.derivReadsError(D, nU(D));
}

/// `seed` and `collapse` have their generic shapes, and `collapse_full`, the
/// collapse map with every retention flag set (for a host sizing a reduced
/// derivative basis), comes with `collapse` and aliases downward to a root,
/// never to another alias, so `root[u] = collapse_full[u] orelse u` is one
/// lookup.
pub fn seedCollapseError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "seed"))
        if (shape.genericError(D, "seed", 4, "fn (comptime S: type, *const Model, *const Instance, SimState) [n_u]?f64")) |m| return m;
    // Node collapse: per internal unknown, the index it merges into when its
    // separating parasitic resistance is 0, or null.
    if (@hasDecl(D, "collapse"))
        if (shape.genericError(D, "collapse", 3, "fn (comptime S: type, *const Model, *const Instance) [n_u]?u8")) |m| return m;
    if (@hasDecl(D, "collapse_full")) {
        if (!@hasDecl(D, "collapse"))
            return name ++ ": collapse_full without a `collapse`";
        if (@TypeOf(D.collapse_full) != [nU(D)]?u8)
            return name ++ ".collapse_full must be [n_u]?u8";
        for (D.collapse_full, 0..) |e, u| if (e) |r| {
            if (r >= u) return name ++ ".collapse_full must alias downward";
            if (D.collapse_full[r] != null) return name ++ ".collapse_full must be fully resolved";
        };
    }
    return null;
}

/// `eval` reads `Instance`, so state `eval` sees (a switch position) lives
/// in `Instance` fields, and `updateState` gets it mutable: `initState` and
/// `updateState` come with a `State` and have their shapes, and
/// `state_class` agrees with them.
pub fn stateError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "initState") or @hasDecl(D, "updateState")) {
        if (!@hasDecl(D, "State"))
            return name ++ ": initState/updateState require pub const State";
        // initState takes a mutable Instance so a §5.10 held variable can get
        // a parameter-dependent initial value, which a comptime field default
        // cannot express. §9.22 driver access never reaches a device (E0818).
        if (shape.fnError(D, "initState", fn (*const D.Model, *D.Instance) D.State)) |m| return m;
        if (shape.genericError(D, "updateState", 6, "fn (comptime S: type, *const Model, *Instance, [n_u]f64, *State, SimState) UpdateResult")) |m| return m;
        if (@hasDecl(D, "stateCtl"))
            if (shape.fnError(D, "stateCtl", fn (*const D.Model, *D.Instance, *D.State, sim_state.StateCtlOp) bool)) |m| return m;
    }
    if (@hasDecl(D, "state_class")) {
        if (@TypeOf(D.state_class) != sim_state.StateClass)
            return name ++ ".state_class must be a contract.StateClass";
        if ((D.state_class == .none) == @hasDecl(D, "updateState"))
            return name ++ ".state_class: `.none` exactly when there is no updateState";
        // `path_latch` promises the commit that latches the staged values.
        if (D.state_class == .path_latch and !@hasDecl(D, "stateCtl"))
            return name ++ ".state_class = .path_latch requires stateCtl";
    }
    return null;
}

/// The solve-invariant slice: `setup` fills `model.su`, and `eval` reads it
/// as constants, so `setup`'s family must compute values the way `eval`'s
/// does. `Setup`, `setup` and `setup_simparams` come together; then
/// `setupInstance`, `setup_chunks` and the fused `acceptQ` have their shapes.
pub fn setupError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "Setup") != @hasDecl(D, "setup") or @hasDecl(D, "setup") != @hasDecl(D, "setup_simparams"))
        return name ++ ": Setup, setup and setup_simparams come together";
    if (@hasDecl(D, "setup")) {
        const info = @typeInfo(@TypeOf(D.setup));
        if (info != .@"fn" or info.@"fn".param_types.len != 2 or info.@"fn".param_types[0] != type)
            return name ++ ".setup: expected fn (comptime S: type, *Model) void";
        if (!@hasField(D.Model, "su") or @FieldType(D.Model, "su") != D.Setup)
            return name ++ ".Model must carry `su: Setup`";
        const sp = @typeInfo(@TypeOf(D.setup_simparams));
        if (sp != .array or sp.array.child != []const u8)
            return name ++ ".setup_simparams must be [k][]const u8";
    }
    if (@hasDecl(D, "setupInstance") and @TypeOf(D.setupInstance) != fn (*const D.Model, *D.Instance) void)
        return name ++ ".setupInstance: expected fn (*const Model, *Instance) void";
    if (@hasDecl(D, "setup_chunks")) {
        if (!@hasDecl(D, "setup")) return name ++ ".setup_chunks needs `setup`";
        if (@TypeOf(D.setup_chunks.n) != usize or D.setup_chunks.n == 0)
            return name ++ ".setup_chunks.n must be a positive usize";
        if (@TypeOf(D.setup_chunks.exportChunk) != fn (comptime type, comptime usize) void)
            return name ++ ".setup_chunks.exportChunk: expected fn (comptime V: type, comptime k: usize) void";
    }
    // §5.6.1.2/§4.5.2 `q` and `updateState` fused into one evaluation.
    if (@hasDecl(D, "acceptQ")) {
        if (!@hasDecl(D, "q") or !@hasDecl(D, "updateState"))
            return name ++ ".acceptQ requires q and updateState";
        if (shape.genericError(D, "acceptQ", 6, "fn (comptime S: type, *const [n_u]S.V, *const Model, *Instance, *State, SimState) Sites(D, S)")) |m| return m;
    }
    return null;
}

/// §9.15/§9.17.3 iteration state is separate from accepted-time history:
/// `advanceIteration` and `checkConvergence` have their shapes, and so does
/// `attempt`, the card modified for continuation step `lambda`.
pub fn iterationError(comptime D: type) ?[]const u8 {
    if (@hasDecl(D, "advanceIteration"))
        if (shape.genericError(D, "advanceIteration", 5, "fn (comptime S: type, *const Model, *Instance, [n_u]f64, SimState) void")) |m| return m;
    if (@hasDecl(D, "checkConvergence"))
        if (shape.genericError(D, "checkConvergence", 5, "fn (comptime S: type, *const Model, *const Instance, [n_u]f64, SimState) bool")) |m| return m;
    if (@hasDecl(D, "attempt"))
        if (shape.fnError(D, "attempt", fn (D.Model, f64) D.Model)) |m| return m;
    return null;
}
