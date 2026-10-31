//! The device/host ABI: a device's declarations in, the comptime interface
//! every generated or hand-written device satisfies and every host compiles
//! against out. `validate(D)` checks a device where it is defined and
//! `validateHost(H, D)` where a host links it, when the program asks for it
//! (`validating`). Physics is generic over a host-supplied scalar family
//! (`family_fns`); `RefFamily` is the reference one and `gm` the f64
//! transcendentals it and GPU kernels share. A member with no consumer yet
//! names the LRM clause that requires it.
//!
//! Hosts compile against this file and the `contract/` directory beside it
//! (installed as `share/vera/contract.zig` and `share/vera/contract/`, and
//! passed to `vera --contract` as this file's path), which import only each
//! other, std, builtin and the program's root (`validating`). This root holds
//! the release stamp, the one mutable table a host writes (`host_strings`),
//! and the re-exports; each name's contract is on its declaration in the file
//! the re-export names.
//!
//! Cites: VAMS-2023 §2.9.2 (`DeclMeta`), §3.4 (shape parameters), §3.6
//! (unknown metadata), §4.5 (operators, `ac_dyn_slots`), §4.6.3/§4.6.4 (AC
//! stimuli, noise and its tables), §5.4-§5.6 (rows, charge sites, collapse),
//! §5.10 (held state), §6.3.6 (`$mfactor`), §9.4/§9.5/§9.7.3 (display
//! records, files, status), §9.15 (`$simparam`), §9.17 (limiting), §12.32
//! (`Systf`).
//!
//! Contents:
//! - `pub const vera_version: []const u8`
//! - `pub var host_strings: []const []const u8`
//! - `pub fn hostString(i: u32, fallback: []const u8) []const u8`
//! - `pub fn validateHost(comptime H: type, comptime D: type) void`
//! - `pub const gm`: the transcendentals namespace (`contract/gm.zig`)
//! - re-exported from `contract/build_config.zig`: `validating`, `DevicePart`
//! - from `contract/display_records.zig`: `StatusSite`, `SaySite`, `Say`,
//!   `SayPass`, `statusCode`, `statusSite`, `formatStatus`, `formatSay`
//! - from `contract/sim_state.zig`: `UpdateResult`, `StateClass`, `StateCtlOp`,
//!   `AnalysisKind`, `SimState`, `SimReads`, `Constant`, `LimitResult`,
//!   `stateClass`, `simReads`, `InstancePtr`
//! - from `contract/metadata.zig`: `UnknownKind`, `DeclMeta`
//! - from `contract/noise.zig`: `NoiseGen`, `NoiseTable`, `PsdTerm`,
//!   `sortNoiseTable`, `noiseTable`, `noiseTableAt`
//! - from `contract/host_callbacks.zig`: `Systf`, `SystfHost`, `FileIo`, `fileIo`
//! - from `contract/ac.zig`: `AcGen`, `AcPhasor`, `acStimActive`, `acDynSlots`
//! - from `contract/masks.zig`: `nU`, `MaskOf`, `Mask`, `derivReads`,
//!   `limitReads`, `limitWrites`, `ddxReads`, `JacConst`, `JacWhen`,
//!   `jacConstApplies`, `jacConst`, `denseMask`, `rowMask`, `siteMask`,
//!   `LaneUse`, `laneMasks`
//! - from `contract/rows.zig`: `QStamp`, `nQ`, `qStamps`, `qLte`, `qRowMask`,
//!   `Rows`, `Sites`, `QRows`, `qRows`, `probes`, `rows`, `sites`
//! - from `contract/family.zig`: `family_fns`, `family_primitives`, `no_lane`,
//!   `RefOptions`, `checkFamily`, `RefFamily`, `denseRow`
//! - from `contract/family_check.zig`: `expectFamily`
//! - from `contract/lead.zig`: `leads`, `instLanes`, `LeadState`,
//!   `leadMergeInto`, `region`
//! - from `contract/validate.zig`: `validate`

const std = @import("std");
const gm_file = @import("contract/gm.zig");
const host = @import("contract/host.zig");
const mocks = @import("contract/mock_devices.zig");
const build_config = @import("contract/build_config.zig");
const display_records = @import("contract/display_records.zig");
const sim_state = @import("contract/sim_state.zig");
const metadata = @import("contract/metadata.zig");
const noise = @import("contract/noise.zig");
const host_callbacks = @import("contract/host_callbacks.zig");
const ac = @import("contract/ac.zig");
const masks = @import("contract/masks.zig");
const rows_file = @import("contract/rows.zig");
const family = @import("contract/family.zig");
const family_check = @import("contract/family_check.zig");
const lead = @import("contract/lead.zig");
const validate_file = @import("contract/validate.zig");

/// The VerA release that generated a device, and that this file ships with
/// (semver; `build.zig.zon`'s `.version`, which a test in `zig build test`
/// holds it equal to, and which `tools/conformance.py` rewrites in this line
/// at a release). A generated device declares
/// `pub const vera_version = "<this>";` and `validateHost` refuses, with a
/// compile error naming both versions, a device whose value is not exactly
/// this one: regenerate it with this VerA. A host that pins a VerA release
/// checks the device it links, `pinned` being the release it supports:
///
///     if (comptime !std.mem.eql(u8, D.vera_version, pinned)) @compileError("regenerate " ++ @typeName(D) ++ " with VerA " ++ pinned);
///
/// A contract change of any kind (an entry point, a published table, a
/// field, a default) ships in a VerA release, and the version a device
/// carries names it: `CHANGELOG.md` under that version says what changed.
/// An additive optional declaration stays optional for a host that checks
/// it with `@hasDecl`. Replaces the integer `abi_version` (last 6) and the
/// device's `contract_abi`, 2026-10-18.
pub const vera_version = "0.20.0";

/// §9.15 Table 9-28 the host's strings: entry i is the text a `Model` index
/// field holding i names (`cwd_idx__`, `analysis_name_idx__`). The host owns
/// the bytes, sets the slice before the first evaluation that reads an index,
/// and does not change it while one runs; entry 0 is never read, since index
/// 0 means "not written". One table per compilation of this file: an
/// in-process host sets it once, and a `--emit-so` library has its own, which
/// the host's `dyn` module sets inside the library (in a split build that
/// exports `eval` from another part, in that part too).
///
/// Only the CPU reads it. On an NVPTX or AMDGCN target `hostString` answers
/// its fallback, so a host keeps a device whose `Model` has `cwd_idx__` on its
/// CPU path when the strings matter to it.
// A mutable global, against the house rule, because it is ABI: generated
// devices read it through `hostString` from every entry point, and a
// parameter would change every entry point's signature (pass 2's call).
pub var host_strings: []const []const u8 = &.{};

/// The transcendentals of every target, the GPU ones included.
pub const gm = gm_file;

pub const validating = build_config.validating;
pub const DevicePart = build_config.DevicePart;
pub const StatusSite = display_records.StatusSite;
pub const SaySite = display_records.SaySite;
pub const Say = display_records.Say;
pub const SayPass = display_records.SayPass;
pub const statusCode = display_records.statusCode;
pub const statusSite = display_records.statusSite;
pub const formatStatus = display_records.formatStatus;
pub const formatSay = display_records.formatSay;
pub const UpdateResult = sim_state.UpdateResult;
pub const StateClass = sim_state.StateClass;
pub const StateCtlOp = sim_state.StateCtlOp;
pub const AnalysisKind = sim_state.AnalysisKind;
pub const SimState = sim_state.SimState;
pub const SimReads = sim_state.SimReads;
pub const Constant = sim_state.Constant;
pub const LimitResult = sim_state.LimitResult;
pub const stateClass = sim_state.stateClass;
pub const simReads = sim_state.simReads;
pub const InstancePtr = sim_state.InstancePtr;
pub const UnknownKind = metadata.UnknownKind;
pub const DeclMeta = metadata.DeclMeta;
pub const NoiseGen = noise.NoiseGen;
pub const NoiseTable = noise.NoiseTable;
pub const PsdTerm = noise.PsdTerm;
pub const sortNoiseTable = noise.sortNoiseTable;
pub const noiseTable = noise.noiseTable;
pub const noiseTableAt = noise.noiseTableAt;
pub const Systf = host_callbacks.Systf;
pub const SystfHost = host_callbacks.SystfHost;
pub const FileIo = host_callbacks.FileIo;
pub const fileIo = host_callbacks.fileIo;
pub const AcGen = ac.AcGen;
pub const AcPhasor = ac.AcPhasor;
pub const acStimActive = ac.acStimActive;
pub const acDynSlots = ac.acDynSlots;
pub const nU = masks.nU;
pub const MaskOf = masks.MaskOf;
pub const Mask = masks.Mask;
pub const derivReads = masks.derivReads;
pub const limitReads = masks.limitReads;
pub const limitWrites = masks.limitWrites;
pub const ddxReads = masks.ddxReads;
pub const JacConst = masks.JacConst;
pub const JacWhen = masks.JacWhen;
pub const jacConstApplies = masks.jacConstApplies;
pub const jacConst = masks.jacConst;
pub const denseMask = masks.denseMask;
pub const rowMask = masks.rowMask;
pub const siteMask = masks.siteMask;
pub const LaneUse = masks.LaneUse;
pub const laneMasks = masks.laneMasks;
pub const QStamp = rows_file.QStamp;
pub const nQ = rows_file.nQ;
pub const qStamps = rows_file.qStamps;
pub const qLte = rows_file.qLte;
pub const qRowMask = rows_file.qRowMask;
pub const Rows = rows_file.Rows;
pub const Sites = rows_file.Sites;
pub const QRows = rows_file.QRows;
pub const qRows = rows_file.qRows;
pub const probes = rows_file.probes;
pub const rows = rows_file.rows;
pub const sites = rows_file.sites;
pub const family_fns = family.family_fns;
pub const family_primitives = family.family_primitives;
pub const no_lane = family.no_lane;
pub const RefOptions = family.RefOptions;
pub const checkFamily = family.checkFamily;
pub const RefFamily = family.RefFamily;
pub const denseRow = family.denseRow;
pub const expectFamily = family_check.expectFamily;
pub const leads = lead.leads;
pub const instLanes = lead.instLanes;
pub const LeadState = lead.LeadState;
pub const leadMergeInto = lead.leadMergeInto;
pub const region = lead.region;
pub const validate = validate_file.validate;

/// Returns `host_strings[i]`, or `fallback` (a device passes the `Instance`
/// field) when `i` is 0 or past the end of the table, and always on a GPU
/// target, whose kernels cannot reach host memory.
pub fn hostString(i: u32, fallback: []const u8) []const u8 {
    if (comptime gm.gpu) return fallback;
    const s = if (i != 0 and i < host_strings.len) host_strings[i] else fallback;
    std.debug.assert(i != 0 or s.ptr == fallback.ptr);
    return s;
}

/// Checks host `H` against what device `D` needs from it, for this
/// contract's `vera_version`: `contract/host.zig`'s `validateHost`, whose
/// doc lists the obligations. The version check always runs; the rest only
/// when `validating`.
pub fn validateHost(comptime H: type, comptime D: type) void {
    host.validateHost(H, D, vera_version);
}

test {
    // Every file of the module, so each one's tests run with this root's.
    _ = gm_file;
    _ = host;
    _ = build_config;
    _ = display_records;
    _ = sim_state;
    _ = metadata;
    _ = noise;
    _ = host_callbacks;
    _ = ac;
    _ = masks;
    _ = rows_file;
    _ = family;
    _ = family_check;
    _ = lead;
    _ = validate_file;
    _ = @import("contract/c_format.zig");
    _ = @import("contract/host_fields.zig");
    _ = @import("contract/validate_entries.zig");
    _ = @import("contract/validate_shape.zig");
    _ = @import("contract/validate_tables.zig");
    _ = @import("contract/gm/arm_exp.zig");
    _ = @import("contract/gm/arm_log.zig");
    _ = @import("contract/gm/arm_pow.zig");
    _ = @import("contract/gm/bits.zig");
    _ = @import("contract/gm/musl.zig");
}

test "validateHost: the device's release is this contract's" {
    const version = vera_version;
    comptime validateHost(struct {}, struct {
        pub const vera_version = version;
    });
}

test "§9.15 Table 9-28 hostString reads the host's table by index; 0 and out of range fall back" {
    const saved = host_strings;
    defer host_strings = saved;
    host_strings = &.{ "", "/run/here", "tran1" };
    try std.testing.expectEqualStrings("/run/here", hostString(1, "inst"));
    try std.testing.expectEqualStrings("tran1", hostString(2, ""));
    // 0 is "not written": the Instance field a host of the old channel wrote.
    try std.testing.expectEqualStrings("inst", hostString(0, "inst"));
    try std.testing.expectEqualStrings("inst", hostString(3, "inst"));
}

test "hostString: an empty table answers every index with the fallback" {
    const saved = host_strings;
    defer host_strings = saved;
    host_strings = &.{};
    try std.testing.expectEqualStrings("fb", hostString(1, "fb"));
}

test "the optional tables' defaults: every lane, no slot, one charge site per row" {
    try std.testing.expectEqual(@as(usize, 0), acDynSlots(mocks.MockR).len);
    try std.testing.expectEqual(~@as(u64, 0), limitReads(mocks.MockR));
    try std.testing.expectEqual(~@as(u64, 0), limitWrites(mocks.MockR));
    try std.testing.expectEqual(~@as(u64, 0), ddxReads(mocks.MockR));
    try std.testing.expect(fileIo(mocks.MockR) == null);
    try std.testing.expect(fileIo(mocks.MockAll) != null);
    try std.testing.expectEqual(2, comptime nQ(mocks.MockR));
    try std.testing.expectEqual([2]bool{ true, true }, qLte(mocks.MockR));
    const lm = laneMasks(mocks.MockR);
    try std.testing.expectEqual(@as(usize, 1), lm.len);
    try std.testing.expectEqual(@as(u64, 0b11), lm[0].mask);
    try std.testing.expect(InstancePtr(mocks.MockR) == *const mocks.MockR.Instance);
    const Mut = struct {
        pub const Instance = struct {};
        pub const mutable_eval = true;
    };
    try std.testing.expect(InstancePtr(Mut) == *Mut.Instance);
}

test "past 64 unknowns a device names every pin in MaskOf(|U|) masks, one lane per diagonal row" {
    comptime validate(mocks.MockWide);
    try std.testing.expect(Mask(mocks.MockWide) == u300);
    try std.testing.expect(MaskOf(3) == u64);
    try std.testing.expectEqual(@as(u300, 1) << 298, comptime rowMask(mocks.MockWide, 298));
    try std.testing.expectEqual(@as(u300, 0), comptime rowMask(mocks.MockWide, 299));
    // A sparse family carries one lane per even row: the cost is per pin.
    const S = RefFamily(f64, &@as([300]u8, @splat(0)), .{});
    var x: [300]f64 = undefined;
    for (&x, 0..) |*v, u| v.* = @floatFromInt(u);
    const r = mocks.MockWide.eval(S, &x, &.{}, &.{}, .{});
    try std.testing.expectEqual(1, @popCount(@TypeOf(r[298]).mask));
    try std.testing.expectEqual(@as(f64, 596), r[298].val());
    try std.testing.expectEqual(@as(f64, 2), r[298].ddxAt(298));
    try std.testing.expectEqual(0, @popCount(@TypeOf(r[299]).mask));
    // A u64 `deriv_reads` past 64 unknowns cannot name them all.
    try std.testing.expect(comptime (masks.derivReadsError(struct {
        pub const deriv_reads: u64 = 1;
    }, 300) != null));
}

test "deriv_reads/jac_const: a linear device needs no lane, and the table is its Jacobian" {
    comptime validate(mocks.MockVsrc);
    // The table is exact, so a unit step on a column moves each row by
    // exactly the entry's `g`, a finite difference with no truncation error,
    // because every term the column enters is linear.
    const m: mocks.MockVsrc.Model = .{};
    const base = [3]f64{ 0.25, -0.5, 2e-3 };
    const Values = RefFamily(f64, &@as([3]u8, @splat(no_lane)), .{});
    const r0: [3]Values.Of(0) = mocks.MockVsrc.eval(Values, &base, &m, &.{}, .{});
    for (0..3) |col| {
        var xs = base;
        xs[col] += 1.0;
        const r1: [3]Values.Of(0) = mocks.MockVsrc.eval(Values, &xs, &m, &.{}, .{});
        for (0..3) |row| {
            var want: f64 = 0;
            for (jacConst(mocks.MockVsrc)) |e| {
                if (@backingInt(e.row) == row and @backingInt(e.col) == col) want = e.g;
            }
            try std.testing.expectEqual(want, r1[row].v - r0[row].v);
        }
    }
}
