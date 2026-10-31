//! The two blobs a simulator allocates per device: a VerA device type `D`
//! in, the layout of its OSDI model (`model_size` bytes) and instance
//! (`instance_size` bytes) out. The simulator allocates each zeroed, writes
//! parameter slots through `access`, and reads and writes the instance at
//! the offsets the descriptor names (`descriptor.zig`); nothing else in the
//! blobs is the simulator's.
//!
//! Cites OpenVAF-Reloaded `osdi_0_4.h` for which instance fields the
//! simulator reads or writes, and ngspice-45 `osdisetup.c`, which places
//! both blobs at `max_align_t` (16 bytes). No LRM clause.
//!
//! Contents:
//! - `pub fn Model(comptime D: type) type`
//! - `pub fn Model(D).of(mp: *anyopaque) *Model(D)`
//! - `pub fn Instance(comptime D: type) type`
//! - `pub const Instance(D).paras_none: u16`
//! - `pub fn Instance(D).of(ip: *anyopaque) *Instance(D)`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const abi = @import("abi.zig");
const tables = @import("tables.zig");

/// The model blob of device `D`: the card's parameter slots and the card
/// `setup_model` builds from them.
pub fn Model(comptime D: type) type {
    const T = tables.Tables(D);
    return struct {
        /// The model-side parameter slots, by `T.params` index: one 8-byte
        /// C value each (double, int32 or char*), which the simulator writes
        /// through `access`.
        vals: [T.np]u64,
        /// Which `vals` the simulator wrote (an `access` with
        /// `ACCESS_FLAG_SET`). The zeroed blob has none.
        // A byte per flag, not a bit set: `overlay` and `readback` test every
        // flag in an unrolled loop, and a `std.StaticBitSet` there grew
        // psp103's library text by 314 KB (5.09 to 5.41 MB, 6%) to save
        // 700 bytes per model blob.
        given: [T.np]bool,
        /// The card: defaults, the simulator's `$simparam`s and the given
        /// parameters, before `derive`.
        card: D.Model,

        comptime {
            assert(@alignOf(@This()) <= 16); // The simulator's max_align_t.
            assert(@sizeOf(@FieldType(@This(), "vals")) == 8 * T.np);
        }

        /// The simulator's model blob as this layout. Asserts that the blob
        /// is aligned for it.
        pub fn of(mp: *anyopaque) *@This() {
            assert(@intFromPtr(mp) % @alignOf(@This()) == 0);
            // SAFETY: the simulator allocates `model_size` bytes for this
            // descriptor's model and passes that blob back here.
            return @ptrCast(@alignCast(mp));
        }
    };
}

/// The instance blob of device `D`: its parameter slots, its own `Model`
/// row and `Instance`, the simulator's node and matrix pointers, and the
/// last evaluation the `load_*` calls stamp.
pub fn Instance(comptime D: type) type {
    const T = tables.Tables(D);
    return struct {
        /// The instance-side parameter slots, by OSDI id: the `T.inst_idx`
        /// parameters, then `$mfactor` (a double) when `T.has_mf`.
        vals: [T.num_inst_params]u64,
        /// Which `vals` the simulator wrote. The zeroed blob has none.
        given: [T.num_inst_params]bool,
        /// This instance's own `Model` row, derived and set up.
        row: D.Model,
        inst: D.Instance,
        /// The simulator's node of each unknown (`node_mapping_offset`).
        node_mapping: [T.n]u32,
        /// `hostParamsAt`'s cache: the names list it indexed, null before the
        /// first, and each `tables.host_fields` row's position in it.
        paras_names: ?[*]const abi.Str,
        paras_at: [tables.host_fields.len]u16,
        /// One flag per `T.pairs` row, which the simulator reads
        /// (`collapsed_offset`) after `setup_instance`.
        collapsed: [@max(T.pairs.len, 1)]bool,
        /// `state_idx_off`'s target. The descriptor declares no OSDI state,
        /// so the simulator writes none of it.
        state_idx: [1]u32,
        /// The simulator's matrix slot per entry (`jacobian_ptr_resist_offset`
        /// and each entry's `react_ptr_off`), null for one it left out.
        jac_ptr: [T.nj]?*f64,
        react_ptr: [T.nj]?*f64,
        /// The residuals at the last evaluated point, resistive and reactive.
        res: [T.n]f64,
        q: [T.n]f64,
        /// OpenVAF's lim_rhs, J·(x_limited − x), resistive and reactive.
        lim_res: [T.n]f64,
        lim_q: [T.n]f64,
        /// The Jacobian at the last evaluated point, one value per entry.
        jac: [T.nj]f64,
        jac_q: [T.nj]f64,
        /// The point `eval` last evaluated at, limited; read only when `have_x`.
        x: [T.n]f64,
        have_x: bool,
        /// The analysis of the last evaluation.
        sim: contract.SimState,
        state: T.State,
        /// The transient's last two distinct times evaluated, which `dt` is
        /// taken between.
        t_prev: f64,
        t_last: f64,
        /// The time `accept` last committed.
        t_acc: f64,
        /// The step bound the simulator reads (`bound_step_offset`) when the
        /// device schedules breakpoints: see `eval.boundStep`.
        bound: f64,

        /// `paras_at`'s "not in the simulator's list".
        pub const paras_none: u16 = std.math.maxInt(u16);

        comptime {
            assert(@alignOf(@This()) <= 16); // The simulator's max_align_t.
            assert(tables.max_sim_paras < paras_none); // Every position fits `paras_at`.
        }

        /// The simulator's instance blob as this layout. Asserts that the
        /// blob is aligned for it.
        pub fn of(ip: *anyopaque) *@This() {
            assert(@intFromPtr(ip) % @alignOf(@This()) == 0);
            // SAFETY: the simulator allocates `instance_size` bytes for this
            // descriptor's instance and passes that blob back here.
            return @ptrCast(@alignCast(ip));
        }
    };
}
