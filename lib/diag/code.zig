//! The diagnostic code catalogue: a `Code` in, its `Info` (title, LRM clause,
//! `--explain` text) out, one indexed load into a table built at comptime.
//! Each row cites its own clause in `Info.lrm`; the file's code cites none.
//!
//! The file is data: `names` lists every code in tag order and `Code` is
//! that list reified; the rows live in `codes/`, one file per class (or part
//! of one), gathered into the table at comptime, so a code without a row, or
//! a row for no code, fails to compile. It imports only `std` and its own
//! rows, so every stage can name a code without pulling in the renderer.
//!
//! Contents:
//! - `pub const Info = struct { title, lrm, explain: []const u8 }`, `annexPrefix`
//! - `pub const Code = enum(u16)`, reified from `names`; `@tagName` is its spelling
//! - `pub fn info(c: Code) Info`
//! - `pub fn retiredInfo(explanation: []const u8) Info`

const std = @import("std");

/// Static documentation for one code; every field is a comptime string literal.
pub const Info = struct {
    /// Headline after `error[E0313]: `: a lowercase noun phrase with no
    /// trailing period, code or location. Fixtures pin the code, not the title,
    /// but a title that changes meaning needs a new code.
    title: []const u8,
    /// LRM clause, e.g. `"5.6.1"`, `"A.6.4"`, `"C.7"`; the renderer prints it
    /// under every diagnostic, so messages never spell it inline. Empty for an
    /// engine limit rather than a language rule (`explain` then says so).
    lrm: []const u8,
    /// Long form for `--explain`: the rule, why it exists, how to satisfy it.
    /// Authored pre-wrapped at 76 columns; `--explain` prints it verbatim.
    explain: []const u8,

    /// Returns `"annex "` when `lrm` names an annex (`A.6.4`, `C`) and `""`
    /// for a clause number or an IEEE 1364-2005 clause, so `LRM annex C`
    /// reads as a pointer where `LRM C` reads as a typo. The LRM numbers its
    /// clauses and letters its annexes, A to H.
    pub fn annexPrefix(self: Info) []const u8 {
        if (self.lrm.len == 0) return "";
        return if (self.lrm[0] >= 'A' and self.lrm[0] <= 'H') "annex " else "";
    }

    // Budget: three slices, 48 B for each of the catalogue's rows.
    comptime {
        if (@sizeOf(Info) > 48) @compileError("Info grew: every catalogue row pays for it");
    }
};

/// Every diagnosable condition VerA can report, reified from `names` in tag
/// order (`E0101` is 0). The tag name is the rendered spelling: `@tagName`,
/// one letter and four digits (the catalogue test pins the shape).
///
/// Adding a code:
///   - Codes are stable: fixtures, docs and user scripts pin them. A code is
///     never renumbered or reused; retire one by keeping its name and giving
///     it `retiredInfo`. A new name goes at the end of its class's run in
///     `names`, its row in that class's file under `codes/`.
///   - The first letter is the severity (`E` error, `W` warning).
///   - The first two digits are the owning stage class:
///       01 lexical and preprocessing    06 numerical safety (proof)
///       02 syntax, annex A (parser)     07 events and timing
///       03 types, disciplines, decls    08 system tasks and functions
///       04 behavioral semantics         09 hierarchy and elaboration
///       05 analog operators and math    10 runtime and artifact contract
pub const Code = @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, names.len));

/// Every code's spelling, in tag order: `Code`'s fields.
const names = [_][]const u8{
    // ---------------------------------------------------------------- class 1
    // Preprocessing directives (LRM 10) — preprocessor.zig.
    "E0101", "E0102", "E0103", "E0104", "E0105", "E0106", "E0107", "E0108",
    "E0109", "E0110", "E0111", "E0112", "E0113", "E0114", "E0115", "E0116",
    "E0117", "E0118", "E0119", "E0120", "E0121", "E0122", "E0123", "E0124",
    "E0125", "E0126", "E0127", "E0128", "E0129",
    // Lexical (LRM 2) — reported by parser.zig against a lexer `.invalid` token
    // or a `ValueError` from `Lexer.decode*`.
    "E0130", "E0131", "E0132",
    "E0133", "E0134", "E0135", "E0136", "E0137", "E0138", "E0139", "E0140",
    "E0141", "E0142", "E0143", "E0144", "E0145",
    // Out of scope (IEEE 1364-2005 §28) — preprocessor.zig.
    "E0146", "E0147",
    // Lexical (LRM 2.7) — parser.zig's string-literal scan.
    "E0148",
    "W0149", "E0150", "W0151", "E0152", "E0153",
    // Engine limit — preprocessor.zig's file table.
    "E0154",

    // ---------------------------------------------------------------- class 2
    // Syntax / annex A — parser.zig.
    "E0201", "E0202",
    "E0203", "E0204", "E0205", "E0206", "E0207", "E0208", "E0209", "E0210",
    "E0211", "E0212", "E0213", "E0214", "E0215", "E0216", "E0217", "E0218",
    "E0219", "E0220", "E0221", "E0222", "E0223", "E0224", "E0225", "E0226",
    "E0227", "E0228", "E0229", "E0230", "E0231", "E0232", "E0233", "E0234",
    "E0235", "E0236", "E0237", "E0238", "E0239", "E0240", "E0241", "E0242",
    "E0243", "E0244", "E0245", "E0246", "E0247", "E0248", "E0249", "E0250",
    "E0254", "E0255", "E0256", "E0257", "E0258", "E0295", "E0296", "E0297",
    "E0289", "E0290", "E0291", "E0292", "E0293", "W0250", "W0251", "W0252",
    "W0253", "W0259",

    // ---------------------------------------------------------------- class 3
    // Declarations, types, disciplines — src/analog/.
    "E0301", "E0302", "E0303", "E0304", "E0305", "E0306",
    "E0307", "E0308", "E0309", "E0310", "E0311", "E0312", "E0313", "E0314",
    "E0315", "E0316", "E0317", "E0318", "E0319", "E0320", "E0321", "E0322",
    "E0323", "E0324", "E0325", "E0326", "E0327", "E0328", "E0329", "E0330",
    "E0331", "E0332", "E0333", "E0334", "E0335", "E0336", "E0337", "E0338",
    "E0339", "E0340", "E0341", "E0342", "E0343", "E0344", "E0345", "E0346",
    "E0347", "E0348", "E0349", "E0350", "E0351", "E0352", "E0353", "E0354",
    "E0355", "E0356", "E0357", "E0358", "E0359", "E0360", "E0361", "E0362",
    "E0363", "E0364", "E0365", "E0366", "E0367", "E0368", "E0369", "E0370",
    "E0371", "E0372", "E0373", "E0374", "E0375", "E0376", "E0377", "E0378",

    // ---------------------------------------------------------------- class 4
    // Behavioral semantics: statements and contributions — src/analog/.
    "E0401", "E0402", "E0403", "E0404", "E0405", "E0406", "E0407", "E0408",
    "E0409", "E0410", "E0411", "E0412", "E0413", "E0414", "E0415", "E0416",
    "E0417", "E0418", "E0419", "E0420", "E0421", "E0422", "E0423", "E0424",
    "E0425", "E0426", "E0427", "E0428", "E0429", "E0430", "E0431", "E0432",
    "E0433", "E0434", "E0435", "E0436", "E0437", "E0438", "E0439", "E0440",
    "E0477",

    // ---------------------------------------------------------------- class 5
    // Analog operators and math functions — src/analog/.
    "E0501", "E0502", "E0503", "E0504", "E0505", "E0506", "E0507",
    "E0508", "E0509", "E0510", "E0511", "E0512", "E0513", "E0514", "E0515",
    "E0516", "E0517", "E0518", "E0519", "E0520", "E0521", "E0522", "E0523",
    "E0524", "E0525", "E0526", "E0527", "E0528", "E0529", "E0530", "E0531",
    "E0532", "E0533", "E0534", "E0535", "E0536", "E0537", "E0538", "E0539",
    "E0540", "E0572", "E0573", "E0574",

    // ---------------------------------------------------------------- class 6
    // Numerical safety / finiteness — proof.zig.
    "E0601", "E0602", "E0603", "E0604",
    "E0605", "E0606", "E0607", "E0608", "E0609", "W0650", "W0651", "W0652",
    "W0653",

    // ---------------------------------------------------------------- class 7
    // Events and timing — src/analog/.
    "E0701", "E0702", "E0703", "E0704", "E0705", "E0706", "E0707",
    "E0708",
    // A monitored event under the fixed-grid testbench, which inserts no
    // timepoint at a crossing or timer.
    "W0750",

    // ---------------------------------------------------------------- class 8
    // System tasks and functions — src/analog/.
    "E0801", "E0802", "E0803", "E0804", "E0805", "E0806",
    "E0807", "E0808", "E0809", "E0810", "E0811", "E0812", "E0813", "E0814",
    "E0815", "E0816", "E0817", "E0818", "E0819", "W0850", "W0852",

    // ---------------------------------------------------------------- class 9
    // Hierarchy and elaboration — src/analog/, src/elab/.
    "E0901",
    "E0902", "E0903", "E0904", "E0905", "E0906", "E0907", "E0908", "E0909",
    "E0910", "E0911", "E0912", "E0913", "E0914", "E0915", "E0916", "E0917",

    // --------------------------------------------------------------- class 10
    // Runtime / artifact contract — codegen.zig, root.zig.
    "E1001", "E1002", "E1003", "E1004", "E1010", "E1011", "E1012", "E1013",
    "E1014", "E1015", "E1016", "E1017", "E1018", "E1019", "E1020", "E1021",
    "E1022", "E1100", "E1101",
    // IEEE 1364-2005 §17.2.10: an SDF file `$sdf_annotate` cannot read.
    "E1102",
    // IEEE 1364-2005 §16: an SDF construct the annotator does not apply.
    "W1105",
    // A `.v` design that cannot be a contract device.
    "E1103",
    // A SystemVerilog source.
    "E1104",
    // IEEE 1364-2005 §15: a timing check argument the digital engine
    // cannot bind (a notifier that is no variable, an event terminal that
    // is no whole or constant-select vector).
    "E1147",
    // IEEE 1364-2005 Tables 15-1..15-11: a limit or threshold that is not
    // a non-negative constant expression.
    "E1148",
    // IEEE 1364-2005 §15: a timing check form the digital engine does not
    // evaluate, refused by name.
    "E1149", "W1150", "W1151", "W1152", "W1153", "W1154",
    // A `.v` device whose digital tick is 1 s.
    "W1155",
    // A `$readmem` file address outside the memory, with no bounds given.
    "W1156",
    // IEEE 1364-2005 §17.2.9: a `$readmem` load that cannot go on (a file
    // address outside the task's range, a malformed word or address, a
    // file that cannot be read, a bound outside the memory); the load is
    // terminated, the run goes on.
    "W1157", "W1160",
    // IEEE 1364-2005 §12.2.2.1: more ordered parameter values than the
    // module has parameters; the extra ones are ignored.
    "W1161",
    // IEEE 1364-2005 §15.5.1: negative timing check limits no delayed
    // signals can meet; the most negative one is set to 0.
    "W1162",
    // IEEE 1364-2005 §15: a timing check reported a violation at run time.
    "W1199",
    // --------------------------------------------------------------- class 12
    // `--emit-rtlil` refusals: a construct outside the synthesizable subset
    // (src/codegen/digital/rtlil*.zig), one code per refusal.
    "E1200", "E1201",
    "E1202", "E1203", "E1204", "E1205", "E1206", "E1207", "E1208", "E1209",
    "E1210", "E1211", "E1212", "E1213", "E1214", "E1215", "E1216", "E1217",
    "E1218", "E1219", "E1220", "E1221", "E1222", "E1223", "E1224", "E1225",
    "E1226", "E1227", "E1228", "E1229", "E1230", "E1231", "E1232", "E1233",
    "E1234", "E1235", "E1236", "E1237", "E1238", "E1239", "E1240", "E1241",
    "E1242", "E1243", "E1244", "E1245", "E1246", "E1247", "E1248", "E1249",
    "E1250", "E1251", "E1252", "E1253", "E1254", "E1255", "E1256", "E1257",
    "E1258", "E1259", "E1260", "E1261", "E1262", "E1263", "E1264", "E1265",
    "E1266", "E1267", "E1268", "E1269", "E1270", "E1271", "E1272", "E1273",
    "E1274", "E1275", "E1276", "E1277", "E1278", "W1050", "W0950", "W0951",
    "E0952", "E0953", "E0820", "E0821", "E0822", "E0824", "E0918", "E0919",
    "E0920", "E0921", "E0922", "E0923", "E0924", "E0925", "E0926", "E0927",
    "E0928", "E0929", "E0930", "E0960", "E0982", "E0997", "E0998", "E0482",
    "E0483", "E0484", "E0485", "E0486", "E0887", "E0888", "E0889", "E0890",
    // §9.17.3 a `$limit` argument that is not the form Syntax 9-12 spells.
    "E0891",
    // §9.14 / IEEE 1364-2005 §17.11.1 `$clog2` takes an integral operand.
    "E0892",
    // §9.14 an analog wide operand whose high bits the carrier erased.
    "E0893", "E0894",
    // §9.17.3 a `$limit` site the device does not honour: the probe is
    // returned unchanged, which the clause permits.
    "W0853",
    // A `$limit` seed on a branch `seed` does not start: named, never
    // silently dropped.
    "W0854",
    // §9.16 a `$simprobe` name that does not fold: run-time resolution is
    // not implemented, and the fallback would answer a valid name wrongly.
    "E0823",
    // `--emit-osdi` of a device with `$vera_reject_step`: OSDI 0.4 has no
    // slot for a step-rejection request (VD-102).
    "E1099",
    // `--emit-osdi` of a device whose §4.6.4.6 noise generator feeds two
    // rows: OSDI 0.4 reports them as independent sources (VD-102).
    "W1098",
    // LRM 4.5.7: an absdelay history ring that filled while its window was
    // still needed now keeps older samples at a coarser spacing.
    "W1051",
    // §9.4.3 the '#' flag on a conversion that has no alternative form.
    "E0825",
    // §9.4.2 Table 9-21's `%%` written with a flag, width or precision.
    "E0826",
    // IEEE 1364-2005 §17.1.1.2 C's '-', '+' or ' ' flag on a digital-context
    // conversion that is not a real one.
    "E0827",
    // §9.4.3 an analog-context format's field width or precision past
    // VerA's limit of 2^30.
    "E0828",
    // §9.2 a system function the tables allow in the digital context that
    // VerA's digital engine does not run, refused by name.
    "E0829",
};

/// Every class's rows (`codes/`), in catalogue order.
const row_files = .{
    @import("codes/class01a.zig"),
    @import("codes/class01b.zig"),
    @import("codes/class02a.zig"),
    @import("codes/class02b.zig"),
    @import("codes/class02c.zig"),
    @import("codes/class03a.zig"),
    @import("codes/class03b.zig"),
    @import("codes/class03c.zig"),
    @import("codes/class04a.zig"),
    @import("codes/class04b.zig"),
    @import("codes/class05a.zig"),
    @import("codes/class05b.zig"),
    @import("codes/class06.zig"),
    @import("codes/class07.zig"),
    @import("codes/class08a.zig"),
    @import("codes/class08b.zig"),
    @import("codes/class09a.zig"),
    @import("codes/class09b.zig"),
    @import("codes/class10a.zig"),
    @import("codes/class10b.zig"),
    @import("codes/class12a.zig"),
    @import("codes/class12b.zig"),
};

// Rows bind to codes by field name; the switch-free literal never reaches the
// binary. What does: one 48 B row per code of `.rodata` plus the text, and
// nothing touched until a diagnostic renders. Rows of u32 offsets into one
// blob would save ~14 KB of the binary and no RSS; not worth a second encoding.
// `EnumArray.init`'s field-struct check is the loop's: each row names a
// `Code` field (`@field` fails on any other name), once, and every code has
// one. A row is an anonymous literal, copied field by field into `Info`.
const table: std.enums.EnumArray(Code, Info) = blk: {
    @setEvalBranchQuota(64 * names.len);
    var t: std.enums.EnumArray(Code, Info) = undefined;
    var seen: std.enums.EnumSet(Code) = .empty;
    for (row_files) |file| {
        for (@typeInfo(@TypeOf(file.rows)).@"struct".field_names) |n| {
            const c = @field(Code, n);
            if (seen.contains(c)) @compileError("two rows for " ++ n);
            seen.insert(c);
            const r = @field(file.rows, n);
            t.set(c, .{ .title = r.title, .lrm = r.lrm, .explain = r.explain });
        }
    }
    for (std.enums.values(Code)) |c| {
        if (!seen.contains(c)) @compileError("no row for " ++ @tagName(c));
    }
    break :blk t;
};

/// Returns the documentation for `c` with one indexed load.
pub fn info(c: Code) Info {
    return table.get(c);
}

/// The row of a retired code: its title says so and `explanation` says what
/// replaced it. The `codes/` files give it to every code they retire.
pub fn retiredInfo(explanation: []const u8) Info {
    return .{
        .title = "(retired)",
        .lrm = "",
        .explain = explanation,
    };
}

test "every code has info and a well-formed name" {
    @setEvalBranchQuota(4000);
    const e = @typeInfo(Code).@"enum";
    inline for (e.field_names) |name| {
        const i = info(@field(Code, name));

        // The tag name IS the rendered code: one letter, then four digits.
        try std.testing.expectEqual(@as(usize, 5), name.len);
        try std.testing.expect(name[0] == 'E' or name[0] == 'W');
        for (name[1..]) |ch| try std.testing.expect(std.ascii.isDigit(ch));

        // A title that is empty, capitalised or punctuated renders wrong: it is
        // pasted straight after "error[E0313]: ". An acronym ("IEEE 1800 ...",
        // W0151) is not a capitalised word: its whole first word is upper case.
        try std.testing.expect(i.title.len > 0);
        try std.testing.expect(i.title[i.title.len - 1] != '.');
        const word = i.title[0 .. std.mem.findScalar(u8, i.title, ' ') orelse i.title.len];
        if (std.ascii.isUpper(word[0])) {
            for (word) |ch| try std.testing.expect(std.ascii.isUpper(ch) or std.ascii.isDigit(ch));
        }
        try std.testing.expect(i.explain.len > 0);
    }
}

test "a refusal cites the clause that states its rule (#62)" {
    // §4.2.11: "The arithmetic shift operators can not be used in an analog
    // block." §4.2.10: "The reduction operators can not be used inside the
    // analog block". Annex C.5 removes only `===` and `!==`, so neither is C.
    try std.testing.expectEqualStrings("4.2.11", info(.E0324).lrm);
    try std.testing.expectEqualStrings("4.2.10", info(.E0320).lrm);
    // §3.6.1.2 defines the `access` attribute; the 2023 LRM has no §3.6.1.4.
    try std.testing.expectEqualStrings("3.6.1.2", info(.E0501).lrm);
}

test "a parse error cites the production that derives the text (#68)" {
    // A.1.2: "source_text ::= { description }". E0201 is a token that begins
    // no description; annex C (the Verilog-A subset) states no such rule.
    try std.testing.expectEqualStrings("A.1.2", info(.E0201).lrm);
    // E0207 fires inside every production; A.1.2's start symbol is the one
    // they all derive from, where the bare "A" named the whole annex.
    try std.testing.expectEqualStrings("A.1.2", info(.E0207).lrm);
}
