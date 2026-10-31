//! Stamping: the instance's last evaluation (`eval.zig`) in, the
//! simulator's right-hand sides, matrix slots, Jacobian arrays and noise
//! densities out, each `load_*` adding into what the simulator passes.
//!
//! Cites LRM §4.6.4 and §4.6.4.3/.4 (noise, tables), §6.3.6 (`$mfactor` in
//! noise power), OpenVAF-Reloaded `osdi_0_4.h`, `load.rs` (`load_spice_rhs_*`)
//! and internals.md (`write_jacobian_array_*`), and ngspice-45 `osdiload.c`,
//! `osdiacld.c` (alpha is ω under AC) and `osdinoise.c`.
//!
//! Contents:
//! - `pub fn Load(comptime D: type) type`
//! - `pub fn Load(D).loadResidualResist(ip: *anyopaque, mp: *anyopaque, dst: [*]f64) callconv(.c) void`
//! - `pub fn Load(D).loadResidualReact(ip: *anyopaque, mp: *anyopaque, dst: [*]f64) callconv(.c) void`
//! - `pub fn Load(D).loadLimitRhsResist(ip: *anyopaque, mp: *anyopaque, dst: [*]f64) callconv(.c) void`
//! - `pub fn Load(D).loadLimitRhsReact(ip: *anyopaque, mp: *anyopaque, dst: [*]f64) callconv(.c) void`
//! - `pub fn Load(D).loadSpiceRhsDc(ip: *anyopaque, mp: *anyopaque, dst: [*]f64, prev: [*]const f64) callconv(.c) void`
//! - `pub fn Load(D).loadSpiceRhsTran(ip: *anyopaque, mp: *anyopaque, dst: [*]f64, prev: [*]const f64, alpha: f64) callconv(.c) void`
//! - `pub fn Load(D).loadJacobianResist(ip: *anyopaque, mp: *anyopaque) callconv(.c) void`
//! - `pub fn Load(D).loadJacobianReact(ip: *anyopaque, mp: *anyopaque, alpha: f64) callconv(.c) void`
//! - `pub fn Load(D).loadJacobianTran(ip: *anyopaque, mp: *anyopaque, alpha: f64) callconv(.c) void`
//! - `pub fn Load(D).writeJacobianResist(ip: *anyopaque, mp: *anyopaque, dst: [*]f64) callconv(.c) void`
//! - `pub fn Load(D).writeJacobianReact(ip: *anyopaque, mp: *anyopaque, dst: [*]f64) callconv(.c) void`
//! - `pub fn Load(D).loadNoise(ip: *anyopaque, mp: *anyopaque, freq: f64, dens: [*]f64) callconv(.c) void`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const blobs = @import("blobs.zig");
const tables = @import("tables.zig");

/// The stamps of device `D`.
// Generic over `D` (axis: the device; every device VerA emits is a case).
pub fn Load(comptime D: type) type {
    const T = tables.Tables(D);
    const I = blobs.Instance(D);
    const n = T.n;
    return struct {
        /// Adds the resistive residual into `dst`, by node.
        pub fn loadResidualResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = I.of(ip);
            for (self.res, self.node_mapping) |v, k| dst[k] += v;
        }

        /// Adds the reactive residual into `dst`, by node.
        pub fn loadResidualReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = I.of(ip);
            for (self.q, self.node_mapping) |v, k| dst[k] += v;
        }

        /// Subtracts the resistive lim_rhs from `dst`, by node.
        pub fn loadLimitRhsResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = I.of(ip);
            for (self.lim_res, self.node_mapping) |v, k| dst[k] -= v;
        }

        /// Subtracts the reactive lim_rhs from `dst`, by node.
        pub fn loadLimitRhsReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = I.of(ip);
            for (self.lim_q, self.node_mapping) |v, k| dst[k] -= v;
        }

        /// Adds SPICE's RHS, J·x − f at the limited point `x`, into `dst`
        /// (OpenVAF load_spice_rhs_dc: J·prev_solve − f + lim_rhs, the same
        /// sum). `prev` is not read.
        pub fn loadSpiceRhsDc(ip: *anyopaque, _: *anyopaque, dst: [*]f64, _: [*]const f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            var rhs: [n]f64 = undefined;
            for (&rhs, self.res) |*r, f| r.* = -f;
            inline for (T.entries, 0..) |e, k| rhs[e.r] += self.jac[k] * self.x[e.c];
            for (rhs, self.node_mapping) |v, k| dst[k] += v;
        }

        /// The DC RHS plus alpha·Jq·x; the simulator subtracts its own
        /// integrated dQ/dt (ngspice osdiload.c).
        pub fn loadSpiceRhsTran(ip: *anyopaque, mp: *anyopaque, dst: [*]f64, prev: [*]const f64, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            loadSpiceRhsDc(ip, mp, dst, prev);
            const self = I.of(ip);
            var rhs: [n]f64 = @splat(0);
            inline for (T.entries, 0..) |e, k| rhs[e.r] += self.jac_q[k] * self.x[e.c];
            for (rhs, self.node_mapping) |v, k| dst[k] += alpha * v;
        }

        /// Adds each resistive entry into its matrix slot, where the
        /// simulator gave one.
        pub fn loadJacobianResist(ip: *anyopaque, _: *anyopaque) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            inline for (T.entries, 0..) |e, k| if (e.resist) {
                if (self.jac_ptr[k]) |p| p.* += self.jac[k];
            };
        }

        /// Adds alpha·dQ/dx into each reactive slot; under AC or noise also
        /// the frequency-dependent slots `eval` left out (`acDyn`), whose
        /// real part goes to the real slot and whose imaginary part already
        /// carries ω (ngspice passes alpha = ω, osdiacld.c).
        pub fn loadJacobianReact(ip: *anyopaque, _: *anyopaque, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            inline for (T.entries, 0..) |e, k| if (e.react) {
                if (self.react_ptr[k]) |p| p.* += alpha * self.jac_q[k];
            };
            if (!@hasDecl(D, "acDyn")) return;
            if (self.sim.kind != .ac and self.sim.kind != .noise) return;
            var out: [D.ac_dyn_slots.len]std.math.Complex(f64) = undefined;
            D.acDyn(f64, &self.row, &self.inst, &self.x, self.sim, alpha, &out);
            inline for (D.ac_dyn_slots, 0..) |s, j| {
                if (comptime T.shortFlow(s / n) or T.shortFlow(s % n)) continue;
                const k = comptime T.entryOf(s / n, s % n);
                if (self.jac_ptr[k]) |p| p.* += out[j].re;
                if (self.react_ptr[k]) |p| p.* += out[j].im;
            }
        }

        /// Adds J + alpha·Jq into each resistive slot (a transient's
        /// companion matrix).
        pub fn loadJacobianTran(ip: *anyopaque, _: *anyopaque, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            inline for (0..T.nj) |k| if (self.jac_ptr[k]) |p| {
                p.* += self.jac[k] + alpha * self.jac_q[k];
            };
        }

        /// Writes the resistive entries into `dst`, which holds
        /// `num_resistive_jacobian_entries` doubles: the entries with the flag,
        /// in entry order (OpenVAF internals.md).
        pub fn writeJacobianResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            comptime var j = 0;
            inline for (T.entries, 0..) |e, k| if (e.resist) {
                dst[j] = self.jac[k];
                j += 1;
            };
            comptime assert(j == T.n_resist);
        }

        /// Writes the reactive entries into `dst`, which holds
        /// `num_reactive_jacobian_entries` doubles, in entry order.
        pub fn writeJacobianReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            comptime var j = 0;
            inline for (T.entries, 0..) |e, k| if (e.react) {
                dst[j] = self.jac_q[k];
                j += 1;
            };
            comptime assert(j == T.n_react);
        }

        /// Writes one density per noise source into `dens`: its PSD
        /// coeff²·(white + flicker/f^ef + table) from `noisePsd` at the last
        /// evaluated point, times `$mfactor` (§6.3.6: in power).
        pub fn loadNoise(ip: *anyopaque, _: *anyopaque, freq: f64, dens: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            if (T.gens.len == 0) return;
            const self = I.of(ip);
            const psd = D.noisePsd(T.Val, self.x, &self.row, &self.inst, self.sim);
            comptime assert(psd.len == T.gens.len);
            const m = if (T.has_mf) self.inst.mfactor else 1;
            inline for (T.gens, 0..) |g, k| {
                const t = psd[k];
                const shape = if (t.flicker == 0 or freq <= 0) t.white else t.white + t.flicker / std.math.pow(f64, freq, t.ef);
                dens[k] = m * t.coeff * t.coeff * (shape + tableAt(&self.row, g.table, freq));
            }
        }

        // ---- private ----

        /// §4.6.4.3/.4 a table generator's PSD at `f`, from the card's knots
        /// (`contract.noiseTable` on the derived row); 0 for any other.
        fn tableAt(row: *const D.Model, comptime table: ?u16, f: f64) f64 {
            const ti = table orelse return 0;
            return contract.noiseTableAt(contract.noiseTable(D, row, ti), f);
        }
    };
}
