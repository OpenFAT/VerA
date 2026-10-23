//! SSA construction (Braun et al., "Simple and Efficient Construction of
//! Static Single Assignment Form"): per-block variable writes and reads for
//! §5.8 conditionals and §5.9 loops → MIR Values and phis. Consumers must pass
//! every Value through `Mir.resolveAlias` (a collapsed phi is aliased, not
//! rewritten), and must treat `.phi` rows as block headers: a phi is minted on
//! demand, so its row can sit anywhere in the chain, even after the terminator.
//!
//! LRM clauses this file's code cites: §3.4.4, §5.7.

const std = @import("std");
const Mir = @import("ir").Mir;
const assert = std.debug.assert;

// Spelled out, not inferred: sealBlock's addPhiOperands calls readFrom.
const Error = std.mem.Allocator.Error;

/// A "place" is an assignable location (a variable or a lowered temp).
pub const Place = enum(u32) { _ };

/// End-of-list sentinel for the intrusive pools. Not 0: index 0 is a real slot.
const list_end: u32 = std.math.maxInt(u32);

/// "No definition recorded for this (place, block)" in the builder's map.
///
/// Not `Mir.Value.undef`, which is a legitimate stored result (a phi over only
/// self-references collapses to it); confusing the two would re-run the
/// recursive read and re-create the collapsed phi. Cells hold
/// `@backingInt(value) + 1` so a zeroed chunk already reads as empty.
/// `writeVariable` asserts no overflow.
const absent: u32 = 0;

/// "This (place, block) is a join whose predecessors are being read right
/// now"; see the ≥2-preds arm of `readJoin`. A read that meets
/// it has come round a cycle and mints the phi there (`climb`). Never
/// a biased Value: `writeVariable` keeps the Value space two short of it.
const pending: u32 = std.math.maxInt(u32);

/// log2 of the cells per chunk of the `(place, slot)` map. A chunk is the
/// unit that becomes resident, so this is the map's memory granularity: 64
/// cells (256 B) against the 1024 of a 4 KiB page. A place's cells cluster
/// along the slots between its definition and its last read, so finer
/// chunks keep the map near its written cells and coarser ones only add
/// zeros; a narrower one makes the directory grow instead.
/// Measured on the memo cells psp103 and hisimhv_va leave behind: 64 cells
/// fill 70-77%, 16 fill 89-92% but double the directory, which costs more
/// than the zeros it saves.
const chunk_bits = 6;
const chunk_len = 1 << chunk_bits;

/// `BlockState.slot` of a block with no memo cell yet.
const no_slot: u32 = std.math.maxInt(u32);
/// `BlockState.slot` of a block whose cells live in `arm_cells`, not the map.
const arm_slot: u32 = no_slot - 1;

/// Braun-style SSA builder over one `Mir`. Blocks are created by the caller
/// (`Mir.addBlock`); the builder records edges, writes and reads, and emits
/// phis into the Mir as reads require.
pub const SsaBuilder = struct {
    /// Allocates the phi rows the builder emits into `mir`; never the
    /// builder's own tables (`map`).
    gpa: std.mem.Allocator,
    /// The builder's own tables (the map, the predecessor and phi-user pools,
    /// the per-block state), which `deinit` frees. Not `gpa`: lowering passes
    /// its compilation arena, which frees nothing before the compile ends, and
    /// these are scratch for the lowering phase alone. A field so a test can
    /// leak-check them and fail each allocation in turn.
    map: std.mem.Allocator = std.heap.page_allocator,
    /// The Mir the builder reads blocks from and emits phis into. Borrowed:
    /// it must outlive the builder.
    mir: *Mir,
    /// (place, slot) → Value as a two-level place-major table: the place's
    /// `rows` entry names a run of `dir` covering the columns (`slot >>
    /// chunk_bits`) it has cells in, each entry a `chunk_len`-cell chunk of
    /// `cells`, and the cell is `slot`'s low bits within it. A cell holds
    /// `absent` (= 0) where unwritten and `@backingInt(value) + 1` where
    /// written. Chunk 0 is all `absent` and never written: every directory
    /// entry starts on it, so a read needs no presence test.
    ///
    /// The column is a block's `slot`, numbered in order of its first memo
    /// cell, not the block itself: `readFrom` memoizes only in joins, so
    /// keyed by block a place's cells sat one block in three (the arms in
    /// between) and the chunks were 29% full. Numbered by slot they are
    /// 70-77% full, and the map is a third the size (psp103 9.2 → 3.7 MB,
    /// hisimhv_va 13.3 → 5.2 MB): the largest table alive while lowering.
    ///
    /// Two-level, not one dense matrix: a place has cells only between its
    /// definition and its last read. The dense matrix touched each page that
    /// held one cell, and regrowing it copied every row whole, zeros
    /// included, while the old copy was still mapped: a 100 MB transient on
    /// psp103. A hash map cost more in both time and memory. Place-major
    /// because a read climbs predecessor blocks for one fixed place, so
    /// consecutive probes land in one chunk. A run per place, not a dense
    /// directory row of every column: n flattened instances each own places
    /// whose cells sit in their own few columns, and dense rows were
    /// O(places * columns): 6.8 GB peak at 10^5 instances.
    dir: std.ArrayList(u32) = .empty,
    /// Per place, its run of `dir`; a place past the end has none.
    rows: std.ArrayList(Row) = .empty,
    /// The chunks, `chunk_len` cells each, appended as first written.
    cells: std.ArrayList(u32) = .empty,
    /// Slots handed out so far; the next block to need one gets this.
    next_slot: u32 = 0,
    /// The cells of arm blocks (sealed, one predecessor; `arm_slot`): a
    /// short list per block, headed by `BlockState.arm_head`. Only lowering
    /// writes there (an assignment inside an `if` arm), and `climb` after a
    /// climb past `memo_climb` arms, so a slot each would put back the gaps
    /// the slot numbering removes: psp103 has 3396 such cells, hisimhv_va
    /// 6955, a few per arm.
    arm_cells: std.ArrayList(ArmCell) = .empty,
    /// Row per Mir.Block, grown lazily (lower.zig owns block creation).
    block_state: std.MultiArrayList(BlockState) = .empty,
    /// Flat pools; BlockState holds head/tail indices into them.
    pred_pool: std.ArrayList(PredNode) = .empty,
    incomplete_pool: std.ArrayList(IncompletePhi) = .empty,
    /// Phi def-use edges: for a Value, the phis that name it as an operand.
    /// Intrusive list like pred_pool; `user_head` is a dense array parallel to
    /// `Mir.defs` (index = value - first_dynamic), `list_end` = no users.
    /// Only the trivial-phi re-check reads it.
    user_pool: std.ArrayList(UserNode) = .empty,
    user_head: std.ArrayList(u32) = .empty,
    /// Shared phi-operand scratch, used with stack discipline (save length,
    /// restore on exit) so re-entrant lowering needs no per-phi allocation.
    scratch: std.ArrayList(Mir.PhiPair) = .empty,
    /// Trivial-phi worklist, with the same save/restore discipline as `scratch`.
    phi_work: std.ArrayList(Mir.Value) = .empty,
    /// `readFrom`'s explicit stack of joins being read, same discipline.
    joins: std.ArrayList(JoinRead) = .empty,
    /// Places handed out so far (`newPlace`).
    next_place: u32 = 0,
    /// Per block, parallel to `block_state`: its node in the dominator
    /// tree `skipUp` climbs.
    dom: std.ArrayList(Dom) = .empty,
    /// Per place: the `Dom.born` span of the blocks `writeVariable` wrote it
    /// in, but for a sealed block with no predecessor (the entry, where
    /// lowering seeds every place), which no span between two blocks holds.
    written: std.ArrayList(Span) = .empty,
    /// Ticks once per `ensureState` that adds blocks; saturating only
    /// stops the skipping.
    clock: u32 = 0,
    /// Loop headers (blocks that got a successor while unsealed) not sealed
    /// yet: a block sealed meanwhile is inside a loop.
    open_loops: u32 = 0,
    /// Off: Braun's walk alone, which the skip is tested against.
    skip: bool = true,

    /// Per-block SSA state, one row per `Mir.Block`.
    const BlockState = struct {
        /// Braun: sealed ⇒ this block's predecessor set is final.
        sealed: bool = false,
        preds_head: u32 = list_end,
        preds_tail: u32 = list_end,
        /// Kept beside the list so `readFrom`'s single-predecessor
        /// test is a load, not a walk.
        preds_len: u32 = 0,
        /// Phis created before the block was sealed; filled by `sealBlock`.
        phis_head: u32 = list_end,
        /// The block's column in the memo map, fixed at its first cell:
        /// `no_slot` before that, `arm_slot` when its cells are `arm_cells`.
        slot: u32 = no_slot,
        /// The block's first `arm_cells` node, or `list_end`.
        arm_head: u32 = list_end,
        /// Bit `place % 32` set for every place in the block's `arm_cells`:
        /// a climb through an arm skips the list for a place it never wrote.
        arm_mask: u32 = 0,
    };

    /// A block's node in the dominator tree, filled when it is sealed.
    ///
    /// A read that reaches a sealed block with no cell for its place reads
    /// back to the block's immediate dominator: its one predecessor, or
    /// every predecessor of a join. Where nothing wrote the place in
    /// between, that is the dominator's value, so `climb` goes straight
    /// there, and on up while that holds. Without it a place read at the
    /// end of a module climbs every block after its last write, and
    /// memoizes a cell in each join: 10^4 instances, each with an `if`, a
    /// named generate block's exit and its own branch share, took 5.5 s and
    /// 865 MB.
    ///
    /// "Nothing wrote it" compares when blocks got their rows (`born`): a
    /// place whose written blocks were all born before, or all after, every
    /// block between the dominator and this one (`span`) was written in none
    /// of them. A block inside a loop (sealed while a header is open), a
    /// loop header and a block that held an incomplete phi get the span
    /// that holds everything, never skipped: a read there can mint a phi,
    /// and the skip must leave the MIR exactly as Braun's walk does.
    const Dom = struct {
        /// The immediate dominator, or `no_dom` for a root: the entry, or
        /// a block with an unsealed predecessor or predecessors in
        /// different trees (a loop header).
        parent: u32 = no_dom,
        /// An ancestor up to twice as far as the last one (Myers' skew
        /// binary jump pointers): a climb is O(log depth).
        jump: u32 = no_dom,
        depth: u32 = 0,
        /// `clock` when the block got its row.
        born: u32 = 0,
        /// `born` over this block and every block between `parent` and it:
        /// a place written in no block of it ends this block with the value
        /// it ended `parent` with.
        span: Span = .all,
        /// `span` over this block up to, not including, `jump`.
        jspan: Span = .all,
        /// Got a successor while unsealed (`open_loops`).
        header: bool = false,
        /// Held an incomplete phi.
        phi: bool = false,
        /// Has two or more predecessors.
        join: bool = false,
        /// A block from this one up to, not including, `jump` has two or
        /// more predecessors.
        jjoin: bool = false,
    };
    const no_dom: u32 = std.math.maxInt(u32);

    /// An interval of `born` clocks.
    const Span = struct {
        lo: u32,
        hi: u32,
        const all: Span = .{ .lo = 0, .hi = std.math.maxInt(u32) };
        const none: Span = .{ .lo = std.math.maxInt(u32), .hi = 0 };
        fn join(a: Span, b: Span) Span {
            return .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
        }
        /// Every block born in `w` is outside `self`.
        fn misses(self: Span, w: Span) bool {
            return w.hi < self.lo or w.lo > self.hi;
        }
    };

    /// `dir[off..][0..len]` holds columns `base .. base + len`.
    const Row = struct { base: u32 = 0, off: u32 = 0, len: u32 = 0 };

    const PredNode = struct { block: Mir.Block, next: u32 };
    /// One memo cell of an arm block (`raw` as in `cells`).
    const ArmCell = struct { place: Place, raw: u32, next: u32 };
    const IncompletePhi = struct { place: Place, value: Mir.Value, next: u32 };
    const UserNode = struct { phi: Mir.Value, next: u32 };

    // Row budgets: per block (psp103 4,234), per pool node (psp103: 5,682
    // edges, 4,997 phi users, 3,396 arm cells).
    comptime {
        assert(std.MultiArrayList(BlockState).capacityInBytes(1) == 29);
        assert(@sizeOf(PredNode) == 8);
        assert(@sizeOf(IncompletePhi) == 12);
        assert(@sizeOf(UserNode) == 8);
        assert(@sizeOf(ArmCell) == 12);
        // Per block, beside `block_state`; `skipUp` reads 26 of its 36 bytes.
        assert(@sizeOf(Dom) == 36);
        assert(@sizeOf(Row) == 12);
        assert(@sizeOf(JoinRead) <= 32);
    }

    /// Returns an empty builder writing into `mir`, whose rows (phis) `gpa`
    /// allocates. Call `deinit` to free the builder's own tables.
    pub fn init(gpa: std.mem.Allocator, mir: *Mir) SsaBuilder {
        return .{ .gpa = gpa, .mir = mir };
    }

    /// Frees builder scratch only; the MIR it wrote into is untouched.
    pub fn deinit(self: *SsaBuilder) void {
        self.dir.deinit(self.map);
        self.cells.deinit(self.map);
        self.rows.deinit(self.map);
        self.arm_cells.deinit(self.map);
        self.block_state.deinit(self.map);
        self.pred_pool.deinit(self.map);
        self.incomplete_pool.deinit(self.map);
        self.user_pool.deinit(self.map);
        self.user_head.deinit(self.map);
        self.scratch.deinit(self.map);
        self.phi_work.deinit(self.map);
        self.joins.deinit(self.map);
        self.dom.deinit(self.map);
        self.written.deinit(self.map);
        self.* = .{ .gpa = self.gpa, .mir = self.mir, .map = self.map };
    }

    /// Returns a fresh assignable location (a §3.4.4 variable or a lowered
    /// temporary).
    pub fn newPlace(self: *SsaBuilder) Place {
        defer self.next_place += 1;
        return @fromBackingInt(@intCast(self.next_place));
    }

    // ------------------------------------------------------------- CFG edges --

    /// Declares the CFG edge `pred → block` (§5.8, §5.9).
    /// Asserts that `block` is not sealed yet, and that both blocks exist.
    pub fn addPredecessor(self: *SsaBuilder, block: Mir.Block, pred: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        assert(!self.block_state.items(.sealed)[b]); // preds are final once sealed
        const p = try self.ensureState(pred);
        if (!self.block_state.items(.sealed)[p] and !self.dom.items[p].header) {
            self.dom.items[p].header = true;
            self.open_loops += 1;
        }

        const node: u32 = @intCast(self.pred_pool.items.len);
        try self.pred_pool.append(self.map, .{ .block = pred, .next = list_end });
        const tail = self.block_state.items(.preds_tail)[b];
        if (tail == list_end) {
            self.block_state.items(.preds_head)[b] = node;
        } else {
            self.pred_pool.items[tail].next = node;
        }
        self.block_state.items(.preds_tail)[b] = node;
        self.block_state.items(.preds_len)[b] += 1;
    }

    /// Marks a block's predecessors final and fills every incomplete phi.
    /// Idempotent. Filling reads predecessors, which may emit phis into the
    /// Mir and so invalidate its `InstIterator`s. Asserts that `block` exists.
    pub fn sealBlock(self: *SsaBuilder, block: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        if (self.block_state.items(.sealed)[b]) return;
        // Seal FIRST: a recursive read that comes back here while we fill must
        // take the (now final) predecessor path instead of queueing another
        // incomplete phi onto the list we are walking.
        self.block_state.items(.sealed)[b] = true;
        if (self.dom.items[b].header) self.open_loops -= 1;
        self.placeInTree(b);

        var node = self.block_state.items(.phis_head)[b];
        self.block_state.items(.phis_head)[b] = list_end;
        while (node != list_end) {
            const rec = self.incomplete_pool.items[node]; // copy: recursion may realloc
            node = rec.next;
            _ = try self.addPhiOperands(rec.place, rec.value, block);
        }
    }

    // ------------------------------------------------------- read / write --

    /// Records the §5.7 assignment `place := value` in `block`; a later write
    /// to the same pair overwrites it. Asserts that `block` exists and that
    /// `value` is not one of the two highest Value indices (see `pending`).
    pub fn writeVariable(self: *SsaBuilder, place: Place, block: Mir.Block, value: Mir.Value) Error!void {
        const b = try self.ensureState(block);
        const p = @backingInt(place);
        if (p >= self.written.items.len) try self.written.appendNTimes(self.map, .none, p + 1 - self.written.items.len);
        if (!self.block_state.items(.sealed)[b] or self.block_state.items(.preds_len)[b] != 0) {
            const born = self.dom.items[b].born;
            self.written.items[p] = self.written.items[p].join(.{ .lo = born, .hi = born });
        }
        return self.writeCell(place, block, value);
    }

    /// `writeVariable` off the clock: a phi the builder mints names the
    /// value already there, it writes nothing new.
    fn writeCell(self: *SsaBuilder, place: Place, block: Mir.Block, value: Mir.Value) Error!void {
        // see `absent` and `pending`: the +1 bias lands on neither
        assert(@backingInt(value) < std.math.maxInt(u32) - 1);
        const b = try self.ensureState(block);
        const raw = @backingInt(value) + 1;
        const slot = self.slotOf(b);
        if (slot != arm_slot) {
            self.cells.items[try self.cellIndex(place, slot)] = raw;
            return;
        }
        const head = &self.block_state.items(.arm_head)[b];
        var node = head.*;
        while (node != list_end) : (node = self.arm_cells.items[node].next) {
            if (self.arm_cells.items[node].place == place) {
                self.arm_cells.items[node].raw = raw;
                return;
            }
        }
        const new: u32 = @intCast(self.arm_cells.items.len);
        try self.arm_cells.append(self.map, .{ .place = place, .raw = raw, .next = head.* });
        self.block_state.items(.arm_head)[b] = new;
        self.block_state.items(.arm_mask)[b] |= armBit(place);
    }

    /// Returns the value of `place` in `block`, emitting phis as needed. A place
    /// undefined on some path yields `.undef` there; initializing declared
    /// variables (§3.4.4) is the caller's job. The result may be a phi that a
    /// later `sealBlock` collapses: pass it through `Mir.resolveAlias` before
    /// comparing it. A minted phi invalidates the Mir's `InstIterator`s.
    /// Asserts that `block` exists.
    pub fn readVariable(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        _ = try self.ensureState(block);
        return self.readFrom(place, block);
    }

    /// `readVariable` for a block that has a `block_state` row. Every block it
    /// reaches has one too: `addPredecessor` gives each predecessor a row.
    ///
    /// Braun's readVariable/readVariableRecursive recursion, run on an
    /// explicit stack (`joins`): a join being read is a `JoinRead` row, and
    /// the top row reads its predecessors one at a time. The order of reads,
    /// phi emissions and memo writes is the recursion's (depth first, each
    /// join's predecessors in declaration order), so the emitted MIR is the
    /// same; the depth is bounded by memory, not by the native stack
    /// (10,000 sequential `if`s).
    fn readFrom(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        const base = self.joins.items.len;
        defer self.joins.shrinkRetainingCapacity(base);
        var got = try self.climb(place, block);
        while (true) {
            if (got) |v| {
                if (self.joins.items.len == base) return v;
                // The value at the end of the top join's current predecessor.
                const top = self.joins.items[self.joins.items.len - 1];
                try self.scratch.append(self.map, .{ .block = top.pred, .value = v });
            }
            const j = &self.joins.items[self.joins.items.len - 1];
            if (j.node != list_end) {
                const pred = self.pred_pool.items[j.node];
                j.node = pred.next;
                j.pred = pred.block;
                got = try self.climb(place, pred.block); // may push: `j` is stale after
                continue;
            }
            got = try self.finishJoin(self.joins.pop().?);
        }
    }

    /// One join `readFrom` is reading: its cell (marked `pending`), where its
    /// phi pairs start in `scratch`, and its place in the predecessor list.
    const JoinRead = struct {
        block: Mir.Block,
        cell: usize,
        top: usize,
        /// The next predecessor node to read (`list_end` once all are read).
        node: u32,
        /// The predecessor whose value is being read now.
        pred: Mir.Block = undefined,
    };

    /// Climbs from `block` through sealed single-predecessor blocks, which
    /// memoize nothing there: two thirds of Braun's memo writes landed in such
    /// blocks (the arms of every `if`), and skipping them is 4-5% of a compact
    /// model's whole compile (callgrind, psp103/bsim4va/hisimhv_va). Except
    /// after a climb past `memo_climb` blocks: then the value is memoized in
    /// every block it crossed, as Braun would, so the arms of n nested `?:`s,
    /// else-ifs or `if`s, each climbing the chain above it, read in O(n), not
    /// O(n^2) (#29). Returns the value found, or null after pushing a
    /// `JoinRead` for a sealed join whose predecessors must be read first.
    fn climb(self: *SsaBuilder, place: Place, block: Mir.Block) Error!?Mir.Value {
        assert(@backingInt(block) < self.block_state.len);
        const sealed = self.block_state.items(.sealed);
        const preds_len = self.block_state.items(.preds_len);
        const preds_head = self.block_state.items(.preds_head);
        const slots = self.block_state.items(.slot);
        const p = @backingInt(place);
        const w: Span = if (p < self.written.items.len) self.written.items[p] else .none;
        // Set once a skip passed a join, whose `finishJoin` would have
        // returned the value through `resolveAlias`; past single-predecessor
        // blocks alone Braun returns the cell as it is.
        var resolve = false;
        var jumped = false;
        var b = block;
        var steps: u32 = 0;
        while (true) : (steps += 1) {
            const raw = self.cellRaw(place, @backingInt(b), slots[@backingInt(b)]);
            if (raw == pending) {
                // The read came round a cycle (§5.9) into a join whose
                // predecessors are still being read: the join needs a real
                // phi after all. Mint it empty; that join's `finishJoin`
                // fills it.
                const phi = try self.mir.emitPhi(self.gpa, b, &.{});
                try self.writeCell(place, b, phi);
                return phi;
            }
            if (raw != absent) {
                const v: Mir.Value = @fromBackingInt(@intCast(raw - 1));
                // A climb that took a `skipUp` jump is already short; one
                // that walked `memo_climb` single-predecessor blocks memoizes
                // in each of them, so nested arms read in O(n) (#29).
                if (!jumped and steps >= memo_climb) {
                    var m = block;
                    for (0..steps) |_| {
                        try self.writeVariable(place, m, v);
                        m = self.pred_pool.items[preds_head[@backingInt(m)]].block;
                    }
                }
                return if (resolve) self.mir.resolveAlias(v) else v;
            }
            const i = @backingInt(b);
            if (self.skip and sealed[i]) {
                const up = self.skipUp(w, i);
                if (up.to != i) {
                    resolve = resolve or up.join;
                    jumped = true;
                    b = @fromBackingInt(up.to);
                    continue;
                }
            }
            if (!sealed[i] or preds_len[i] != 1) return self.readJoin(place, b);
            b = self.pred_pool.items[preds_head[i]].block;
        }
    }

    /// Braun §readVariableRecursive, for a block `climb` cannot climb: an
    /// unsealed block's incomplete phi, or a sealed join pushed for
    /// `readFrom` to read. Both memoize in the block's cell, which is also
    /// what breaks cycles on the loop path.
    fn readJoin(self: *SsaBuilder, place: Place, block: Mir.Block) Error!?Mir.Value {
        const b = @backingInt(block);
        assert(b < self.block_state.len); // `readVariable` ensured it

        if (!self.block_state.items(.sealed)[b]) {
            // Preds not final yet (loop header, §5.9): incomplete phi, filled by sealBlock.
            const phi = try self.mir.emitPhi(self.gpa, block, &.{});
            const node: u32 = @intCast(self.incomplete_pool.items.len);
            try self.incomplete_pool.append(self.map, .{
                .place = place,
                .value = phi,
                .next = self.block_state.items(.phis_head)[b],
            });
            self.block_state.items(.phis_head)[b] = node;
            self.dom.items[b].phi = true;
            try self.writeCell(place, block, phi);
            return phi;
        }
        assert(self.block_state.items(.preds_len)[b] != 1); // `climb` climbs those
        // ≥2 preds (or 0: an undefined read in a source-less block).
        //
        // Braun emits the phi first and collapses a trivial one by aliasing,
        // which leaves a dead row behind; on a compact model with long `if`
        // chains nearly every phi row was dead. So the cell is marked
        // `pending` instead, and a phi is emitted only when a read cycles
        // back here (`climb` mints it) or the predecessors disagree.
        // An acyclic trivial join gets no row at all.
        //
        // `cell` stays valid across the reads: they may regrow `cells` and
        // the directory, but a chunk keeps its number in both.
        const slot = self.slotOf(b);
        assert(slot != arm_slot); // sealed and not single-predecessor
        const cell = try self.cellIndex(place, slot);
        self.cells.items[cell] = pending;
        try self.joins.append(self.map, .{ .block = block, .cell = cell, .top = self.scratch.items.len, .node = self.predsHead(block) });
        return null;
    }

    /// A join whose predecessors have all been read (their pairs are
    /// `scratch[j.top..]`): its phi, or the one value they agree on.
    fn finishJoin(self: *SsaBuilder, j: JoinRead) Error!Mir.Value {
        defer self.scratch.shrinkRetainingCapacity(j.top);
        const pairs = self.scratch.items[j.top..];
        const now = self.cells.items[j.cell];
        const val = if (now != pending)
            try self.fillPhi(@fromBackingInt(@intCast(now - 1)), pairs)
        else if (sameValue(self.mir, pairs)) |same|
            same
        else blk: {
            const phi = try self.mir.emitPhi(self.gpa, j.block, pairs);
            for (pairs) |p| try self.addUser(p.value, phi);
            break :blk phi;
        };
        assert(@backingInt(val) < std.math.maxInt(u32) - 1); // see `writeVariable`
        self.cells.items[j.cell] = @backingInt(val) + 1;
        return val;
    }

    /// Arms a climb crosses before it memoizes what it found (`climb`). A
    /// shorter climb keeps skipping the memo write, the saving measured above.
    const memo_climb = 64;

    fn armBit(place: Place) u32 {
        return @as(u32, 1) << @truncate(@backingInt(place));
    }

    /// The raw cell of `place` in block row `b`, whose slot the caller has read.
    fn cellRaw(self: *const SsaBuilder, place: Place, b: u32, slot: u32) u32 {
        const p = @backingInt(place);
        if (slot == no_slot) return absent;
        if (slot == arm_slot) {
            if (self.block_state.items(.arm_mask)[b] & armBit(place) == 0) return absent;
            var node = self.block_state.items(.arm_head)[b];
            while (node != list_end) : (node = self.arm_cells.items[node].next) {
                const c = self.arm_cells.items[node];
                if (c.place == place) return c.raw;
            }
            return absent;
        }
        if (p >= self.rows.items.len) return absent;
        const r = self.rows.items[p];
        const at = (slot >> chunk_bits) -% r.base; // wraps past `len` below `base`
        if (at >= r.len) return absent;
        const chunk: usize = self.dir.items[r.off + at];
        return self.cells.items[chunk << chunk_bits | (slot & (chunk_len - 1))];
    }

    /// The cell of (`place`, `block`) without growing anything: a block with
    /// no row reads as absent, like an unwritten cell. Tests only.
    fn defsPeek(self: *const SsaBuilder, place: Place, block: Mir.Block) ?Mir.Value {
        const b = @backingInt(block);
        const v = if (b >= self.block_state.len) absent else self.cellRaw(place, b, self.block_state.items(.slot)[b]);
        assert(v != pending);
        return if (v == absent) null else @fromBackingInt(@intCast(v - 1));
    }

    /// Returns block `b`'s slot, giving it one at its first cell: `arm_slot`
    /// for a sealed single-predecessor block, the next map column otherwise.
    /// Fixed from then on, so the cell is always looked for where it was put;
    /// an unsealed block that ends with one predecessor keeps its column.
    fn slotOf(self: *SsaBuilder, b: u32) u32 {
        const slots = self.block_state.items(.slot);
        if (slots[b] != no_slot) return slots[b];
        const arm = self.block_state.items(.sealed)[b] and self.block_state.items(.preds_len)[b] == 1;
        assert(self.next_slot < arm_slot);
        slots[b] = if (arm) arm_slot else self.next_slot;
        if (!arm) self.next_slot += 1;
        return slots[b];
    }

    /// Index into `cells` of (place, slot), growing the place's run to cover
    /// it and giving the pair's chunk its own cells on first write. A run
    /// grows geometrically toward the column that missed, into a fresh
    /// stretch at the end of `dir` (the old one is left behind: at most the
    /// size of the live runs again). The index stays valid for the builder's
    /// life (chunks are only appended and keep their numbers when a run
    /// moves); a pointer into `cells` does not survive the next new chunk.
    fn cellIndex(self: *SsaBuilder, place: Place, slot: u32) Error!usize {
        assert(slot < arm_slot);
        const p = @backingInt(place);
        const col = slot >> chunk_bits;
        if (self.cells.items.len == 0) try self.cells.appendNTimes(self.map, absent, chunk_len); // chunk 0
        if (p >= self.rows.items.len) try self.rows.appendNTimes(self.map, .{}, p + 1 - self.rows.items.len);
        var r = self.rows.items[p];
        if (col -% r.base >= r.len) {
            const base = if (r.len == 0) col else if (col < r.base) @min(col, r.base -| r.len) else r.base;
            const end = if (r.len == 0) col + 1 else if (col < r.base) r.base + r.len else @max(col + 1, r.base + 2 * r.len);
            const off = self.dir.items.len;
            if (off + (end - base) > std.math.maxInt(u32)) return error.OutOfMemory;
            try self.dir.appendNTimes(self.map, 0, end - base);
            if (r.len != 0) @memcpy(self.dir.items[off + (r.base - base) ..][0..r.len], self.dir.items[r.off..][0..r.len]);
            r = .{ .base = base, .off = @intCast(off), .len = end - base };
            self.rows.items[p] = r;
        }
        const d = r.off + (col - r.base);
        if (self.dir.items[d] == 0) {
            const chunk = self.cells.items.len >> chunk_bits;
            if (chunk > std.math.maxInt(u32)) return error.OutOfMemory;
            try self.cells.appendNTimes(self.map, absent, chunk_len);
            self.dir.items[d] = @intCast(chunk);
        }
        return @as(usize, self.dir.items[d]) << chunk_bits | (slot & (chunk_len - 1));
    }

    /// Braun §addPhiOperands: one operand per predecessor edge, then collapse.
    fn addPhiOperands(self: *SsaBuilder, place: Place, phi: Mir.Value, block: Mir.Block) Error!Mir.Value {
        // One shared scratch used as a stack: this is re-entrant (readVariable
        // recurses back in), and a list per phi would allocate per phi.
        const top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(top);
        // `(pred, place's value at the end of pred)` per edge, in declaration order.
        var node = self.predsHead(block);
        while (node != list_end) {
            const pred = self.pred_pool.items[node]; // copy: recursion may realloc
            node = pred.next;
            const v = try self.readFrom(place, pred.block);
            try self.scratch.append(self.map, .{ .block = pred.block, .value = v });
        }
        return self.fillPhi(phi, self.scratch.items[top..]);
    }

    fn fillPhi(self: *SsaBuilder, phi: Mir.Value, pairs: []const Mir.PhiPair) Error!Mir.Value {
        try self.mir.setPhiPairs(self.gpa, self.mir.valueDef(phi).inst_result, pairs);
        for (pairs) |p| try self.addUser(p.value, phi);
        return self.tryRemoveTrivialPhi(phi);
    }

    /// The one value every pair resolves to (`.undef` for no pairs), or null
    /// when they disagree: `tryRemoveTrivialPhi`'s rule for a phi that does
    /// not exist yet, so there is no self-reference to skip.
    fn sameValue(mir: *const Mir, pairs: []const Mir.PhiPair) ?Mir.Value {
        if (pairs.len == 0) return .undef;
        const first = mir.resolveAlias(pairs[0].value);
        for (pairs[1..]) |p| if (mir.resolveAlias(p.value) != first) return null;
        return first;
    }

    /// Collapse a phi whose operands all resolve to one value (self-references
    /// ignored) to that value. Braun §tryRemoveTrivialPhi.
    ///
    /// Users are rerouted by aliasing, not rewriting: operand lists keep naming
    /// the dead phi and consumers resolve through `Mir.resolveAlias`. Dependent
    /// phis are then re-checked.
    //
    // An explicit worklist, not Braun's recursion: the recursion follows the
    // phi def-use graph, whose depth nothing syntactic bounds. It must match
    // the recursive form exactly, since the alias table decides the emitted
    // bytes:
    //   - Return: the recursion fixes `repl` for the root before descending and
    //     discards every nested result, so returning the first iteration's
    //     result is the same whatever the drain order.
    //   - Order: users are appended in list order and reversed, so the LIFO pops
    //     them head to tail and a popped phi's users drain before its siblings,
    //     the recursion's pre-order DFS. `hasAlias` is tested at pop time, as the
    //     recursion re-tests it after each sibling's subtree. Nothing on this
    //     path calls `addUser`, so `user_pool` cannot move mid-walk.
    //   - Termination: only the branch that just called `setAlias` pushes, and
    //     aliases are never cleared, so each phi pushes its users at most once.
    fn tryRemoveTrivialPhi(self: *SsaBuilder, phi: Mir.Value) Error!Mir.Value {
        // Stack discipline like `scratch`: this runs under re-entrant lowering.
        const top = self.phi_work.items.len;
        defer self.phi_work.shrinkRetainingCapacity(top);

        var root_repl: ?Mir.Value = null;
        var cur = phi; // the root is processed unconditionally, as in the recursion
        while (true) {
            const inst = self.mir.valueDef(cur).inst_result;
            assert(self.mir.instOp(inst) == .phi);

            var same: ?Mir.Value = null;
            const count = self.mir.instData(inst).phi.count;
            var i: u32 = 0;
            const repl = while (i < count) : (i += 1) {
                const op = self.mir.resolveAlias(self.mir.phiPair(inst, i).value);
                if (op == cur) continue; // self-reference (loop back edge)
                if (same) |s| {
                    if (op == s) continue;
                    break cur; // merges ≥2 distinct values ⇒ a real phi
                }
                same = op;
            } else same orelse Mir.Value.undef; // no operands / only self-refs ⇒ undefined

            if (repl != cur) {
                self.mir.setAlias(cur, repl);
                // Queue only the phis that named `cur` as an operand: they may now
                // be trivial. Walking every phi here dominated runtime.
                const mark = self.phi_work.items.len;
                var node = self.userHead(cur);
                while (node != list_end) {
                    const u = self.user_pool.items[node];
                    node = u.next;
                    try self.phi_work.append(self.map, u.phi);
                }
                // ponytail: append-then-reverse, because `user_pool` is singly
                // linked and cannot be walked backwards. Ceiling is one extra
                // pass over one phi's users; if that ever shows up in a profile
                // the fix is a tail pointer per value, not a smarter reversal.
                std.mem.reverse(Mir.Value, self.phi_work.items[mark..]);
            }
            if (root_repl == null) root_repl = repl;

            cur = while (self.phi_work.items.len > top) {
                const u = self.phi_work.pop().?;
                if (!self.mir.hasAlias(u)) break u;
            } else return root_repl.?;
        }
    }

    // ---------------------------------------------------------- internals --

    fn ensureState(self: *SsaBuilder, block: Mir.Block) Error!u32 {
        const i = @backingInt(block);
        assert(i < self.mir.blockCount());
        if (self.block_state.len <= i) {
            assert(self.dom.items.len == self.block_state.len);
            // Both reserved before either grows, so a failure leaves them parallel.
            try self.block_state.ensureTotalCapacity(self.map, i + 1);
            try self.dom.ensureTotalCapacity(self.map, i + 1);
            const born = self.tick();
            while (self.block_state.len <= i) self.block_state.appendAssumeCapacity(.{});
            self.dom.appendNTimesAssumeCapacity(.{ .born = born }, i + 1 - self.dom.items.len);
        }
        return i;
    }

    fn tick(self: *SsaBuilder) u32 {
        if (self.clock < std.math.maxInt(u32)) self.clock += 1;
        return self.clock;
    }

    /// Fills sealed block `b`'s `Dom`. Its immediate dominator is the
    /// nearest common ancestor of its predecessors, and `span` joins the
    /// spans of the blocks the walks there leave behind, each covering the
    /// blocks below it. A predecessor without a tree (unsealed) or in
    /// another tree leaves `b` a root.
    fn placeInTree(self: *SsaBuilder, b: u32) void {
        const sealed = self.block_state.items(.sealed);
        const dom = self.dom.items;
        dom[b].jump = b;
        dom[b].jspan = .none;
        var node = self.block_state.items(.preds_head)[b];
        if (node == list_end) return;
        var a = @backingInt(self.pred_pool.items[node].block);
        if (!sealed[a]) return;
        var span: Span = .{ .lo = dom[b].born, .hi = dom[b].born };
        node = self.pred_pool.items[node].next;
        while (node != list_end) : (node = self.pred_pool.items[node].next) {
            var c = @backingInt(self.pred_pool.items[node].block);
            if (!sealed[c]) return;
            // Level the depths, then climb in step.
            while (a != c) {
                const up_a = dom[a].depth >= dom[c].depth;
                const x = if (up_a) a else c;
                if (dom[x].parent == no_dom) return; // different trees
                span = span.join(dom[x].span);
                if (up_a) a = dom[x].parent else c = dom[x].parent;
            }
        }
        dom[b].parent = a;
        dom[b].depth = dom[a].depth + 1;
        dom[b].join = self.block_state.items(.preds_len)[b] >= 2;
        dom[b].span = if (self.open_loops > 0 or dom[b].header or dom[b].phi) .all else span;
        const j = dom[a].jump;
        const jj = dom[j].jump;
        if (j != a and dom[a].depth - dom[j].depth == dom[j].depth - dom[jj].depth) {
            dom[b].jump = jj;
            dom[b].jspan = dom[b].span.join(dom[a].jspan).join(dom[j].jspan);
            dom[b].jjoin = dom[b].join or dom[a].jjoin or dom[j].jjoin;
        } else {
            dom[b].jump = a;
            dom[b].jspan = dom[b].span;
            dom[b].jjoin = dom[b].join;
        }
    }

    /// The highest ancestor of `b` (itself included) where a place written
    /// in blocks born in `w` ends with the value it has at the end of `b`:
    /// up the tree while each block passed has a `span` `w` misses.
    /// `join`: a block passed has two or more predecessors.
    fn skipUp(self: *const SsaBuilder, w: Span, b: u32) struct { to: u32, join: bool } {
        const dom = self.dom.items;
        var x = b;
        var join = false;
        while (dom[x].parent != no_dom and dom[x].span.misses(w)) {
            if (dom[x].jspan.misses(w)) {
                join = join or dom[x].jjoin;
                x = dom[x].jump;
            } else {
                join = join or dom[x].join;
                x = dom[x].parent;
            }
        }
        return .{ .to = x, .join = join };
    }

    /// Record "`user` (a phi) reads `value`". Sentinels never collapse, so they
    /// get no list.
    fn addUser(self: *SsaBuilder, value: Mir.Value, user: Mir.Value) Error!void {
        const i = @backingInt(value);
        if (i < Mir.Value.first_dynamic) return;
        const slot = i - Mir.Value.first_dynamic;
        if (self.user_head.items.len <= slot) try self.user_head.appendNTimes(self.map, list_end, slot + 1 - self.user_head.items.len);
        const node: u32 = @intCast(self.user_pool.items.len);
        try self.user_pool.append(self.map, .{ .phi = user, .next = self.user_head.items[slot] });
        self.user_head.items[slot] = node;
    }

    fn userHead(self: *const SsaBuilder, value: Mir.Value) u32 {
        const i = @backingInt(value);
        if (i < Mir.Value.first_dynamic) return list_end;
        const slot = i - Mir.Value.first_dynamic;
        if (slot >= self.user_head.items.len) return list_end;
        return self.user_head.items[slot];
    }

    fn predsHead(self: *const SsaBuilder, block: Mir.Block) u32 {
        const b = @backingInt(block);
        if (b >= self.block_state.len) return list_end;
        return self.block_state.items(.preds_head)[b];
    }
};

// -------------------------------------------------------------------------

test "ssa: diamond phi, trivial collapse, loop phi, undefined read" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_selfcheck" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    //        entry
    //        /   \
    //     then   else       (LRM §5.8 conditional)
    //        \   /
    //         join
    const entry = try mir.addBlock(gpa);
    const then_b = try mir.addBlock(gpa);
    const else_b = try mir.addBlock(gpa);
    const join = try mir.addBlock(gpa);

    try b.sealBlock(entry); // no predecessors
    try b.addPredecessor(then_b, entry);
    try b.addPredecessor(else_b, entry);
    try b.sealBlock(then_b);
    try b.sealBlock(else_b);
    try b.addPredecessor(join, then_b);
    try b.addPredecessor(join, else_b);
    try b.sealBlock(join);

    const x = b.newPlace();
    const y = b.newPlace();
    const c1 = try mir.addFloatConst(gpa, 1.0);
    const c2 = try mir.addFloatConst(gpa, 2.0);
    const y0 = try mir.addFloatConst(gpa, 7.0);

    try b.writeVariable(y, entry, y0);
    try b.writeVariable(x, then_b, c1);
    try b.writeVariable(x, else_b, c2);

    // x differs per arm ⇒ a real phi, operands in predecessor-declaration order.
    const xj = try b.readVariable(x, join);
    try std.testing.expectEqual(xj, mir.resolveAlias(xj));
    const x_inst = mir.valueDef(xj).inst_result;
    try std.testing.expectEqual(Mir.Opcode.phi, mir.instOp(x_inst));
    try std.testing.expectEqual(@as(u32, 2), mir.instData(x_inst).phi.count);
    try std.testing.expectEqual(c1, mir.phiPair(x_inst, 0).value);
    try std.testing.expectEqual(then_b, mir.phiPair(x_inst, 0).block);
    try std.testing.expectEqual(c2, mir.phiPair(x_inst, 1).value);

    // y is the same on both arms ⇒ the join is trivial: y0 itself, and no phi
    // row at all (x's is the join's only one).
    const yj = try b.readVariable(y, join);
    try std.testing.expectEqual(y0, yj);
    {
        var it = mir.blockInsts(join);
        try std.testing.expectEqual(x_inst, it.next().?);
        try std.testing.expect(it.next() == null);
    }

    // Reading x again is memoized, not a second phi.
    try std.testing.expectEqual(xj, try b.readVariable(x, join));

    //   join → header ⇄ body        (LRM §5.9 loop: header sealed only after the
    //             ↘ exit             back edge exists)
    const header = try mir.addBlock(gpa);
    const body = try mir.addBlock(gpa);

    const i_pl = b.newPlace();
    const i_init = try mir.addIntConst(gpa, 0);
    try b.writeVariable(i_pl, join, i_init);

    try b.addPredecessor(header, join);
    try b.addPredecessor(body, header);
    try b.sealBlock(body);

    // Read before the header is sealed ⇒ INCOMPLETE phi in the header.
    const iv = try b.readVariable(i_pl, body);
    const i_inst = mir.valueDef(iv).inst_result;
    try std.testing.expectEqual(Mir.Opcode.phi, mir.instOp(i_inst));
    try std.testing.expectEqual(@as(u32, 0), mir.instData(i_inst).phi.count);

    const i_next = try mir.emit(gpa, body, .iadd, &.{ iv, .one });
    try b.writeVariable(i_pl, body, i_next);
    const yb = try b.readVariable(y, body); // loop-invariant ⇒ trivial header phi

    try b.addPredecessor(header, body); // back edge
    try b.sealBlock(header);

    // The induction variable's phi is real: {join: 0, body: i+1}.
    try std.testing.expectEqual(iv, mir.resolveAlias(iv));
    try std.testing.expectEqual(@as(u32, 2), mir.instData(i_inst).phi.count);
    try std.testing.expectEqual(i_init, mir.phiPair(i_inst, 0).value);
    try std.testing.expectEqual(join, mir.phiPair(i_inst, 0).block);
    try std.testing.expectEqual(i_next, mir.phiPair(i_inst, 1).value);
    try std.testing.expectEqual(body, mir.phiPair(i_inst, 1).block);

    // y's header phi is {join: <collapsed join phi>, body: itself} ⇒ collapses,
    // transitively through the already-aliased join phi, all the way to y0.
    try std.testing.expect(yb != y0);
    try std.testing.expectEqual(y0, mir.resolveAlias(yb));

    // Never written anywhere ⇒ undef, not a live phi.
    const z = b.newPlace();
    try std.testing.expectEqual(Mir.Value.undef, mir.resolveAlias(try b.readVariable(z, join)));

    // A read that enters the SEALED loop from below cycles back into the
    // header through the body: the pending header mints its phi, and the phi
    // collapses onto the value from outside the loop.
    const w = b.newPlace();
    const w0 = try mir.addFloatConst(gpa, 3.0);
    try b.writeVariable(w, join, w0);
    const exit = try mir.addBlock(gpa);
    try b.addPredecessor(exit, header);
    try b.sealBlock(exit);
    try std.testing.expectEqual(w0, mir.resolveAlias(try b.readVariable(w, exit)));
}

test "ssa: map growth preserves values, undefined cells and unused rows" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_growth" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    const entry = try mir.addBlock(gpa);
    const x = b.newPlace();
    const y = b.newPlace();
    try b.writeVariable(x, entry, .f_one);
    try b.writeVariable(y, entry, .undef);
    var last = entry;
    const w = b.newPlace();
    for (0..2 * chunk_len) |_| { // a slot per block: grows the slot axis with spare rows
        last = try mir.addBlock(gpa);
        try b.writeVariable(w, last, .f_ten);
    }
    try b.writeVariable(x, last, .f_two);
    try std.testing.expectEqual(Mir.Value.f_one, try b.readVariable(x, entry));
    try std.testing.expectEqual(Mir.Value.undef, try b.readVariable(y, entry));
    try std.testing.expectEqual(Mir.Value.f_two, try b.readVariable(x, last));
    try std.testing.expectEqual(null, b.defsPeek(y, last));

    const z = b.newPlace(); // this row was not copied during block growth
    try std.testing.expectEqual(null, b.defsPeek(z, entry));
    try std.testing.expectEqual(null, b.defsPeek(z, last));
    try b.writeVariable(z, last, .f_neg_one);
    const old_cap = b.rows.items.len + 16;
    while (b.next_place <= old_cap) {
        try b.writeVariable(b.newPlace(), entry, .f_two); // grow the place axis
    }
    try std.testing.expectEqual(Mir.Value.f_one, try b.readVariable(x, entry));
    try std.testing.expectEqual(Mir.Value.undef, try b.readVariable(y, entry));
    try std.testing.expectEqual(Mir.Value.f_two, try b.readVariable(x, last));
    try std.testing.expectEqual(Mir.Value.f_neg_one, try b.readVariable(z, last));
    try std.testing.expectEqual(null, b.defsPeek(z, entry));
    try std.testing.expectEqual(null, b.defsPeek(y, last));
}

test "ssa: an arm block's cells live in arm_cells and the climb finds them" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_arm" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    const entry = try mir.addBlock(gpa);
    const arm = try mir.addBlock(gpa);
    const inner = try mir.addBlock(gpa);
    try b.sealBlock(entry);
    try b.addPredecessor(arm, entry);
    try b.sealBlock(arm);
    try b.addPredecessor(inner, arm);
    try b.sealBlock(inner);

    const x = b.newPlace();
    const y = b.newPlace();
    try b.writeVariable(x, entry, .f_one);
    try b.writeVariable(x, arm, .f_two);
    try b.writeVariable(y, arm, .f_ten);
    try b.writeVariable(x, arm, .f_inf); // overwrites, no second node
    try std.testing.expectEqual(arm_slot, b.block_state.items(.slot)[@backingInt(arm)]);
    try std.testing.expectEqual(@as(usize, 2), b.arm_cells.items.len);
    try std.testing.expectEqual(Mir.Value.f_inf, try b.readVariable(x, inner));
    try std.testing.expectEqual(Mir.Value.f_ten, try b.readVariable(y, inner));
    try std.testing.expectEqual(Mir.Value.f_one, try b.readVariable(x, entry));
}

test "ssa: a sealed block with no predecessor reads undef, and sealing twice is a no-op" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();
    const entry = try mir.addBlock(gpa);
    const orphan = try mir.addBlock(gpa);
    try b.sealBlock(entry);
    try b.sealBlock(entry);
    try b.sealBlock(orphan);
    const x = b.newPlace();
    try b.writeVariable(x, entry, .f_two);
    // `orphan` is unreachable and has no edge from `entry`: nothing defines x.
    try std.testing.expectEqual(Mir.Value.undef, try b.readVariable(x, orphan));
    try std.testing.expectEqual(Mir.Value.f_two, try b.readVariable(x, entry));
    // No phi row was needed for either read.
    try std.testing.expectEqual(@as(usize, 0), mir.insts.len);
}

test "ssa: a short single-predecessor chain is climbed without memo cells, a long one memoizes its path" {
    // `readFrom` climbs sealed single-predecessor blocks in a loop, so a
    // chain costs no stack. One shorter than `memo_climb` writes no cell on
    // the way; a longer one memoizes every block it crossed, so the next
    // read below it climbs one block, not the chain again (#29).
    const gpa = std.testing.allocator;
    for ([_]usize{ SsaBuilder.memo_climb - 1, 10_000 }) |n| {
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        var b = SsaBuilder.init(gpa, &mir);
        defer b.deinit();
        // The dominator skip would jump the whole chain in one step, which
        // memoizes nothing; the memo is for a climb that cannot jump.
        b.skip = false;
        const entry = try mir.addBlock(gpa);
        try b.sealBlock(entry);
        const x = b.newPlace();
        try b.writeVariable(x, entry, .f_ten);
        const cells_before = b.cells.items.len;
        var last = entry;
        for (0..n) |_| {
            const next = try mir.addBlock(gpa);
            try b.addPredecessor(next, last);
            try b.sealBlock(next);
            last = next;
        }
        try std.testing.expectEqual(Mir.Value.f_ten, try b.readVariable(x, last));
        try std.testing.expectEqual(cells_before, b.cells.items.len);
        try std.testing.expectEqual(if (n < SsaBuilder.memo_climb) 0 else n, b.arm_cells.items.len);
        if (n < SsaBuilder.memo_climb) continue;
        // One more block reads its parent's memo: no new cell.
        const tail = try mir.addBlock(gpa);
        try b.addPredecessor(tail, last);
        try b.sealBlock(tail);
        try std.testing.expectEqual(Mir.Value.f_ten, try b.readVariable(x, tail));
        try std.testing.expectEqual(n, b.arm_cells.items.len);
    }
}

test "SsaBuilder.newPlace: places are dense from 0" {
    var mir: Mir = .{};
    defer mir.deinit(std.testing.allocator);
    var b = SsaBuilder.init(std.testing.allocator, &mir);
    defer b.deinit();
    for (0..3) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), @backingInt(b.newPlace()));
}
