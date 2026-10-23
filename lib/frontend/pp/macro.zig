//! Text macros: a `define or `undef line in, a macro table entry out; a macro
//! use in, its expansion scanned into the output (arguments pre-expanded,
//! recursion refused).
//! LRM §2.7, §2.8.1, §10.4, §10.7; IEEE 1364 §19.3.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const diag = @import("diag");
const Error = Preprocessor.Error;
const Macro = Preprocessor.Macro;
const Pp = Preprocessor.Pp;
const scan = Preprocessor.scan;
const stringStop = Preprocessor.stringStop;
const Rest = Preprocessor.Rest;
const isSpace = Preprocessor.isSpace;
const isIdentStart = Preprocessor.isIdentStart;
const isIdentChar = Preprocessor.isIdentChar;
const identEnd = Preprocessor.identEnd;
const escapedEnd = Preprocessor.escapedEnd;

// ---------------------------------------------------------------------------
// §10.4 `define / `undef
// ---------------------------------------------------------------------------

/// Parses a §10.4 `define and adds or replaces its macro. `rest` is everything
/// after the word on one logical line, starting at offset `off`; `at` is the
/// '`'. The macro borrows `rest`, which must outlive `pp.macros`. Fails with
/// E0109 (no name), E0143 (a directive's name), E0110-E0112 (the formal
/// list), E0139 (text begins with __VAMS_) or E0145 (text splits a string).
pub fn handleDefine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Syntax 10-3 writes two different nonterminals into adjacent lines:
    //   formal_argument_identifier ::= simple_identifier
    //   text_macro_identifier      ::= identifier
    // and A.9.3 makes `identifier` simple or escaped. So the name may be
    // escaped and the formals may not. §2.8: "The first character of an
    // identifier shall not be a digit or $", and `ident` admits the `$` of a
    // system name, so that is refused here.
    const name = r.escapedIdent() orelse (if (r.peek() == '$') null else r.ident()) orelse
        return pp.fail(pp.spanAt(at, off), .E0109, "", .{});
    // IEEE 1364 §19.3.1: "All compiler directives shall be considered
    // predefined macro names; it shall be illegal to redefine a compiler
    // directive as a macro name." §10.1 Table 10-1 is the list, and it names
    // `__FILE__ and `__LINE__ too.
    if (Preprocessor.directive_map.has(name) or std.mem.eql(u8, name, "__FILE__") or std.mem.eql(u8, name, "__LINE__"))
        return pp.fail(pp.spanAt(off + r.i - name.len, off + r.i), .E0143, "`{s}` is a compiler directive", .{name});

    var m: Macro = .{ .body = "" };
    // The '(' of a formal argument list must touch the macro name (§10.4).
    if (r.peek() == '(') {
        r.i += 1;
        m.is_func = true;
        var params: std.ArrayList([]const u8) = .empty;
        while (true) {
            r.skipSpace();
            // `()` is an empty list, but `{ , formal_argument_identifier }`
            // puts a formal after every comma: `M(a,)` is malformed.
            if (params.items.len == 0 and r.peek() == ')') {
                r.i += 1;
                break;
            }
            // formal_argument_identifier ::= simple_identifier, and §2.8 bars
            // `$` as its first character (`ident` admits it for system names).
            const p = (if (r.peek() == '$') null else r.ident()) orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0110, "`{s}`", .{name});
            try params.append(pp.scratch, p);
            r.skipSpace();
            const c = r.peek() orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i), .E0111, "`{s}`", .{name});
            if (c == ',') {
                r.i += 1;
                continue;
            }
            if (c == ')') {
                r.i += 1;
                break;
            }
            return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0112, "`{s}`", .{name});
        }
        m.params = params.items;
    }
    r.skipSpace();
    m.body = try joinContinuations(pp, std.mem.trimEnd(u8, r.s[r.i..], " \t\r"));

    // §10.4: "To avoid conflicts with predefined Verilog-AMS macros (10.5), the
    // `define compiler directive's macro text shall not begin with __VAMS_."
    // The target is the text (Syntax 10-3's second operand), not the name.
    if (std.mem.startsWith(u8, m.body, "__VAMS_"))
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0139, "`{s}` begins with __VAMS_", .{m.body});

    // IEEE 1364 §19.3.1: "The text specified for macro text shall not be split
    // across the following lexical tokens: ... Strings", and its own example of
    // the illegal case is a body whose string literal never closes. The other
    // five token kinds cannot be told apart from a legal fragment here; a
    // string can, because it must close on the line that opened it (§2.7).
    if (splitsString(m.body))
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0145, "`{s}`", .{name});

    // §10.4: a redefinition silently replaces. Predefined macros keep their flag
    // so `undef still has no effect on them.
    if (pp.macros.get(name)) |old| m.predefined = old.predefined;
    try pp.putMacro(name, m);
}

/// Parses a §10.4 `undef and removes the macro; a §10.5 predefined macro is
/// left alone, and an undefined name is not an error. Arguments as for
/// `handleDefine`. Fails with E0113 when no name follows.
pub fn removeDefine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Syntax 10-3: the operand is an identifier, simple or escaped (A.9.3),
    // so `` `undef \M-X `` withdraws what `` `define \M-X `` created.
    const name = r.escapedIdent() orelse r.ident() orelse
        return pp.fail(pp.spanAt(at, off), .E0113, "", .{});
    // §10.4: "`undef shall have no effect on predefined Verilog-AMS macros".
    if (pp.macros.get(name)) |m| {
        if (m.predefined) return;
    }
    pp.removeMacro(name);
}

/// A macro body is one logical line: `\`+newline collapses to a space. The
/// newlines it swallowed are re-emitted by the caller, so lines still line up.
fn joinContinuations(pp: *Pp, body: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, body, '\n') == null) return body;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.scratch, body.len);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            var k = i + 1;
            while (k < body.len and (body[k] == ' ' or body[k] == '\t' or body[k] == '\r')) k += 1;
            if (k < body.len and body[k] == '\n') {
                // One separating space, unless the text already ends in one.
                if (out.items.len != 0 and out.items[out.items.len - 1] != ' ')
                    out.appendAssumeCapacity(' ');
                i = k;
                // Also eat the indentation of the continuation line.
                while (i + 1 < body.len and (body[i + 1] == ' ' or body[i + 1] == '\t')) i += 1;
                continue;
            }
        }
        if (body[i] == '\n' or body[i] == '\r') continue;
        out.appendAssumeCapacity(body[i]);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// §10.4 macro expansion
// ---------------------------------------------------------------------------

/// Expands the macro use whose '`' is at `at`, with `after_name` just past the
/// name, into `pp.out`. Handles §10.7 `__LINE__` and `__FILE__`. Returns the
/// offset to resume scanning from; inside an inactive arm that is
/// `after_name`, with nothing emitted. Fails with E0115 (undefined),
/// E0116/E0117 (argument list), E0118 (recursion) or E0120 (unbalanced
/// arguments), with E0150 once the text passes `Options.text_limit`, and
/// with E0119 when no stack can be reserved for the nesting. Asserts that
/// `after_name` is past `at`, so the offset returned moves the scan.
pub fn expand(pp: *Pp, text: []const u8, at: usize, after_name: usize, name: []const u8) Error!usize {
    std.debug.assert(after_name > at);
    std.debug.assert(after_name <= text.len);
    if (!pp.emitting()) return after_name;
    // The whole use, backtick included: `FOO.
    const sp = pp.spanAt(at, after_name);

    const m = pp.macros.get(name) orelse {
        // §10.7. Not in `macros` because both depend on where the use sits.
        // `handleDefine` refuses a user `define of either name (E0143).
        if (std.mem.eql(u8, name, "__LINE__")) {
            // "in the form of a simple decimal number": an integer token.
            var buf: [20]u8 = undefined;
            try pp.out.appendSlice(pp.scratch, std.mem.print(&buf, "{d}", .{pp.currentLine(at)}) catch unreachable);
            return after_name;
        }
        if (std.mem.eql(u8, name, "__FILE__")) {
            // "in the form of a string literal" (§2.7): quoted, with '"' and
            // '\' in the path escaped.
            try pp.out.appendSlice(pp.scratch, "\"");
            // A `line directive's file name replaces the real one (§10.7).
            for (pp.file_override orelse pp.opts.bag.fileName(pp.cur_file_id)) |c| {
                if (c == '"' or c == '\\') try pp.out.appendSlice(pp.scratch, "\\");
                try pp.out.append(pp.scratch, c);
            }
            try pp.out.appendSlice(pp.scratch, "\"");
            return after_name;
        }
        var b = pp.failWith(sp, .E0115);
        b.msg("`{s}", .{name});
        if (diag.didYouMeanMap(name, pp.macros)) |near| {
            // `sp` includes the backtick, so the replacement restores it.
            const repl = try pp.arena.print("`{s}", .{near});
            b.suggest(.{ .span = sp, .replacement = repl }, "did you mean `{s}`?", .{near});
        }
        try b.emit();
        return error.PreprocessFailed;
    };
    // `require_std_includes`: annex D.2's macros reach only a source that includes it.
    if (m.annex_d2 and pp.opts.require_std_includes and !pp.constants_included and !pp.in_std_defs) {
        var b = pp.failWith(sp, .E0115);
        b.msg("`{s}", .{name});
        b.note("`{s} is annex D.2's: add `include \"constants.vams\"", .{name});
        try b.emit();
        return error.PreprocessFailed;
    }

    var end = after_name;
    var args: []const []const u8 = &.{};
    if (m.is_func) {
        var k = after_name;
        while (k < text.len and isSpace(text[k])) k += 1;
        if (k >= text.len or text[k] != '(')
            return pp.fail(sp, .E0116, "`{s}` takes {d} argument(s)", .{ name, m.params.len });
        const parsed = try macroArgs(pp, text, k, at, name);
        args = parsed.args;
        end = parsed.end;
        // `M()` on a zero-parameter macro is an empty list, not one empty arg.
        if (m.params.len == 0 and args.len == 1 and args[0].len == 0) args = &.{};
        if (args.len != m.params.len)
            return pp.fail(sp, .E0117, "expected {d}, found {d}", .{ m.params.len, args.len });
    }

    if (pp.expanding_set.contains(name)) {
        var b = pp.failWith(sp, .E0118);
        b.msg("`{s}`", .{name});
        b.note("expansion chain: {s}", .{try pp.joinChain(pp.expanding.items, name)});
        try b.emit();
        return error.PreprocessFailed;
    }

    // IEEE 1364 forbids a macro's text from referring to the macro itself, a
    // property of the definition. A nested use in an actual argument
    // (`` `MAX(`MAX(a,b),c) ``) is not that: arguments are fully expanded
    // before substitution, as in the C preprocessor. So arguments expand here,
    // before `name` is pushed, while a self-reference in the body is rescanned
    // with the name on the stack and is still E0118.
    const body = if (m.is_func) blk: {
        var actuals = args;
        for (args, 0..) |a, first| {
            if (std.mem.findScalar(u8, a, '`') == null) continue;
            // Some argument invokes a macro: expand from here on into a copy.
            // Backtick-free arguments are substituted verbatim.
            const copy = try pp.scratch.dupe([]const u8, args);
            for (copy[first..]) |*slot| try pp.nested(sp, expandArg, .{ pp, slot, at });
            actuals = copy;
            break;
        }
        break :blk try substitute(pp, m.body, m.params, actuals);
    } else m.body;
    try pp.expanding.append(pp.scratch, name);
    try pp.expanding_set.put(pp.scratch, name, {});
    defer {
        _ = pp.expanding.pop();
        _ = pp.expanding_set.remove(name);
    }

    // Provenance: only the outermost expansion gets segments, since a nested
    // one resolves to the same invocation site.
    const outermost = pp.expand_site == null;
    if (outermost) {
        const site: u32 = @intCast(at);
        // An actual's own buffer is not the output (`expandArg`): its text is
        // mapped later, as part of the expansion that substitutes it. This
        // use is outermost there only inside a file an `include in the actual
        // opened.
        if (!pp.in_actual) {
            const o: u32 = @intCast(pp.out.items.len);
            const inv: u32 = @intCast(pp.segs.items.len);
            // A zero-width verbatim segment pinning the invocation site, so
            // `resolve` walking out of the macro lands on the use, not on
            // wherever the enclosing segment happened to start.
            try pp.segs.append(pp.scratch, .{ .out_start = o, .in_start = site, .file = pp.cur_file_id, .kind = .verbatim });
            try pp.segs.append(pp.scratch, .{
                .out_start = o,
                .in_start = site,
                .file = pp.cur_file_id,
                .kind = .macro,
                .parent = inv,
                .macro = name,
            });
            pp.expansion_seg = inv + 1;
        }
        pp.expand_site = site;
    }
    defer if (outermost) {
        pp.expand_site = null;
    };

    // Rescan the expansion so nested macro uses (§10.4) expand too. The cycle
    // guard above is what makes this terminate; the text bound stops a finite
    // expansion too large to address (a macro doubling its text 40 times).
    try pp.nested(sp, scan, .{ pp, body });
    try pp.checkTextSize(sp);

    // The invocation may have spanned lines; keep the count.
    try pp.putNewlines(text[at..end]);
    // `scan` resyncs the map to `end` when this returns.
    return end;
}

/// Replaces `arg.*` with that actual argument fully macro-expanded, on
/// `pp.scratch`. Scans into a fresh output list with `expand_site` set to
/// `at`, the invocation's '`', so diagnostics and `__LINE__` behave as in a
/// body rescan. Backtick-free text is kept as is.
fn expandArg(pp: *Pp, arg: *[]const u8, at: usize) Error!void {
    if (std.mem.findScalar(u8, arg.*, '`') == null) return;
    const saved_out = pp.out;
    const saved_site = pp.expand_site;
    const saved_actual = pp.in_actual;
    pp.out = .empty;
    pp.in_actual = true;
    if (pp.expand_site == null) pp.expand_site = @intCast(at);
    defer {
        pp.out = saved_out;
        pp.expand_site = saved_site;
        pp.in_actual = saved_actual;
    }
    try scan(pp, arg.*);
    arg.* = pp.out.items;
}

/// A macro use's trimmed actual arguments and the offset just past its `)`.
const MacroArgs = struct { args: []const []const u8, end: usize };

/// Splits the top-level comma list opening at `lparen`. Nested (), [], {},
/// string literals and escaped identifiers are opaque. A closer that does not
/// match its opener, or a missing `)`, is E0120. The arguments slice `text`;
/// the list is on `pp.scratch`. Asserts that `text[lparen]` is `(`.
pub fn macroArgs(pp: *Pp, text: []const u8, lparen: usize, at: usize, name: []const u8) Error!MacroArgs {
    std.debug.assert(text[lparen] == '(');
    var args: std.ArrayList([]const u8) = .empty;
    var opens: std.ArrayList(u8) = .empty;
    var i = lparen;
    var arg_start = lparen + 1;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"' => i = stringStop(text, i),
            // §2.8.1: an escaped identifier runs to white space, commas and
            // brackets included.
            '\\' => i = escapedEnd(text, i + 1) - 1,
            '(', '[', '{' => try opens.append(pp.scratch, c),
            ')', ']', '}' => {
                // Non-empty: the first iteration pushes the '(' at `lparen`,
                // and the list returns the moment the stack empties.
                const open = opens.pop().?;
                const want: u8 = switch (open) {
                    '(' => ')',
                    '[' => ']',
                    else => '}',
                };
                if (c != want) return pp.fail(pp.spanAt(i, i + 1), .E0120, "`{s}`: `{c}` cannot close `{c}`", .{ name, c, open });
                if (opens.items.len == 0) {
                    try args.append(pp.scratch, try oneLine(pp, std.mem.trim(u8, text[arg_start..i], " \t\r\n")));
                    return .{ .args = args.items, .end = i + 1 };
                }
            },
            ',' => if (opens.items.len == 1) {
                try args.append(pp.scratch, try oneLine(pp, std.mem.trim(u8, text[arg_start..i], " \t\r\n")));
                arg_start = i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return pp.fail(pp.spanAt(at, at + 1 + name.len), .E0120, "`{s}`", .{name});
}

/// Returns `arg` with each newline outside a string literal turned into a
/// space, copied to `pp.scratch` only when there is one. `expand` emits the
/// newlines of the invocation's whole span after the expansion, so a newline
/// kept inside an actual would reach the output twice (once per use of the
/// formal, plus once). Between tokens a newline and a space are the same
/// white space, so IEEE 1364 §19.3.1's literal substitution is unchanged.
fn oneLine(pp: *Pp, arg: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, arg, '\n') == null) return arg;
    const copy = try pp.scratch.dupe(u8, arg);
    var i: usize = 0;
    while (i < copy.len) : (i += 1) {
        if (copy[i] == '"') {
            // A string keeps its bytes. One left open ends at its newline
            // (`stringStop`), and that newline is outside it.
            i = stringStop(copy, i);
            if (i == copy.len or copy[i] != '\n') continue;
        }
        if (copy[i] == '\n') copy[i] = ' ';
    }
    return copy;
}

/// Returns `body` with each whole-identifier formal replaced by its actual,
/// on `pp.scratch`. Strings, escaped identifiers, numbers and the name after a
/// '`' are never substituted into. Asserts one actual per formal.
pub fn substitute(pp: *Pp, body: []const u8, params: []const []const u8, args: []const []const u8) Error![]const u8 {
    std.debug.assert(params.len == args.len);
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.scratch, body.len);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < body.len and body[i] != '"') {
                if (body[i] == '\\' and i + 1 < body.len) i += 1;
                i += 1;
            }
            if (i < body.len) i += 1;
            try out.appendSlice(pp.scratch, body[start..i]);
            continue;
        }
        if (c == '`') {
            const start = i;
            i = identEnd(body, i + 1);
            try out.appendSlice(pp.scratch, body[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1 escaped identifier, opaque to the next white space: in
            // `` `define M(x) real \sig-x ; `` the `x` is not the formal.
            const start = i;
            i = escapedEnd(body, i + 1);
            try out.appendSlice(pp.scratch, body[start..i]);
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            i = identEnd(body, i);
            const word = body[start..i];
            const idx = for (params, 0..) |formal, n| {
                // The length test first: most words are no formal, and it
                // spares the call.
                if (formal.len == word.len and std.mem.eql(u8, formal, word)) break n;
            } else null;
            try out.appendSlice(pp.scratch, if (idx) |k| args[k] else word);
            // IEEE 1364 §19.3.1 substitutes each actual "literally", and an
            // escaped identifier's terminating white space (§2.8.1) is part of
            // it, and `macroArgs` trimmed that space off with the rest. Put one
            // back, or `(ARG)` turns `\a.b ` into the identifier `\a.b)`.
            if (idx) |k| if (endsInEscapedIdent(args[k])) try out.append(pp.scratch, ' ');
            continue;
        }
        if (std.ascii.isDigit(c)) {
            // A number is one token (IEEE 1364 §19.3.1): the `e` of `1e-3` and
            // the `k` of `2k` are not identifiers a formal could replace.
            const start = i;
            i += 1;
            while (i < body.len) : (i += 1) {
                const d = body[i];
                if (isIdentChar(d) or d == '.') continue;
                if ((d == '+' or d == '-') and (body[i - 1] | 0x20) == 'e') continue;
                break;
            }
            try out.appendSlice(pp.scratch, body[start..i]);
            continue;
        }
        try out.append(pp.scratch, c);
        i += 1;
    }
    return out.items;
}

/// Does `text` open a string literal it does not close? A `\`-started
/// escaped identifier (§2.8.1) is skipped, so a `"` spelled inside one is not
/// taken for a quote.
fn splitsString(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => {
                i = stringStop(text, i);
                if (i >= text.len or text[i] != '"') return true;
            },
            '\\' => i = escapedEnd(text, i + 1) - 1,
            else => {},
        }
    }
    return false;
}

/// Does `text` end inside a §2.8.1 escaped identifier, i.e. with no white
/// space after its last `\`-started run? String literals are skipped, so the
/// `\` of an escape sequence does not count.
fn endsInEscapedIdent(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => i = stringStop(text, i),
            '\\' => {
                i = escapedEnd(text, i + 1);
                if (i == text.len) return true;
            },
            else => {},
        }
    }
    return false;
}
