//! The `va_list` the C shim (`varargs.c`) hands to the Zig side, opaque.
//! Cites: none (the platform C ABI).
//!
//! Contents:
//! - `pub const List = opaque {}`
//! - `pub fn arg(ap: *List, comptime T: type) T`

const std = @import("std");

/// A `va_list *`, opaque: only `varargs.c` knows its layout.
pub const List = opaque {};

/// `va_arg(*ap, T)`. An unsigned type reads its signed twin, which C11
/// 7.16.1.1 allows for a value both represent and which passes in the same
/// place; `intmax_t` is read as `long long`, the same 64 bits on every target.
///
/// Asserts, at compile time, that `T` passes in one argument slot and that
/// `long long` is 64 bits.
pub fn arg(ap: *List, comptime T: type) T {
    comptime std.debug.assert(@sizeOf(T) <= 8);
    comptime std.debug.assert(@bitSizeOf(c_longlong) == 64);
    return switch (T) {
        c_int => vera_va_int(ap),
        c_long => vera_va_long(ap),
        c_ulong => @bitCast(vera_va_long(ap)),
        c_longlong, i64 => vera_va_longlong(ap),
        c_ulonglong, u64 => @bitCast(vera_va_longlong(ap)),
        usize => vera_va_size(ap),
        isize => @bitCast(vera_va_size(ap)),
        f64 => vera_va_double(ap),
        ?*anyopaque => vera_va_ptr(ap),
        ?[*:0]const u8 => @ptrCast(vera_va_ptr(ap)),
        else => @compileError("va.arg: no C accessor for " ++ @typeName(T)),
    };
}

// ---- private ----

extern fn vera_va_int(ap: *List) c_int;

extern fn vera_va_long(ap: *List) c_long;

extern fn vera_va_longlong(ap: *List) c_longlong;

extern fn vera_va_size(ap: *List) usize;

extern fn vera_va_double(ap: *List) f64;

extern fn vera_va_ptr(ap: *List) ?*anyopaque;
