const std = @import("std");

/// Whether `name` is a system function whose §9.2 "supported in analog
/// context" cell says No, across the seven Chapter 9 tables (E0806).
///
/// A name test, with no context flag: every statement lowering sees is in the
/// analog context (A.6.2 `analog_construct`, with §4.7.2 function bodies
/// inlined into one).
pub fn isDigitalOnlySysFunc(name: []const u8) bool {
    // ponytail: add the flag when a §7 digital block is lowered here.
    const digital_only = comptime nameSet(&.{
        // Table 9-1 (§9.4.1) — radix variants and the $monitor mode switches.
        "$displayb",         "$displayh",         "$displayo",
        "$strobeb",          "$strobeh",          "$strobeo",
        "$writeb",           "$writeh",           "$writeo",
        "$monitorb",         "$monitorh",         "$monitoro",
        "$monitoron",        "$monitoroff",
        // Table 9-2 (§9.5) — the same radix story against a descriptor, plus
        // the byte/vector reads and the two digital-netlist loaders.
              "$fdisplayb",
        "$fdisplayh",        "$fdisplayo",        "$fwriteb",
        "$fwriteh",          "$fwriteo",          "$fstrobeb",
        "$fstrobeh",         "$fstrobeo",         "$fmonitorb",
        "$fmonitorh",        "$fmonitoro",        "$swriteb",
        "$swriteh",          "$swriteo",          "$fgetc",
        "$ungetc",           "$fread",            "$readmemb",
        "$readmemh",         "$sdf_annotate",
        // Table 9-3 (§9.6) — the timescale tick, which the analog kernel has
        // no notion of.
            "$printtimescale",
        "$timeformat",
        // Table 9-5 (§9.8) — "Verilog AMS HDL does not extend the PLA modeling
        // tasks defined in IEEE Std 1364 Verilog." All sixteen spellings; the
        // `$` inside the name is an ordinary identifier character (§2.8.3), so
        // each of these is one token.
              "$async$and$array",  "$async$and$plane",
        "$async$nand$array", "$async$nand$plane", "$async$or$array",
        "$async$or$plane",   "$async$nor$array",  "$async$nor$plane",
        "$sync$and$array",   "$sync$and$plane",   "$sync$nand$array",
        "$sync$nand$plane",  "$sync$or$array",    "$sync$or$plane",
        "$sync$nor$array",   "$sync$nor$plane",
        // Table 9-6 (§9.9) — "Verilog AMS HDL does not extend the stochastic
        // analysis tasks defined in IEEE Std 1364 Verilog."
          "$q_initialize",
        "$q_remove",         "$q_exam",           "$q_add",
        "$q_full",
        // Table 9-7 (§9.10) — tick counts. $abstime is the analog spelling and
        // is the one row of that table with Yes in both columns; §9.10's NOTE
        // additionally deprecates $realtime in the analog context.
                  "$time",             "$stime",
        "$realtime",
        // Table 9-8 (§9.11) — the extension is four names, not two:
        // "$bitstoreal and $realtobits,$rtoi and $itor can be used in the
        // analog context". Table 9-8's analog column agrees — only $signed and
        // $unsigned read No, and both presuppose a sized vector.
                "$signed",           "$unsigned",
    });
    return digital_only.has(name);
}

/// Whether `name` is analog-only: its §9.2 "Supported in digital context" cell
/// is No and its analog cell Yes. §9.7 says it of the severity tasks in prose.
pub fn isAnalogOnlySysFunc(name: []const u8) bool {
    const analog_only = comptime nameSet(&.{
        "$debug", "$fdebug", // Tables 9-1/9-2
        "$fatal", "$warning", "$error", "$info", // Table 9-4
        "$simprobe", // §9.15
        "$discontinuity", "$limit", "$bound_step", // §9.17
        "$vera_reject_step", // VerA's step rejection
        "$param_given", "$port_connected", // §9.19
        "$analog_node_alias", "$analog_port_alias", // §9.20
    });
    return analog_only.has(name);
}

/// §9.22 paragraph 3, second sentence: "Driver access functions can only be
/// called from connect modules." §9.23 repeats the fence for its four
/// supplementary functions ("supported in the digital context of
/// connectmodules"), and Table 9-19 gives every name below "Supported in analog
/// context of connectmodule: No".
///
/// A rule about the call site: an ordinary module is not a connect module, so
/// the call is illegal on sight. Answering 0 in codegen would look right and be
/// wrong, since §9.22.2/§9.22.3/§9.23.x index "between 0 and N-1".
///
/// A name test like `isDigitalOnlySysFunc`: every call site lowering reaches is
/// inside the elaborated device, and `elaborate.pickTop` never picks a connect
/// module (§7.6), so a driver call inside one is never lowered here.
///
/// `$receiver_count` is listed because its "Non-normative" §9.22.1 paragraph
/// sits inside §9.22, takes the same `signal_name` argument, and Table 9-19
/// carries it with the rest.
pub fn isConnectModuleOnlySysFunc(name: []const u8) bool {
    const cm_only = comptime nameSet(&.{
        // §9.22.1–§9.22.3 and the §9.22.1 non-normative paragraph.
        "$driver_count",         "$receiver_count", "$driver_state",
        "$driver_strength",
        // §9.23.1–§9.23.4, the supplementary pending-event queries.
             "$driver_delay",   "$driver_next_state",
        "$driver_next_strength", "$driver_type",
    });
    return cm_only.has(name);
}

/// `names` as a comptime set, so each list above keeps its per-table comments.
fn nameSet(comptime names: []const []const u8) std.StaticStringMap(void) {
    var kvs: [names.len]struct { []const u8 } = undefined;
    for (names, &kvs) |n, *kv| kv.* = .{n};
    return .initComptime(kvs);
}

test isDigitalOnlySysFunc {
    try std.testing.expect(isDigitalOnlySysFunc("$time")); // Table 9-7
    try std.testing.expect(isDigitalOnlySysFunc("$async$and$array")); // Table 9-5, one token (§2.8.3)
    try std.testing.expect(isDigitalOnlySysFunc("$displayb")); // Table 9-1
    try std.testing.expect(!isDigitalOnlySysFunc("$abstime")); // Yes in both columns
    try std.testing.expect(!isDigitalOnlySysFunc("$realtobits")); // §9.11 extends it to analog
    try std.testing.expect(!isDigitalOnlySysFunc("$strobe"));
}

test isAnalogOnlySysFunc {
    try std.testing.expect(isAnalogOnlySysFunc("$bound_step"));
    try std.testing.expect(isAnalogOnlySysFunc("$fatal"));
    try std.testing.expect(!isAnalogOnlySysFunc("$display"));
}

test isConnectModuleOnlySysFunc {
    try std.testing.expect(isConnectModuleOnlySysFunc("$driver_count"));
    try std.testing.expect(isConnectModuleOnlySysFunc("$receiver_count"));
    try std.testing.expect(isConnectModuleOnlySysFunc("$driver_type"));
    try std.testing.expect(!isConnectModuleOnlySysFunc("$port_connected"));
}
