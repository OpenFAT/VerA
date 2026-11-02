//! SSA construction checked end to end: random structured programs in, every
//! `SsaBuilder` read compared with a concrete run, and the MIR left behind
//! passed through `verify`. Here, not in `analog/ssa.zig`, because `verify`
//! is `prove`'s and `analog` cannot import `prove`.
//! LRM §5.8, §5.9.

const std = @import("std");
const Mir = @import("ir").Mir;
const SsaBuilder = @import("analog").Ssa.SsaBuilder;
const Place = @import("analog").Ssa.Place;

test "ssa: every read agrees with a concrete run of a random structured program" {
    // Oracle: the generated program is also executed directly, each place
    // holding the constant last written to it, while the SSA side keeps one
    // value per phi, set on entry to its block from the pair of the edge
    // taken (a parallel copy). Every read's Value, through `resolveAlias`,
    // must evaluate to the place's concrete value at that point, on several
    // random paths. `verify` then checks the MIR the builder left behind.
    // Shapes are the ones lowering builds: §5.8 if/else with a join, §5.9
    // loops whose header is sealed only after the back edge.
    const gpa = std.testing.allocator;
    const Lowered = @import("ir").Lowered;
    const verify = @import("prove").verify;
    var prng = std.Random.DefaultPrng.init(0x55a_b4a1);
    const r = prng.random();

    const Kind = enum { write, read, cond, loop };
    const Stmt = struct {
        kind: Kind,
        place: u32 = 0,
        /// write: the constant; read: the builder's answer.
        value: Mir.Value = .undef,
        /// cond: the then and else sequences; loop: the body in `seq_a`.
        seq_a: u32 = 0,
        seq_b: u32 = 0,
        /// cond: then, else, join; loop: header, body, exit.
        blk: [3]Mir.Block = @splat(.entry),
    };
    const Gen = struct {
        gpa: std.mem.Allocator,
        r: std.Random,
        mir: *Mir,
        b: *SsaBuilder,
        places: []const Place,
        stmts: std.ArrayList(Stmt) = .empty,
        seqs: std.ArrayList(std.ArrayList(u32)) = .empty,
        cur: Mir.Block = .entry,
        next_const: f64 = 1000.5,

        fn deinit(g: *@This()) void {
            for (g.seqs.items) |*s| s.deinit(g.gpa);
            g.seqs.deinit(g.gpa);
            g.stmts.deinit(g.gpa);
        }

        // Mutually recursive with `stmt`, so the error set is spelled out.
        fn seq(g: *@This(), depth: u32) anyerror!u32 {
            const si: u32 = @intCast(g.seqs.items.len);
            try g.seqs.append(g.gpa, .empty);
            for (0..g.r.uintLessThan(u32, 5)) |_| {
                const st = try g.stmt(depth);
                // Indexed again: `stmt` may have grown `seqs`.
                try g.seqs.items[si].append(g.gpa, st);
            }
            return si;
        }

        fn stmt(g: *@This(), depth: u32) anyerror!u32 {
            const kind: Kind = if (depth >= 3) (if (g.r.boolean()) .write else .read) else g.r.enumValue(Kind);
            var s: Stmt = .{ .kind = kind, .place = g.r.uintLessThan(u32, @intCast(g.places.len)) };
            switch (kind) {
                .write => {
                    s.value = try g.mir.addFloatConst(g.gpa, g.next_const);
                    g.next_const += 1;
                    try g.b.writeVariable(g.places[s.place], g.cur, s.value);
                },
                .read => s.value = try g.b.readVariable(g.places[s.place], g.cur),
                .cond => {
                    const x = g.cur;
                    const t = try g.mir.addBlock(g.gpa);
                    const e = try g.mir.addBlock(g.gpa);
                    const j = try g.mir.addBlock(g.gpa);
                    _ = try g.mir.emitBranch(g.gpa, x, .one, t, e);
                    try g.b.addPredecessor(t, x);
                    try g.b.addPredecessor(e, x);
                    try g.b.sealBlock(t);
                    try g.b.sealBlock(e);
                    g.cur = t;
                    s.seq_a = try g.seq(depth + 1);
                    const t_end = g.cur;
                    _ = try g.mir.emitJump(g.gpa, t_end, j);
                    g.cur = e;
                    s.seq_b = try g.seq(depth + 1);
                    const e_end = g.cur;
                    _ = try g.mir.emitJump(g.gpa, e_end, j);
                    try g.b.addPredecessor(j, t_end);
                    try g.b.addPredecessor(j, e_end);
                    try g.b.sealBlock(j);
                    g.cur = j;
                    s.blk = .{ t, e, j };
                },
                .loop => {
                    const x = g.cur;
                    const h = try g.mir.addBlock(g.gpa);
                    const body = try g.mir.addBlock(g.gpa);
                    const exit = try g.mir.addBlock(g.gpa);
                    _ = try g.mir.emitJump(g.gpa, x, h);
                    try g.b.addPredecessor(h, x);
                    _ = try g.mir.emitBranch(g.gpa, h, .one, body, exit);
                    try g.b.addPredecessor(body, h);
                    try g.b.sealBlock(body);
                    g.cur = body;
                    s.seq_a = try g.seq(depth + 1);
                    const b_end = g.cur;
                    _ = try g.mir.emitJump(g.gpa, b_end, h);
                    try g.b.addPredecessor(h, b_end);
                    try g.b.sealBlock(h);
                    try g.b.addPredecessor(exit, h);
                    try g.b.sealBlock(exit);
                    g.cur = exit;
                    s.blk = .{ h, body, exit };
                },
            }
            const si: u32 = @intCast(g.stmts.items.len);
            try g.stmts.append(g.gpa, s);
            return si;
        }
    };
    const Run = struct {
        mir: *Mir,
        g: *const Gen,
        r: std.Random,
        /// Per place: the constant last written, `.undef` before any.
        conc: []Mir.Value,
        /// Per Value: a phi's value on the last entry to its block.
        phi_val: []Mir.Value,
        cur: Mir.Block = .entry,

        fn eval(run: *@This(), v: Mir.Value) Mir.Value {
            const x = run.mir.resolveAlias(v);
            return if (run.mir.valueKind(x) == .inst_result) run.phi_val[@backingInt(x)] else x;
        }

        fn enter(run: *@This(), to: Mir.Block) anyerror!void {
            var buf: [32]struct { Mir.Value, Mir.Value } = undefined;
            var n: usize = 0;
            var it = run.mir.blockInsts(to);
            while (it.next()) |inst| {
                if (run.mir.instOp(inst) != .phi) continue;
                const res = run.mir.instResult(inst);
                if (run.mir.resolveAlias(res) != res) continue; // collapsed
                const d = run.mir.instData(inst).phi;
                const incoming = for (0..d.count) |k| {
                    const p = run.mir.phiPair(inst, @intCast(k));
                    if (p.block == run.cur) break p.value;
                } else return error.TestLivePhiMissesTheEdgeTaken;
                try std.testing.expect(n < buf.len);
                buf[n] = .{ res, run.eval(incoming) };
                n += 1;
            }
            for (buf[0..n]) |e| run.phi_val[@backingInt(e[0])] = e[1];
            run.cur = to;
        }

        fn exec(run: *@This(), si: u32) anyerror!void {
            for (run.g.seqs.items[si].items) |sti| {
                const s = run.g.stmts.items[sti];
                switch (s.kind) {
                    .write => run.conc[s.place] = s.value,
                    .read => try std.testing.expectEqual(run.conc[s.place], run.eval(s.value)),
                    .cond => {
                        const then = run.r.boolean();
                        try run.enter(if (then) s.blk[0] else s.blk[1]);
                        try run.exec(if (then) s.seq_a else s.seq_b);
                        try run.enter(s.blk[2]);
                    },
                    .loop => {
                        try run.enter(s.blk[0]);
                        for (0..run.r.uintLessThan(u32, 3)) |_| {
                            try run.enter(s.blk[1]);
                            try run.exec(s.seq_a);
                            try run.enter(s.blk[0]);
                        }
                        try run.enter(s.blk[2]);
                    },
                }
            }
        }
    };

    for (0..300) |round| {
        errdefer std.debug.print("ssa model: round {d}\n", .{round});
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        var b = SsaBuilder.init(gpa, &mir);
        defer b.deinit();
        const entry = try mir.addBlock(gpa);
        try b.sealBlock(entry);
        var places: [4]Place = undefined;
        for (&places) |*p| p.* = b.newPlace();
        const seed = r.int(u64);
        var prog = std.Random.DefaultPrng.init(seed);
        var g: Gen = .{ .gpa = gpa, .r = prog.random(), .mir = &mir, .b = &b, .places = &places };
        defer g.deinit();
        const top = try g.seq(0);

        // The same program on Braun's walk alone (`skip` off) leaves the
        // same MIR and reads the same raw Values: the dominator skip only
        // shortens the walk.
        {
            var mir2: Mir = .{};
            defer mir2.deinit(gpa);
            var b2 = SsaBuilder.init(gpa, &mir2);
            b2.skip = false;
            defer b2.deinit();
            try b2.sealBlock(try mir2.addBlock(gpa));
            var places2: [4]Place = undefined;
            for (&places2) |*p| p.* = b2.newPlace();
            var prog2 = std.Random.DefaultPrng.init(seed);
            var g2: Gen = .{ .gpa = gpa, .r = prog2.random(), .mir = &mir2, .b = &b2, .places = &places2 };
            defer g2.deinit();
            _ = try g2.seq(0);
            try std.testing.expectEqual(mir2.insts.len, mir.insts.len);
            try std.testing.expectEqualSlices(u32, mir2.extra.items, mir.extra.items);
            try std.testing.expectEqualSlices(Mir.Value, mir2.alias.items, mir.alias.items);
            for (g2.stmts.items, g.stmts.items) |s2, s| try std.testing.expectEqual(s2.value, s.value);
        }

        const conc = try gpa.alloc(Mir.Value, places.len);
        defer gpa.free(conc);
        const phi_val = try gpa.alloc(Mir.Value, mir.valueCount());
        defer gpa.free(phi_val);
        for (0..3) |_| {
            @memset(conc, .undef);
            @memset(phi_val, .undef);
            var run: Run = .{ .mir = &mir, .g = &g, .r = r, .conc = conc, .phi_val = phi_val };
            try run.exec(top);
        }

        const lw: Lowered = .{};
        if (try verify.verify(&mir, &lw)) |v| {
            std.debug.print("verify: `{s}`: {s}\n", .{ @tagName(v.invariant), v.what });
            return error.TestUnexpectedResult;
        }
    }
}
