//! A device type and the name of one of its declarations in, why that
//! declaration has the wrong shape (or null) out: the signature, array,
//! pairing and field-type checks every `validate` rule is built from. Each
//! returns its message rather than raising it, so a refusal is testable.
//! Cites: none (the contract's own shapes).
//!
//! Contents:
//! - `pub fn genericFnError(comptime D: type, comptime fn_name: []const u8, comptime ret: []const u8) ?[]const u8`
//! - `pub fn genericError(comptime D: type, comptime fn_name: []const u8, comptime params: usize, comptime shape: []const u8) ?[]const u8`
//! - `pub fn fnError(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) ?[]const u8`
//! - `pub fn arrayError(comptime D: type, comptime decl: []const u8, comptime Child: type) ?[]const u8`
//! - `pub fn requireWithError(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) ?[]const u8`
//! - `pub fn defaultedStructError(comptime D: type, comptime decl: []const u8) ?[]const u8`
//! - `pub fn hasFloatField(comptime T: type, comptime name: []const u8) bool`
//! - `pub fn isValueType(comptime T: type) bool`
//! - `pub fn isDenseEnum(comptime E: type) bool`

const std = @import("std");
const assert = std.debug.assert;
const SystfHost = @import("host_callbacks.zig").SystfHost;

/// The shape shared by `eval`, `q`, `evalQ` and `display`: five parameters,
/// the first `comptime S: type`. `ret` only names the result in the message.
/// Asserts that `D` declares `fn_name`.
pub fn genericFnError(comptime D: type, comptime fn_name: []const u8, comptime ret: []const u8) ?[]const u8 {
    assert(@hasDecl(D, fn_name));
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".param_types.len != 5 or info.@"fn".param_types[0] != type)
        return @typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, *const [n_u]S.V, *const Model, InstancePtr, SimState) " ++ ret;
    return null;
}

/// A generic entry point: `params` parameters, the first `comptime S: type`.
/// `shape` names the whole expected signature in the complaint. Asserts that
/// `D` declares `fn_name`.
pub fn genericError(comptime D: type, comptime fn_name: []const u8, comptime params: usize, comptime shape: []const u8) ?[]const u8 {
    assert(@hasDecl(D, fn_name));
    assert(params >= 1);
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".param_types.len != params or info.@"fn".param_types[0] != type)
        return @typeName(D) ++ "." ++ fn_name ++ ": expected " ++ shape;
    return null;
}

/// `D.fn_name` must exist and be exactly `Expected`.
pub fn fnError(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) ?[]const u8 {
    assert(@typeInfo(Expected) == .@"fn");
    if (!@hasDecl(D, fn_name))
        return @typeName(D) ++ ": missing " ++ fn_name;
    if (@TypeOf(@field(D, fn_name)) != Expected)
        return @typeName(D) ++ "." ++ fn_name ++ ": expected " ++ @typeName(Expected);
    return null;
}

/// If `D` declares `decl`, it must be a `[k]Child` array.
pub fn arrayError(comptime D: type, comptime decl: []const u8, comptime Child: type) ?[]const u8 {
    if (!@hasDecl(D, decl)) return null;
    const info = @typeInfo(@TypeOf(@field(D, decl)));
    if (info != .array or info.array.child != Child)
        return @typeName(D) ++ "." ++ decl ++ " must be [k]" ++ @typeName(Child);
    return null;
}

/// Refuses `decl` without `needs`. A rule calls it both ways for a mutually
/// required pair.
pub fn requireWithError(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) ?[]const u8 {
    assert(!std.mem.eql(u8, decl, needs));
    if (@hasDecl(D, decl) and !@hasDecl(D, needs))
        return @typeName(D) ++ ": `" ++ decl ++ "` requires `" ++ needs ++ "`";
    return null;
}

/// `D.decl` must be a struct whose every field has a default and a value
/// type (`isValueType`), so a host can make one and copy it.
pub fn defaultedStructError(comptime D: type, comptime decl: []const u8) ?[]const u8 {
    assert(@hasDecl(D, decl));
    const T = @field(D, decl);
    if (@typeInfo(T) != .@"struct")
        return @typeName(D) ++ "." ++ decl ++ " must be a struct";
    const s = @typeInfo(T).@"struct";
    for (s.field_names, s.field_types, s.field_attrs) |f_name, F, attrs| {
        if (attrs.default_value_ptr == null)
            return @typeName(D) ++ "." ++ decl ++ "." ++ f_name ++ " must have a default value";
        if (!isValueType(F))
            return @typeName(D) ++ "." ++ decl ++ "." ++ f_name ++
                ": field type must be numeric/bool/enum, []const u8, or a fixed-size array of these";
    }
    return null;
}

/// A float field of either width: VerA emits `f64` parameters, and a
/// hand-written device may declare `f32`.
pub fn hasFloatField(comptime T: type, comptime name: []const u8) bool {
    const s = @typeInfo(T).@"struct";
    for (s.field_names, s.field_types) |f_name, F| {
        if (std.mem.eql(u8, f_name, name) and (F == f32 or F == f64)) return true;
    }
    return false;
}

/// What a `Model` or `Instance` field may be: plain data a host can copy,
/// plus three host-owned pointers admitted by name.
pub fn isValueType(comptime T: type) bool {
    // String parameters point at literals in the device image, which a
    // loader keeps mapped for as long as any Model blob lives.
    if (T == []const u8) return true;
    // The §12.32 VPI binding: a host-owned pointer the device only calls
    // through. Admitted by name, not by shape, because a pointer in `Model`
    // would be copied across the `.so` seam; an `Instance` never is.
    if (T == ?*const SystfHost) return true;
    // §9.12 `Instance.plusargs`, admitted by name for the same reason: the
    // host's own argv, host-owned and host-lifetime.
    if (T == []const [:0]const u8) return true;
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        // Integer-backed enums are fixed-size POD.
        .@"enum" => |e| isValueType(e.tag_type),
        .array => |a| isValueType(a.child),
        // `Model.su` (a `Setup`): a plain struct of value fields is as
        // copyable as its fields. `void` is `su_ok` outside Debug, or when
        // the program did not ask for the checks (`validating`).
        .@"struct" => |s| for (s.field_types) |F| {
            if (!isValueType(F)) break false;
        } else true,
        .void => true,
        else => false,
    };
}

/// An unsigned tag of 8 bits or more, values 0..n-1: what `U` must be.
pub fn isDenseEnum(comptime E: type) bool {
    const info = @typeInfo(E).@"enum";
    const tag = @typeInfo(info.tag_type).int;
    if (tag.signedness != .unsigned or tag.bits < 8) return false;
    for (info.field_values, 0..) |value, idx| {
        if (value != idx) return false;
    }
    return true;
}

test "isDenseEnum: an unsigned tag of 8 bits or more, values 0..n-1" {
    const testing = std.testing;
    try testing.expect(comptime isDenseEnum(enum(u8) { a, b }));
    try testing.expect(comptime isDenseEnum(enum(u16) { a }));
    try testing.expect(comptime !isDenseEnum(enum(i8) { a, b }));
    try testing.expect(comptime !isDenseEnum(enum(u4) { a, b }));
    try testing.expect(comptime !isDenseEnum(enum(u8) { a = 1, b = 2 }));
}

test "isValueType: what a Model or Instance field may be, and what it may not" {
    const testing = std.testing;
    inline for (.{ f64, u32, bool, enum(u8) { a }, [3]f32, struct { a: f64, b: [2]u8 }, void, []const u8, ?*const SystfHost, []const [:0]const u8 }) |T|
        try testing.expect(comptime isValueType(T));
    inline for (.{ *f64, ?f64, []const f64, struct { p: *u8 }, [2]*u8 }) |T|
        try testing.expect(comptime !isValueType(T));
}

test "requireWith and the generic-entry check refuse their own mistakes" {
    const testing = std.testing;
    const PsdOnly = struct {
        pub const noisePsd = 0;
    };
    const Both = struct {
        pub const noisePsd = 0;
        pub const noise_gens = 0;
    };
    try testing.expect(comptime requireWithError(PsdOnly, "noisePsd", "noise_gens") != null);
    try testing.expect(comptime requireWithError(Both, "noisePsd", "noise_gens") == null);
    try testing.expect(comptime requireWithError(struct {}, "noisePsd", "noise_gens") == null);
    const OpVarsOnly = struct {
        pub const op_vars = [_][]const u8{"i"};
    };
    try testing.expect(comptime requireWithError(OpVarsOnly, "op_vars", "opVars") != null);
    const NotFn = struct {
        pub const eval = 3;
    };
    try testing.expect(comptime genericFnError(NotFn, "eval", "Rows(D, S)") != null);
    const Good = struct {
        pub fn display(comptime _: type, _: *const [2]f64, _: *const void, _: *const void, _: u8) void {}
    };
    try testing.expect(comptime (genericFnError(Good, "display", "void") == null));
    try testing.expect(comptime (genericError(Good, "display", 6, "six") != null));
    try testing.expect(comptime (fnError(Good, "missing", fn () void) != null));
    try testing.expect(comptime (arrayError(struct {
        pub const t = [_]u8{1};
    }, "t", u16) != null));
}
