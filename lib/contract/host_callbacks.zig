//! What a host lends a device to call back into in, the contract of those
//! function-pointer tables out: the §12.32 VPI application behind every
//! `$name` the compiler could not resolve (`Systf`, `SystfHost`), and the
//! §9.5 descriptor table a mixed simulation's second context shares
//! (`FileIo`). Also the rule `validate` applies to `systf_calls`.
//! Cites: VAMS-2023 §2.8.3 (unresolved system tasks), §12.22.1-§12.22.2
//! (calltf, derivtf, output arguments), §12.30, §12.32 (analog systf
//! registration), §9.5.1-§9.5.1.2 (descriptors shared across contexts),
//! §9.5.7 (`$ferror`).
//!
//! Contents:
//! - `pub const Systf = struct`
//! - `pub const SystfHost = struct`, with `pub fn output`
//! - `pub const FileIo = struct`
//! - `pub fn fileIo(comptime D: type) ?FileIo`
//! - `pub fn systfError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;

/// §2.8.3/§12.32 one call of a `$name` the compiler could not resolve, left
/// to a VPI application. Position k of `systf_calls` is what
/// `SystfHost.call(ctx, k, ...)` answers. One entry per source call, so two
/// calls of one `$name` are two entries with that name: a host binds the
/// application by name (`vpi_register_analog_systf()` registers names) and
/// tells the calls apart by k, as §12.32.1's `vpi_handle(vpiSysTfCall, NULL)`
/// must.
pub const Systf = struct {
    /// `$sampnhold`, with the `$`. §12.32: "first character shall be `$`".
    name: []const u8,
    /// The source token of the call, in the token stream the compiler lexed:
    /// a host that parsed the same source (VerA's VPI host) matches its call
    /// object by it. `maxInt(u32)` when the call has no source token.
    tok: u32 = std.math.maxInt(u32),
    /// §12.22.2 the arguments the device reads back after the call, bit
    /// j - 1 for argument j: each is a variable, and its new value is what
    /// `SystfHost.output` answers.
    outs: u64 = 0,
    /// The call is a system task (§2.8.3 `$name(...);`, a statement), not a
    /// function in an expression, so the device discards what `call`
    /// returns. A host refuses by this a registration whose type does not
    /// match (§12.32.1 `vpiAnalogSysTask` / `vpiAnalogSysFunc`) without
    /// re-parsing the source. Only a task has `outs`.
    task: bool = false,
};

/// The VPI application as the device sees it. The host owns it and writes a
/// pointer into `Instance.systf`; `validateHost` requires a binding for every
/// device that declares `systf_calls`. The call returns a value and its
/// partials (§12.22.1, §12.32 `derivtf`) rather than a family value, because a
/// function pointer cannot be generic over the family.
pub const SystfHost = struct {
    /// The application's own state (`s_vpi_analog_systf_data.user_data`).
    /// One `SystfHost` per instance when the application keeps state per
    /// call, so `ctx` can name the instance: VerA's `vpi` module keys a
    /// calltf's user data and outputs by the instance a host passes to
    /// `vpi.analog_run.Binding.call` (VerA #84).
    ctx: *anyopaque,
    /// §12.32 `calltf` and §12.22.1 `derivtf` in one call: returns the value
    /// of `systf_calls[k]` at `args` and writes d(value)/d(args[j]) into
    /// `partials[j]`. `partials.len == args.len` and it is not zeroed on
    /// entry, so the callee must write every slot.
    call: *const fn (ctx: *anyopaque, k: usize, args: []const f64, partials: []f64) f64,
    /// §12.22.2/§12.30 argument j (1-based) of `systf_calls[k]` after its
    /// latest `call`, for an argument in that entry's `outs`: the value
    /// calltf put on it, with d(it)/d(args[i]) in `partials[i]` (§12.32.2,
    /// zero where none was put). `args` are that call's. Null: the
    /// application puts no argument. Read it through `output`.
    out: ?*const fn (ctx: *anyopaque, k: usize, j: usize, args: []const f64, partials: []f64) f64 = null,

    /// `out`, or, when it is null, argument j unchanged: the value an
    /// argument calltf did not put keeps (`args[j - 1]`, partial 1 on itself
    /// and 0 elsewhere). Writes every slot of `partials`.
    /// Asserts that `j` is 1-based and in range (1 <= j <= `args.len`) and
    /// that `partials.len == args.len`.
    pub fn output(h: *const SystfHost, k: usize, j: usize, args: []const f64, partials: []f64) f64 {
        assert(j >= 1);
        assert(j <= args.len);
        assert(partials.len == args.len);
        if (h.out) |f| return f(h.ctx, k, j, args, partials);
        @memset(partials, 0);
        partials[j - 1] = 1;
        assert(partials[j - 1] == 1);
        return args[j - 1];
    }
};

/// The device's §9.5 descriptor table, for a host whose second context (a
/// mixed simulation's digital half) must share it (§9.5.1.2). The host routes
/// that context's file tasks through these, so a descriptor names the same
/// channel in both, with §9.5.1's encodings (an mcd has bit 31 clear, an fd bit
/// 31 set). `put` writes already-formatted text. Declared only by a printing
/// artifact that calls the §9.5 family.
pub const FileIo = struct {
    open: *const fn (path: []const u8, ty: []const u8, mcd: bool) i64,
    close: *const fn (d: i64) i64,
    put: *const fn (d: i64, text: []const u8) i64,
    getc: *const fn (d: i64) i64,
    ungetc: *const fn (c: i64, d: i64) i64,
    tell: *const fn (d: i64) i64,
    seek: *const fn (d: i64, off: i64, op: i64) i64,
    eof: *const fn (d: i64) i64,
    /// §9.5.7 `$ferror`'s code for the most recent operation on `d`, or on
    /// the failed open that returned `d` = 0. Optional: without it every
    /// `$ferror` answers 0, "no error".
    err: ?*const fn (d: i64) i64 = null,
    /// §9.5.1.1: a host running several analyses in one process calls this
    /// at the first point of each analysis after the first, so a file one
    /// analysis opened "w" and a later one reopens "w" is appended to rather
    /// than truncated. Optional: a one-analysis host never calls it.
    new_analysis: ?*const fn () void = null,
};

/// Returns the device's `file_io`, or null when it has no descriptor table.
pub fn fileIo(comptime D: type) ?FileIo {
    return if (@hasDecl(D, "file_io")) D.file_io else null;
}

/// Why `D.systf_calls` breaks §2.8.3/§12.32, or null: every name starts
/// with `$` (§12.32 "first character shall be `$`"), only a task has
/// output arguments (§12.22.2 reads back a task's variables; a function's
/// value is its result), and a device with a call has the `Instance.systf`
/// slot a host binds.
pub fn systfError(comptime D: type) ?[]const u8 {
    if (!@hasDecl(D, "systf_calls")) return null;
    const name = @typeName(D);
    for (D.systf_calls) |c| {
        if (c.name.len < 2 or c.name[0] != '$') return name ++ ".systf_calls: `" ++ c.name ++ "` does not start with `$` (§12.32)";
        if (!c.task and c.outs != 0) return name ++ ".systf_calls: `" ++ c.name ++ "` is a function call with output arguments; only a task has them (§12.22.2)";
    }
    // The device must have the `Instance.systf` slot the host binds;
    // `validateHost` checks the host.
    if (D.systf_calls.len != 0) {
        if (!@hasField(D.Instance, "systf"))
            return name ++ ": declares systf_calls but Instance has no `systf` field " ++
                "for the host to bind — see contract.SystfHost";
        if (@FieldType(D.Instance, "systf") != ?*const SystfHost)
            return name ++ ".Instance.systf must be `?*const contract.SystfHost`";
    }
    return null;
}

test "systf_calls: a task may have outputs, a function may not, and every name has its `$`" {
    const testing = std.testing;
    const Of = struct {
        fn dev(comptime calls: []const Systf) type {
            return struct {
                pub const Instance = struct { systf: ?*const SystfHost = null };
                pub const systf_calls = calls[0..calls.len].*;
            };
        }
    };
    // `$resistor(curr, V(p, n), r);` (§12.22.2) is a task reading back
    // argument 1; `$get(V(p))` in an expression is a function.
    try testing.expect(comptime (systfError(Of.dev(&.{
        .{ .name = "$resistor", .outs = 0b1, .task = true },
        .{ .name = "$get" },
    })) == null));
    try testing.expect(comptime (systfError(Of.dev(&.{.{ .name = "$get", .outs = 0b1 }})) != null));
    try testing.expect(comptime (systfError(Of.dev(&.{.{ .name = "get", .task = true }})) != null));
    try testing.expect(comptime (systfError(Of.dev(&.{.{ .name = "$" }})) != null));
    // A call needs the slot a host binds.
    try testing.expect(comptime (systfError(struct {
        pub const Instance = struct {};
        pub const systf_calls = [_]Systf{.{ .name = "$x" }};
    }) != null));
    // The default is a function: a device built before the flag existed
    // reads as one.
    try testing.expect(!(Systf{ .name = "$x" }).task);
}

test "SystfHost.output: without `out` an argument keeps its value, partial 1 on itself" {
    const testing = std.testing;
    const h: SystfHost = .{ .ctx = undefined, .call = undefined };
    var partials: [3]f64 = @splat(9);
    try testing.expectEqual(@as(f64, 2), h.output(0, 2, &.{ 1, 2, 3 }, &partials));
    try testing.expectEqualSlices(f64, &.{ 0, 1, 0 }, &partials);
    // With `out`, the application answers: 10·k + j + args[0] here.
    const Echo = struct {
        fn out(_: *anyopaque, k: usize, j: usize, args: []const f64, p: []f64) f64 {
            @memset(p, 0.5);
            return @as(f64, @floatFromInt(10 * k + j)) + args[0];
        }
    };
    const e: SystfHost = .{ .ctx = undefined, .call = undefined, .out = &Echo.out };
    try testing.expectEqual(@as(f64, 31.25), e.output(3, 1, &.{0.25}, partials[0..1]));
    try testing.expectEqual(@as(f64, 0.5), partials[0]);
}
