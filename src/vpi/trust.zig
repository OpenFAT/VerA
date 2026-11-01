//! The handle trust boundary: a `vpiHandle` from C -> a row VerA issued, or
//! null. Never reads through a pointer before membership proves it ours. Also
//! §12.3 vpi_compare_objects and §12.4 vpi_free_object over every handle kind.
//! Cites: VAMS-2023 §11.3.1, §12.3, §12.4, §12.30; IEEE 1364-2005 §27.35.
//!
//! Contents:
//! - `pub fn asObj(h: abi.vpiHandle) ?*Obj`
//! - `pub fn asIter(h: abi.vpiHandle) ?*Iter`
//! - `pub fn handleOf(o: *Obj) abi.vpiHandle`
//! - `pub fn describe(h: abi.vpiHandle) []const u8`
//! - `pub fn vpi_compare_objects(obj1: abi.vpiHandle, obj2: abi.vpiHandle) c_int`
//! - `pub fn issued(h: abi.vpiHandle) ?*anyopaque`
//! - `pub fn vpi_free_object(obj: abi.vpiHandle) c_int`
//! - `pub fn vpi_release_handle(obj: abi.vpiHandle) c_int`

const std = @import("std");
const abi = @import("abi.zig");
const callback = @import("callback.zig");
const delays = @import("delays.zig");
const iterate = @import("iterate.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const value_put = @import("value_put.zig");
const schema = @import("schema.zig");
const Design = @import("Design.zig");
const Iter = schema.Iter;
const Obj = schema.Obj;

/// Returns `h` as an object of the installed design, or null. Never reads
/// through `h`.
/// Asserts that the model is within `Design.objects_max` rows.
pub fn asObj(h: abi.vpiHandle) ?*Obj {
    const d = &(session.design orelse return null);
    std.debug.assert(d.objects.len <= Design.objects_max);
    const p = h orelse return null;
    if (d.objects.len == 0) return null;
    const base = @intFromPtr(d.objects.ptr);
    const addr = @intFromPtr(p);
    if (addr < base) return null;
    const off = addr - base;
    if (off >= d.objects.len * @sizeOf(Obj)) return null;
    if (off % @sizeOf(Obj) != 0) return null;
    const i = off / @sizeOf(Obj);
    std.debug.assert(i < d.objects.len);
    return &d.objects[i];
}

/// Returns `h` as a live iterator of the installed design, or null. Never
/// reads through `h`: membership in `Design.iters` is the proof.
/// Asserts that a live iterator is keyed by its own address.
pub fn asIter(h: abi.vpiHandle) ?*Iter {
    const d = &(session.design orelse return null);
    const p = h orelse return null;
    const it = d.iters.get(@intFromPtr(p)) orelse return null;
    // `newIter` keys each iterator by its own address.
    std.debug.assert(@intFromPtr(it) == @intFromPtr(p));
    std.debug.assert(it.handles != null or it.at <= it.items.len);
    return it;
}

/// The handle an application receives for `o`, which must be a row of
/// `design.objects`; `asObj` is its inverse. Valid until `close`. Asserts
/// that `o` is such a row.
pub fn handleOf(o: *Obj) abi.vpiHandle {
    const h: abi.vpiHandle = @ptrCast(o);
    std.debug.assert(session.design != null);
    std.debug.assert(asObj(h) == o);
    return h;
}

/// How an invalid handle is named in a message. Never dereferences it.
/// Asserts that the name is never empty.
pub fn describe(h: abi.vpiHandle) []const u8 {
    const name = if (h == null) "NULL" else "that handle";
    std.debug.assert(name.len != 0);
    std.debug.assert((h == null) == std.mem.eql(u8, name, "NULL"));
    return name;
}

/// "Handle equivalence can not be determined with a C `==` comparison."
///
/// Two invalid handles are not "the same object": that is FALSE plus an
/// error, not TRUE.
///
/// Asserts that one handle value always names one identity.
pub export fn vpi_compare_objects(obj1: abi.vpiHandle, obj2: abi.vpiHandle) c_int {
    if (status.refused("vpi_compare_objects")) return 0;
    const a = issued(obj1) orelse {
        status.fail("BADHANDLE", "vpi_compare_objects: {s} is not a handle VerA issued", .{describe(obj1)});
        return 0;
    };
    const b = issued(obj2) orelse {
        status.fail("BADHANDLE", "vpi_compare_objects: {s} is not a handle VerA issued", .{describe(obj2)});
        return 0;
    };
    // One handle value is one identity: `issued` is a function of it.
    std.debug.assert(obj1 != obj2 or a == b);
    std.debug.assert(status.vpi_chk_error(null) == 0);
    return @intFromBool(a == b);
}

/// The identity of a handle VerA issued, object or iterator (§12.23 gives an
/// iterator the type `vpiIterator`, so it is an object too). Erased to
/// `*anyopaque` because identity is all `vpi_compare_objects` reads.
///
/// Asserts that every registry hands out its own row's address as the handle,
/// so the identity is the handle value.
pub fn issued(h: abi.vpiHandle) ?*anyopaque {
    const id: ?*anyopaque = if (asObj(h)) |o| @ptrCast(o) else if (asIter(h)) |it| @ptrCast(it) else if (callback.asCb(h)) |cb| @ptrCast(cb) else if (run.asQueue(h)) |q| @ptrCast(q) else if (value_put.asEvent(h)) |e| @ptrCast(e) else if (systf.asSystf(h)) |s| @ptrCast(s) else if (delays.asPath(h)) |m| @ptrCast(m) else null;
    std.debug.assert(id == null or h != null);
    std.debug.assert(id == null or @intFromPtr(id.?) == @intFromPtr(h.?));
    return id;
}

/// "It shall generally be used to free memory created for iterator objects. ...
/// This routine can also optionally be used for implementations which have to
/// allocate memory for objects."
///
/// Freeing an iterator frees it and invalidates the handle. Freeing an object
/// is a no-op returning TRUE: objects live as long as the design, and an
/// application is entitled to call this on one.
///
/// Asserts that a freed iterator is gone, and that a refused handle is none
/// VerA issued.
pub export fn vpi_free_object(obj: abi.vpiHandle) c_int {
    if (status.refused("vpi_free_object")) return 0;
    if (asIter(obj)) |it| {
        iterate.destroyIter(&session.design.?, it);
        std.debug.assert(asIter(obj) == null);
        return 1;
    }
    // A callback handle is freed by vpi_remove_cb (§12.34), not here; freeing
    // the handle leaves the callback registered, as an object's does.
    if (asObj(obj) != null or callback.asCb(obj) != null or run.asQueue(obj) != null or systf.asSystf(obj) != null or delays.asPath(obj) != null) return 1;
    // §12.30 "Calling vpi_free_object() on the handle shall free the handle
    // but shall not effect the event."
    if (value_put.asEvent(obj)) |e| {
        value_put.freeEvent(e);
        return 1;
    }
    std.debug.assert(issued(obj) == null);
    status.fail("BADHANDLE", "vpi_free_object: {s} is not a handle VerA issued", .{describe(obj)});
    return 0;
}

/// IEEE 1364-2005's later spelling of `vpi_free_object`; same contract, same
/// body.
/// Asserts that a FALSE answer recorded its error.
pub export fn vpi_release_handle(obj: abi.vpiHandle) c_int {
    const ok = vpi_free_object(obj);
    std.debug.assert(ok == 0 or ok == 1);
    std.debug.assert(ok == 1 or status.vpi_chk_error(null) != 0);
    return ok;
}
