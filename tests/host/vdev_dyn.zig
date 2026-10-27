//! A `.v` contract device's transient as one C-ABI call: the `--dyn` host
//! `vera --emit-so` builds it under (`exportDevice`, exporting `vdev_run`),
//! and the same code over a statically imported device (`Run`), so
//! `tests/host/vdev_so_host.zig` can compare a device linked against the prebuilt
//! engine (`sim/rt/engine.zig`) with one that compiles the whole engine.
//! The transient takes `steps` points 1 ns apart, every input a 0/5 V
//! square wave of period 20 ns, runs `updateState` and commits each, and
//! hashes every output level, ramp end and next event the device keeps.
const contract = @import("contract");

/// The `--dyn` hook `vera --emit-so` calls: exports `Run(D).run` as the C
/// symbol `vdev_run`. `name` is the hook's, unused here.
pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    @export(&Run(D).run, .{ .name = "vdev_run" });
}

/// The transient over device `D`, as a namespace with one `run`.
pub fn Run(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const V = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{});

        /// Runs `steps` committed points and returns the FNV-1a hash of every
        /// output level, ramp end and next event after each; `run(0)` is the
        /// FNV offset basis, which `vdev_so_host.zig` refuses as "ran nothing".
        pub fn run(steps: u64) callconv(.c) u64 {
            const m: D.Model = .{};
            var inst: D.Instance = .{};
            var st = D.initState(&m, &inst);
            var h: u64 = 0xcbf29ce484222325;
            var k: u64 = 1;
            while (k <= steps) : (k += 1) {
                const x: [n]f64 = @splat(if ((k / 10) % 2 == 0) 0 else 5);
                const sim: contract.SimState = .{ .kind = .tran, .t = @as(f64, @floatFromInt(k)) * 1e-9, .dt = 1e-9, .analog_initial = false };
                _ = D.updateState(V, &m, &inst, x, &st, sim);
                _ = D.stateCtl(&m, &inst, &st, .commit);
                for (inst.lvl_to ++ inst.lvl_t1) |v| h = (h ^ @as(u64, @bitCast(v))) *% 0x100000001b3;
                h = (h ^ @as(u64, @bitCast(inst.next_ev))) *% 0x100000001b3;
            }
            return h;
        }
    };
}
