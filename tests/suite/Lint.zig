//! The assertion lint, the mechanical half of "restricting and true": a
//! fixture's raw source -> whether every `CHECK*` call in it can fail. A want
//! must be a numeric literal a human derived, so the compiler under test never
//! supplies its own expectation. Two exemptions, each argued at its function:
//! `CHECKEQ` (two expressions on purpose) and a want piecewise in `$abstime`.
//!
//! LRM clauses: §10.3 (what counts as a macro call), §2.5.1 and §2.6 (how a
//! literal and a scale factor are spelled), §4.5.3 (why a want may be
//! piecewise in time).
//!
//! Contents:
//! - `pub fn checkAssertions(source: []const u8) AssertionCheck`

const std = @import("std");

/// The assertion lint's finding for one source.
const AssertionCheck = union(enum) {
    /// At least one assertion, and every one of them can fail.
    ok,
    /// No `CHECK` macro anywhere in the source.
    none,
    /// `CHECK("x", expr, expr, tol)` — got and want are textually identical.
    tautology: []const u8,
    /// The want is not a numeric literal, so it may be the compiler's own output.
    computed_want: []const u8,
};

/// Finds each `CHECK*` macro call outside comments and string literals. A call
/// is §10.3's `` `identifier `` followed by `(` with at most horizontal white
/// space between; a name with no argument list is not a call, so it cannot
/// borrow a later `(` from unrelated text.
const MacroScan = struct {
    src: []const u8,
    i: usize = 0,

    const Call = struct {
        /// Spelling without the backtick, so `CHECKEQ` is compared and not
        /// prefix-matched — `CHECKEQX` would be a different macro.
        name: []const u8,
        /// Index of the backtick, where a quoted site starts.
        at: usize,
        /// Index of the `(` that opens the actual arguments.
        open: usize,
    };

    fn next(s: *MacroScan) ?Call {
        while (s.i < s.src.len) {
            switch (s.src[s.i]) {
                '/' => if (s.i + 1 < s.src.len) switch (s.src[s.i + 1]) {
                    '/' => {
                        s.i = std.mem.findScalarPos(u8, s.src, s.i, '\n') orelse s.src.len;
                        continue;
                    },
                    '*' => {
                        const end = std.mem.findPos(u8, s.src, s.i + 2, "*/");
                        s.i = if (end) |e| e + 2 else s.src.len;
                        continue;
                    },
                    else => {},
                },
                // A string literal holds a CHECK's own NAME argument, and names
                // quote code: `CHECKX("`CHECKEQ would be vacuous here", …)`.
                '"' => {
                    s.i += 1;
                    while (s.i < s.src.len and s.src[s.i] != '"') : (s.i += 1) {
                        if (s.src[s.i] == '\\') s.i += 1;
                    }
                },
                '`' => {
                    const at = s.i;
                    var j = at + 1;
                    while (j < s.src.len and isIdentChar(s.src[j])) j += 1;
                    var k = j;
                    while (k < s.src.len and (s.src[k] == ' ' or s.src[k] == '\t')) k += 1;
                    s.i = j; // always progress: `j > at`, even for a bare backtick
                    const name = s.src[at + 1 .. j];
                    if (std.mem.startsWith(u8, name, "CHECK") and
                        k < s.src.len and s.src[k] == '(')
                    {
                        s.i = k;
                        return .{ .name = name, .at = at, .open = k };
                    }
                    continue;
                },
                else => {},
            }
            s.i += 1;
        }
        return null;
    }
};

/// Lints the `CHECK*` calls in raw source: every want must be a literal a
/// human typed, never an expression the compiler under test evaluates.
/// `CHECK("sin", sin(0.5), sin(0.5), 1e-15)` passes in any compiler; this
/// rejects it. Whether the literal is right is the reviewer's job.
pub fn checkAssertions(source: []const u8) AssertionCheck {
    var found = false;
    var scan: MacroScan = .{ .src = source };
    while (scan.next()) |call| {
        const rest = source[call.at..];
        const open = call.open - call.at;
        // An unbalanced `(` is a syntax error the compile will report; it is not
        // this lint's business, and it must not abandon the CHECKs after it.
        const close = matchParen(rest, open) orelse continue;
        const site = trimLine(rest[0..@min(close + 1, rest.len)]);

        // `CHECKEQ` is the marked relational form: its want is another
        // expression on purpose, so the literal rule does not apply to it.
        const relational = std.mem.eql(u8, call.name, "CHECKEQ");

        var args: [8][]const u8 = undefined;
        const n = splitArgs(rest[open + 1 .. close], &args);
        // NAME, GOT, WANT[, TOL] — every CHECK* form puts the want third.
        if (n < 3) continue;
        found = true;

        const got = stripParens(std.mem.trim(u8, args[1], " \t\r\n\\"));
        const want = stripParens(std.mem.trim(u8, args[2], " \t\r\n\\"));
        if (std.mem.eql(u8, got, want)) {
            // Two identical LITERALS are a round-trip check on the lexer
            // (`CHECKI("unary minus", -7, -7)`) — weak, but it can fail if a
            // literal is mangled on one side. Two identical EXPRESSIONS cannot
            // fail at all, whatever the compiler does.
            if (!isNumericLiteral(got)) return .{ .tautology = site };
        } else if (!relational and !isNumericLiteral(want) and !isTimePiecewiseWant(want)) {
            return .{ .computed_want = site };
        }
    }
    return if (found) .ok else .none;
}

// ---- private ----

fn isIdentChar(c: u8) bool {
    return c == '_' or c == '$' or std.ascii.isAlphanumeric(c);
}

/// Drop redundant outer parentheses, so `(V(a,b))` and `V(a,b)` compare equal.
/// Otherwise parens around one side would hide a tautology.
fn stripParens(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    while (t.len >= 2 and t[0] == '(' and matchParen(t, 0) == t.len - 1) {
        t = std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
    }
    return t;
}

/// Index of the `)` closing the `(` at `open`, or null if unbalanced. String
/// literals are skipped so a `")"` inside a CHECK's name does not close it.
fn matchParen(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    var in_string = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Split on TOP-LEVEL commas only: `CHECKR("atan2(1,1)", atan2(1.0, 1.0), …)`
/// has commas inside both a string and a nested call, and neither separates an
/// argument. Returns the count written.
fn splitArgs(s: []const u8, out: *[8][]const u8) usize {
    var n: usize = 0;
    var depth: usize = 0;
    var in_string = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                if (n == out.len) return n;
                out[n] = s[start..i];
                n += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    if (n < out.len and start <= s.len) {
        out[n] = s[start..];
        n += 1;
    }
    return n;
}

/// Is this text a number a human wrote, and nothing else?
///
/// Deliberately strict. A leading sign and a Verilog-A real or integer literal
/// are all that is allowed — no `M_PI`, no `1.0/3.0`, no identifiers. A fixture
/// that wants pi writes its digits, which is what a reviewer checks against the
/// LRM anyway, and which no amount of compiler misbehaviour can change.
fn isNumericLiteral(s: []const u8) bool {
    var t = s;
    if (t.len != 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
    if (t.len == 0) return false;

    var seen_digit = false;
    var seen_dot = false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        switch (t[i]) {
            '0'...'9' => seen_digit = true,
            '_' => {}, // §2.5.1 allows underscores in numbers.
            '.' => {
                if (seen_dot) return false;
                seen_dot = true;
            },
            'e', 'E' => {
                if (!seen_digit) return false;
                // Exponent: an optional sign then digits, to the end.
                var j = i + 1;
                if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
                if (j == t.len) return false;
                while (j < t.len) : (j += 1) switch (t[j]) {
                    '0'...'9', '_' => {},
                    else => return false,
                };
                return true;
            },
            else => return false,
        }
    }
    return seen_digit;
}

/// The one widening of the literal rule: a want that is piecewise in TIME.
///
/// A transient fixture's expectation often changes at a `//! time` point —
/// §4.5.3 makes `ddt` zero at the DC point that opens the analysis and the ramp
/// slope after it, so "0 then 1.0" is one claim about one branch and splitting
/// it across two fixtures would test less, not more. Writing it as
/// `($abstime > 0) * 1.0` is not the thing the literal rule exists to stop: the
/// DIGITS are still typed by a human, and `$abstime` is a harness INPUT — the
/// `//! time` line supplies it — not something the compiler under test derives.
///
/// The exemption is therefore exactly as narrow as that argument: the want may
/// mention `$abstime` and nothing else with a name. Every other identifier is
/// refused, so a want cannot smuggle in `V(p)`, a parameter, or a call and
/// launder the compiler's own answer through a conditional. A want with NO
/// identifier at all is not exempt either — `2.0*1e-18` restates a derivation
/// instead of stating a number, which is the original rule's point.
///
/// An identifier is a run starting at a letter, `_` or `$` that is not preceded
/// by one — so the `n` of `1n` (§2.6's scale factor) is part of the number and
/// not a name.
fn isTimePiecewiseWant(s: []const u8) bool {
    var found_abstime = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const starts = (std.ascii.isAlphabetic(c) or c == '_' or c == '$') and
            (i == 0 or !(std.ascii.isAlphanumeric(s[i - 1]) or s[i - 1] == '_' or s[i - 1] == '.'));
        if (!starts) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_' or s[j] == '$')) j += 1;
        if (!std.mem.eql(u8, s[i..j], "$abstime")) return false;
        found_abstime = true;
        i = j;
    }
    return found_abstime;
}

/// The macro call as one line, for an error message. A CHECK often spans lines
/// via `\` continuations, and a four-line quote buries the point.
fn trimLine(s: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, s, '\n') orelse s.len;
    return std.mem.trim(u8, s[0..end], " \t\r\\");
}

test "an assertion whose want is the got cannot fail" {
    try std.testing.expect(checkAssertions(
        \\`CHECK("sin", sin(0.5), sin(0.5), 1e-15);
    ) == .tautology);
    try std.testing.expect(checkAssertions(
        \\`CHECKX("round trip", y, expected_y);
    ) == .computed_want);
    try std.testing.expect(checkAssertions("I(p,n) <+ 1.0;") == .none);
    try std.testing.expect(checkAssertions(
        \\`CHECKR("atan2(1,1)", atan2(1.0, 1.0), 0.7853981633974483, 1e-15);
    ) == .ok);
    // A negative and an exponent are both literals a human typed.
    try std.testing.expect(checkAssertions(
        \\`CHECK("limexp underflow", limexp(-80.0), -1.8048513878454153e-35, 1e-40);
    ) == .ok);
    // A concatenation's comma is inside the got, not between arguments.
    try std.testing.expect(checkAssertions(
        \\`CHECKI("concatenation", {4'h1, 16'h5}, 65541);
    ) == .ok);
    // Two identical literals round-trip the lexer; two identical expressions
    // cannot fail whatever the compiler does.
    try std.testing.expect(checkAssertions(
        \\`CHECKI("unary minus", -7, -7);
    ) == .ok);
    try std.testing.expect(checkAssertions(
        \\`CHECKI("above threshold?", V(p, n) > vth, (V(p, n) > vth));
    ) == .tautology);
    // A want piecewise in TIME is exempt: the digits are still a human's and
    // `$abstime` is what the `//! time` line put there, not something the
    // compiler under test worked out.
    try std.testing.expect(checkAssertions(
        \\`CHECK("ddt is zero at the DC point and the slope after it", I(cap), ($abstime > 0) * 1.0, 1e-9);
    ) == .ok);
    try std.testing.expect(checkAssertions(
        \\`CHECKX("three levels", Vgain * val, ($abstime < 4n) ? 0.25 : (($abstime < 12n) ? 0.5 : 0.75));
    ) == .ok);
    // ...and exactly that narrow. One other name in the want and the
    // exemption is gone, or a conditional would launder the compiler's own
    // answer past the rule.
    try std.testing.expect(checkAssertions(
        \\`CHECK("laundered", I(cap), ($abstime > 0) * V(p, n), 1e-9);
    ) == .computed_want);
    try std.testing.expect(checkAssertions(
        \\`CHECK("laundered through a parameter", I(cap), ($abstime > 0) * c, 1e-9);
    ) == .computed_want);
    // A want with no name at all restates a derivation instead of stating a
    // number, which is the rule's original point and is still refused.
    try std.testing.expect(checkAssertions(
        \\`CHECK("arithmetic", x, 2.0 * 1e-18, 1e-30);
    ) == .computed_want);
    // The marked relational form may pin two expressions together...
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("branch probe equals the node pair", V(br), V(a, b), 0.0);
    ) == .ok);
    // ...but not to itself.
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("vacuous", V(a, b), V(a, b), 0.0);
    ) == .tautology);
}

test "the assertion lint reads code, not prose" {
    // A name with no argument list must not borrow a `(` from later text.
    try std.testing.expect(checkAssertions(
        \\// so this assertion is `CHECKX and not a tolerance.
        \\I(p, n) <+ ddt(V(p, n), 1.0);
    ) == .none);
    try std.testing.expect(checkAssertions(
        \\// An earlier revision wrote `CHECKEQ(y, expected_y) here.
        \\`CHECKX("real", V(p, n), 0.5);
    ) == .ok);
    // A comment naming the macro is not an invocation even when it quotes a
    // full argument list.
    try std.testing.expect(checkAssertions(
        \\// It WAS `CHECKEQ("x", code, $fseek(fd, 0, 0), 0), which asserted nothing.
    ) == .none);
    try std.testing.expect(checkAssertions(
        \\/* `CHECK("sin", sin(0.5), sin(0.5), 1e-15); */
    ) == .none);
    // A name argument may quote a macro; the quote is data.
    try std.testing.expect(checkAssertions(
        \\`CHECKX("`CHECKEQ(V(a,b), V(a,b)) would be vacuous", V(a, b), 0.5);
    ) == .ok);
    // §10.3 allows horizontal white space before the actual arguments, but a
    // newline ends the usage: the name would be a macro taking no arguments.
    try std.testing.expect(checkAssertions(
        \\`CHECKX ("spaced", V(a, b), 0.5);
    ) == .ok);
    // An unbalanced paren is the compiler's error to report, and must not hide
    // the real defect after it.
    try std.testing.expect(checkAssertions(
        \\`CHECKX("truncated", V(a, b, 0.5);
    ) == .none);
}
