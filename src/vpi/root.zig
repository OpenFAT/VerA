//! The VPI library: an elaborated design -> the object model a C application
//! walks through the `vpi_*` routines, and the digital and analog runs it
//! watches. Re-exports only: what `host.zig` and `tests/unit.zig` call.
//! Cites: IEEE 1364-2005 §26-§27 and Annex G; VAMS-2023 §11.6, §12.
//!
//! The spine, in the order a host drives it:
//!
//!   session.open / openDigital   model_analog.zig, model_digital.zig build
//!                                the rows, model.zig freezes them
//!   session.runStartupRoutines   §12.33.2: the application registers
//!                                (systf.zig, callback.zig)
//!   the routines                 handle, iterate, property, value,
//!                                value_put, delays, print, analog_value
//!   run.simulate / Binding.run   the digital and the analog runs
//!   session.close                frees the model and resets every registry
//!
//! Contents:
//! - `pub const user = @import("vpi_user.zig")`
//! - `pub const abi = @import("abi.zig")`
//! - `pub const schema = @import("schema.zig")`
//! - `pub const Design = @import("Design.zig")`
//! - `pub const session = @import("session.zig")`
//! - `pub const status = @import("status.zig")`
//! - `pub const trust = @import("trust.zig")`
//! - `pub const handle = @import("handle.zig")`
//! - `pub const iterate = @import("iterate.zig")`
//! - `pub const property = @import("property.zig")`
//! - `pub const value = @import("value.zig")`
//! - `pub const value_put = @import("value_put.zig")`
//! - `pub const delays = @import("delays.zig")`
//! - `pub const callback = @import("callback.zig")`
//! - `pub const callback_fire = @import("callback_fire.zig")`
//! - `pub const systf = @import("systf.zig")`
//! - `pub const run = @import("run.zig")`
//! - `pub const print = @import("print.zig")`
//! - `pub const analog = @import("analog.zig")`
//! - `pub const Binding = @import("Binding.zig")`
//! - `pub const analog_value = @import("analog_value.zig")`
//! - `pub const code_tables = @import("code_tables.zig")`

pub const user = @import("vpi_user.zig");
pub const abi = @import("abi.zig");
pub const schema = @import("schema.zig");
pub const Design = @import("Design.zig");
pub const session = @import("session.zig");
pub const status = @import("status.zig");
pub const trust = @import("trust.zig");
pub const handle = @import("handle.zig");
pub const iterate = @import("iterate.zig");
pub const property = @import("property.zig");
pub const value = @import("value.zig");
pub const value_put = @import("value_put.zig");
pub const delays = @import("delays.zig");
pub const callback = @import("callback.zig");
pub const callback_fire = @import("callback_fire.zig");
pub const systf = @import("systf.zig");
pub const run = @import("run.zig");
pub const print = @import("print.zig");
pub const analog = @import("analog.zig");
pub const Binding = @import("Binding.zig");
pub const analog_value = @import("analog_value.zig");
pub const code_tables = @import("code_tables.zig");

// Every file with an `export fn`, so each C entry point is emitted.
comptime {
    _ = @import("analog_value.zig");
    _ = @import("callback.zig");
    _ = @import("cformat.zig");
    _ = @import("delays.zig");
    _ = @import("handle.zig");
    _ = @import("iterate.zig");
    _ = @import("print.zig");
    _ = @import("property.zig");
    _ = @import("run.zig");
    _ = @import("session.zig");
    _ = @import("status.zig");
    _ = @import("systf.zig");
    _ = @import("trust.zig");
    _ = @import("value.zig");
    _ = @import("value_put.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("analog_call.zig");
    _ = @import("analog_walk.zig");
    _ = @import("attribute.zig");
    _ = @import("Builder.zig");
    _ = @import("callback_fire.zig");
    _ = @import("callback_sites.zig");
    _ = @import("cformat.zig");
    _ = @import("code_expr.zig");
    _ = @import("code_module.zig");
    _ = @import("code_stmt.zig");
    _ = @import("decompile.zig");
    _ = @import("model.zig");
    _ = @import("model_analog.zig");
    _ = @import("model_arrays.zig");
    _ = @import("model_branches.zig");
    _ = @import("model_digital.zig");
    _ = @import("reverse_index.zig");
    _ = @import("udp.zig");
    _ = @import("value_text.zig");
}
