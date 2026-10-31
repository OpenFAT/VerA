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
const Iter = schema.Iter;
const Obj = schema.Obj;

/// Returns `h` as an object of the installed design, or null. Never reads
/// through `h`.
pub fn asObj(h: abi.vpiHandle) ?*Obj {
    const d = &(session.design orelse return null);
    const p = h orelse return null;
    if (d.objects.len == 0) return null;
    const base = @intFromPtr(d.objects.ptr);
    const addr = @intFromPtr(p);
    if (addr < base) return null;
    const off = addr - base;
    if (off >= d.objects.len * @sizeOf(Obj)) return null;
    if (off % @sizeOf(Obj) != 0) return null;
    return &d.objects[off / @sizeOf(Obj)];
}

/// Returns `h` as a live iterator of the installed design, or null. Never
/// reads through `h`: membership in `Design.iters` is the proof.
pub fn asIter(h: abi.vpiHandle) ?*Iter {
    const d = &(session.design orelse return null);
    const p = h orelse return null;
    return d.iters.get(@intFromPtr(p));
}

/// The handle an application receives for `o`, which must be a row of
/// `design.objects`; `asObj` is its inverse. Valid until `close`.
pub fn handleOf(o: *Obj) abi.vpiHandle {
    return @ptrCast(o);
}

/// How an invalid handle is named in a message. Never dereferences it.
pub fn describe(h: abi.vpiHandle) []const u8 {
    return if (h == null) "NULL" else "that handle";
}

/// "Handle equivalence can not be determined with a C `==` comparison."
///
/// Two invalid handles are not "the same object": that is FALSE plus an
/// error, not TRUE.
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
    return @intFromBool(a == b);
}

/// The identity of a handle VerA issued, object or iterator (§12.23 gives an
/// iterator the type `vpiIterator`, so it is an object too). Erased to
/// `*anyopaque` because identity is all `vpi_compare_objects` reads.
pub fn issued(h: abi.vpiHandle) ?*anyopaque {
    if (asObj(h)) |o| return @ptrCast(o);
    if (asIter(h)) |it| return @ptrCast(it);
    if (callback.asCb(h)) |cb| return @ptrCast(cb);
    if (run.asQueue(h)) |q| return @ptrCast(q);
    if (value_put.asEvent(h)) |e| return @ptrCast(e);
    if (systf.asSystf(h)) |s| return @ptrCast(s);
    if (delays.asPath(h)) |m| return @ptrCast(m);
    return null;
}

/// "It shall generally be used to free memory created for iterator objects. ...
/// This routine can also optionally be used for implementations which have to
/// allocate memory for objects."
///
/// Freeing an iterator frees it and invalidates the handle. Freeing an object
/// is a no-op returning TRUE: objects live as long as the design, and an
/// application is entitled to call this on one.
pub export fn vpi_free_object(obj: abi.vpiHandle) c_int {
    if (status.refused("vpi_free_object")) return 0;
    if (asIter(obj)) |it| {
        iterate.destroyIter(&session.design.?, it);
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
    status.fail("BADHANDLE", "vpi_free_object: {s} is not a handle VerA issued", .{describe(obj)});
    return 0;
}

/// IEEE 1364-2005's later spelling of `vpi_free_object`; same contract, same
/// body.
pub export fn vpi_release_handle(obj: abi.vpiHandle) c_int {
    return vpi_free_object(obj);
}
