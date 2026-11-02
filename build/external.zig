//! VerA's output in the reference tools (`test-external`: verilator,
//! iverilog and yosys on `--emit-verilog` and `--emit-rtlil`), and the
//! output checks that need no tool: `--emit-verilog`'s pinned text and
//! refusals, `--emit-so` naming its source, E1013's size refusal. Analog
//! builds only; `build.zig` calls `add` once.
//!
//! Contents:
//! - `pub fn add(g: Graph) void`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;
const Graph = common.Graph;
const byName = common.byName;
const globFiles = common.globFiles;

pub fn add(g: Graph) void {
    const b = g.b;
    const exe = g.exe;
    const test_step = g.test_step;

    // The reference tools of `nix develop .#external`: verilator, iverilog, yosys.
    const external = b.step("test-external", "Reference tools on VerA's output (`nix develop .#external`): --emit-verilog in verilator and iverilog, --emit-rtlil in yosys");
    const vdd_vss = "`ifdef USE_POWER_PINS\n    , vdd\n    , vss\n`endif\n);";
    for ([_]struct { va: []const u8, args: []const []const u8, says: []const u8, supplies: []const u8 = vdd_vss }{
        .{ .va = "strongarm", .args = &.{ "--digital-pins", "clk,outp,outn" }, .says = "parameter real vera_fall_fp = 0.500000; // ns" },
        .{ .va = "async_ctrl", .args = &.{ "--digital-pins", "go adc_done xbar_rst adc_go latch_out done" }, .says = "parameter real vera_rise_s = 48.000000; // ns" },
        .{ .va = "tq_chain", .args = &.{ "--digital-pins", "in,tap1,tap2,tap3,tap4" }, .says = "parameter real vera_rise_m1 = 7.100000; // ns" },
        .{ .va = "attrs", .args = &.{}, .says = "parameter real vera_rise_z = 3.000000; // ns", .supplies = "`ifdef USE_POWER_PINS\n    , pwr\n    , gnd0\n`endif\n);" },
    }) |f| {
        const va = b.path(b.fmt("tests/beh_verilog/{s}.va", .{f.va}));
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "--emit-verilog", "--power-pins", "--allow=W0650" });
        gen.addArgs(f.args);
        gen.addFileArg(va);
        gen.addArg("-o");
        const v = gen.addOutputFileArg(b.fmt("{s}.v", .{f.va}));
        gen.expectExitCode(0);
        test_step.dependOn(&gen.step);
        const pinned = b.addRunArtifact(exe);
        pinned.addArgs(&.{ "--emit-verilog", "--power-pins", "--allow=W0650" });
        pinned.addArgs(f.args);
        pinned.addFileArg(va);
        pinned.addCheck(.{ .expect_stdout_match = f.says });
        pinned.addCheck(.{ .expect_stdout_match = f.supplies });
        test_step.dependOn(&pinned.step);
        for ([_][]const []const u8{ &.{}, &.{"-DUSE_POWER_PINS"} }) |def| {
            const lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wall", "--timing" });
            lint.addArgs(def);
            lint.addFileArg(v);
            lint.expectExitCode(0);
            external.dependOn(&lint.step);
            const comp = b.addSystemCommand(&.{ "iverilog", "-Wall" });
            comp.addArgs(def);
            comp.addArg("-o");
            const vvp = comp.addOutputFileArg(b.fmt("tb_{s}.vvp", .{f.va}));
            comp.addFileArg(v);
            comp.addFileArg(b.path(b.fmt("tests/beh_verilog/tb_{s}.v", .{f.va})));
            comp.expectExitCode(0);
            const sim_run = b.addSystemCommand(&.{ "vvp", "-n" });
            sim_run.addFileArg(vvp);
            sim_run.addCheck(.{ .expect_stdout_match = b.fmt("PASS tb_{s}", .{f.va}) });
            external.dependOn(&sim_run.step);
        }
    }
    {
        const va = b.path("tests/beh_verilog/rc_charge.va");
        const bad = b.addRunArtifact(exe);
        bad.addArgs(&.{ "--emit-verilog", "--allow=W0650", "--digital-pins", "a,y", "--param", "c=inf" });
        bad.addFileArg(va);
        bad.expectExitCode(1);
        bad.expectStdOutEqual("");
        bad.addCheck(.{ .expect_stderr_match = "--emit-verilog: node `y`: its delay is not finite" });
        test_step.dependOn(&bad.step);
        const ok = b.addRunArtifact(exe);
        ok.addArgs(&.{ "--emit-verilog", "--allow=W0650", "--digital-pins", "a,y" });
        ok.addFileArg(va);
        ok.expectExitCode(0);
        ok.addCheck(.{ .expect_stdout_match = "parameter real vera_rise_y = 0.693147; // ns" });
        ok.addCheck(.{ .expect_stdout_match = "parameter real vera_fall_y = 0.693147; // ns" });
        test_step.dependOn(&ok.step);
    }

    // `--emit-rtlil` read back by Yosys itself: `proc` lowers the processes
    // and `check -assert` finds a wire with no driver or two of them.
    for (globFiles(b, "tests/rtlil", ".v")) |v| {
        const gen = b.addRunArtifact(exe);
        gen.addArg("--emit-rtlil");
        gen.addFileArg(b.path(v));
        gen.addArg("-o");
        const il = gen.addOutputFileArg(b.fmt("{s}.il", .{std.fs.path.stem(v)}));
        // Yosys reads the positional `.il` first, then runs the script.
        const yosys = b.addSystemCommand(&.{ "yosys", "-q", "-p", "hierarchy -check -top top; proc; opt_clean; check -assert; stat" });
        yosys.addFileArg(il);
        yosys.expectExitCode(0);
        external.dependOn(&yosys.step);
    }

    // --emit-so must still name the .va when the device fails to compile.
    {
        const wf = b.addWriteFiles();
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--emit-so", "--allow=W0650", "--contract" });
        run.addFileArg(wf.add("contract.zig", "comptime {\n    @compileError(\"broken contract\");\n}\n"));
        run.addArg("--dyn");
        run.addFileArg(wf.add("dyn.zig", "pub fn exportDevice(comptime D: type, comptime name: []const u8) void {\n    _ = D;\n    _ = name;\n}\n"));
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("so", .{});
        run.addFileArg(b.path("tests/conformance/tests/verilog-ams/ch11_vpi/vpi_design.va"));
        run.expectExitCode(1);
        run.expectStdOutEqual("");
        run.addCheck(.{ .expect_stderr_match = "vpi_design.va: codegen produced Zig that does not compile" });
        run.addCheck(.{ .expect_stderr_match = "broken contract" });
        test_step.dependOn(&run.step);
    }

    // E1013: a sparse file one byte past the lexer's u32 offsets is refused from its size.
    if (b.graph.host.result.os.tag != .windows) {
        const mk = b.addSystemCommand(&.{ "dd", "if=/dev/zero", "bs=1", "count=0", "seek=4294967296" });
        const big = mk.addPrefixedOutputFileArg("of=", "big.va");
        _ = mk.captureStdErr(.{});
        for ([_]bool{ false, true }) |netlist| {
            const run = b.addRunArtifact(exe);
            run.setCwd(b.path("."));
            run.addArg("--lint");
            if (netlist) run.addArg("--spice");
            run.addFileArg(big);
            if (netlist) run.addArg("tests/conformance/tests/verilog-a/ch02_lexical/identifier_1024_chars.va");
            run.expectExitCode(2);
            run.addCheck(.{ .expect_stderr_match = "big.va` is larger than 4294967295 bytes" });
            test_step.dependOn(&run.step);
        }
    }
}
