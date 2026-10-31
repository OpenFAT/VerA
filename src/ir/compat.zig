//! Compatibility shim, DELETE IN PASS 2: the pre-rewrite `pub` names that
//! the rewrite renamed, mapped onto the new ones so the dependents of `ir`
//! still build while pass 2 migrates them. Nothing in `ir` imports this
//! file but `root.zig`. Every mapping is listed in the API change file
//! (`api/ir.md`); a caller migrates by spelling the new name.
//!
//! Cites: none (no behaviour lives here).
//!
//! Contents:
//! - `pub const simparam = struct`: every `simparam.zig` decl under its new
//!   name (`HostParam`, `host_params`, `Source`, `source`, `valueIn`,
//!   `isRuntime`, `hostField`), plus `simparamValueIn`, `simparamIsRuntime`,
//!   `simparamHostField` and `host_simparams` under their old ones.

const file = @import("simparam.zig");

/// `simparam.zig` with its pre-rewrite names beside the new ones.
pub const simparam = struct {
    /// See `simparam.HostParam`.
    pub const HostParam = file.HostParam;
    /// See `simparam.host_params`.
    pub const host_params = file.host_params;
    /// See `simparam.Source`.
    pub const Source = file.Source;
    /// See `simparam.source`.
    pub const source = file.source;
    /// See `simparam.valueIn`.
    pub const valueIn = file.valueIn;
    /// See `simparam.isRuntime`.
    pub const isRuntime = file.isRuntime;
    /// See `simparam.hostField`.
    pub const hostField = file.hostField;

    /// Old name of `valueIn` (delete in pass 2).
    pub const simparamValueIn = file.valueIn;
    /// Old name of `isRuntime` (delete in pass 2).
    pub const simparamIsRuntime = file.isRuntime;
    /// Old name of `hostField` (delete in pass 2).
    pub const simparamHostField = file.hostField;
    /// Old name of `host_params` (delete in pass 2).
    pub const host_simparams = file.host_params;
};
