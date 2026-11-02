//! Test support: a hand-built `Mir` + `Lowered` and the `Analysis` over them,
//! the setup a setup-tier or codegen `plan/` test needs. Every test states its
//! MIR instruction by instruction, so what a plan is asked about sits next to
//! what it answers. No clause of its own.
//!
//! Contents:
//! - `pub const Fixture = struct`
//! - `Fixture.init(f: *Fixture, nets: []const []const u8) Allocator.Error!void`
//! - `Fixture.deinit(f: *Fixture) void`, `Fixture.alloc(f: *Fixture) Allocator`
//! - `Fixture.probe(f: *Fixture, u: u32) Allocator.Error!Mir.Value`
//! - `Fixture.call(f: *Fixture, name: []const u8, args: []const Mir.Value) Allocator.Error!Mir.Value`
//! - `Fixture.analysis(f: *Fixture) Analysis.Error!Analysis`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("Analysis.zig");

/// A hand-built module for one planner test. Set `arena`, then `init`; every
/// allocation goes to `arena` and `deinit` frees them all.
pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    mir: Mir = .{ .name = "mymod" },
    lowered: Lowered = undefined,

    /// Makes `nets` the `Lowered.nodes` (unknowns 0..) and creates the entry
    /// block. Asserts that it runs once, on a fresh fixture.
    pub fn init(f: *Fixture, nets: []const []const u8) Allocator.Error!void {
        assert(f.mir.blockCount() == 0);
        f.lowered = .{};
        const a = f.arena.allocator();
        for (nets) |n|
            try f.lowered.nodes.append(a, .{ .name = n, .kind = .net, .disc = "", .dir = .unspecified });
        _ = try f.mir.addBlock(a);
        assert(f.lowered.nodes.len == nets.len);
    }

    /// Frees everything the fixture and its tests allocated through `alloc`.
    pub fn deinit(f: *Fixture) void {
        assert(f.mir.blockCount() > 0); // `init` ran
        f.arena.deinit();
    }

    /// Returns the fixture's arena; everything it allocates is freed by `deinit`.
    pub fn alloc(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    /// Returns `V(net)`: the probe value of unknown `u`.
    pub fn probe(f: *Fixture, u: u32) Allocator.Error!Mir.Value {
        assert(f.mir.blockCount() > 0); // `init` ran
        return f.mir.addBlockParam(f.alloc(), u);
    }

    /// Emits a call to the callee spelled `name` in the entry block.
    pub fn call(f: *Fixture, name: []const u8, args: []const Mir.Value) Allocator.Error!Mir.Value {
        assert(f.mir.blockCount() > 0); // `init` ran: `.entry` exists
        assert(name.len != 0);
        const a = f.alloc();
        return f.mir.emitCall(a, .entry, try f.mir.internString(a, name), args);
    }

    /// Returns the analysis over what the test has written so far. The MIR
    /// and `lowered` must not change afterwards (see `Input`).
    pub fn analysis(f: *Fixture) Analysis.Error!Analysis {
        assert(f.mir.blockCount() > 0); // `init` ran
        const an = try Analysis.build(f.alloc(), &f.mir, &f.lowered);
        assert(an.nb == f.mir.blockCount());
        return an;
    }
};
