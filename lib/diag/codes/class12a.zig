//! The diagnostic catalogue's class 12 rows, `--emit-rtlil` refusals, part a:
//! `E1200` .. `E1238`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E1200 = .{
        .title = "an analog or mixed-signal description --emit-rtlil does not lower",
        .lrm = "",
        .explain =
        \\The source declares a discipline, nature, paramset or connectrules: it
        \\is Verilog-AMS. RTLIL is a digital netlist with no analog side.
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL: it is digital only.
        ,
    },
    .E1201 = .{
        .title = "a user-defined primitive --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 8",
        .explain =
        \\A UDP's table has no RTLIL cell; Yosys reads UDPs only through its own
        \\Verilog front end. `vera --run` simulates the design; --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL,
        \\and refuses the rest by name rather than emit RTLIL whose circuit
        \\differs.
        ,
    },
    .E1202 = .{
        .title = "an analog block --emit-rtlil does not lower",
        .lrm = "",
        .explain =
        \\An `analog` block is continuous-time behaviour, which RTLIL cannot
        \\express. --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL: it is digital only.
        ,
    },
    .E1203 = .{
        .title = "a connect module --emit-rtlil does not lower",
        .lrm = "7.8",
        .explain =
        \\A connect module bridges a digital and an analog net; RTLIL has no
        \\analog net. --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL: it is digital only.
        ,
    },
    .E1204 = .{
        .title = "a generate construct --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 12.4",
        .explain =
        \\Generate loops and conditionals are not elaborated by --emit-rtlil.
        \\`vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1205 = .{
        .title = "a defparam --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 12.2.1",
        .explain =
        \\A defparam overrides a parameter by hierarchical name; parameters fold
        \\at their defaults here. Pass the value as an instance override
        \\(`#(...)`). `vera --run` simulates the design; --emit-rtlil lowers only
        \\the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses
        \\the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1206 = .{
        .title = "a task --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 10.2",
        .explain =
        \\Tasks are not inlined into the processes that enable them. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1207 = .{
        .title = "a function --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 10.4",
        .explain =
        \\Functions are not inlined into the expressions that call them. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1208 = .{
        .title = "a named event --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 9.7.3",
        .explain =
        \\A named event is a simulation synchronization with no hardware. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1209 = .{
        .title = "a pullup or pulldown --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 7.8",
        .explain =
        \\A pull source drives a net at a strength; RTLIL nets carry no strength.
        \\`vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1210 = .{
        .title = "a switch primitive --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 7.5",
        .explain =
        \\MOS, CMOS and bidirectional pass switches are switch-level models with
        \\no RTLIL cell. `vera --run` simulates the design; --emit-rtlil lowers
        \\only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and
        \\refuses the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1211 = .{
        .title = "an analog branch --emit-rtlil does not lower",
        .lrm = "3.12",
        .explain =
        \\A branch joins two analog nodes; RTLIL has no analog node. --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL:
        \\it is digital only.
        ,
    },
    .E1212 = .{
        .title = "a port expression --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 12.3.1",
        .explain =
        \\A header port written `.name(expr)` or as a concatenation is not a plain
        \\port name, and an RTLIL wire port is one name. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1213 = .{
        .title = "a header port that selects part of its net",
        .lrm = "A.1.3",
        .explain =
        \\A.1.3's port_reference may select part of its net; that port is narrower
        \\than the net, and an RTLIL port is a whole wire. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1214 = .{
        .title = "a wreal port --emit-rtlil does not lower",
        .lrm = "3.7",
        .explain =
        \\A wreal carries a real value; RTLIL wires are bits. --emit-rtlil lowers
        \\only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL: it is
        \\digital only.
        ,
    },
    .E1215 = .{
        .title = "a wreal net --emit-rtlil does not lower",
        .lrm = "3.7",
        .explain =
        \\A wreal carries a real value; RTLIL wires are bits. --emit-rtlil lowers
        \\only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL: it is
        \\digital only.
        ,
    },
    .E1216 = .{
        .title = "a net array --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 4.9",
        .explain =
        \\A net with unpacked dimensions is not lowered to one RTLIL wire per
        \\element. `vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1217 = .{
        .title = "a memory --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 4.9.3",
        .explain =
        \\A reg array is not lowered to an RTLIL memory. `vera --run` simulates
        \\the design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1218 = .{
        .title = "a real variable --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 4.8",
        .explain =
        \\A real or realtime variable holds a floating-point value; RTLIL wires
        \\are bits. `vera --run` simulates the design; --emit-rtlil lowers only
        \\the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses
        \\the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1219 = .{
        .title = "a string variable --emit-rtlil does not lower",
        .lrm = "",
        .explain =
        \\A string variable has no RTLIL wire. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1220 = .{
        .title = "a range --emit-rtlil cannot fold to a constant",
        .lrm = "IEEE 1364-2005 4.3.1",
        .explain =
        \\A declared `[msb:lsb]` must fold to integers here, from literals and
        \\parameters at their defaults; a function or a value outside 64 bits does
        \\not. `vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1221 = .{
        .title = "a range whose bounds do not fit RTLIL's 32-bit wire offset",
        .lrm = "IEEE 1364-2005 4.3.1",
        .explain =
        \\RTLIL's wire offset is a C int: a bound outside -2^31 to 2^31 - 1 has no
        \\spelling. `vera --run` simulates the design; --emit-rtlil lowers only
        \\the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses
        \\the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1222 = .{
        .title = "a range wider than RTLIL's 2^31 - 1 bits",
        .lrm = "IEEE 1364-2005 4.3.1",
        .explain =
        \\RTLIL's wire width is a C int. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1223 = .{
        .title = "a parameter default --emit-rtlil cannot fold to a constant",
        .lrm = "IEEE 1364-2005 12.2",
        .explain =
        \\Parameters fold at their defaults, from literals and earlier parameters;
        \\a function call or a system function other than `$clog2`, `$signed` and
        \\`$unsigned` does not fold. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1224 = .{
        .title = "a name not declared in its module",
        .lrm = "IEEE 1364-2005 4.5",
        .explain =
        \\Every name an expression or a target reads must be a port, net, variable
        \\or parameter of the module: --emit-rtlil creates no implicit net. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1225 = .{
        .title = "a real literal --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 3.5.2",
        .explain =
        \\A real constant has no RTLIL bit value outside an `initial` or parameter
        \\value that converts it. `vera --run` simulates the design; --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL,
        \\and refuses the rest by name rather than emit RTLIL whose circuit
        \\differs.
        ,
    },
    .E1226 = .{
        .title = "a string literal --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 3.6",
        .explain =
        \\A string literal is not lowered to its bits in an expression. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1227 = .{
        .title = "a hierarchical reference --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 12.5",
        .explain =
        \\A hierarchical name reads a signal of another module, which an RTLIL
        \\module cannot see. `vera --run` simulates the design; --emit-rtlil
        \\lowers only the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL,
        \\and refuses the rest by name rather than emit RTLIL whose circuit
        \\differs.
        ,
    },
    .E1228 = .{
        .title = "a function call --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 10.4",
        .explain =
        \\Functions are not inlined. `vera --run` simulates the design;
        \\--emit-rtlil lowers only the synthesizable subset of IEEE 1364-2005 to
        \\Yosys RTLIL, and refuses the rest by name rather than emit RTLIL whose
        \\circuit differs.
        ,
    },
    .E1229 = .{
        .title = "an expression no synthesizable design has here",
        .lrm = "IEEE 1364-2005 5",
        .explain =
        \\The expression is an analog, event or range form where a digital value
        \\is read. `vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1230 = .{
        .title = "a system function --emit-rtlil does not lower",
        .lrm = "IEEE 1364-2005 17",
        .explain =
        \\Only `$signed`, `$unsigned` (one argument) and `$clog2` of a constant
        \\are lowered. `vera --run` simulates the design; --emit-rtlil lowers only
        \\the synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses
        \\the rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1231 = .{
        .title = "a `$clog2` of a non-constant",
        .lrm = "IEEE 1364-2005 17.11.1",
        .explain =
        \\`$clog2` folds at its constant argument; there is no RTLIL cell for it.
        \\`vera --run` simulates the design; --emit-rtlil lowers only the
        \\synthesizable subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the
        \\rest by name rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1232 = .{
        .title = "a real parameter read in an expression",
        .lrm = "IEEE 1364-2005 12.2",
        .explain =
        \\A real parameter has no bit value to read. `vera --run` simulates the
        \\design; --emit-rtlil lowers only the synthesizable subset of IEEE
        \\1364-2005 to Yosys RTLIL, and refuses the rest by name rather than emit
        \\RTLIL whose circuit differs.
        ,
    },
    .E1233 = .{
        .title = "a replication count --emit-rtlil cannot fold to a constant",
        .lrm = "IEEE 1364-2005 5.1.14",
        .explain =
        \\5.1.14: the count of `{n{...}}` is a constant expression. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1234 = .{
        .title = "a replication count that is zero or negative",
        .lrm = "IEEE 1364-2005 5.1.14",
        .explain =
        \\A replication of zero or fewer copies has no bits to lower. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1235 = .{
        .title = "a replication wider than --emit-rtlil's constant limit",
        .lrm = "IEEE 1364-2005 5.1.14",
        .explain =
        \\The replication's width passes rtlil_fold.max_width (2^20 bits). `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1236 = .{
        .title = "a part-select bound --emit-rtlil cannot fold to a constant",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\5.2.1: the bounds of `[msb:lsb]` are constant expressions. `vera --run`
        \\simulates the design; --emit-rtlil lowers only the synthesizable subset
        \\of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name rather
        \\than emit RTLIL whose circuit differs.
        ,
    },
    .E1237 = .{
        .title = "an indexed part-select width --emit-rtlil cannot fold to a constant",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\5.2.1: the width of `[base +: width]` is a constant expression. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
    .E1238 = .{
        .title = "an indexed part-select width that is zero or negative",
        .lrm = "IEEE 1364-2005 5.2.1",
        .explain =
        \\5.2.1: the width of `[base +: width]` is a positive constant. `vera
        \\--run` simulates the design; --emit-rtlil lowers only the synthesizable
        \\subset of IEEE 1364-2005 to Yosys RTLIL, and refuses the rest by name
        \\rather than emit RTLIL whose circuit differs.
        ,
    },
};
