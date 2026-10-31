//! Pass-1 shim, delete in pass 2: the old `Elaborate` namespace over the new
//! files, so the modules that import `elab` keep building while their
//! migration is pending. Every mapping is in the api file.
//!
//! Contents:
//! - `pub const elaborate`, `pub const Ctx`, `pub const Design`, `pub const Error`, `pub const sep`
//! - `pub const UnitPath`, `pub const NameSite`, `pub const ParamsetDefparam`, `pub const PortAmmeter`
//! - `pub const PortConcat`, `pub const PortWidth`, `pub const PsOutput`, `pub const SystemCheck`
//! - `pub const NetPart`, `pub const SignalDiscipline`, `pub const Inserted`
//! - `pub const DisciplineResolution`, `pub const ParamOverride`
//! - `pub const flatReference`, `pub const unnamedGenScopes`, `pub const spiceCase`, `pub const genvarLoop`

const design = @import("design.zig");

pub const elaborate = @import("elaborate.zig").elaborate;
pub const Ctx = design.Ctx;
pub const Design = design.Design;
pub const Error = design.Error;
pub const sep = design.sep;
pub const UnitPath = design.UnitPath;
pub const NameSite = design.NameSite;
pub const ParamsetDefparam = design.ParamsetDefparam;
pub const PortAmmeter = design.PortAmmeter;
pub const PortConcat = design.PortConcat;
pub const PortWidth = design.PortWidth;
pub const PsOutput = design.PsOutput;
pub const SystemCheck = design.SystemCheck;
pub const NetPart = design.NetPart;
pub const SignalDiscipline = design.SignalDiscipline;
pub const Inserted = design.Inserted;
pub const DisciplineResolution = design.DisciplineResolution;
pub const ParamOverride = design.ParamOverride;
pub const flatReference = @import("flat_name.zig").flatReference;
pub const unnamedGenScopes = @import("flat_name.zig").unnamedGenScopes;
pub const spiceCase = @import("spice_case.zig").spiceCase;
pub const genvarLoop = @import("generate.zig").genvarLoop;
