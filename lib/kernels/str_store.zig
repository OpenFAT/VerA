//! §3.3 string storage for a device: a call site's text in, bytes that
//! outlive the expression that made them out. Per-site scratch rows
//! (`zSBuf`, `zSRow`), held string values (`ZStrHeldN`), run-time
//! concatenation and replication, NUL compaction, the E1011 overrun, and
//! §9.4.1's `$monitor` latch. Device text (`text.str`, with `str_scan.zig`,
//! `str_real.zig` and `str_format.zig`).
//! Cites: VAMS §3.3 (Table 3-3), §5.10, §9.4.1, §9.5.2, §9.5.3.
//!
//! Storage that has to outlive an expression is file scope, one instance per
//! comptime `site`: a distinct site instantiates a distinct struct and so a
//! distinct array, which keeps two `$sformat` calls in one module from
//! writing over each other (§9.5.3 has each name its own string variable).
//! The rows are thread-local on a CPU, so two threads evaluating the same
//! call site on different instances each format into their own row. A
//! `$monitor` latch is state of the instance (`ZMon`, `Instance.zm__`), so
//! two instances of one model each compare against their own last report.
//!
//! Contents:
//! - `pub const ZStrHeld = ZStrHeldN(4096)`
//! - `pub fn ZStrHeldN(comptime len: usize) type` (`get(h: *const @This()) []const u8`)
//! - `pub fn zSBuf(comptime site: usize) *[4096]u8`
//! - `pub fn zSRow(comptime site: usize, comptime slot: usize, comptime len: usize) *[len]u8`
//! - `pub fn zSTmp(comptime len: usize) *[len]u8`
//! - `pub fn zStringStore(bytes: []u8) []const u8`
//! - `pub fn zStrHeldN(comptime len: usize, s: []const u8) ZStrHeldN(len)`
//! - `pub fn zStrHeld(s: []const u8) ZStrHeld`
//! - `pub fn zStrCat(buf: anytype, parts: []const []const u8) []const u8`
//! - `pub fn zStrRepeat(buf: anytype, count: i64, s: []const u8) []const u8`
//! - `pub fn zSOver() noreturn`
//! - `pub const ZMon = struct { armed: bool, seen: bool, h: u64 }`
//! - `pub fn zMonitor(m: *const ZMon, vals: []const u64, text: []const u8) ?[]const u8`
//! - `pub fn zMonitorArm(m: *const ZMon) f64`

const zstd = @import("std");

// ---- device text ----

/// One §9.4.1 `$monitor`/`$fmonitor` site's latch in one instance
/// (`Instance.zm__`, one per `Lower.armMonitor` key): whether the statement
/// ran (`armed`), whether a step was reported (`seen`), and the hash of the
/// values it reported (`h`). A plain value, so a host copies it with the
/// instance.
// ponytail: one Wyhash of the watched values, not the values: a change is
// missed with probability 2^-64, as a string operand's own hash already is.
// Keep the values the day a site's operand count reaches the instance field.
pub const ZMon = struct {
    armed: bool = false,
    seen: bool = false,
    h: u64 = 0,
};

/// The held string of the 4096-byte row.
pub const ZStrHeld = ZStrHeldN(4096);

/// Whether the scratch rows are thread-local: on every CPU target, not on a
/// GPU, which has no thread-local storage (one GPU thread formats nothing).
const zs_tls = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => false,
    else => true,
};

/// Returns the type of a held string variable's own bytes, an `Instance`
/// field (§5.10/§3.3, #19), `len` bytes: the longest text the model can put
/// there (`cg_strcap.heldCap`). Not a slice: a `$sformat` result lives in its
/// site's row, which the site rewrites the next time it runs (a Newton
/// iterate, a rejected step, a second instance), so a held slice of it
/// changed under the device's feet. `stateCtl` copies the whole value, so a
/// revert restores the text. Invariant: `n <= len`.
// ponytail: `stateCtl` copies all `len` bytes per commit and revert; copy
// `n` there if a model holds many strings and it measures hot.
pub fn ZStrHeldN(comptime len: usize) type {
    return struct {
        n: zstd.math.IntFittingRange(0, len) = 0,
        b: [len]u8 = @splat(0),

        /// Returns the held text, a view of `h`'s own bytes.
        pub fn get(h: *const @This()) []const u8 {
            zstd.debug.assert(h.n <= len);
            return h.b[0..h.n];
        }
    };
}

/// Returns call site `site`'s 4096-byte scratch row, keyed by the site's MIR
/// instruction id: the formatted bytes outlive the expression that produced
/// them (a string slot is a `[]const u8` and the writer a subexpression). A
/// site whose text can be longer gets a row of its own size (`zSRow`, sized
/// by `cg_strcap`).
pub fn zSBuf(comptime site: usize) *[4096]u8 {
    const Buf = if (zs_tls) struct {
        const n = site;
        threadlocal var b: [4096]u8 = undefined;
    } else struct {
        const n = site;
        var b: [4096]u8 = undefined;
    };
    return &Buf.b;
}

/// Returns call site `site`'s row `slot` of `len` bytes: slot 0 is its text,
/// slot k + 1 the scratch of its operand k's composed field when that is too
/// wide for the stack (`cg_display.Spec.max_stack`). `zSBuf`'s terms
/// otherwise.
pub fn zSRow(comptime site: usize, comptime slot: usize, comptime len: usize) *[len]u8 {
    const Row = if (zs_tls) struct {
        const n = site;
        const k = slot;
        threadlocal var b: [len]u8 = undefined;
    } else struct {
        const n = site;
        const k = slot;
        var b: [len]u8 = undefined;
    };
    return &Row.b;
}

/// Returns `len` bytes of scratch that live for one kernel call (`zStrCat`,
/// `zStrRepeat`, `zSFormatRt`): static, so a long row makes no long frame.
/// For this group's kernels only; the next call of any of them with the same
/// `len` reuses the bytes.
pub fn zSTmp(comptime len: usize) *[len]u8 {
    const Tmp = if (zs_tls) struct {
        threadlocal var b: [len]u8 = undefined;
    } else struct {
        var b: [len]u8 = undefined;
    };
    return &Tmp.b;
}

/// Compacts completed formatter output in place, dropping its NUL bytes
/// (§3.3 string storage excludes NUL), and returns the prefix of `bytes`
/// that holds it; padding counted the original bytes. Invalidates `bytes`
/// past the returned prefix.
pub fn zStringStore(bytes: []u8) []const u8 {
    // Text almost never holds a NUL: a vectorized search proves that and
    // copies nothing. Past the first one every byte is stored and only a
    // nonzero one advances the cursor.
    var used = zstd.mem.findScalar(u8, bytes, 0) orelse return bytes;
    const first = used;
    for (bytes[used + 1 ..]) |byte| {
        bytes[used] = byte;
        used += @intFromBool(byte != 0);
    }
    zstd.debug.assert(used >= first);
    zstd.debug.assert(used < bytes.len);
    return bytes[0..used];
}

/// Returns a `ZStrHeldN(len)` holding a copy of `s`: a fresh value, so `s`
/// may be a slice of the field the result is stored into. Text longer than
/// the field is E1011, at compile time for an initializer.
pub fn zStrHeldN(comptime len: usize, s: []const u8) ZStrHeldN(len) {
    var h: ZStrHeldN(len) = .{};
    if (s.len > len) {
        if (@inComptime()) @compileError("error[E1011]: a held string initializer exceeds its field");
        zSOver();
    }
    @memcpy(h.b[0..s.len], s);
    h.n = @intCast(s.len);
    zstd.debug.assert(h.n == s.len);
    return h;
}

/// Returns `zStrHeldN` for the 4096-byte `ZStrHeld`.
pub fn zStrHeld(s: []const u8) ZStrHeld {
    return zStrHeldN(4096, s);
}

/// Returns §3.3 Table 3-3's "Concatenation of Str1,…,Strn" when a piece is
/// known only at run time, in its call site's row `buf` (a pointer to it). A
/// piece may be this site's previous result (`s = {s, "x"}`), so the bytes
/// are built in scratch first and copied once. An overrun is E1011.
pub fn zStrCat(buf: anytype, parts: []const []const u8) []const u8 {
    const tmp = zSTmp(buf.len);
    var n: usize = 0;
    for (parts) |p| {
        if (p.len > tmp.len - n) zSOver();
        @memcpy(tmp[n..][0..p.len], p);
        n += p.len;
    }
    if (n > buf.len) zSOver();
    @memcpy(buf[0..n], tmp[0..n]);
    zstd.debug.assert(n <= buf.len);
    return buf[0..n];
}

/// Returns §3.3 Table 3-3's replication with a run-time multiplier: "a
/// string containing N concatenated copies of Str", in `buf`. The row fixes
/// no result for a negative N (§4.2.13's "non-negative" governs a
/// constant), so N <= 0 is the empty string, as zero copies are. `zStrCat`'s
/// scratch and overrun rule.
pub fn zStrRepeat(buf: anytype, count: i64, s: []const u8) []const u8 {
    if (count <= 0 or s.len == 0) return "";
    const tmp = zSTmp(buf.len);
    if (count > tmp.len / s.len) zSOver();
    const k: usize = @intCast(count);
    zstd.debug.assert(k * s.len <= buf.len);
    for (0..k) |j| @memcpy(tmp[j * s.len ..][0..s.len], s);
    @memcpy(buf[0 .. k * s.len], tmp[0 .. k * s.len]);
    return buf[0 .. k * s.len];
}

/// E1011: run-time text outgrew the row its call site or held string was
/// sized for. Fatal, like `$fatal`: §9.5.3 gives no truncation rule, so
/// neither a cut nor an empty string is an answer the clause allows.
pub fn zSOver() noreturn {
    zstd.debug.print("error[E1011]: run-time text exceeds the row the compiler sized for it; see `vera --explain E1011`\n", .{});
    zstd.process.exit(1);
}

/// Returns `text` when latch `m`'s watched values differ from those it last
/// reported, else null (§9.4.1): "for each accepted step, if the variable or
/// an expression in the argument list changes value compared with the last
/// accepted step ... the entire argument list is displayed", once however
/// many changed (§9.5.2 carries it to `$fmonitor`). The emitter hands one u64
/// per watched argument (a real's or integer's bits, a string's hash) with
/// the exempt `$abstime`/`$realtime` operands left out: a rendered-line
/// comparison could not honour that exemption. The first accepted step
/// reports, and nothing reports before the statement ran (`zMonitorArm`).
/// `m` is the site's latch in the instance the display unit runs for,
/// written through the `*const Instance` the contract hands `display`, as
/// `file_kernels.zFCtx` writes the table: only the display phase writes it,
/// one call per instance at a time.
pub fn zMonitor(m: *const ZMon, vals: []const u64, text: []const u8) ?[]const u8 {
    const l: *ZMon = @constCast(m);
    if (!l.armed) return null;
    const h = zstd.hash.Wyhash.hash(0, zstd.mem.sliceAsBytes(vals));
    if (l.seen and l.h == h) return null;
    l.h = h;
    l.seen = true;
    zstd.debug.assert(l.seen);
    return text;
}

/// §9.4.1 "sets up a mechanism": the statement ran, so latch `m` reports at
/// the end of this accepted step and every one after it. Returns 0: the call
/// is a void task riding the display chain. Writes through `*const` as
/// `zMonitor` does.
pub fn zMonitorArm(m: *const ZMon) f64 {
    const l: *ZMon = @constCast(m);
    l.armed = true;
    zstd.debug.assert(m.armed);
    return 0.0;
}
