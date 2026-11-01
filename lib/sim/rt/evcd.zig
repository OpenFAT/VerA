//! IEEE 1364-2005 §18.3/§18.4 extended VCD in a native executable: the
//! `$dumpports` calls `emit` resolved at compile time (`File`), and per file
//! what has been written -> the file `digital/evcd.zig` writes. A port's
//! state is read from its net's driver rows in `rt.net`, split at the
//! instance boundary (`Port.inside`, §18.4.3.2). Changes are looked for at
//! the end of every time step (`State.count`, and the run's end), which is
//! where the interpreter's `.vcd_tick` writes them; a step whose ports did
//! not change writes nothing either way.
//!
//! Contents:
//! - `pub const Op`
//! - `pub const Port = struct`
//! - `pub const File = struct`
//! - `pub const Live = struct`
//! - `Dump.len(d: Dump) usize`
//! - `Dump.dir(d: Dump, n: usize) Ast.Direction`
//! - `Dump.width(d: Dump, n: usize) u32`
//! - `Dump.last(d: Dump, n: usize) *[]u8`
//! - `Dump.sides(d: Dump, n: usize, bit: u32) [2]Signal`
//! - `Dump.write(d: Dump, bytes: []const u8) Error!void`
//! - `pub fn select(s: *State, k: u32) Error!void`
//! - `pub fn control(s: *State, op: Op, k: ?u32, size: u64) Error!void`
//! - `pub fn tick(s: *State, at: u64) Error!void`
//! - `pub fn close(s: *State, at: u64) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const State = @import("State.zig");
const Error = design.Error;
const net = @import("net/root.zig");
const dvcd = @import("../digital/vcd.zig");
const devcd = @import("../digital/evcd.zig");
const Signal = @import("../digital/net.zig").Signal;

/// §18.3 the control tasks after `$dumpports`.
pub const Op = devcd.Op;

/// One dumped port (§18.4.2) of a `File`.
pub const Port = struct {
    off: u32,
    width: u32,
    /// Its `rt.net` row; null for an output declared as a variable.
    net: ?u32 = null,
    dir: Ast.Direction,
    /// Per driver of the net, in its row's order: inside the dumped
    /// instance, so the port's output side.
    inside: []const bool = &.{},
};

/// One `$dumpports` call: its file, the call as written, the tick's power
/// of ten, and the `$scope`/`$var port` text of its ports.
pub const File = struct {
    name: []const u8,
    call: []const u8,
    finest: i32,
    header: []const u8,
    ports: []const Port,
};

/// What a run has done with one `File`.
pub const Live = struct {
    selected: bool = false,
    started: bool = false,
    on: bool = true,
    limit: ?u64 = null,
    limited: bool = false,
    pos: u64 = 0,
    last_time: ?u64 = null,
    file: ?std.Io.File = null,
    /// Per port, the state text last written.
    last: [][]u8 = &.{},
};

/// `devcd.writeCheckpoint`'s and `devcd.writeChanges`' view of file `f`
/// (`file` as compiled): each port's sides from `rt.net`'s driver rows,
/// every text from `s.gpa`.
const Dump = struct {
    s: *State,
    f: *Live,
    file: File,
    scratch: std.mem.Allocator,
    keep: std.mem.Allocator,

    /// Returns the number of ports the dump watches.
    pub fn len(d: Dump) usize {
        // `select` sized `last` to the ports; only a selected file is dumped.
        assert(d.f.selected);
        assert(d.f.last.len == d.file.ports.len);
        return d.file.ports.len;
    }
    /// Returns port `n`'s direction.
    pub fn dir(d: Dump, n: usize) Ast.Direction {
        assert(d.f.selected);
        assert(n < d.file.ports.len);
        return d.file.ports[n].dir;
    }
    /// Returns port `n`'s width in bits.
    pub fn width(d: Dump, n: usize) u32 {
        assert(n < d.file.ports.len);
        assert(d.file.ports[n].width != 0); // A port is a net or variable.
        return d.file.ports[n].width;
    }
    /// Returns port `n`'s last written state text, which the caller overwrites.
    pub fn last(d: Dump, n: usize) *[]u8 {
        assert(d.f.last.len == d.file.ports.len);
        assert(n < d.f.last.len);
        return &d.f.last[n];
    }
    /// Bit `bit` of port `n` as its input side and its output side drive it.
    pub fn sides(d: Dump, n: usize, bit: u32) [2]Signal {
        const s = d.s;
        assert(n < d.file.ports.len);
        const p = d.file.ports[n];
        assert(bit < p.width);
        // One side flag per driver row of the net.
        if (p.net) |k| assert(p.inside.len == s.nets.nets[k].drivers.len);
        var in: Signal = .{};
        var out: Signal = .{};
        if (p.net) |k| {
            for (s.nets.nets[k].drivers, p.inside) |di, inside| {
                const c = net.contribution(&s.nets, di, bit);
                if (inside) out = out.combine(c) else in = in.combine(c);
            }
        } else out = .of(net.shown(s, p.off, bit), .strong, .strong);
        return .{ in, out };
    }
    /// Writes `bytes` to the dump's file (`put`).
    pub fn write(d: Dump, bytes: []const u8) Error!void {
        assert(d.f.selected);
        assert(d.f.started); // `tick` created the file first.
        return put(d.s, d.f, d.file, bytes);
    }
};

/// `$dumpports` call `k` runs: its file is written at the end of the step.
/// Asserts that `k` is a compiled call.
pub fn select(s: *State, k: u32) Error!void {
    assert(s.dumps.port_live.len == s.dumps.port_files.len);
    assert(k < s.dumps.port_live.len);
    if (s.quiet) return;
    // "the execution of all $dumpports tasks shall be at the same
    // simulation time" (§18.3.1).
    if (s.dumps.ports_at) |t| if (t != s.sched.now) return s.fail("§18.3.1: every $dumpports shall execute at the same simulation time", .{});
    s.dumps.ports_at = s.sched.now;
    const f = &s.dumps.port_live[k];
    if (f.selected) return s.fail("§18.3.1: the same file_pathname shall not be given to two $dumpports calls", .{});
    f.selected = true;
    f.last = try s.gpa.alloc([]u8, s.dumps.port_files[k].ports.len);
    @memset(f.last, &.{});
    assert(f.last.len == s.dumps.port_files[k].ports.len);
}

/// `$dumpportsoff`, `on`, `all`, `limit` (`size`) or `flush` of file `k`,
/// or of every file when `k` is null (`devcd.task`). Asserts that `k`,
/// when given, is a compiled call, and `op` is no `$dumpports`.
pub fn control(s: *State, op: Op, k: ?u32, size: u64) Error!void {
    assert(op != .ports);
    if (k) |want| assert(want < s.dumps.port_live.len);
    if (s.quiet) return;
    for (s.dumps.port_live, s.dumps.port_files, 0..) |*f, file, i| {
        if (k) |want| if (want != i) continue;
        if (!f.selected) continue;
        switch (op) {
            .ports => unreachable, // `select`
            .limit => f.limit = size,
            .flush => {},
            .off => if (f.started and f.on) {
                try changes(s, f, file, s.sched.now);
                try checkpoint(s, f, file, "$dumpportsoff", true, s.sched.now);
                f.on = false;
            },
            .on => if (f.started and !f.on) {
                f.on = true;
                try checkpoint(s, f, file, "$dumpportson", false, s.sched.now);
            },
            .all => if (f.started and f.on) {
                try changes(s, f, file, s.sched.now);
                try checkpoint(s, f, file, "$dumpportsall", false, s.sched.now);
            },
        }
    }
}

/// The end of the step at tick `at`: each new file's header and
/// `$dumpports` section, and each running file's changes.
pub fn tick(s: *State, at: u64) Error!void {
    assert(s.dumps.port_live.len == s.dumps.port_files.len);
    if (s.quiet) return;
    for (s.dumps.port_live, s.dumps.port_files) |*f, file| {
        if (!f.selected) assert(!f.started); // Only a selected file starts.
        if (!f.selected) continue;
        if (f.started) {
            try changes(s, f, file, at);
            continue;
        }
        f.file = std.Io.Dir.cwd().createFile(s.io, file.name, .{}) catch return s.fail("cannot create the dump file `{s}`", .{file.name});
        f.started = true;
        var w: std.Io.Writer.Allocating = .init(s.gpa);
        defer w.deinit();
        try dvcd.preamble(&w.writer, s.io, file.call, file.finest);
        try w.writer.writeAll(file.header);
        try put(s, f, file, w.written());
        try checkpoint(s, f, file, "$dumpports", false, at);
        assert(f.started);
    }
}

/// The run is over at tick `at`: the step's changes, then §18.3.6.1's
/// `$vcdclose`.
pub fn close(s: *State, at: u64) Error!void {
    assert(s.dumps.port_live.len == s.dumps.port_files.len);
    if (s.quiet or s.dumps.port_live.len == 0) return;
    try tick(s, at);
    for (s.dumps.port_live, s.dumps.port_files) |*f, file| if (f.started) {
        assert(f.selected);
        var buf: [64]u8 = undefined;
        try put(s, f, file, std.mem.print(&buf, "$vcdclose #{d} $end\n", .{at}) catch unreachable);
    };
}

// ---- private ----

fn put(s: *State, f: *Live, file: File, bytes: []const u8) Error!void {
    assert(f.started);
    assert(f.file != null); // `tick` opened it before `started`.
    devcd.writeAt(s.io, f, bytes) catch return s.fail("cannot write the dump file `{s}`", .{file.name});
}

fn checkpoint(s: *State, f: *Live, file: File, keyword: []const u8, as_x: bool, at: u64) Error!void {
    assert(f.started);
    assert(std.mem.startsWith(u8, keyword, "$dumpports"));
    return devcd.writeCheckpoint(Dump{ .s = s, .f = f, .file = file, .scratch = s.gpa, .keep = s.gpa }, keyword, as_x, at);
}

fn changes(s: *State, f: *Live, file: File, at: u64) Error!void {
    assert(f.started);
    assert(f.last.len == file.ports.len);
    return devcd.writeChanges(Dump{ .s = s, .f = f, .file = file, .scratch = s.gpa, .keep = s.gpa }, at);
}
