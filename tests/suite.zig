//! The suite runner behind `zig build suite -- <mode>`, `test-spice` and the canary in `test`:
//! fixtures -> verdicts on stderr and a timing table on stdout. `Suite.main`
//! dispatches on the mode word; each mode is one namespace below:
//!   (none)       `Suite`: `benchmark`, the depth pass and the timing table
//!   `--sweep`    `SizeSweep`, the generated size sweep
//!   `devices`    `Devices` (`--native`: `Native`, `--fuzz`: `Fuzz`)
//!   `vpi`        `CFixtures`
//!   `spice`      `SpiceDecks`
//!   `golden`     `Golden`, the before/after snapshot of what vera says
//!   `canary`     `Canary`, the wrong-on-purpose fixtures the judge must FAIL
//! `Fixtures` is the harness every mode shares (the fixture walk, the verdict
//! algebra, the parallel run); `Analog` plugs VerA into it; `Lint` and
//! `Digital` are its tables; `Child` runs a process to completion.
//!
//! Each namespace is its own file, `suite/<Namespace>.zig`, named as the
//! namespace so its tests keep their names (`suite.Golden.test...`); it
//! imports the siblings it names and keeps its own imports. This file
//! declares only the namespaces, `main` and the test below.
//!
//! `tools/report.py` parses the `pass fail unasserted xfail` row `Suite`
//! prints: that row's text is frozen.
//!
//! The fixtures are the VAMS Conformance Suite's `tests/` (`suite_options.fixture_root`,
//! the submodule `tests/conformance`): `verilog-a/`, `verilog-ams/` (its `digital/`
//! the digital-context cases), `spice/`, `verilog/` (IEEE 1364-2005) and `include/`
//! (`check.vh`); its `netlist/` is ESPice's. Every path a verdict prints is relative
//! to that root. The suite's conventions hold: a source `include`s the annex D files
//! it uses (every compile sets `require_std_includes`), a `.v` names its extra inputs
//! with `//@` lines, and no fixture carries `//! xfail`: VerA's own expected failures
//! are `tests/suite.xfail`, and the canary is `tests/canary/`.

const Suite = @import("suite/Suite.zig");
const Fixtures = @import("suite/Fixtures.zig");
const Analog = @import("suite/Analog.zig");
const Canary = @import("suite/Canary.zig");
const CFixtures = @import("suite/CFixtures.zig");
const Child = @import("suite/Child.zig");
const Devices = @import("suite/Devices.zig");
const Digital = @import("suite/Digital.zig");
const Fuzz = @import("suite/Fuzz.zig");
const Golden = @import("suite/Golden.zig");
const Lint = @import("suite/Lint.zig");
const Native = @import("suite/Native.zig");
const SpiceDecks = @import("suite/SpiceDecks.zig");
const SizeSweep = @import("suite/SizeSweep.zig");

pub fn main(init: @import("std").process.Init) !u8 {
    return Suite.main(init);
}

// Zig collects `test` blocks only from the containers the root references, so
// every namespace's tests run through this block.
test {
    _ = Suite;
    _ = Fixtures;
    _ = Analog;
    _ = Canary;
    _ = CFixtures;
    _ = Child;
    _ = Devices;
    _ = Digital;
    _ = Fuzz;
    _ = Golden;
    _ = Lint;
    _ = Native;
    _ = SpiceDecks;
    _ = SizeSweep;
}
