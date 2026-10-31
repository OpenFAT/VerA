//! The device's comptime tables: a VerA device type `D` (lib/contract.zig)
//! in, the rows its OSDI descriptor and callbacks are built from out: the
//! §3.4 parameters, the Jacobian entries, the collapsible pairs, and the
//! per-unknown facts (flow, KCL, reactive) every other file reads.
//! Everything here is comptime; nothing is stored per instance.
//!
//! Cites LRM §3.4 (parameters), §9.15 (`$simparam`), §5.4.2 (a switched-off branch's flow
//! collapses), §5.6.5 (collapsible branches, `jac_const` guards), and
//! OpenVAF-Reloaded `osdi_0_4.h` for what an entry and a pair mean.
//!
//! Contents:
//! - `pub const HostField = struct`
//! - `pub const host_fields: [6]HostField`
//! - `pub const max_sim_paras: usize`
//! - `pub fn Tables(comptime D: type) type`
//! - `pub const Tables(D).n, .np, .ni, .has_mf, .num_inst_params, .num_params, .nj, .n_resist, .n_react: comptime_int`
//! - `pub const Tables(D).has_q, .collapses, .has_bp: bool`
//! - `pub const Tables(D).State: type`, `.Val`, `.Dual: type`
//! - `pub const Tables(D).Kind = enum`, `.Param = struct`, `.params: []const Param`
//! - `pub const Tables(D).all_idx: [np]u16`, `.inst_idx: []const u16`
//! - `pub const Tables(D).Entry = struct`, `.entries: []const Entry`
//! - `pub const Tables(D).PairKind = enum`, `.Pair = struct`, `.pairs: []const Pair`
//! - `pub const Tables(D).gens: []const contract.NoiseGen(D)`
//! - `pub fn Tables(D).isFlow(comptime u: usize) bool`
//! - `pub fn Tables(D).shortFlow(comptime u: usize) bool`
//! - `pub fn Tables(D).kcl(comptime i: usize) bool`
//! - `pub fn Tables(D).reactRow(comptime i: usize) bool`
//! - `pub fn Tables(D).entryOf(comptime r: usize, comptime c: usize) u32`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");

/// One `$simparam` a simulator passes (`SimParas.names`) and the `Model`
/// field VerA's device reads it from.
pub const HostField = struct { sim: []const u8, field: []const u8 };

/// The `$simparam`s copied into a device's host fields, where the device
/// has the field (§9.15).
pub const host_fields = [_]HostField{
    .{ .sim = "tnom", .field = "nom_temp__" },
    .{ .sim = "gmin", .field = "gmin__" },
    .{ .sim = "reltol", .field = "reltol__" },
    .{ .sim = "abstol", .field = "abstol__" },
    .{ .sim = "vntol", .field = "vntol__" },
    .{ .sim = "sourceScaleFactor", .field = "source_scale__" },
};

/// The most `$simparam` names a simulator's `SimParas.names` may hold before
/// its NULL (ngspice-45 passes 10, osdiload.c); a longer list is refused,
/// never read past.
pub const max_sim_paras: usize = 256;

/// Every table's comptime budget: the loops below are O(n²) in the unknowns.
const quota = 10_000_000;

/// The comptime tables of device `D`, one namespace per device type.
// Generic over `D` because the dyn protocol hands the device in as a type:
// every table's length is the device's (axis: the device; every device
// VerA emits is a case).
pub fn Tables(comptime D: type) type {
    return struct {
        /// The unknowns: every OSDI node, ports first.
        pub const n = contract.nU(D);
        /// `D.State`, or `void` for a device that carries none.
        pub const State = if (contract.stateClass(D) == .none) void else D.State;
        /// Whether the device has a reactive half (`q`, evaluated as `evalQ`).
        pub const has_q = @hasDecl(D, "q");
        /// Whether the device names its 0 V shorts (`collapse`, and
        /// `collapse_full` for the pairs at comptime). The descriptor then
        /// lists each as an OSDI collapsible pair, the simulator merges the
        /// short's nodes as it does OpenVAF's, and the families say so
        /// (`collapse_applied`): the device drops the short's flow unknown and
        /// its stamps instead of a zero-diagonal branch row per short.
        pub const collapses = @hasDecl(D, "collapse") and @hasDecl(D, "collapse_full");
        /// Whether `pendingBreakpoint` bounds the step (`eval.boundStep`).
        pub const has_bp = State != void and @hasDecl(D, "pendingBreakpoint");

        /// The value-only hooks' family: no lanes.
        pub const Val = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .collapse_applied = collapses });
        /// `eval`'s family: unknown `u` on lane `u`.
        pub const Dual = contract.RefFamily(f64, &lanes, .{ .collapse_applied = collapses });

        /// A parameter's C type.
        pub const Kind = enum { real, int, str };
        /// One §3.4 parameter: its `Model` field and C type.
        pub const Param = struct { field: []const u8, kind: Kind };
        /// The §3.4 parameters: `Model` fields with no `__` (VerA's own
        /// fields all carry one, and a sanitized leaf never does) other than
        /// the setup cache (`su`, `su_ok`), of a real, integer or string type.
        pub const params: []const Param = blk: {
            @setEvalBranchQuota(quota);
            var ps: []const Param = &.{};
            const s = @typeInfo(D.Model).@"struct";
            for (s.field_names, s.field_types) |f, T| {
                if (std.mem.find(u8, f, "__") != null) continue;
                if (std.mem.eql(u8, f, "su") or std.mem.eql(u8, f, "su_ok")) continue;
                const k: Kind = switch (@typeInfo(T)) {
                    .float => .real,
                    .int => .int,
                    else => if (T == []const u8) .str else continue, // else: every other field type is no parameter
                };
                ps = ps ++ [_]Param{.{ .field = f, .kind = k }};
            }
            break :blk ps;
        };
        /// How many parameters: the model card's set.
        pub const np = params.len;
        /// Every parameter, as `params` indices: the model card's set.
        pub const all_idx: [np]u16 = blk: {
            @setEvalBranchQuota(quota);
            var a: [np]u16 = undefined;
            for (&a, 0..) |*x, i| x.* = i;
            break :blk a;
        };
        /// The instance parameters, as `params` indices: the ones the device
        /// marks (`instance_params`, OpenVAF's `type = "instance"`), else every
        /// one, so a device that marks none lets an instance line set any.
        pub const inst_idx: []const u16 = blk: {
            @setEvalBranchQuota(quota);
            if (!@hasDecl(D, "instance_params")) break :blk &all_idx;
            var a: []const u16 = &.{};
            for (params, 0..) |p, i| for (D.instance_params) |f| {
                if (std.mem.eql(u8, p.field, f)) a = a ++ [_]u16{i};
            };
            break :blk a;
        };
        /// How many instance parameters `inst_idx` names.
        pub const ni = inst_idx.len;
        /// Whether `$mfactor` is an instance parameter: `Instance` has
        /// `mfactor`. Its OSDI id is `ni`, after the instance parameters.
        pub const has_mf = @hasField(D.Instance, "mfactor");
        /// The instance-side ids: `inst_idx`, then `$mfactor`.
        pub const num_inst_params = ni + @intFromBool(has_mf);
        /// Every OSDI id: the instance side, then the model side (`params`).
        pub const num_params = num_inst_params + np;

        /// One Jacobian entry: unknown `r`'s row, unknown `c`'s column, and
        /// which halves it has.
        pub const Entry = struct { r: u16, c: u16, resist: bool, react: bool };
        /// The Jacobian entries, row-major: every (row, col) in
        /// `jac_pattern | q_pattern`, plus the `jac_const` and `ac_dyn_slots`
        /// entries, less a 0 V short's flow row and column (`shortFlow`).
        pub const entries: []const Entry = blk: {
            @setEvalBranchQuota(quota);
            var es: []const Entry = &.{};
            for (0..n) |r| for (0..n) |c| {
                // A short's flow unknown always collapses into ground: its row
                // and column reach no matrix slot.
                if (shortFlow(r) or shortFlow(c)) continue;
                const jac_row = if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(u64, 0);
                const q_row = if (@hasDecl(D, "q_pattern")) D.q_pattern[r] else ~@as(u64, 0);
                var e: Entry = .{ .r = r, .c = c, .resist = bit(jac_row, c), .react = has_q and bit(q_row, c) };
                for (contract.jacConst(D)) |j| if (@backingInt(j.row) == r and @backingInt(j.col) == c) {
                    e.resist = e.resist or j.g != 0;
                    e.react = e.react or j.c != 0;
                };
                for (contract.acDynSlots(D)) |s| if (s == r * n + c) {
                    e.resist = true;
                    e.react = true;
                };
                if (e.resist or e.react) es = es ++ [_]Entry{e};
            };
            break :blk es;
        };
        /// How many entries.
        pub const nj = entries.len;
        /// How many entries have a resistive half.
        pub const n_resist = count(.resist);
        /// How many entries have a reactive half.
        pub const n_react = count(.react);

        /// What collapses a pair in `setup_instance`:
        ///   merge      `D.collapse` resolves `from` to `to`: a 0 V short (a
        ///              chain of them) joins the two nodes
        ///   short_flow always, under `collapses`: the family drops the
        ///              short's flow unknown, row and column, in either arm
        ///   dead_flow  `<flow>__retained` = 0: the §5.4.2 branch's
        ///              `V(...) <+` arm is not taken, and `eval` writes
        ///              neither the flow's row nor its column
        pub const PairKind = enum { merge, short_flow, dead_flow };
        /// One OSDI collapsible pair: `from` into `to` (a merge) or into
        /// ground (every other kind; `to` is then unused).
        pub const Pair = struct { from: u16, to: u16, kind: PairKind };
        /// The collapsible pairs. A merge is listed for every root its node can
        /// resolve to (`collapse_full` names the deepest; a card that keeps
        /// part of a chain resolves to a root in between), so exactly the pair
        /// `D.collapse` picks is set, whatever the card.
        pub const pairs: []const Pair = blk: {
            @setEvalBranchQuota(quota);
            var ps: []const Pair = &.{};
            if (collapses) for (0..n) |u| {
                const root = D.collapse_full[u] orelse continue;
                if (isFlow(u)) continue;
                for (0..u) |r| {
                    if (!isFlow(r) and (D.collapse_full[r] orelse r) == root)
                        ps = ps ++ [_]Pair{.{ .from = u, .to = r, .kind = .merge }};
                }
            };
            for (@typeInfo(D.U).@"enum".field_names, 0..) |f, u| {
                if (shortFlow(u)) {
                    ps = ps ++ [_]Pair{.{ .from = u, .to = 0, .kind = .short_flow }};
                } else if (@hasField(D.Model, f ++ "__retained")) {
                    ps = ps ++ [_]Pair{.{ .from = u, .to = 0, .kind = .dead_flow }};
                }
            }
            break :blk ps;
        };

        /// The noise generator rows, one OSDI source each.
        pub const gens: []const contract.NoiseGen(D) = if (@hasDecl(D, "noise_gens")) &D.noise_gens else &.{};

        comptime {
            @setEvalBranchQuota(quota);
            // The u16 rows above hold every unknown.
            assert(n <= std.math.maxInt(u16));
            assert(D.num_ports <= n);
            assert(ni <= np);
            assert(num_params == num_inst_params + np);
            assert(nj <= n * n);
            assert(n_resist <= nj);
            assert(n_react <= nj);
            for (entries) |e| {
                assert(e.r < n);
                assert(e.c < n);
                assert(e.resist or e.react);
            }
            for (pairs) |p| {
                assert(p.from < n);
                if (p.kind == .merge) assert(p.to < p.from);
                if (p.kind == .short_flow) assert(shortFlow(p.from));
            }
            for (gens) |g| {
                assert(g.row < n);
                assert(g.col < n);
            }
        }

        /// Whether unknown `u` is a flow (a `.current`/`.flow` unknown, an
        /// OSDI flow node, ngspice's `CKTmkCur`).
        pub fn isFlow(comptime u: usize) bool {
            comptime assert(u < n);
            return @hasDecl(D, "u_kinds") and D.u_kinds[u] != .voltage;
        }

        /// Whether unknown `u` is a 0 V short's flow, which `collapses` drops.
        pub fn shortFlow(comptime u: usize) bool {
            comptime assert(u < n);
            return collapses and isFlow(u) and D.collapse_full[u] != null;
        }

        /// Whether row `i` is a KCL row: a voltage unknown's.
        pub fn kcl(comptime i: usize) bool {
            comptime assert(i < n);
            return !@hasDecl(D, "u_kinds") or D.u_kinds[i] == .voltage;
        }

        /// Whether `q` writes row `i`.
        pub fn reactRow(comptime i: usize) bool {
            comptime assert(i < n);
            return has_q and bit(if (@hasDecl(D, "q_rows")) D.q_rows else ~@as(u64, 0), i);
        }

        /// The index in `entries` of (row `r`, column `c`). Asserts at
        /// compile time that the entry exists.
        pub fn entryOf(comptime r: usize, comptime c: usize) u32 {
            @setEvalBranchQuota(quota);
            for (entries, 0..) |e, k| if (e.r == r and e.c == c) return k;
            unreachable; // Every caller's (r, c) is in `jac_pattern`, `jac_const` or `ac_dyn_slots`.
        }

        // ---- private ----

        /// Unknown `u` on lane `u`. A `u8` table holds 255 lanes, its maximum
        /// being `no_lane`; a larger device takes `u16`, whose maximum then is.
        const lanes = blk: {
            @setEvalBranchQuota(quota);
            var a: [n]if (n < contract.no_lane) u8 else u16 = undefined;
            for (&a, 0..) |*l, i| l.* = i;
            break :blk a;
        };

        /// Whether `row`, a pattern row, has column `c`: a column past the
        /// row's width is taken as set, as for an undeclared pattern.
        fn bit(row: anytype, c: usize) bool {
            return c >= @bitSizeOf(@TypeOf(row)) or (row >> @intCast(c)) & 1 != 0;
        }

        fn count(comptime half: enum { resist, react }) comptime_int {
            @setEvalBranchQuota(quota);
            var c = 0;
            for (entries) |e| c += @intFromBool(@field(e, @tagName(half)));
            return c;
        }
    };
}
