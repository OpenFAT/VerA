//! The keyword table and the §10.6 reserved-word sets (LRM §2.8.2, §10.6,
//! annex B, annex G; IEEE 1364-2005 §19.11). In: a word's spelling. Out: its
//! keyword `Tag` (`lookupKeyword`), and whether a §10.6 set reserves it
//! (`isReserved`). The table is built at comptime from `token.Tag` (every
//! `kw_` tag is its own spelling) and `reserved_keywords` (the annex B words
//! with no tag of their own, all `kw_reserved`).
//! Cites: LRM §2.8, §2.8.2, §10.6, annex B Table B.1, annex G Tables G.6 and
//! G.7; IEEE 1364-1995, 1364-2001 and 1364-2005 reserved-word lists, §19.11.
//!
//! Contents:
//! - `pub const KeywordSet = enum(u8)`, `KeywordSet.fromSpecifier(text: []const u8) ?KeywordSet`, `KeywordSet.specifier(self: KeywordSet) []const u8`
//! - `pub const default_keyword_set: KeywordSet`
//! - `pub const Sim = enum(u8)`, `Sim.fromFlag(text: []const u8) ?Sim`
//! - `pub fn lookupKeyword(name: []const u8) ?Tag`
//! - `pub fn isReserved(name: []const u8, set: KeywordSet) bool`

const std = @import("std");
const assert = std.debug.assert;
const Tag = @import("token.zig").Tag;

/// A §10.6 version_specifier: "the valid set of reserved keywords in effect
/// when a design unit is parsed". Five sets form a chain, oldest first
/// (1364-1995 ⊂ 1364-2001 ⊂ 1364-2005 ⊂ VAMS-2.3 ⊂ VAMS-2023), so a word is
/// reserved in set `s` iff `keyword_intro` dates it no later than `s`; IEEE
/// 1364-2005 §19.11's sixth, "1364-2001-noconfig", is 1364-2001 less
/// `noconfig_words`.
///
/// §10.6: the directives "do not affect the semantics, tokens, and other
/// aspects" of the language. So the lexer ignores the set (`sin` is always
/// `kw_sin`); the parser decides whether the token may stand as an identifier
/// (`parser.identLike`). Under `begin_keywords "1364-2005", `input sin;` is
/// legal and `analog` still parses.
pub const KeywordSet = enum(u8) {
    v1364_1995,
    v1364_2001,
    /// IEEE 1364-2005 §19.11: "1364-2001" without `noconfig_words`, so it
    /// sits between its neighbours in the chain.
    v1364_2001_noconfig,
    v1364_2005,
    vams_2_3,
    vams_2023,

    /// Parses a §10.6 (IEEE 1364-2005 §19.11) version_specifier. `null` for
    /// any other string; the two standards name exactly these six, so the
    /// caller reports an unknown one.
    pub fn fromSpecifier(text: []const u8) ?KeywordSet {
        const set = specifier_map.get(text) orelse return null;
        // `specifier` is the inverse; the pair holds the two tables together.
        assert(std.mem.eql(u8, set.specifier(), text));
        return set;
    }

    /// Returns the §10.6 version_specifier string that selects `self`, the
    /// inverse of `fromSpecifier`.
    pub fn specifier(self: KeywordSet) []const u8 {
        return switch (self) {
            .v1364_1995 => "1364-1995",
            .v1364_2001 => "1364-2001",
            .v1364_2001_noconfig => "1364-2001-noconfig",
            .v1364_2005 => "1364-2005",
            .vams_2_3 => "VAMS-2.3",
            .vams_2023 => "VAMS-2023",
        };
    }
};

/// The implementation's default set when no `begin_keywords is in effect
/// (§10.6: "the implementation's default set of reserved keywords").
pub const default_keyword_set: KeywordSet = .vams_2023;

/// The language family `vera --sim=` compiles: all of Verilog-AMS, annex C's
/// Verilog-A subset of it (`Parser.verilog_a`: a digital or mixed-signal
/// construct is E0250), or IEEE 1364-2005 Verilog alone (a `.v` design under
/// a 1364 `KeywordSet`, so a Verilog-AMS construct is E0242).
pub const Sim = enum(u8) {
    verilog_ams,
    verilog_a,
    verilog,

    /// Parses the flag's value: `verilogAMS`, `verilogA` or `verilog`.
    pub fn fromFlag(text: []const u8) ?Sim {
        return sim_map.get(text);
    }
};

const sim_map = std.StaticStringMap(Sim).initComptime(.{
    .{ "verilogAMS", Sim.verilog_ams },
    .{ "verilogA", Sim.verilog_a },
    .{ "verilog", Sim.verilog },
});

const specifier_map = std.StaticStringMap(KeywordSet).initComptime(.{
    .{ "1364-1995", KeywordSet.v1364_1995 },
    .{ "1364-2001", KeywordSet.v1364_2001 },
    .{ "1364-2001-noconfig", KeywordSet.v1364_2001_noconfig },
    .{ "1364-2005", KeywordSet.v1364_2005 },
    .{ "VAMS-2.3", KeywordSet.vams_2_3 },
    .{ "VAMS-2023", KeywordSet.vams_2023 },
});

/// Every annex B keyword spelling and its tag (LRM §2.8.2), built at comptime
/// from `Tag` and `reserved_keywords`.
/// This is the reference definition. `get` scans a whole length bucket linearly,
/// so the lexer calls `lookupKeyword`, which must agree with it.
const keyword_map = std.StaticStringMap(Tag).initComptime(keyword_kvs);

/// Lane count for the bucket scan, from the target. `null` on a target with no
/// useful `u8` vector, which then uses the scalar loop only.
const kw_lanes = std.simd.suggestVectorLength(u8);

/// The first byte of each keyword, in `keyword_map.keys()` order. A few cache
/// lines, where the map's own scan walks a slice header per key.
///
/// Padded by one lane of 0, which no keyword starts with, so a full-width load
/// at any index below `keys().len` is in bounds and the extra lanes cannot
/// match. The chunk loop can then run past a bucket's end and mask it.
const kw_first: [keyword_map.keys().len + (kw_lanes orelse 1)]u8 = blk: {
    var t: [keyword_map.keys().len + (kw_lanes orelse 1)]u8 = @splat(0);
    for (keyword_map.keys(), 0..) |k, i| t[i] = k[0];
    break :blk t;
};

/// Longest keyword. `kw_len_start[L]..kw_len_start[L+1]` is the run of keys of
/// length L, which relies on `StaticStringMap` sorting its keys by length; the
/// table below fails to compile if it stops doing so.
const kw_max_len: usize = keyword_map.max_len;

const kw_len_start: [kw_max_len + 2]u16 = blk: {
    const keys = keyword_map.keys();
    for (keys[1..], keys[0 .. keys.len - 1]) |b, a| {
        if (b.len < a.len) @compileError("StaticStringMap no longer sorts keys by length");
    }
    var t: [kw_max_len + 2]u16 = undefined;
    for (keyword_map.len_indexes[0 .. kw_max_len + 1], 0..) |off, len| {
        t[len] = @intCast(off);
    }
    t[kw_max_len + 1] = keys.len;
    break :blk t;
};

const KV = struct { []const u8, Tag };

/// Annex B keywords without their own tag: IEEE 1364 primitives, specify and
/// table, config-file keywords, and the annex C.16 "not used by Verilog-A" list.
/// All lex to `.kw_reserved`; being in the map keeps them out of identifiers.
/// A spelling here must not also have a `kw_` tag (checked in `keyword_kvs`).
const reserved_keywords = [_][]const u8{
    // annex C.16. `wreal` (§3.7) declares a discrete real net there is no
    // digital kernel to drive.
    //
    // §2.8.2 makes annex B Table B.1 the whole reservation, and it has neither
    // `net_resolution` (removed by annex G Table G.7 item 5027) nor `assert`
    // (the run reads `asinh`, `assign`), so both are ordinary identifiers
    // (ch10_directives/d10_11, d10_12). `isReserved` models each set by an
    // introduction date only, so it cannot say `net_resolution` was reserved
    // under "VAMS-2.3"; that needs a retirement date as well.
    "wreal",
    // IEEE 1364 digital behavior and structure. Tagged spellings (`assign`,
    // `wait`, the A.3.4 gate types, `posedge`/`negedge`) are not listed here;
    // `keyword_intro` still dates them through `kw_1364_1995`.
    "automatic",
    "cmos",
    "deassign",
    "edge",
    "endprimitive",
    "endspecify",
    "endtable",
    "endtask",
    "force",
    "fork",
    "highz0",
    "highz1",
    "ifnone",
    "join",
    "large",
    "medium",
    "nmos",
    "noshowcancelled",
    "pmos",
    "primitive",
    "pull0",
    "pull1",
    "pulldown",
    "pullup",
    "pulsestyle_ondetect",
    "pulsestyle_onevent",
    "rcmos",
    "release",
    "rnmos",
    // `tranif`/`rtranif` stay untagged: a pass enable switch is a three-terminal
    // gate whose conduction is a logic value, a different construct from `tran`.
    "rpmos",
    "rtranif0",
    "rtranif1",
    "showcancelled",
    "small",
    "specify",
    "specparam",
    "strong0",
    "strong1",
    "table",
    "task",
    "tranif0",
    "tranif1",
    "weak0",
    "weak1",
    // configuration / library (IEEE 1364 clause 13)
    "cell",
    "config",
    "design",
    "endconfig",
    "incdir",
    "include",
    "instance",
    "liblist",
    "library",
    "use",
};

/// IEEE Std 1364-1995 reserved words (102). The oldest set §10.6 names, and a
/// subset of every later one.
const kw_1364_1995 = [_][]const u8{
    "always",    "and",          "assign",     "begin",
    "buf",       "bufif0",       "bufif1",     "case",
    "casex",     "casez",        "cmos",       "deassign",
    "default",   "defparam",     "disable",    "edge",
    "else",      "end",          "endcase",    "endfunction",
    "endmodule", "endprimitive", "endspecify", "endtable",
    "endtask",   "event",        "for",        "force",
    "forever",   "fork",         "function",   "highz0",
    "highz1",    "if",           "ifnone",     "initial",
    "inout",     "input",        "integer",    "join",
    "large",     "macromodule",  "medium",     "module",
    "nand",      "negedge",      "nmos",       "nor",
    "not",       "notif0",       "notif1",     "or",
    "output",    "parameter",    "pmos",       "posedge",
    "primitive", "pull0",        "pull1",      "pulldown",
    "pullup",    "rcmos",        "real",       "realtime",
    "reg",       "release",      "repeat",     "rnmos",
    "rpmos",     "rtran",        "rtranif0",   "rtranif1",
    "scalared",  "small",        "specify",    "specparam",
    "strong0",   "strong1",      "supply0",    "supply1",
    "table",     "task",         "time",       "tran",
    "tranif0",   "tranif1",      "tri",        "tri0",
    "tri1",      "triand",       "trior",      "trireg",
    "vectored",  "wait",         "wand",       "weak0",
    "weak1",     "while",        "wire",       "wor",
    "xnor",      "xor",
};

/// Added by IEEE Std 1364-2001 (21): generate/config/library and signedness.
const kw_1364_2001 = [_][]const u8{
    "automatic",          "cell",          "config",          "design",
    "endconfig",          "endgenerate",   "generate",        "genvar",
    "incdir",             "include",       "instance",        "liblist",
    "library",            "localparam",    "noshowcancelled", "pulsestyle_ondetect",
    "pulsestyle_onevent", "showcancelled", "signed",          "unsigned",
    "use",
};

/// IEEE 1364-2005 §19.11: "the following identifiers are excluded from the
/// reserved list" under "1364-2001-noconfig".
const noconfig_words = std.StaticStringMap(void).initComptime(.{
    .{"cell"},    .{"config"},   .{"design"},  .{"endconfig"}, .{"incdir"},
    .{"include"}, .{"instance"}, .{"liblist"}, .{"library"},   .{"use"},
});

/// Added by IEEE Std 1364-2005 (1).
const kw_1364_2005 = [_][]const u8{"uwire"};

/// Verilog-AMS keywords that postdate the "VAMS-2.3" specifier, per annex G
/// tables G.6 (v2.3.1→v2.4) and G.7 (v2.4→VAMS-2023): `$noise_table_log`
/// (G.6 item 4349), `absdelta` (G.6 item 4803), `return`/`break`/`continue`
/// (G.7 item 830) and `expm1`/`ln1p` (G.7 item 7780). Every other VAMS keyword
/// defaults to `.vams_2_3` (see `isReserved`).
const kw_vams_2023 = [_][]const u8{
    "absdelta", "break", "continue", "expm1", "ln1p", "noise_table_log", "return",
};

const keyword_intro = std.StaticStringMap(KeywordSet).initComptime(intro_kvs);

const IntroKV = struct { []const u8, KeywordSet };

const intro_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const n = kw_1364_1995.len + kw_1364_2001.len + kw_1364_2005.len + kw_vams_2023.len;
    var out: [n]IntroKV = undefined;
    var i: usize = 0;
    for (.{ kw_1364_1995, kw_1364_2001, kw_1364_2005, kw_vams_2023 }, [_]KeywordSet{
        .v1364_1995, .v1364_2001, .v1364_2005, .vams_2023,
    }) |names, set| {
        for (names) |name| {
            out[i] = .{ name, set };
            i += 1;
        }
    }
    break :kvs out;
};

/// One entry per spelling. A spelling listed twice (a tagged keyword left in
/// `reserved_keywords`) would make `lookupKeyword`'s answer depend on the
/// order `StaticStringMap`'s unstable sort leaves the two in, so it is a
/// compile error here.
const keyword_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(Tag).@"enum".field_names[@backingInt(Tag.first_keyword)..@backingInt(Tag.kw_reserved)];
    const n = reserved_keywords.len + fields.len;

    var out: [n]KV = undefined;
    var i: usize = 0;
    for (fields) |f| {
        out[i] = .{ f[3..], @field(Tag, f) };
        i += 1;
    }
    for (reserved_keywords) |name| {
        out[i] = .{ name, .kw_reserved };
        i += 1;
    }
    // Tag names are unique by construction, so a duplicate is a reserved
    // spelling that also has a tag, or one listed twice.
    for (reserved_keywords, 0..) |name, j| {
        if (@hasField(Tag, "kw_" ++ name)) @compileError("keyword spelled twice: " ++ name);
        for (reserved_keywords[0..j]) |b| if (std.mem.eql(u8, name, b)) @compileError("keyword spelled twice: " ++ name);
    }
    break :kvs out;
};

/// Returns the keyword tag spelled `name`, or null (LRM §2.8.2, annex B).
/// Same answer as `keyword_map.get(name)`, found by matching first bytes within
/// the length bucket; the differential test below holds the two together.
pub fn lookupKeyword(name: []const u8) ?Tag {
    // One compare rejects the empty string and everything longer than the
    // longest keyword; `name[0]` is in bounds after it.
    if (name.len -% 1 >= kw_max_len) return null;
    const lo: usize = kw_len_start[name.len];
    const hi: usize = kw_len_start[name.len + 1];
    assert(lo <= hi);
    assert(hi <= keyword_map.keys().len);

    if (kw_lanes) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        const needle: V = @splat(name[0]);
        var i = lo;
        while (i < hi) : (i += lanes) {
            const block: V = kw_first[i..][0..lanes].*;
            var m: Mask = @bitCast(block == needle);
            // Lanes past this bucket belong to the next length and must not
            // match. The padding covers the lanes past the table itself.
            const valid = hi - i;
            if (valid < lanes) m &= (@as(Mask, 1) << @intCast(valid)) - 1;
            while (m != 0) : (m &= m - 1) {
                const k = i + @ctz(m);
                assert(k < hi);
                if (std.mem.eql(u8, keyword_map.keys()[k], name)) return keyword_map.values()[k];
            }
        }
        return null;
    }
    return lookupKeywordScalar(name, lo, hi);
}

/// Returns whether the keyword spelled `name` is reserved under `set` (LRM
/// §10.6, annex B). Asserts that `name` is a keyword spelling.
pub fn isReserved(name: []const u8, set: KeywordSet) bool {
    assert(keyword_map.has(name));
    if (set == .v1364_2001_noconfig and noconfig_words.has(name)) return false;
    const reserved = @backingInt(keyword_intro.get(name) orelse .vams_2_3) <= @backingInt(set);
    // annex B is the union of every set: the newest reserves every keyword.
    if (set == .vams_2023) assert(reserved);
    return reserved;
}

// ---- private ----

/// Scalar form of `lookupKeyword`'s bucket scan: the fallback on a target with
/// no vectors, and the second reference in the differential test.
fn lookupKeywordScalar(name: []const u8, lo: usize, hi: usize) ?Tag {
    assert(name.len > 0);
    assert(hi <= keyword_map.keys().len);
    for (kw_first[lo..hi], lo..) |first, i| {
        if (first == name[0] and std.mem.eql(u8, keyword_map.keys()[i], name)) {
            return keyword_map.values()[i];
        }
    }
    return null;
}

test "keyword_map: spelling round-trips through lexeme" {
    for (keyword_map.keys(), keyword_map.values()) |key, tag| {
        if (tag == .kw_reserved) continue;
        try std.testing.expectEqualStrings(key, Tag.lexeme(tag).?);
    }
    try std.testing.expectEqual(Tag.kw_module, keyword_map.get("module").?);
    try std.testing.expectEqual(Tag.kw_initial_step, keyword_map.get("initial_step").?);
    try std.testing.expectEqual(Tag.kw_posedge, keyword_map.get("posedge").?);
    try std.testing.expectEqual(Tag.kw_reserved, keyword_map.get("primitive").?);
    // Not keywords: system function names (§2.8.3) and ordinary identifiers.
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("temperature"));
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("V"));
    // Nor these two, and the reason is the map's own definition: §2.8.2 makes
    // Annex B the list of all keywords and the 2023 Table B.1 carries neither.
    // Annex G item 5027 took `net_resolution` off it on purpose; `assert` was
    // never on it (the run is `asinh`, `assign`). Pinned here because both are
    // easy to re-add from an older printing. ch10_directives/d10_11, d10_12.
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("assert"));
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("net_resolution"));
}

test "lookupKeyword: differential against keyword_map, which stays the reference" {
    // Every spelling is checked three ways: the vector loop that ships, the
    // scalar reference next to it, and `keyword_map.get`, which is §2.8.2's
    // actual definition. A miscompare here is a silent miscompile: a keyword
    // read as an identifier, or the reverse.
    const check = struct {
        fn all(s: []const u8) !void {
            const want = keyword_map.get(s);
            try std.testing.expectEqual(want, lookupKeyword(s));
            if (s.len >= 1 and s.len <= kw_max_len) {
                const lo: usize = kw_len_start[s.len];
                const hi: usize = kw_len_start[s.len + 1];
                try std.testing.expectEqual(want, lookupKeywordScalar(s, lo, hi));
            }
        }
    }.all;

    // 1. Every keyword is still found. This is the only way the scan can be
    //    wrong in the direction that matters: a missed keyword changes the
    //    parse of legal source.
    for (keyword_map.keys()) |key| try check(key);

    // 2. Random spellings. Lengths sweep 0 .. 3× the lane count (32 lanes on
    //    x86_64_v3 → 0..96), so every bucket boundary, the empty case and
    //    everything past the longest keyword are exercised.
    var prng: std.Random.DefaultPrng = .init(0x2820);
    const rand = prng.random();
    var buf: [3 * 64 + 2]u8 = undefined;
    const max_len = 3 * (kw_lanes orelse 32);
    const alphabet = "abcdefghijklmnopqrstuvwxyz_0123456789ABZ";
    for (0..20_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, max_len);
        for (buf[0..len]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        try check(buf[0..len]);
    }
    try check("");
    try check("\xffodule");
    try check(&@as([32]u8, @splat('m')));

    // 3. Near misses, where a scan that stops one lane early actually shows up:
    //    every keyword with one byte dropped, one appended, and its first byte
    //    replaced by one no keyword starts with.
    for (keyword_map.keys()) |key| {
        @memcpy(buf[0..key.len], key);
        try check(buf[0 .. key.len - 1]);
        buf[key.len] = '_';
        try check(buf[0 .. key.len + 1]);
        buf[0] = 'q';
        try check(buf[0..key.len]);
    }
}

test "§10.6 keyword sets nest, and the intro table cannot drift from annex B" {
    // Anti-drift: every name that has an introduction date must actually be a
    // keyword. A typo here would silently un-reserve nothing at all.
    for (keyword_intro.keys()) |name| {
        if (keyword_map.get(name) == null) {
            std.debug.print("keyword_intro names a non-keyword: {s}\n", .{name});
            return error.NotAKeyword;
        }
    }
    // Counts straight from the standards (see the array doc comments).
    try std.testing.expectEqual(102, kw_1364_1995.len);
    try std.testing.expectEqual(21, kw_1364_2001.len);

    // The five sets are a chain: reserved in an older set ⇒ reserved in every
    // newer one. `sin` is the LRM §10.6 worked example.
    for (keyword_map.keys()) |name| {
        var prev = false;
        for ([_]KeywordSet{ .v1364_1995, .v1364_2001, .v1364_2005, .vams_2_3, .vams_2023 }) |s| {
            const now = isReserved(name, s);
            try std.testing.expect(!prev or now); // monotone
            prev = now;
        }
        try std.testing.expect(isReserved(name, .vams_2023)); // annex B is the union
    }
    try std.testing.expect(!isReserved("sin", .v1364_2005));
    try std.testing.expect(isReserved("sin", .vams_2_3));
    try std.testing.expect(isReserved("module", .v1364_1995));
    try std.testing.expect(!isReserved("localparam", .v1364_1995));
    try std.testing.expect(isReserved("localparam", .v1364_2001));
    try std.testing.expect(!isReserved("uwire", .v1364_2001));
    try std.testing.expect(isReserved("uwire", .v1364_2005));
    try std.testing.expect(!isReserved("config", .v1364_2001_noconfig)); // §19.11
    try std.testing.expect(isReserved("generate", .v1364_2001_noconfig));
    try std.testing.expect(!isReserved("uwire", .v1364_2001_noconfig));
    try std.testing.expect(!isReserved("ln1p", .vams_2_3)); // annex G.7 item 7780
    try std.testing.expect(isReserved("ln1p", .vams_2023));
    // §10.6 version_specifier strings, all five of them.
    try std.testing.expectEqual(KeywordSet.v1364_1995, KeywordSet.fromSpecifier("1364-1995").?);
    try std.testing.expectEqual(KeywordSet.v1364_2001, KeywordSet.fromSpecifier("1364-2001").?);
    try std.testing.expectEqual(KeywordSet.v1364_2005, KeywordSet.fromSpecifier("1364-2005").?);
    try std.testing.expectEqual(KeywordSet.vams_2_3, KeywordSet.fromSpecifier("VAMS-2.3").?);
    try std.testing.expectEqual(KeywordSet.vams_2023, KeywordSet.fromSpecifier("VAMS-2023").?);
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("1800-2017"));
}

test "§10.6 every version_specifier round-trips; nothing else is one" {
    for (std.enums.values(KeywordSet)) |set| {
        try std.testing.expectEqual(set, KeywordSet.fromSpecifier(set.specifier()).?);
    }
    // §10.6 and IEEE 1364-2005 §19.11 name exactly six strings.
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier(""));
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("1364-2005 "));
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("VAMS-2.4"));
}

test "§19.11 1364-2001-noconfig is 1364-2001 less exactly the ten config words" {
    for (keyword_map.keys()) |name| {
        // Between its neighbours in the chain.
        if (isReserved(name, .v1364_1995)) try std.testing.expect(isReserved(name, .v1364_2001_noconfig));
        if (isReserved(name, .v1364_2001_noconfig)) try std.testing.expect(isReserved(name, .v1364_2001));
        const differs = isReserved(name, .v1364_2001) != isReserved(name, .v1364_2001_noconfig);
        try std.testing.expectEqual(noconfig_words.has(name), differs);
    }
    try std.testing.expectEqual(@as(usize, 10), noconfig_words.keys().len);
    // An annex B keyword no 1364 list dates is a Verilog-AMS word: `wreal`
    // (§3.7) is free under 1364-2005 and reserved from VAMS-2.3 on.
    try std.testing.expect(!isReserved("wreal", .v1364_2005));
    try std.testing.expect(isReserved("wreal", .vams_2_3));
    // Annex G Table G.6 item 4803: `absdelta` arrived after VAMS-2.3.
    try std.testing.expect(!isReserved("absdelta", .vams_2_3));
    try std.testing.expect(isReserved("absdelta", .vams_2023));
}

test "lookupKeyword is case-sensitive and whole-word (§2.8: identifiers are case sensitive)" {
    try std.testing.expectEqual(Tag.kw_module, lookupKeyword("module").?);
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("Module"));
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("MODULE"));
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("modul"));
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("modules"));
    // The longest keyword sits in the last bucket, and is found there.
    var longest: []const u8 = "";
    for (keyword_map.keys()) |k| if (k.len > longest.len) {
        longest = k;
    };
    try std.testing.expectEqual(kw_max_len, longest.len);
    try std.testing.expectEqual(keyword_map.get(longest).?, lookupKeyword(longest).?);
}
