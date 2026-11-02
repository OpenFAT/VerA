//! Every module of `build.zig`'s `module_specs`, `pub` so `tests/unit.zig`'s
//! `refAllDecls` reaches each one. Clauses: none (build wiring).
//!
//! Contents:
//! - `pub const contract`
//! - `pub const base`
//! - `pub const diag`
//! - `pub const frontend`
//! - `pub const elab`
//! - `pub const kernels`
//! - `pub const ir`
//! - `pub const analog`
//! - `pub const prove`
//! - `pub const zigbuild`
//! - `pub const device`
//! - `pub const verilog`
//! - `pub const exe`
//! - `pub const sim`
//! - `pub const digital`
//! - `pub const vera`
//! - `pub const vpi`

pub const contract = @import("contract");
pub const base = @import("base");
pub const diag = @import("diag");
pub const frontend = @import("frontend");
pub const elab = @import("elab");
pub const kernels = @import("kernels");
pub const ir = @import("ir");
pub const analog = @import("analog");
pub const prove = @import("prove");
pub const zigbuild = @import("zigbuild");
pub const device = @import("device");
pub const verilog = @import("verilog");
pub const exe = @import("exe");
pub const sim = @import("sim");
pub const digital = @import("digital");
pub const vera = @import("vera");
pub const vpi = @import("vpi");
