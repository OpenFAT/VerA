//! Pass-1 shim: the old `prove` names, mapped onto the rewritten API, so the
//! rest of the tree keeps building while its own rewrite lands. Delete in
//! pass 2: every mapping is listed in the API file, and each caller moves to
//! the name on the right of its line. Old names in, the new calls out; no
//! logic of its own beyond reshaping two results.
//!
//! No LRM clause: this is VerA's own API history.
//!
//! Contents:
//! - `pub const ifconv = struct`: `Mode`, `keepSlice`, `runMode`, `run(gpa: Allocator, mir: *Mir) Error!u32`
//! - `pub const proof = struct`: `FloatMode`, `Verdict`, `Options`, `unitCount`, `proveOpts`, `max_errors`,
//!   `isPredicateValue`, `domainOf(op: Mir.Opcode) Mir.opcode.Domain`
//! - `pub const setup = struct`: `Error`, `Sinv` (`Sinv.movedTo`), `Cd`, `plan(in: Input) Error!Sinv`, `candidate`,
//!   `branchCond`, `timepointVarying`, `pruneHeld`, `controlDeps(in: Input, ipdom: []const u32) Error!struct`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const diag = @import("diag");
const ifconv_new = @import("ifconv.zig");
const proof_new = @import("proof.zig");
const setup_new = @import("setup.zig");
const timepoint_new = @import("timepoint.zig");
const held_new = @import("held.zig");
const guards = @import("guards.zig");
const Input = @import("input.zig").Input;

/// Old `prove.ifconv`. Pass 2: `prove.ifconv`.
pub const ifconv = struct {
    /// `ifconv.Mode`.
    pub const Mode = ifconv_new.Mode;
    /// `ifconv.keepSlice`.
    pub const keepSlice = ifconv_new.keepSlice;
    /// `ifconv.run(gpa, mir, mode, keep)`.
    pub const runMode = ifconv_new.run;

    /// `ifconv.run(gpa, mir, .pure, null)`.
    pub fn run(gpa: Allocator, mir: *Mir) ifconv_new.Error!u32 {
        return ifconv_new.run(gpa, mir, .pure, null);
    }
};

/// Old `prove.proof`. Pass 2: `prove.proof`.
pub const proof = struct {
    /// `proof.FloatMode`.
    pub const FloatMode = proof_new.FloatMode;
    /// `proof.Verdict` (`error_count` is now a `u8`).
    pub const Verdict = proof_new.Verdict;
    /// `proof.Options`.
    pub const Options = proof_new.Options;
    /// `proof.unitCount`.
    pub const unitCount = proof_new.unitCount;
    /// `proof.prove`.
    pub const proveOpts = proof_new.prove;
    /// `proof.errors_max`.
    pub const max_errors = proof_new.errors_max;
    /// `prove.guards`' `isPredicateValue`, now private to the module: ifconv
    /// is its only other reader.
    pub const isPredicateValue = guards.isPredicateValue;

    /// `Mir.opcode.get(op).domain`.
    pub fn domainOf(op: Mir.Opcode) Mir.opcode.Domain {
        return Mir.opcode.get(op).domain;
    }
};

/// Old `prove.setup`. Pass 2: `prove.setup`, `prove.timepoint`, `prove.held`.
pub const setup = struct {
    /// Every fallible call fails only on allocation.
    pub const Error = setup_new.Error;

    /// `setup.Invariance`, with its old field names: `val` is `invariant`,
    /// `blk` is `placeable`.
    pub const Sinv = struct {
        val: []bool = &.{},
        blk: []bool = &.{},
        loop_varying: []bool = &.{},
        home: []u32 = &.{},
        moved: []Mir.Value = &.{},
        moved_off: []u32 = &.{},

        /// `Invariance.movedTo`.
        pub fn movedTo(s: Sinv, b: u32) []const Mir.Value {
            return toNew(s).movedTo(b);
        }

        fn toNew(s: Sinv) setup_new.Invariance {
            return .{ .invariant = s.val, .placeable = s.blk, .loop_varying = s.loop_varying, .home = s.home, .moved = s.moved, .moved_off = s.moved_off };
        }
    };

    /// `setup.ControlDep`: `a` is `branch`, `then` is `edge == .then_edge`.
    pub const Cd = struct { a: u32, then: bool };

    /// `setup.plan`, reshaped to `Sinv`.
    pub fn plan(in: Input) Error!Sinv {
        const r = try setup_new.plan(in);
        return .{ .val = r.invariant, .blk = r.placeable, .loop_varying = r.loop_varying, .home = r.home, .moved = r.moved, .moved_off = r.moved_off };
    }

    /// `setup.candidate`.
    pub const candidate = setup_new.candidate;
    /// `setup.branchCond`.
    pub const branchCond = setup_new.branchCond;
    /// `timepoint.varying`.
    pub const timepointVarying = timepoint_new.varying;
    /// `held.prune`.
    pub const pruneHeld = held_new.prune;

    /// `setup.controlDeps(in)`, reshaped to the old rows in `in.arena`.
    /// Asserts that `ipdom` is `in.an.ipdom`.
    pub fn controlDeps(in: Input, ipdom: []const u32) Error!struct { off: []u32, cd: []Cd } {
        assert(ipdom.ptr == in.an.ipdom.ptr);
        const c = try setup_new.controlDeps(in);
        const cd = try in.arena.alloc(Cd, c.deps.len);
        for (cd, c.deps) |*o, d| o.* = .{ .a = d.branch, .then = d.edge == .then_edge };
        return .{ .off = c.off, .cd = cd };
    }
};
