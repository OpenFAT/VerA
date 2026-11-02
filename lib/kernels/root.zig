//! The `kernels` module: the runtime numerics a generated device carries as
//! source text, and the host-only operator semantics the compiler, `sim` and
//! the digital engine share. Kernel source in, two consumers of the same
//! bytes out: `text`, which `codegen/kernel_text.zig` splices into a device,
//! and the same files compiled here as ordinary Zig for the hosts that run
//! the numerics outside a device, so what a test checks is what a device
//! runs. Beside them sit the host-only files, never spliced: `integer*.zig`
//! (four-state literals, judged by `ref4.zig`), `fold.zig` and `fmt.zig`.
//! Cites: VAMS §2.6.1, §2.7, §3.2, §4.2, §4.3, §4.5, §4.5.7, §4.5.11,
//! §4.5.12, §4.5.15, §5.10.3.3, §7.3.1, §9.4.1, §9.4.3, §9.5, §9.13, §9.21;
//! IEEE 1364-2005 §5, §17.1, §17.2, §17.9.3.
//!
//! A device-text file is a `//!` header, its imports, the line
//! `// ---- device text ----`, then the text. `text.*` is that text behind a
//! provenance comment line, a blank line and the file's private `std` alias:
//! a `//!` header cannot sit mid-file, and a device declares its own `std`.
//! The rules a device-text file keeps, because its bytes are device text:
//!  - it names `std` only by its alias (`zstd`, `zfstd`, ...) and reaches no
//!    other module but `contract` and `builtin`;
//!  - it holds no `test` block (its tests are `tests/unit.zig`'s
//!    `kernel_tests`), and its comments ship in every device that embeds it;
//!  - a name an emitted body calls is `z` plus an uppercase letter, and an
//!    internal name is not (`kernel_text.appendAliases` aliases the former).
//!
//! Each device-text file is one data domain and owns only the state it
//! declares: `Instance`/`Model` fields holding filter, timer, history and
//! rng state are codegen's, and the kernels read and write the slots they
//! are passed.
//!
//! Contents:
//! - `pub const vera_version`
//! - `pub const str_scan`, `str_real`, `str_format`, `str_store`, `table_kernels`, `rng_kernels`, `filter_kernels`, `file_kernels`, `file_table`, `limit_kernels`, `timer_kernels`, `hist_kernels`, `wide_kernels`, `ops_kernels`
//! - `pub const Integer`, `fmt`, `fold`
//! - `pub const fopen_types: std.StaticStringMap(void)`
//! - `pub const text = struct { str, table, rng, filter, file, limit, timer, hist, wide, ops }`

const std = @import("std");

/// `lib/contract.zig`'s `vera_version`, re-exported for `device`, which
/// cannot import `contract` itself: codegen stamps it into every device.
pub const vera_version = @import("contract").vera_version;

/// §9.5.4.2 `$sscanf`/`$fscanf` scanning.
pub const str_scan = @import("str_scan.zig");
/// §9.4.3 Table 9-23 real conversions (`zCReal`, the `zc_*` flags); also the
/// digital engine's `%e/%f/%g`.
pub const str_real = @import("str_real.zig");
/// §9.5.3 a run-time format string (`zSFormatRt`).
pub const str_format = @import("str_format.zig");
/// §3.3 string storage: per-site rows, held strings, concatenation,
/// replication, E1011, and §9.4.1's `$monitor` latch.
pub const str_store = @import("str_store.zig");
/// §9.21 `$table_model` interpolation.
pub const table_kernels = @import("table_kernels.zig");
/// §9.13 probabilistic distributions; also elaboration's literal folds
/// (`elab/clone.zig`) and the digital engine's IEEE 1364 §17.9 `$dist_*`.
pub const rng_kernels = @import("rng_kernels.zig");
/// §4.5.11/§4.5.12 filter numerics.
pub const filter_kernels = @import("filter_kernels.zig");
/// §9.5 file-descriptor I/O; also the digital engine's IEEE 1364 §17.2
/// descriptor table when no host shares one (`sim/digital/system.zig`
/// `own`). The table is process-global: every caller in one process shares
/// its channels.
pub const file_kernels = @import("file_kernels.zig");
/// §9.5 the descriptor table itself, over a caller's allocator and `Io`.
pub const file_table = @import("file_table.zig");
/// §4.5.15 SPICE limiting functions.
pub const limit_kernels = @import("limit_kernels.zig");
/// §5.10.3.3 absolute timer scheduling, also the mixed coordinator's.
pub const timer_kernels = @import("timer_kernels.zig");
/// §4.5.7 the absdelay ring and its thinning.
pub const hist_kernels = @import("hist_kernels.zig");
/// IEEE 1364 §5.4 integers of any width (`analog/wide.zig`'s trees).
pub const wide_kernels = @import("wide_kernels.zig");
/// §4.5 the analog operator kernels (`zIdt`, `zSlew`, `zTransition`, ...):
/// device text only, every function private.
pub const ops_kernels = @import("ops_kernels.zig");

/// §2.6.1 integer literals and the IEEE 1364-2005 §5 four-state operations
/// on them: the one reference every engine's operators are judged by
/// (`ref4.zig` checks it). Host Zig, not device text.
pub const Integer = @import("integer.zig");
/// IEEE 1364-2005 §17.1 value and time text over `Integer` literals, shared
/// by the digital interpreter and a native executable (`sim`). Host Zig.
pub const fmt = @import("fmt.zig");
/// The §4.2 value folds (`Const`, `unary`, `binary`, `math`, `wrap32`,
/// `ipow32`, `clog2`, `strToInt`) and the A.8.6 operator enums they take:
/// one answer for a parameter default (`frontend.constfold`) and a folded
/// MIR opcode (`ir.opcode`). Host Zig.
pub const fold = @import("fold.zig");

/// §9.5.1 Table 9-24's `$fopen` type strings, the fifteen of IEEE 1364-2005
/// §17.2.1 Table 17-7: one list for lowering's E0889 and the digital engine's
/// `$fopen` (`sim/digital/system.zig` `fileType`). Host Zig.
pub const fopen_types = std.StaticStringMap(void).initComptime(.{
    .{"r"},   .{"rb"}, .{"w"},   .{"wb"},  .{"a"},  .{"ab"},  .{"r+"},  .{"r+b"},
    .{"rb+"}, .{"w+"}, .{"w+b"}, .{"wb+"}, .{"a+"}, .{"a+b"}, .{"ab+"},
});

/// Each kernel group's device text, for `codegen/kernel_text.zig` to splice
/// into a device (`@embedFile` reaches only files under its own module's
/// root). Each begins with one provenance comment line and a blank line,
/// then the group's `std` alias, and ends with a newline.
pub const text = struct {
    pub const str = deviceText(
        "zstd",
        &.{ "str_store.zig", "str_real.zig", "str_format.zig", "str_scan.zig" },
        &.{ @embedFile("str_store.zig"), @embedFile("str_real.zig"), @embedFile("str_format.zig"), @embedFile("str_scan.zig") },
    );
    pub const table = deviceText("ztstd", &.{"table_kernels.zig"}, &.{@embedFile("table_kernels.zig")});
    pub const rng = deviceText("zrstd", &.{"rng_kernels.zig"}, &.{@embedFile("rng_kernels.zig")});
    pub const filter = deviceText("zqstd", &.{"filter_kernels.zig"}, &.{@embedFile("filter_kernels.zig")});
    pub const file = deviceText("zfstd", &.{ "file_table.zig", "file_kernels.zig" }, &.{ @embedFile("file_table.zig"), @embedFile("file_kernels.zig") });
    pub const limit = deviceText("zlstd", &.{"limit_kernels.zig"}, &.{@embedFile("limit_kernels.zig")});
    pub const timer = deviceText("ztm", &.{"timer_kernels.zig"}, &.{@embedFile("timer_kernels.zig")});
    pub const hist = deviceText("zhs", &.{"hist_kernels.zig"}, &.{@embedFile("hist_kernels.zig")});
    pub const wide = deviceText("zwstd", &.{"wide_kernels.zig"}, &.{@embedFile("wide_kernels.zig")});
    pub const ops = deviceText("zostd", &.{"ops_kernels.zig"}, &.{@embedFile("ops_kernels.zig")});
};

/// The line that ends a device-text file's host-only preamble.
const device_marker = "// ---- device text ----\n";

// ---- private ----

/// One group's device text: a provenance line naming `names`, the `std`
/// alias, then each of `srcs` past its marker, in order.
fn deviceText(comptime alias: []const u8, comptime names: []const []const u8, comptime srcs: []const []const u8) []const u8 {
    comptime {
        std.debug.assert(names.len == srcs.len);
        std.debug.assert(srcs.len >= 1);
        @setEvalBranchQuota(1_000_000);
        var out: []const u8 = "// Device text of lib/kernels/";
        for (names, 0..) |name, i| out = out ++ (if (i == 0) "" else ", ") ++ name;
        out = out ++ ".\n\nconst " ++ alias ++ " = @import(\"std\");\n";
        for (srcs, names) |src, name| {
            const at = std.mem.find(u8, src, device_marker) orelse
                @compileError("lib/kernels/" ++ name ++ " has no `" ++ device_marker[0 .. device_marker.len - 1] ++ "` line");
            // The preamble declares the alias; the text must not again.
            if (std.mem.find(u8, src[at..], "const " ++ alias ++ " = @import(") != null)
                @compileError("lib/kernels/" ++ name ++ " imports `std` past its device-text marker");
            out = out ++ src[at + device_marker.len ..];
        }
        std.debug.assert(out[out.len - 1] == '\n');
        const result = out;
        return result;
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = Integer;
    _ = fmt;
    _ = fold;
    // The four-state reference `Integer` is judged by.
    _ = @import("ref4.zig");
}

test "text: each group's text starts with its provenance line and its alias, past every `//!` header" {
    inline for (.{ text.str, text.table, text.rng, text.filter, text.file, text.limit, text.timer, text.hist, text.wide, text.ops }) |t| {
        try std.testing.expect(std.mem.startsWith(u8, t, "// Device text of lib/kernels/"));
        // `deviceText`'s layout: the provenance line, a blank line, then the
        // alias; `kernel_text` splices the text whole, so nothing may precede it.
        const cut = t[std.mem.find(u8, t, "\n\n").? + 2 ..];
        try std.testing.expect(std.mem.startsWith(u8, cut, "const z"));
        try std.testing.expect(std.mem.find(u8, t, "//!") == null);
        try std.testing.expect(std.mem.find(u8, t, device_marker) == null);
        try std.testing.expect(std.mem.find(u8, t, "\ntest ") == null);
    }
}
