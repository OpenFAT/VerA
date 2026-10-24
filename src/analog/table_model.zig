//! §9.21 `$table_model`.
//!
//! In: `$table_model` calls and their data files (and §4.6.4.3's `noise_table`
//! file, which shares the format). Out: one self-describing `$table_model`
//! call whose operands are the table data and its control plan, and the
//! `Lowered.table_samples` row of each array-source snapshot site.
//!
//! LRM clauses this file's code cites: §3.4.8, §4.6.4.3, §9.21, §9.21.1, §9.21.2,
//! §9.21.5.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

/// This file's private state on `Lower` (`Lower.table_model_state`).
pub const State = struct {
    /// The source expression of each array-source snapshot site, so a site keeps
    /// its identity across repeated analog-function inlining.
    table_sources: std.ArrayList(Ast.ExprId) = .empty,
};

// ---- §9.21 $table_model -----------------------------------------------------

/// Lowers a §9.21 `$table_model` call (Syntax 9-16) into one self-describing call:
///
///     $table_model(ND, NP, NCOL, dep, "<interp/extrap>", snapshot_site, previous_call, in₀…in_{ND-1}, row₀…row_{NP-1})
///
/// the dimensionality, sample count, column count, dependent column, one
/// interpolation and two extrapolation control characters per dimension, the lookup
/// point, and the flat row-major sample block. The block is projected onto the
/// columns the lookup reads, so NCOL is `nd + 1` with the dependent last.
///
/// The control string and data source are resolved here because neither survives
/// into MIR; a control string §9.21.2 does not describe reports E0815. The
/// interpolation schemes (Table 9-30) and runtime conditions (Table 9-31's `E`,
/// conflicting duplicates) belong to the kernel, which has the lookup point.
///
/// A file data source is read at compile time, so a file that changes before the
/// first call is not seen (a known gap against §9.21.1). Array sources carry a
/// unique snapshot site; codegen captures their rows at the first executed call.
pub fn lowerTableModel(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const args = ex.args(e)[0 .. try lower_sysfunc.writtenArgs(self, e, "$table_model", ex.args(e)) orelse return poison];

    // Syntax 9-16 puts `table_inputs` first, then `table_data_source`. The
    // boundary is decidable without counting: an input is "any legal expression
    // that can be assigned to an analog signal", while every data-source
    // argument is an array (a name, or a §3.4.8 pattern) or a string.
    var i: usize = 0;
    while (i < args.len and args[i] != .none and !isTableSource(self, args[i])) i += 1;
    const nd = i;
    if (nd == 0 or i == args.len) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "`$table_model(table_inputs, table_data_source [, table_control_string])` — one lookup expression per dimension, then the data source", .{});
        return poison;
    }

    // The columns, in file order: N independents outermost-first, then the
    // dependents. §9.21.1: "When the data source is a sequence of 1-D arrays the
    // isolines are laid out in conceptually the same way with each array being
    // just as a column in the file format described above."
    var cols: std.ArrayList([]const Mir.Value) = .empty;
    defer cols.deinit(self.arena);
    while (i < args.len and isTableArray(self, args[i])) : (i += 1) {
        var one: std.ArrayList(Mir.Value) = .empty;
        defer one.deinit(self.arena);
        _ = try lower_analog_op.appendVectorArg(self, &one, args[i]);
        try cols.append(self.arena, try self.arena.dupe(Mir.Value, one.items[1..]));
    }

    // What is left must be the file name (when there were no arrays) and/or the
    // control string. §9.21's `file_name ::= string_literal | string_parameter`,
    // so a constant fold is the whole admissible set.
    var strs: [2][]const u8 = .{ "", "" };
    var ns: usize = 0;
    while (i < args.len) : (i += 1) {
        if (args[i] == .none) continue;
        const c = lower_constfold.constEval(self, args[i]) orelse break;
        if (c != .str or ns == 2) break;
        strs[ns] = c.str;
        ns += 1;
    }
    if (i != args.len) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "trailing argument to `$table_model` is neither an array data source nor a constant string", .{});
        return poison;
    }

    var rows: []const Mir.Value = &.{};
    var ncol: usize = 0;
    var np: usize = 0;
    var ctl: []const u8 = "";
    if (cols.items.len != 0) {
        // `table_model_array ::= 1st_dim_array_identifier [, …], output_array_identifier`:
        // one column per dimension plus at least one dependent.
        if (ns > 1) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "an array data source takes at most one control string", .{});
            return poison;
        }
        ctl = strs[0];
        ncol = cols.items.len;
        np = cols.items[0].len;
        if (ncol <= nd) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "{d} lookup input(s) need {d} independent arrays plus an output array, got {d}", .{ nd, nd, ncol });
            return poison;
        }
        for (cols.items) |c| {
            if (c.len != np) {
                try self.err(self.file.exprs.mainTok(e), .E0815, "the arrays of a `$table_model` data source are columns of one table and must be the same length; got {d} and {d}", .{ np, c.len });
                return poison;
            }
        }
        const flat = try self.arena.alloc(Mir.Value, np * ncol);
        for (0..np) |r| for (cols.items, 0..) |c, k| {
            flat[r * ncol + k] = c[r];
        };
        rows = flat;
    } else {
        if (ns == 0) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "`$table_model` needs a data source: a file name, or one array per dimension plus an output array", .{});
            return poison;
        }
        ctl = strs[1];
        // §9.21.1: "The state of the data source is captured on the first call
        // to the table model function." An absent file, or one that is not a data
        // set ("The numbers shall be real or integer"), is the call's error, not
        // the compilation's, so it lowers to an empty data set that `zTable`
        // refuses only when a lookup reaches it.
        var absent = false;
        if (try readTableFile(self, e, strs[0], "$table_model", .E0815, &absent)) |nums| {
            if (nums.cols <= nd) {
                try self.err(self.file.exprs.mainTok(e), .E0815, "\"{s}\": {d} lookup input(s) need {d} independent columns plus a dependent one, found {d}", .{ strs[0], nd, nd, nums.cols });
                return poison;
            }
            ncol = nums.cols;
            np = nums.vals.len / ncol;
            const flat = try self.arena.alloc(Mir.Value, nums.vals.len);
            for (nums.vals, flat) |v, *out| out.* = try self.mir.addFloatConst(self.arena, v);
            rows = flat;
        } else {
            if (!absent) return poison;
            // The empty data set. §9.21.2's control string describes columns
            // that do not exist, so it is dropped with them; `parseTableCtl`
            // fills `ext` with Table 9-32's defaults over `nd + 1` columns and
            // the projection below copies no rows.
            ncol = nd + 1;
            np = 0;
            ctl = "";
        }
    }

    // §9.21: "The minimum data requirement is to have the product of at least
    // two points per dimension (2ᴺ for N dimensions)." `np == 0` is the absent
    // file above, whose whole point is that it has no data set to measure.
    const min_samples = std.math.pow(usize, 2, @min(nd, 30));
    if (np != 0 and np < min_samples) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "a {d}-dimensional table needs at least {d} samples, got {d}", .{ nd, min_samples, np });
        return poison;
    }

    const ext = try self.arena.alloc(u8, 3 * nd);
    // `keep[0..nd]` is the source column of each dimension, outermost first;
    // `keep[nd]` is the dependent the selector picked.
    const keep = try self.arena.alloc(usize, nd + 1);
    keep[nd] = (try parseTableCtl(self, e, ctl, nd, ncol, ext, keep[0..nd])) orelse return poison;

    // Project the sample block onto the columns the lookup actually reads.
    // §9.21.2's `I` ("Ignore this input column") and every unselected dependent
    // are dropped, which keeps the kernel's `dim`-is-`column` indexing and its
    // sort valid. After this the block is `nd` independents outermost-first
    // followed by the one dependent.
    const proj = try self.arena.alloc(Mir.Value, np * (nd + 1));
    for (0..np) |r| for (keep, 0..) |c, j| {
        proj[r * (nd + 1) + j] = rows[r * ncol + c];
    };
    rows = proj;
    ncol = nd + 1;
    const dep = nd;

    const site = if (cols.items.len == 0) 0 else blk: {
        if (std.mem.findScalar(Ast.ExprId, self.table_model_state.table_sources.items, e)) |existing| break :blk existing + 1;
        try self.table_model_state.table_sources.append(self.arena, e);
        try self.out.table_samples.append(self.arena, @intCast(rows.len));
        break :blk self.out.table_samples.items.len;
    };
    const previous = if (site == 0) .f_zero else try self.builder.readVariable(try self.effectPlace(), self.cur);
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.appendSlice(self.arena, &.{
        try self.mir.addIntConst(self.arena, @intCast(nd)),
        try self.mir.addIntConst(self.arena, @intCast(np)),
        try self.mir.addIntConst(self.arena, @intCast(ncol)),
        try self.mir.addIntConst(self.arena, @intCast(dep)),
        try self.mir.addStrConst(self.arena, ext),
        try self.mir.addIntConst(self.arena, @intCast(site)),
        previous,
    });
    for (args[0..nd]) |a| try vals.append(self.arena, try self.toReal(try lower_expr.lowerExpr(self, a)));
    try vals.appendSlice(self.arena, rows);
    self.out.uses.insert(.table_model);
    const result = try self.call("$table_model", vals.items);
    if (site != 0) try self.builder.writeVariable(try self.effectPlace(), self.cur, result);
    return .{ .v = result, .ty = .real };
}

/// Is this argument part of `table_data_source` rather than a lookup input?
fn isTableSource(self: *Lower, a: Ast.ExprId) bool {
    if (isTableArray(self, a)) return true;
    const c = lower_constfold.constEval(self, a) orelse return false;
    return c == .str;
}

/// One column of an array data source: an array name (§9.21.1 "via array
/// variable names") or a pattern ("Arrays may be specified directly via the
/// concatenation operator"). `appendVectorArg` reads both shapes.
fn isTableArray(self: *Lower, a: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (a == .none) return false;
    return switch (ex.tag(a)) {
        .assign_pattern, .concat => true,
        .ident => if (self.arrays.get(self.file.str(ex.strOf(a)))) |info| info.dims.len == 1 else false,
        else => false, // else: neither §9.21.1 array shape
    };
}

/// A parsed data file: row-major values and the column count every row shares.
const TableFile = struct { vals: []const f64, cols: usize };

/// Reads a §4.6.4.3 `noise_table` file as `f0, p0, f1, p1, ...`, the layout the
/// vector form produces. Returns null after reporting E0519 when the file cannot be
/// read or its lines do not hold exactly one frequency/power pair. Ordering and sign
/// rules are checked in codegen's `planNoiseTable`, as for the vector form.
/// The returned pairs are `self.arena`'s.
pub fn readNoiseTableFile(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!?[]const f64 {
    const f = (try readTableFile(self, e, name, "noise_table", .E0519, null)) orelse return null;
    if (f.cols != 2) {
        try self.err(self.file.exprs.mainTok(e), .E0519, "\"{s}\": LRM 4.6.4.3's input file is frequency / power PAIRS, one pair per line; found {d} numbers on a line", .{ name, f.cols });
        return null;
    }
    return f.vals;
}

/// §9.21.1's text format: "Each sample point is separated by a newline and each
/// column is separated by one or more spaces or tabs. Comments begin with # and
/// continue to the end of that line. They may appear anywhere in the file. Blank
/// lines are ignored. The numbers shall be real or integer."
///
/// Shared with §4.6.4.3's `noise_table` file input, which states the same format;
/// `who` and `code` name the caller's clause in diagnostics, and the caller checks
/// the column count. Resolved against `include_dirs`, like an `include (§9.21 names
/// no search path). A non-null `missing` defers to the caller (see
/// `lowerTableModel`) both a file that cannot be read and one whose text is not a
/// data set (a token that is not a number, rows of unequal width, no row): either way the
/// first call captures no data set, and that call is where §9.21.1 errs.
fn readTableFile(
    self: *Lower,
    e: Ast.ExprId,
    name: []const u8,
    who: []const u8,
    code: diag.Code,
    missing: ?*bool,
) Oom!?TableFile {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir: std.Io.Dir = .cwd();
    const text = blk: {
        for (self.include_dirs) |base| {
            const full = try std.fs.path.join(self.arena, &.{ base, name });
            // No size bound but memory: a data file is numbers, not text the
            // lexer addresses (§9.21.1 bounds nothing about it).
            const r = dir.readFileAlloc(io, full, self.arena, .unlimited) catch |e2| {
                if (e2 == error.OutOfMemory) return error.OutOfMemory;
                continue; // try the next dir, exactly as `readInclude` does
            };
            break :blk r;
        }
        const r = dir.readFileAlloc(io, name, self.arena, .unlimited) catch |e2| {
            if (e2 == error.OutOfMemory) return error.OutOfMemory;
            if (missing) |m| {
                m.* = true;
                return null;
            }
            try self.err(self.file.exprs.mainTok(e), code, "cannot read the `{s}` data source \"{s}\"", .{ who, name });
            return null;
        };
        break :blk r;
    };

    var vals: std.ArrayList(f64) = .empty;
    var cols: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |tok| {
            const x = std.fmt.parseFloat(f64, tok) catch {
                if (missing) |m| {
                    m.* = true;
                    return null;
                }
                try self.err(self.file.exprs.mainTok(e), code, "\"{s}\": `{s}` is not a real or integer number", .{ name, tok });
                return null;
            };
            try vals.append(self.arena, x);
            n += 1;
        }
        if (n == 0) continue; // blank line, or a line that was only a comment
        if (cols == 0) cols = n;
        if (n != cols) {
            if (missing) |m| {
                m.* = true;
                return null;
            }
            try self.err(self.file.exprs.mainTok(e), code, "\"{s}\": every row is the same width; found a row of {d} after a row of {d}", .{ name, n, cols });
            return null;
        }
    }
    // A file of blank lines and comments has no rows: no data set either.
    if (cols == 0) if (missing) |m| {
        m.* = true;
        return null;
    };
    return .{ .vals = vals.items, .cols = cols };
}

/// §9.21.2 the control string. Writes `3*nd` control bytes into `ext`
/// (interpolation, low extrapolation, high extrapolation) and the source column
/// each dimension reads into `cmap`, and returns the dependent column index, or
/// null when the string is not one §9.21.2 describes.
///
/// Table 9-30's `D`, `1`, `2` and `3` become the dimension's interpolation byte.
/// `I` ("Ignore this input column") spends a column in `cmap` but no dimension, and
/// the caller projects that column out. So the dependent is counted in columns:
/// `leading = nd + ignored columns`, as Table 9-32's examples show (`"I,1CC,1CC;3"`
/// needs "at least 6 column[s]"; `"3,D,I,1;3"` reads "column 7").
fn parseTableCtl(self: *Lower, e: Ast.ExprId, ctl: []const u8, nd: usize, ncol: usize, ext: []u8, cmap: []usize) Oom!?usize {
    // "the function defaults to performing linear interpolation and linear
    // extrapolation in both dimensions" (§9.21.5), which Table 9-32's first row
    // states for every dimension: `""` is "default linear interpolation and
    // extrapolation".
    @memset(ext, 'L');
    for (0..nd) |dim| ext[3 * dim] = '1';
    const semi = std.mem.findScalar(u8, ctl, ';');
    const head = if (semi) |s| ctl[0..s] else ctl;

    // `dependent_selector ::= integer`, "a column number ... This number runs 1
    // through M with M being the total number of dependent variables". Table
    // 9-32: with none given, "Column N+1 is taken as the dependent".
    var sel: usize = 1;
    if (semi) |s| {
        const tail = std.mem.trim(u8, ctl[s + 1 ..], " \t");
        if (tail.len != 0) sel = std.fmt.parseInt(usize, tail, 10) catch 0;
    }

    var d: usize = 0;
    var col: usize = 0; // the source column the next sub-string is spent on
    var it = std.mem.splitScalar(u8, head, ',');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t");
        // Table 9-30 `I`, "Ignore this input column". It marks a column, so it
        // takes no dimension and admits no extrapolation characters.
        if (s.len != 0 and s[0] == 'I') {
            if (s.len != 1) {
                try self.err(self.file.exprs.mainTok(e), .E0815, "`{s}`: Table 9-30's `I` ignores a column and takes no extrapolation characters", .{s});
                return null;
            }
            col += 1;
            continue;
        }
        if (d >= nd) {
            // One sub-string per independent variable, "with the first
            // sub-string applying to the outermost dimension and so on".
            if (s.len == 0) continue;
            try self.err(self.file.exprs.mainTok(e), .E0815, "the control string has more interpolation sub-strings than the {d} lookup input(s)", .{nd});
            return null;
        }
        cmap[d] = col;
        col += 1;
        defer d += 1;
        var j: usize = 0;
        if (s.len != 0 and std.mem.findScalar(u8, "D123", s[0]) != null) {
            ext[3 * d] = s[0];
            j = 1;
        }
        const xs = s[j..];
        if (xs.len > 2) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "`{s}`: a control sub-string carries at most 2 extrapolation characters", .{s});
            return null;
        }
        for (xs) |c| if (std.mem.findScalar(u8, "CLE", c) == null) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "`{c}` is not a Table 9-30 interpolation character or a Table 9-31 extrapolation character", .{c});
            return null;
        };
        // "When one extrapolation method character is given, the specified
        // extrapolation method will be used for both ends. When two ... the
        // first character specifies the extrapolation method used for the end
        // with the lower coordinate value."
        if (xs.len == 1) {
            ext[3 * d + 1] = xs[0];
            ext[3 * d + 2] = xs[0];
        } else if (xs.len == 2) {
            ext[3 * d + 1] = xs[0];
            ext[3 * d + 2] = xs[1];
        }
    }
    // Fewer sub-strings than dimensions: the rest keep the `1LL` default and
    // take the columns that follow, so `leading` is still one column per
    // dimension plus one per ignored column.
    while (d < nd) : (d += 1) {
        cmap[d] = col;
        col += 1;
    }

    // `col + sel - 1 >= ncol`, written so a selector near `maxInt(usize)`
    // cannot overflow the sum.
    if (sel == 0 or col >= ncol or sel > ncol - col) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "dependent selector {d} names no dependent column: the data source has {d} column(s) and {d} leading column(s)", .{ sel, ncol, col });
        return null;
    }
    return col + sel - 1;
}

test "§9.21.2 $table_model: the control string, the dependent selector and the sample count" {
    // One lookup input, two pattern columns (§9.21.1 "Arrays may be specified
    // directly"): ncol = 2, so the leading columns are 1 and there is M = 1
    // dependent. "This number runs 1 though M", so only `;1` selects one.
    try Lower.expectBodies(&.{
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL;1\");", .code = null },
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL;2\");", .code = .E0815 },
        // A selector that parses as an integer but is past every column: the
        // same refusal, never an overflow in the column arithmetic.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL;18446744073709551615\");", .code = .E0815 },
        // "Each sub-string ... has at most 3 characters."
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LLL\");", .code = .E0815 },
        // `X` is in neither Table 9-30 nor Table 9-31.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1X\");", .code = .E0815 },
        // One sub-string per independent variable; there is one.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL,1LL\");", .code = .E0815 },
        // Table 9-30's `I` ignores a column; it takes no extrapolation.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"IC;1\");", .code = .E0815 },
        // §9.21: two dimensions need 2^2 = 4 samples; these columns hold 2.
        .{ .src = "analog I(p) <+ $table_model(V(p), V(q), '{0.0, 1.0}, '{0.0, 1.0}, '{0.0, 1.0});", .code = .E0815 },
        // §9.21.1: the data source "is captured on the first call", so a file
        // that is not there is that call's error, not the compilation's.
        .{ .src = "analog I(p) <+ $table_model(V(p), \"vera_lower_test_no_such_table.tbl\");", .code = null },
    });
}
