//! Parameter transport: the simulator's 8-byte parameter slots and
//! `$simparam` list in, a device `Model` row written from them out, and
//! back: the defaults read into the slots a host did not give.
//! Owns OSDI's parameter ids: `0 .. num_inst_params` the instance side
//! (`inst_idx`, then `$mfactor`), `num_inst_params .. num_params` the model
//! side (`params`). An instance id asked of the model is the card's value of
//! it, as in OpenVAF.
//!
//! Cites LRM §3.4 (parameters), §6.3.6 (`$mfactor`), §9.15 (`$simparam`),
//! and OpenVAF-Reloaded `osdi_0_4.h` (`access`, the given flags, the C types
//! of a slot).
//!
//! Contents:
//! - `pub const SimParasError = error{SimParasUnterminated}`
//! - `pub const sim_paras_refusal: []const u8`
//! - `pub fn Params(comptime D: type) type`
//! - `pub fn Params(D).access(ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) callconv(.c) ?*anyopaque`
//! - `pub fn Params(D).givenModel(mp: *anyopaque, id: u32) callconv(.c) u32`
//! - `pub fn Params(D).givenInstance(ip: *anyopaque, id: u32) callconv(.c) u32`
//! - `pub fn Params(D).overlay(m: *D.Model, comptime idx: []const u16, comptime k: usize, vals: *[k]u64, given: *const [k]bool) ?[]const u8`
//! - `pub fn Params(D).readback(m: *const D.Model, comptime idx: []const u16, comptime k: usize, vals: *[k]u64, given: *const [k]bool) void`
//! - `pub fn Params(D).refuseInt(handle: ?*anyopaque, param: []const u8) void`
//! - `pub fn Params(D).hostParams(m: *D.Model, p: abi.SimParas) SimParasError!bool`
//! - `pub fn Params(D).hostParamsAt(self: *Instance(D), p: abi.SimParas) SimParasError!bool`
//! - `pub fn Params(D).mfactor(self: *const Instance(D)) f64`

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const blobs = @import("blobs.zig");
const tables = @import("tables.zig");

const max_sim_paras = tables.max_sim_paras;
const host_fields = tables.host_fields;

/// The ways the simulator's `$simparam` list is refused. The row being
/// written is left as it was.
pub const SimParasError = error{
    /// `SimParas.names` has no NULL among its first `max_sim_paras + 1`
    /// entries, which are all this library reads.
    SimParasUnterminated,
};

/// What `setup_model`, `setup_instance` and `eval` log, fatal, on
/// `SimParasUnterminated`.
pub const sim_paras_refusal = std.fmt.comptimePrint("vera osdi: the simulator's $simparam names list has no NULL in its first {d} entries", .{max_sim_paras + 1});

/// The parameter transport of device `D`.
// Generic over `D`: every device has its own parameter fields (axis: the
// device; every device VerA emits is a case).
pub fn Params(comptime D: type) type {
    const T = tables.Tables(D);
    const M = blobs.Model(D);
    const I = blobs.Instance(D);
    return struct {
        /// OSDI `access`: the slot of parameter `id` on the instance
        /// (`ACCESS_FLAG_INSTANCE`) or the model, marked given under
        /// `ACCESS_FLAG_SET`; null for an id past the table or a blob the
        /// simulator did not pass.
        pub fn access(ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) callconv(.c) ?*anyopaque {
            const set = flags & abi.access_flag_set != 0;
            // `$mfactor` (id `ni`) is the instance's whichever blob is asked.
            if (T.num_inst_params > 0 and id < T.num_inst_params and (flags & abi.access_flag_instance != 0 or id >= T.ni)) {
                const self = I.of(ip orelse return null);
                if (set) self.given[id] = true;
                assert(!set or self.given[id]);
                return &self.vals[id];
            }
            // §3.4 parameters are optional (#79): with none, no model-side id
            // exists, and `vals` is a zero-length array that a run-time index
            // may not be analysed against.
            if (T.np == 0) return null;
            // An instance parameter asked of the model reads the card's value
            // of it.
            const j: usize = if (id < T.ni) T.inst_idx[id] else if (id >= T.num_inst_params and id < T.num_params) id - T.num_inst_params else return null;
            assert(j < T.np);
            const m = M.of(mp orelse return null);
            if (set) m.given[j] = true;
            return &m.vals[j];
        }

        /// OSDI `given_flag_model`: whether the card gave model-side
        /// parameter `id`; 0 for any other id.
        pub fn givenModel(mp: *anyopaque, id: u32) callconv(.c) u32 {
            // No parameter, no model-side flag (`access`, #79).
            if (T.np == 0 or id < T.num_inst_params or id >= T.num_params) return 0;
            const j = id - T.num_inst_params;
            assert(j < T.np);
            return @intFromBool(M.of(mp).given[j]);
        }

        /// OSDI `given_flag_instance`: whether the instance line gave
        /// instance-side parameter `id`; 0 for any other id.
        pub fn givenInstance(ip: *anyopaque, id: u32) callconv(.c) u32 {
            if (T.num_inst_params == 0 or id >= T.num_inst_params) return 0;
            assert(T.num_inst_params > 0);
            return @intFromBool(I.of(ip).given[id]);
        }

        /// Writes the given slots of `vals` into `m`: slot `i` is parameter
        /// `T.params[idx[i]]`. Returns the name of an integer parameter
        /// whose host value the field cannot hold (the host's `int32_t` into
        /// VerA's narrower field), with `m` partly written; null when every
        /// given value was written. Asserts that `idx` fits the slots.
        pub fn overlay(m: *D.Model, comptime idx: []const u16, comptime k: usize, vals: *[k]u64, given: *const [k]bool) ?[]const u8 {
            @setEvalBranchQuota(10_000_000);
            comptime assert(idx.len <= k);
            inline for (idx, 0..) |pi, i| if (given[i]) {
                const p = T.params[pi];
                const F = @FieldType(D.Model, p.field);
                @field(m, p.field) = switch (p.kind) {
                    .real => @floatCast(slot(f64, &vals[i]).*),
                    .int => std.math.cast(F, slot(i32, &vals[i]).*) orelse return p.field,
                    .str => if (slot(abi.Str, &vals[i]).*) |z| std.mem.span(z) else @as(F, ""),
                };
                if (@hasDecl(D.Model, "setGiven")) m.setGiven(p.field);
            };
            return null;
        }

        /// Writes `m`'s value of every parameter `given` lacks into its slot
        /// of `vals`, so a host reading one back (ngspice `show`) sees the
        /// default. Asserts that `idx` fits the slots.
        pub fn readback(m: *const D.Model, comptime idx: []const u16, comptime k: usize, vals: *[k]u64, given: *const [k]bool) void {
            @setEvalBranchQuota(10_000_000);
            comptime assert(idx.len <= k);
            inline for (idx, 0..) |pi, i| if (!given[i]) switch (T.params[pi].kind) {
                .real => slot(f64, &vals[i]).* = @field(m, T.params[pi].field),
                .int => slot(i32, &vals[i]).* = std.math.lossyCast(i32, @field(m, T.params[pi].field)),
                // ponytail: a default string is not known to be NUL-terminated.
                .str => slot(abi.Str, &vals[i]).* = null,
            };
        }

        /// Logs `overlay`'s refusal of parameter `param`, fatal.
        pub fn refuseInt(handle: ?*anyopaque, param: []const u8) void {
            assert(param.len > 0);
            var buf: [512]u8 = undefined;
            const at = "vera osdi: integer parameter `";
            abi.log(handle, abi.log_lvl_fatal, std.mem.print(&buf, at ++ "{s}` is outside its type's range", .{param}) catch at);
        }

        /// Copies the simulator's `$simparam` values into `m`'s host fields
        /// (`tables.host_fields`) and returns whether one changed. Each name is
        /// read only as far as it can match a host field; the last match wins.
        /// On `SimParasUnterminated` `m` is unchanged.
        pub fn hostParams(m: *D.Model, p: abi.SimParas) SimParasError!bool {
            @setEvalBranchQuota(10_000_000);
            const names = p.names orelse return false;
            const vals = p.vals orelse return false;
            const len = try parasLen(names);
            var changed = false;
            for (names[0..len], vals[0..len]) |name, v| {
                inline for (host_fields) |h| if (@hasField(D.Model, h.field) and eqlZ(name.?, h.sim)) {
                    if (@field(m, h.field) != v) changed = true;
                    @field(m, h.field) = v;
                };
            }
            return changed;
        }

        /// `hostParams` on the instance's row, for `eval`, which runs every
        /// iterate: each host field's position in the simulator's list is
        /// found once per list (ngspice passes one static array, osdiload.c),
        /// and later calls compare only values. The last match wins, as in
        /// `hostParams`. On `SimParasUnterminated` the row is unchanged.
        pub fn hostParamsAt(self: *I, p: abi.SimParas) SimParasError!bool {
            @setEvalBranchQuota(10_000_000);
            const names = p.names orelse return false;
            const vals = p.vals orelse return false;
            if (self.paras_names != names) {
                self.paras_names = null;
                const len = try parasLen(names);
                inline for (host_fields, 0..) |h, j| {
                    self.paras_at[j] = I.paras_none;
                    for (names[0..len], 0..) |name, i| if (eqlZ(name.?, h.sim)) {
                        self.paras_at[j] = @intCast(i);
                    };
                }
                self.paras_names = names;
            }
            assert(self.paras_names == names);
            var changed = false;
            inline for (host_fields, 0..) |h, j| if (@hasField(D.Model, h.field)) {
                const i = self.paras_at[j];
                if (i != I.paras_none) {
                    assert(i < max_sim_paras);
                    if (@field(self.row, h.field) != vals[i]) changed = true;
                    @field(self.row, h.field) = vals[i];
                }
            };
            return changed;
        }

        /// The instance's `$mfactor`: its slot once `setup_instance` has
        /// defaulted it, 1 for a device without one.
        pub fn mfactor(self: *const I) f64 {
            if (!T.has_mf) return 1;
            return @bitCast(self.vals[T.ni]);
        }

        // ---- private ----

        /// One 8-byte value slot as the C type a parameter takes.
        fn slot(comptime C: type, v: *u64) *C {
            comptime assert(@sizeOf(C) <= @sizeOf(u64));
            comptime assert(@alignOf(C) <= @alignOf(u64));
            // SAFETY: an 8-byte, 8-aligned slot holds any of double, int32 and
            // char*, which is what the simulator wrote through `access`.
            return @ptrCast(@alignCast(v));
        }
    };
}

// ---- private ----

/// The length of the simulator's NULL-terminated `$simparam` names list,
/// which OSDI does not count: an error when no NULL is among its first
/// `max_sim_paras + 1` entries, which are all it reads.
fn parasLen(names: [*]const abi.Str) SimParasError!usize {
    const len = for (0..max_sim_paras + 1) |i| {
        if (names[i] == null) break i;
    } else return error.SimParasUnterminated;
    assert(len <= max_sim_paras);
    assert(names[len] == null);
    return len;
}

/// Whether C string `z` is `s`, reading at most `s.len + 1` bytes of `z`
/// (its NUL ends the match at the first byte that differs).
fn eqlZ(z: [*:0]const u8, comptime s: []const u8) bool {
    comptime assert(s.len > 0);
    comptime assert(std.mem.findScalar(u8, s, 0) == null);
    for (s, 0..) |c, i| if (z[i] != c) return false;
    return z[s.len] == 0;
}

test "eqlZ: a host field name matches only whole, and a shorter C string stops at its NUL" {
    try std.testing.expect(eqlZ("gmin", "gmin"));
    try std.testing.expect(!eqlZ("gmi", "gmin"));
    try std.testing.expect(!eqlZ("gminx", "gmin"));
    try std.testing.expect(!eqlZ("", "gmin"));
}
