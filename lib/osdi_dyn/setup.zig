//! Setup: the simulator's `setup_model` and `setup_instance` calls in, a
//! device's derived and set-up `Model` rows out, one on the model blob (the
//! card) and one per instance, plus the instance's collapse flags and its
//! reset evaluation state. Each refusal is a fatal log and
//! `EVAL_RET_FLAG_FATAL` in the call's `InitInfo`.
//!
//! Cites LRM §3.4 (a moved shape parameter is refused), §3.4.2 ("It shall be
//! an error ... during simulation": a card value outside its range, #80),
//! §5.4.2 and §5.6.5 (collapse), §6.3.6 (`$mfactor`), §9.15 (`$simparam`),
//! §9.19 (`$port_connected`), and ngspice-45 `osdisetup.c` (`connected`).
//!
//! Contents:
//! - `pub fn Setup(comptime D: type) type`
//! - `pub fn Setup(D).setupModel(handle: ?*anyopaque, mp: *anyopaque, paras: *const abi.SimParas, res: *abi.InitInfo) callconv(.c) void`
//! - `pub fn Setup(D).setupInstance(handle: ?*anyopaque, ip: *anyopaque, mp: *anyopaque, temperature: f64, connected: u32, paras: *const abi.SimParas, res: *abi.InitInfo) callconv(.c) void`
//! - `pub fn Setup(D).derive(handle: ?*anyopaque, m: *D.Model) bool`

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const blobs = @import("blobs.zig");
const params = @import("params.zig");
const tables = @import("tables.zig");

/// The setup calls of device `D`.
// Generic over `D` (axis: the device; every device VerA emits is a case).
pub fn Setup(comptime D: type) type {
    const T = tables.Tables(D);
    const M = blobs.Model(D);
    const I = blobs.Instance(D);
    const P = params.Params(D);
    return struct {
        /// OSDI `setup_model`: the card from the defaults, the simulator's
        /// `$simparam`s and the given model slots, then checked through
        /// `derive`; each slot not given reads back its derived default.
        pub fn setupModel(handle: ?*anyopaque, mp: *anyopaque, paras: *const abi.SimParas, res: *abi.InitInfo) callconv(.c) void {
            const m = M.of(mp);
            res.* = .{ .flags = 0, .num_errors = 0, .errors = null };
            m.card = .{};
            _ = P.hostParams(&m.card, paras.*) catch |err| switch (err) {
                error.SimParasUnterminated => return refuse(handle, res, params.sim_paras_refusal),
            };
            if (P.overlay(&m.card, &T.all_idx, T.np, &m.vals, m.given)) |param| {
                P.refuseInt(handle, param);
                res.flags |= abi.eval_ret_flag_fatal;
                return;
            }
            var d = m.card;
            if (!derive(handle, &d)) res.flags |= abi.eval_ret_flag_fatal;
            P.readback(&d, &T.all_idx, T.np, &m.vals, m.given);
            assert(res.flags & ~abi.eval_ret_flag_fatal == 0);
        }

        /// OSDI `setup_instance`: the instance's own row from the card, the
        /// simulator's `$simparam`s, its given slots, `temperature` and the
        /// `connected` terminals, through `derive`, `setup` and
        /// `setupInstance`; then its collapse flags, its state and its
        /// evaluation history from time 0. Both refusals of the simulator's
        /// input return before the instance is touched.
        pub fn setupInstance(handle: ?*anyopaque, ip: *anyopaque, mp: *anyopaque, temperature: f64, connected: u32, paras: *const abi.SimParas, res: *abi.InitInfo) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            const m = M.of(mp);
            res.* = .{ .flags = 0, .num_errors = 0, .errors = null };
            // ngspice passes `num_terminals` less the unconnected trailing
            // ones (osdisetup.c), never more.
            if (connected > D.num_ports) {
                var buf: [128]u8 = undefined;
                // Two u32s and the fixed text fit 128 bytes.
                const msg = std.mem.print(&buf, "vera osdi: setup_instance connects {d} terminals; the device has {d}", .{ connected, D.num_ports }) catch unreachable;
                return refuse(handle, res, msg);
            }
            self.row = m.card;
            _ = P.hostParams(&self.row, paras.*) catch |err| switch (err) {
                error.SimParasUnterminated => return refuse(handle, res, params.sim_paras_refusal),
            };
            if (P.overlay(&self.row, T.inst_idx, T.num_inst_params, &self.vals, self.given)) |param| {
                P.refuseInt(handle, param);
                res.flags |= abi.eval_ret_flag_fatal;
                return;
            }
            if (@hasField(D.Model, "temperature__")) self.row.temperature__ = temperature;
            // §9.19 `$port_connected`: ngspice connects the first `connected`
            // terminals and makes the rest internal nodes.
            if (@hasField(D.Model, "port_connected__"))
                self.row.port_connected__ = if (connected >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(connected)) - 1;
            if (!derive(handle, &self.row)) res.flags |= abi.eval_ret_flag_fatal;
            P.readback(&self.row, T.inst_idx, T.num_inst_params, &self.vals, self.given);
            if (@hasDecl(D, "setup")) D.setup(T.Val, &self.row);
            self.inst = .{};
            if (T.has_mf) {
                // §6.3.6: `$mfactor` defaults to 1.
                if (!self.given.isSet(T.ni)) self.vals[T.ni] = @bitCast(@as(f64, 1));
                self.inst.mfactor = P.mfactor(self);
            }
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&self.row, &self.inst);
            const roots: [T.n]?u8 = if (T.collapses) D.collapse(T.Val, &self.row, &self.inst) else @splat(null);
            inline for (T.pairs, 0..) |p, k| self.collapsed[k] = switch (p.kind) {
                .merge => if (roots[p.from]) |r| r == p.to else false,
                .short_flow => true,
                .dead_flow => @field(self.row, @typeInfo(D.U).@"enum".field_names[p.from] ++ "__retained") == 0,
            };
            if (T.State != void) self.state = D.initState(&self.row, &self.inst);
            self.have_x = false;
            self.paras_names = null;
            self.sim = .{};
            self.t_prev = 0;
            self.t_last = 0;
            self.t_acc = 0;
            self.bound = std.math.inf(f64);
            assert(!self.have_x);
            assert(res.flags & ~abi.eval_ret_flag_fatal == 0);
        }

        /// `derive`, `checkShape` and `checkRange` on `m`, and `checkCard`'s
        /// warning; false, with a fatal log, when the card moves a §3.4 shape
        /// parameter or puts one outside its §3.4.2 range.
        pub fn derive(handle: ?*anyopaque, m: *D.Model) bool {
            if (@hasDecl(D, "derive")) D.derive(T.Val, m);
            if (@hasDecl(D, "checkShape")) if (D.checkShape(m)) |why| {
                abi.log(handle, abi.log_lvl_fatal, why);
                return false;
            };
            if (@hasDecl(D, "checkRange")) if (D.checkRange(m)) |param| {
                var buf: [512]u8 = undefined;
                const at = "error[E0377]: LRM 3.4.2: parameter `";
                abi.log(handle, abi.log_lvl_fatal, std.mem.print(&buf, at ++ "{s}` is outside its declared range", .{param}) catch at);
                return false;
            };
            if (@hasDecl(D, "checkCard")) if (D.checkCard(m)) |why| abi.log(handle, abi.log_lvl_err, why);
            return true;
        }

        // ---- private ----

        /// Logs `msg` fatal and marks `res` fatal.
        fn refuse(handle: ?*anyopaque, res: *abi.InitInfo, msg: []const u8) void {
            assert(msg.len > 0);
            abi.log(handle, abi.log_lvl_fatal, msg);
            res.flags |= abi.eval_ret_flag_fatal;
            assert(res.flags & abi.eval_ret_flag_fatal != 0);
        }
    };
}
