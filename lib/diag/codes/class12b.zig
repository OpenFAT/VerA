//! The diagnostic catalogue's class 12 rows, `--emit-rtlil` refusals, part b:
//! `E1239` .. `E1278`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E1239 = .{
        .title = "an indexed part-select with a variable base",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\Only a constant base is lowered, as a slice. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1240 = .{
        .title = "a select of something that is not a declared name",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\Only a port, net or variable is selected from. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1241 = .{
        .title = "a select of a parameter",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\A parameter's bits are not selected. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1242 = .{
        .title = "a variable bit select of an ascending vector",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\A variable index is lowered as a `$shiftx` of a descending (`[hi:lo]`)
        \\vector only. `vera --run` simulates the design; --emit-rtlil lowers only
        \\the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses
        \\the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1243 = .{
        .title = "a constant select outside the declared range",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\5.2.1 reads such a select as x; --emit-rtlil refuses it rather than emit
        \\the x. `vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1244 = .{
        .title = "an assignment target that is not a declared name",
        .lrm = "A.8.5",
        .explain =
        \\The target's base is not a name. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1245 = .{
        .title = "an assignment target that is not a name, a select or a concatenation",
        .lrm = "A.8.5",
        .explain =
        \\A.8.5 admits nothing else. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1246 = .{
        .title = "an assignment to a parameter",
        .lrm = "IEEE 1364-2005 4.10",
        .explain =
        \\A parameter is a constant. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1247 = .{
        .title = "a procedural assignment to a net",
        .lrm = "IEEE 1364-2005 9.2",
        .explain =
        \\9.2: a procedural assignment's target is a variable. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1248 = .{
        .title = "a select of a select as an assignment target",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\Only one select of a declared name is a target. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1249 = .{
        .title = "an indexed part-select as an assignment target",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\Write the target as a constant part-select `[msb:lsb]`. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1250 = .{
        .title = "a variable bit select as an assignment target",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\Only a constant bit select is a target: a variable one is a write
        \\decoder --emit-rtlil does not build. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1251 = .{
        .title = "an initial block that is not constant assignments",
        .lrm = "IEEE 1364-2005 9.9.1",
        .explain =
        \\An `initial` block lowers only as `init` attributes: `reg = constant;`
        \\statements, unnamed `begin`/`end` around them. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1252 = .{
        .title = "an initial assignment with a delay or event control",
        .lrm = "IEEE 1364-2005 9.9.1",
        .explain =
        \\A timed initial assignment is a waveform, not an initial value. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1253 = .{
        .title = "an initial assignment to a select",
        .lrm = "IEEE 1364-2005 9.9.1",
        .explain =
        \\The `init` attribute is the whole reg's value. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1254 = .{
        .title = "an initial value --emit-rtlil cannot fold to a constant",
        .lrm = "IEEE 1364-2005 9.9.1",
        .explain =
        \\The `init` attribute is a constant. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1255 = .{
        .title = "a block with local declarations",
        .lrm = "IEEE 1364-2005 9.8",
        .explain =
        \\A named block's own variables are not lowered. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1256 = .{
        .title = "a fork-join block --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 9.8.2",
        .explain =
        \\Parallel blocks are a simulation construct. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1257 = .{
        .title = "an always block without an event control",
        .lrm = "IEEE 1364-2005 9.9.2",
        .explain =
        \\An `always` block lowers as a process whose body starts with `@(...)`.
        \\`vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1258 = .{
        .title = "an always block that waits on a delay or a level",
        .lrm = "IEEE 1364-2005 9.7",
        .explain =
        \\A `#delay` or `wait` control has no RTLIL sync rule. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1259 = .{
        .title = "an event control mixing edges and levels",
        .lrm = "IEEE 1364-2005 9.7.2",
        .explain =
        \\A process is either edge-triggered (`sync posedge`) or combinational
        \\(`sync always`). `vera --run` simulates the design; --emit-rtlil lowers
        \\only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and
        \\refuses the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1260 = .{
        .title = "an intra-assignment delay or event control",
        .lrm = "IEEE 1364-2005 9.7.7",
        .explain =
        \\Synthesis has no delay. `vera --run` simulates the design; --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL,
        \\and refuses the rest by name rather than emit RTLIL whose circuit
        \\differs.
        ,
    },
    .E1261 = .{
        .title = "a procedural continuous assignment",
        .lrm = "IEEE 1364-2005 9.3",
        .explain =
        \\`assign`, `deassign`, `force` and `release` in a process are a
        \\simulation construct. `vera --run` simulates the design; --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL,
        \\and refuses the rest by name rather than emit RTLIL whose circuit
        \\differs.
        ,
    },
    .E1262 = .{
        .title = "a casex or casez --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 9.5.1",
        .explain =
        \\Only `case` is lowered to an RTLIL switch. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1263 = .{
        .title = "a loop --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 9.6",
        .explain =
        \\`for`, `while` and `repeat` are not unrolled. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1264 = .{
        .title = "a nested event or delay control",
        .lrm = "IEEE 1364-2005 9.7",
        .explain =
        \\Only the event control at the head of an `always` block is lowered.
        \\`vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1265 = .{
        .title = "an event trigger --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 9.7.3",
        .explain =
        \\A `->` trigger is a simulation synchronization. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1266 = .{
        .title = "a disable statement --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 10.3",
        .explain =
        \\Disabling a block is control flow RTLIL's switch rules cannot express.
        \\`vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1267 = .{
        .title = "a jump statement --emit-rtlil does not lower",
        .lrm = "A.6.5",
        .explain =
        \\`return` and `break` are control flow RTLIL's switch rules cannot
        \\express. `vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1268 = .{
        .title = "an analog contribution --emit-rtlil does not lower",
        .lrm = "5.6",
        .explain =
        \\A contribution drives a branch; RTLIL has no analog branch. --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL:
        \\it is digital only.
        ,
    },
    .E1269 = .{
        .title = "an array of gate instances --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 7.1.5",
        .explain =
        \\A gate with a range is not expanded to one cell per element. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1270 = .{
        .title = "an array of module instances --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 12.1.2",
        .explain =
        \\An instance with a range is not expanded to one cell per element. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1271 = .{
        .title = "an ordered parameter override of a module this source does not declare",
        .lrm = "IEEE 1364-2005 12.2.2.1",
        .explain =
        \\An ordered override names its parameter by position, which needs the
        \\module's declaration. Name the parameter (`#(.P(v))`). `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1272 = .{
        .title = "more ordered parameter overrides than the module declares",
        .lrm = "IEEE 1364-2005 12.2.2.1",
        .explain =
        \\Each ordered override takes the next parameter of the module. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1273 = .{
        .title = "a parameter override --emit-rtlil cannot fold to an integer",
        .lrm = "IEEE 1364-2005 12.2.2",
        .explain =
        \\An override is passed to Yosys as a cell parameter, an integer. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1274 = .{
        .title = "an ordered port connection to a module this source does not declare",
        .lrm = "IEEE 1364-2005 12.3.6",
        .explain =
        \\An ordered connection names its port by position, which needs the
        \\module's declaration. Connect by name (`.p(x)`). `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1275 = .{
        .title = "a constant wider than --emit-rtlil's fold limit",
        .lrm = "",
        .explain =
        \\A folded constant passes rtlil_fold.max_width (2^20 bits), wider than
        \\any RTLIL wire a synthesis flow reads. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1276 = .{
        .title = "a constant expression nested deeper than --emit-rtlil's fold limit",
        .lrm = "",
        .explain =
        \\The constant folder recurses on the expression and stops at
        \\rtlil_fold.max_depth (4096) operators. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1277 = .{
        .title = "nesting deeper than the stack --emit-rtlil reserved",
        .lrm = "",
        .explain =
        \\The expression or statement nests deeper than the stack VerA reserved
        \\for --emit-rtlil's walk (the largest the machine allows). `vera --run`
        \\reports the same limit as E1100. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1278 = .{
        .title = "a concatenation wider than --emit-rtlil's constant limit",
        .lrm = "IEEE 1364-2005 5.1.14",
        .explain =
        \\The concatenation's width passes rtlil_fold.max_width (2^20 bits), as a
        \\replication's may not either. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
};
