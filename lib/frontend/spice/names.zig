//! SPICE spellings in, Verilog-AMS ones out: a SPICE number with its scale
//! suffix (`spiceNumber`), whether a word is a §2.8 identifier or a SPICE
//! name, and the §2.8.1 escaped spelling of one that is not an identifier.
//! Cites: LRM §2.6.2 Table 2-1, §2.8, §2.8.1, annex E.2.1.
//!
//! Contents:
//! - `pub fn spiceNumber(t: []const u8) ?f64`
//! - `pub fn spiceScale(rest: []const u8) struct`
//! - `pub fn isIdent(t: []const u8) bool`
//! - `pub fn isSpiceName(t: []const u8) bool`
//! - `pub fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice_cards = @import("../spice_cards.zig");
const Refusal = spice_cards.Refusal;
const File = spice_cards.File;
const keyword = @import("../keyword.zig");
const spice_card = @import("card.zig");
const strip = spice_card.strip;

/// Parses SPICE's scaled notation, which annex E prints throughout its
/// netlists (`10K`, `1P`, `0.3NS`, `1MA`). E.2.2.3 translates `10K` as
/// `10k`, which §2.6.2 Table 2-1 makes ten thousand.
///
/// The scale letter is followed by unit letters that carry no value (`PF`, `UH`,
/// `NS`, `MA`), so anything after the matched suffix is ignored rather than
/// rejected. Returns null when the token does not start with a number at all,
/// when its exponent does not fit an i32, or when a scaled number's joined
/// text passes 128 bytes; a value past f64's range is an infinity. Never
/// panics.
pub fn spiceNumber(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    const digits = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    }
    if (i == digits or (i == digits + 1 and t[digits] == '.')) return null;
    const mant_end = i;
    assert(mant_end <= t.len);
    // An exponent only if it is complete: `1E-18` is a number, the `E` of a bare
    // `1EXP` is the start of unit noise.
    var own: i32 = 0;
    if (i < t.len and t[i] == 'e') {
        var j = i + 1;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        if (j < t.len and std.ascii.isDigit(t[j])) {
            while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
            own = std.fmt.parseInt(i32, t[i + 1 .. j], 10) catch return null;
            i = j;
        }
    }
    const scale = spiceScale(t[i..]);
    if (scale.exp == 0) return (std.fmt.parseFloat(f64, t[0..i]) catch return null) * scale.mul;
    // Rounds once, as `Lexer.scaleExp`'s callers do: `50n` is
    // parseFloat("50e-9"), while 50 * 1e-9 is a different double.
    var buf: [128]u8 = undefined;
    // i64: an exponent at the end of i32 plus the scale's would overflow.
    const joined = std.mem.print(&buf, "{s}e{d}", .{ t[0..mant_end], @as(i64, own) + scale.exp }) catch return null;
    return std.fmt.parseFloat(f64, joined) catch null;
}

/// Berkeley SPICE's ten scale factors, as a power of ten (`exp`) or, for
/// `mil`, a factor. `meg` and `mil` are tested before `m` because they share
/// its first letter and mean 1e6 and 25.4e-6, not 1e-3 with unit noise. SPICE
/// and §2.6.2 Table 2-1 disagree on `M` (milli in SPICE, mega in Verilog),
/// which is why a card's number is converted to plain decimal here rather
/// than handed on with its suffix. SPICE has no atto, so `1A` is one ampere.
pub fn spiceScale(rest: []const u8) struct { exp: i32 = 0, mul: f64 = 1.0 } {
    assert(rest.len <= std.math.maxInt(u32));
    if (std.mem.startsWith(u8, rest, "meg")) return .{ .exp = 6 };
    if (std.mem.startsWith(u8, rest, "mil")) return .{ .mul = 25.4e-6 };
    const scales = [_]struct { suffix: u8, exp: i32 }{
        .{ .suffix = 't', .exp = 12 },
        .{ .suffix = 'g', .exp = 9 },
        .{ .suffix = 'k', .exp = 3 },
        .{ .suffix = 'm', .exp = -3 },
        .{ .suffix = 'u', .exp = -6 },
        .{ .suffix = 'n', .exp = -9 },
        .{ .suffix = 'p', .exp = -12 },
        .{ .suffix = 'f', .exp = -15 },
    };
    if (rest.len != 0) for (scales) |s| if (rest[0] == s.suffix) return .{ .exp = s.exp };
    return .{};
}

/// Reports whether `t` has the §2.7 shape of a simple identifier. `$` is not
/// admitted even though §2.7 allows it in an identifier: `strip` has
/// already treated it as a comment opener, so it cannot reach here.
pub fn isIdent(t: []const u8) bool {
    if (t.len == 0) return false;
    if (!std.ascii.isAlphabetic(t[0]) and t[0] != '_') return false;
    for (t) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    // An identifier is a SPICE name too, so `spell` may write it bare.
    assert(isSpiceName(t));
    return true;
}

/// Reports whether `t` is a SPICE model, subcircuit or node name. SPICE names
/// may lead with digits (`2N2222`) and bare numbers are the default node
/// spelling, so anything printable that is not a parameter (`k=v`, `params:`)
/// qualifies; `spell` decides how it is written.
pub fn isSpiceName(t: []const u8) bool {
    if (t.len == 0) return false;
    assert(t.len <= std.math.maxInt(u32));
    for (t) |c| if (c < 33 or c > 126 or c == '=' or c == ':') return false;
    return true;
}

/// Returns `t` as it must be written to declare it: bare when it is a simple
/// identifier and not a keyword, otherwise as a §2.8.1 escaped identifier
/// (`\wire `, `\2n2222 `), since SPICE has no reserved words and no §2.7
/// shape rule. An escaped identifier is never a keyword (§2.8.2), and neither
/// the `\` nor the terminating white space is part of the name, so lookups
/// still see `wire`. The trailing space is required: `,` and `)` are printable
/// and would otherwise be scanned into the identifier.
pub fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    assert(t.len > 0);
    // ponytail: share the lexer's keyword lookup; extend the common table for new keywords.
    if (isIdent(t) and @import("../keyword.zig").lookupKeyword(t) == null) return t;
    return arena.print("\\{s} ", .{t});
}
