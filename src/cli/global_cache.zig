//! The environment -> the directory `vera` keeps prebuilt artifacts in, shared
//! by every work directory: a subdirectory of Zig's global cache, found the
//! way `zig` finds it. Read by `--emit-osdi` (`vera-osdi`) and the `.v`
//! engine (`vera-engine`).
//!
//! Cites: none (Zig's own lookup order).
//!
//! Contents:
//! - `pub fn globalCache(arena: Allocator, env: *const std.process.Environ.Map, sub: []const u8) Allocator.Error!?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Returns `sub` in Zig's global cache directory (`ZIG_GLOBAL_CACHE_DIR`,
/// else `XDG_CACHE_HOME/zig`, else `HOME/.cache/zig`, else Windows'
/// `LOCALAPPDATA/zig`), in `arena`; null when the environment names none.
/// Asserts that `sub` is a single relative name.
pub fn globalCache(arena: Allocator, env: *const std.process.Environ.Map, sub: []const u8) Allocator.Error!?[]const u8 {
    assert(sub.len != 0);
    assert(!std.fs.path.isAbsolute(sub));
    const global = if (env.get("ZIG_GLOBAL_CACHE_DIR")) |d|
        d
    else if (env.get("XDG_CACHE_HOME")) |d|
        try std.fs.path.join(arena, &.{ d, "zig" })
    else if (env.get("HOME")) |d|
        try std.fs.path.join(arena, &.{ d, ".cache", "zig" })
    else if (env.get("LOCALAPPDATA")) |d|
        try std.fs.path.join(arena, &.{ d, "zig" })
    else
        return null;
    return try std.fs.path.join(arena, &.{ global, sub });
}
