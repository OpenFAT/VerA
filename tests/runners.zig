//! The runner templates compiled: one emitted runner per variant of
//! `src/codegen/exe/text/*.zig.txt`, each type-checked by `zig` the way its
//! build compiles it, without emitting a binary.
//!
//!   vera-runners DIR CONTRACT INCLUDE (KIND FIXTURE)...   (`test-runners`, in `test`)
//!
//! KIND is the variant a fixture must render, checked before compiling:
//! `fixed` (head, body, big_stack), `mixed` (mixed_head, pwl, mixed_tail,
//! adapter_head/tail, big_stack), `mixed_d2a` (the same with explicit D2A
//! events, mixed_tail's `EventPort` rows) and `vpi` (vpi_head, pwl,
//! vpi_tail, the analog VPI library). The oracle is the compiler: no other
//! step under `test` compiles these templates, and a syntax error in
//! mixed_tail passed `check`, `test-exe` and `test-vpi`.
//!
//! Each runner is rendered as `--emit-exe` (`exe.writeRunner`) or the VPI
//! host (`exe.writeVpiLib`) renders it and built by `zigbuild.buildExe`,
//! with this executable as its `zig`: invoked as `zig build-exe|build-lib
//! ...` it runs the real compiler (`VERA_RUNNERS_ZIG`) with `-fno-emit-bin`
//! in place of `-femit-bin=X` and its own cache (`VERA_RUNNERS_CACHE`, a
//! per-checkout directory build.zig names, so runs reuse it instead of
//! piling up in the shared one), then leaves an empty X for the caller: the
//! argv checked is exactly the one a build uses.

const std = @import("std");
const assert = std.debug.assert;
const vera = @import("vera");
const tb = @import("exe");
const zigbuild = @import("zigbuild");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Kind = enum { fixed, mixed, mixed_d2a, vpi };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and (std.mem.eql(u8, args[1], "build-exe") or std.mem.eql(u8, args[1], "build-lib")))
        return asZig(arena, io, init.environ_map, args);

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};
    if (args.len < 4 or (args.len - 4) % 2 != 0) {
        try w.writeAll("usage: vera-runners DIR CONTRACT INCLUDE (KIND FIXTURE)...\n");
        return 2;
    }
    const dir, const contract, const include = .{ args[1], args[2], args[3] };
    const self = try std.process.executablePathAlloc(io, arena);
    var bad: usize = 0;
    var i: usize = 4;
    while (i < args.len) : (i += 2) {
        const kind = std.meta.stringToEnum(Kind, args[i]) orelse return error.UnknownKind;
        const fixture = args[i + 1];
        const work = try std.fs.path.join(arena, &.{ dir, @tagName(kind) });
        if (try one(init.gpa, io, arena, kind, fixture, contract, include, work, self)) |why| {
            try w.print("BAD {t} {s}: {s}\n", .{ kind, fixture, why });
            bad += 1;
        }
    }
    var out_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    // The census on stdout: `zig build` prints a passing step's stderr as noise.
    const census = if (bad == 0) &stdout.interface else w;
    try census.print("runners: {d} variants compiled, {d} BAD\n", .{ (args.len - 4) / 2, bad });
    try census.flush();
    return if (bad == 0) 0 else 1;
}

/// Renders `fixture`'s runner, checks it is the `kind` variant, and builds
/// it with `zig` = `self`. Null when it compiled, else why not.
fn one(gpa: Allocator, io: Io, arena: Allocator, kind: Kind, fixture: []const u8, contract: []const u8, include: []const u8, work: []const u8, self: []const u8) !?[]const u8 {
    const source = try Io.Dir.cwd().readFileAlloc(io, fixture, arena, .limited(1 << 20));
    const includes: []const []const u8 = &.{ include, std.fs.path.dirname(fixture).? };
    const spec = try tb.Spec.parse(arena, source, null);
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    const settings: vera.Settings = .{ .file_name = fixture, .include_dirs = includes, .require_std_includes = true, .display = .emit };
    var result = try vera.analyze(gpa, source, settings, &bag);
    defer result.deinit(gpa);
    const facts = try tb.compileFacts(arena, result.lowered, result.mir);
    // The fixture must render the variant it stands for, or the step
    // silently stops covering that template.
    const is = if (facts.mixed) |mx| (if (mx.events.len != 0) Kind.mixed_d2a else Kind.mixed) else Kind.fixed;
    if (kind != .vpi and is != kind) return try arena.print("renders the {t} runner, not {t}", .{ is, kind });
    if (kind == .vpi and is != .fixed) return try arena.print("is a {t} design; the VPI library is analog only", .{is});

    var device = try result.generate(gpa, .{ .vpi_contribs = kind == .vpi }, &bag);
    defer device.deinit(gpa);
    if (device.refused) return "codegen refused the device";
    var runner: Io.Writer.Allocating = .init(arena);
    if (kind == .vpi) {
        var vf = facts;
        vf.validate_contract = true;
        try tb.writeVpiLib(&runner.writer, std.fs.path.stem(fixture), &spec.bench, vf);
    } else try tb.writeRunner(&runner.writer, arena, std.fs.path.stem(fixture), &spec.bench, facts);
    const built = try zigbuild.buildExe(gpa, io, device.output.text, runner.written(), .{
        .work_dir = work,
        .contract = contract,
        .name = result.mir.name,
        .zig_exe = self,
        .mixed = facts.mixed != null,
        .shared_lib = kind == .vpi,
    });
    defer built.deinit(gpa);
    return switch (built) {
        .ok => null,
        .failed => |text| try arena.dupe(u8, text),
    };
}

/// `zig build-exe|build-lib ...` as the real compiler with `-fno-emit-bin`
/// and the private cache; an empty binary on success, so the caller's build
/// reads as one. Returns zig's exit code.
fn asZig(arena: Allocator, io: Io, env: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    const zig = env.get("VERA_RUNNERS_ZIG") orelse return error.NoVeraRunnersZig;
    const cache = env.get("VERA_RUNNERS_CACHE") orelse return error.NoVeraRunnersCache;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, zig);
    var bin: ?[]const u8 = null;
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        if (std.mem.cutPrefix(u8, args[k], "-femit-bin=")) |p| {
            bin = p;
            try argv.append(arena, "-fno-emit-bin");
        } else if (std.mem.eql(u8, args[k], "--cache-dir") and k + 1 < args.len) {
            k += 1; // the private cache, below
        } else try argv.append(arena, args[k]);
    }
    const out = bin orelse return error.NoEmitBin;
    try argv.appendSlice(arena, &.{ "--cache-dir", cache });
    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const code: u8 = switch (try child.wait(io)) {
        .exited => |c| c,
        else => 1,
    };
    if (code == 0) try Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = "" });
    return code;
}
