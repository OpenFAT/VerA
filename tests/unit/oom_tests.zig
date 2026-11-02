//! L10 fault injection: `checkAllAllocationFailures` over
//! `vera.analyze`, `.lint` on one small positive fixture per chapter and
//! annex directory, `.build` through `Result.generate` on two. Each test fails the n-th
//! allocation for every n the clean compile makes, over an allocator that
//! never grows a block in place (`no_grow`), so the count is the same every
//! run. `BigArena` takes its small blocks from the gpa in chunks, so a
//! failure lands on whichever allocation grew the arena.
//!
//! Oracle: the induced failure surfaces as `error.OutOfMemory` (a success is
//! `SwallowedOutOfMemoryError`, a diagnostic turned refusal escapes as
//! `CompileFailed`), the failed compile frees everything it allocated
//! (`MemoryLeakDetected`), and no other error escapes. No file is written:
//! these run in-process, so "no partial file" is the CLI's half of L10.

const std = @import("std");
const vera = @import("vera");

/// `check.vh` lives here; every fixture below includes nothing else but the
/// built-in annex D files.
const include_dirs: []const []const u8 = &.{@import("repo_options").repo_root ++ "/tests/conformance/tests/include"};

/// How far a compile goes: the analysis (`--lint`), or through codegen too.
const Target = enum { lint, build };

/// `std.testing.allocator` with every in-place growth refused. An arena grows
/// its block in place when the pages after it happen to be free (the backing
/// allocator's `rawResize`; on Linux an `mremap` without MAYMOVE), so whether
/// a compile allocates 19 or 20 times depended on the address space
/// (2026-10-08: {19, 20, 19} over three clean compiles of one fixture).
/// Refused, every growth allocates, and the count is the same every run.
const no_grow: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = struct {
        fn f(_: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(n, a, ra);
        }
    }.f,
    .resize = struct {
        fn f(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
            return n <= m.len and std.testing.allocator.rawResize(m, a, n, ra);
        }
    }.f,
    .remap = struct {
        fn f(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
            return if (n <= m.len) std.testing.allocator.rawRemap(m, a, n, ra) else null;
        }
    }.f,
    .free = struct {
        fn f(_: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(m, a, ra);
        }
    }.f,
} };

// ---- private ----

fn compileOne(gpa: std.mem.Allocator, src: []const u8, target: Target) !void {
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = try vera.analyze(gpa, src, .{
        .include_dirs = include_dirs,
        // `.emit` is the fixture testbench's mode, so `.build` reaches display codegen too.
        .display = if (target == .build) .emit else .drop,
    }, &bag);
    defer res.deinit(gpa);
    if (target == .build) {
        var dev = try res.generate(gpa, .{}, &bag);
        defer dev.deinit(gpa);
        if (dev.refused) return error.CodegenRefused;
    }
}

fn oom(comptime path: []const u8, target: Target) !void {
    const src = @embedFile("../conformance/tests/" ++ path);
    // The sweep assumes every clean compile makes the same allocations; say
    // so by count when one does not, rather than as std's bare
    // NondeterministicMemoryUsage.
    var counts: [3]usize = undefined;
    for (&counts) |*c| {
        var fa: std.testing.FailingAllocator = .init(no_grow, .{});
        try compileOne(fa.allocator(), src, target);
        c.* = fa.alloc_index;
    }
    if (counts[0] != counts[1] or counts[1] != counts[2]) {
        std.debug.print("oom {s}: three clean compiles allocate {any} times\n", .{ path, counts });
        return error.NondeterministicMemoryUsage;
    }
    try std.testing.checkAllAllocationFailures(no_grow, compileOne, .{ src, target });
}

test "OOM .lint ch01_intro" {
    try oom("verilog-a/ch01_intro/reference_ground.va", .lint);
}
test "OOM .lint ch02_lexical" {
    try oom("verilog-a/ch02_lexical/operator_arity.va", .lint);
}
test "OOM .lint ch03_data_types" {
    try oom("verilog-a/ch03_data_types/nature_compatibility_rules.va", .lint);
}
test "OOM .lint ch04_expressions" {
    try oom("verilog-a/ch04_expressions/parameter_reduction_and_arithmetic_shift.va", .lint);
}
test "OOM .lint ch05_analog_behavior" {
    try oom("verilog-a/ch05_analog_behavior/port_flow_includes_the_reactive_part.va", .lint);
}
test "OOM .lint ch06_hierarchy" {
    try oom("verilog-a/ch06_hierarchy/paramset_selected_after_generate.va", .lint);
}
test "OOM .lint ch07_mixed_signal" {
    try oom("verilog-ams/ch07_mixed_signal/mixed_signal_smallest_abstol.va", .lint);
}
test "OOM .lint ch08_scheduling" {
    try oom("verilog-a/ch08_scheduling/shared_conservative_node.va", .lint);
}
test "OOM .lint ch09_system_tasks" {
    try oom("verilog-a/ch09_system_tasks/control_default_filling.va", .lint);
}
test "OOM .lint ch10_directives" {
    try oom("verilog-a/ch10_directives/default_transition_ramp.va", .lint);
}
test "OOM .lint ch11_vpi" {
    try oom("verilog-ams/ch11_vpi/vpi_design.va", .lint);
}
test "OOM .lint ch12_vpi_routines" {
    try oom("verilog-ams/ch12_vpi_routines/rc_ac.va", .lint);
}
test "OOM .lint annex_a_syntax" {
    try oom("verilog-a/annex_a_syntax/expression_primaries.va", .lint);
}
test "OOM .lint annex_b_keywords" {
    try oom("verilog-a/annex_b_keywords/escaped_keyword_port.va", .lint);
}
test "OOM .lint annex_c_analog_subset" {
    try oom("verilog-a/annex_c_analog_subset/compiler_directives.va", .lint);
}
test "OOM .lint annex_d_standard_definitions" {
    try oom("verilog-a/annex_d_standard_definitions/thermal_definitions.va", .lint);
}
test "OOM .lint annex_e_spice" {
    try oom("spice/primitive_mesfet.va", .lint);
}
test "OOM .lint annex_f_resolution" {
    try oom("verilog-ams/annex_f_resolution/resolveto_resolution.va", .lint);
}
test "OOM .lint annex_g_change_history" {
    try oom("verilog-a/annex_g_change_history/transition_fall_time_binding.va", .lint);
}
test "OOM .lint annex_h_glossary" {
    try oom("verilog-a/annex_h_glossary/node_port_terminal.va", .lint);
}
test "OOM .build ch05_analog_behavior (codegen)" {
    try oom("verilog-a/ch05_analog_behavior/port_flow_includes_the_reactive_part.va", .build);
}
test "OOM .build annex_e_spice (codegen)" {
    try oom("spice/primitive_mesfet.va", .build);
}
