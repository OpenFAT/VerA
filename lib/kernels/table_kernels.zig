//! §9.21 `$table_model`: a flat row-major sample block, the lookup point and
//! the per-dimension control in, the interpolated value with its exact
//! gradient out. Device text (`text.table`) for every device that calls
//! `$table_model`. Nothing allocates: `NP`, `NCOL`, `ND` and the control
//! characters are structural constants of the call, so every scratch array
//! is comptime-sized and on the stack.
//! Cites: VAMS §9.21, §9.21.1, §9.21.2, §9.21.4, Tables 9-30 and 9-31.
//!
//! §9.21 defines the lookup as a recursion over dimensions, not an
//! N-dimensional formula ("we first look through the set of isolines in y and
//! find the pair that bracket y1 ... interpolate each isoline to find
//! f(x1,yh) and f(x1,yl) ... we may interpolate this isoline to find the
//! value f(x1,y1)"), so `zTabAt` recurses on the dimension index, at most
//! `ND` deep, and every interpolation is one-dimensional, which is why
//! §9.21.2 can name a scheme per dimension. The sample block is NP rows of
//! NCOL columns, independents outermost first, then the dependents. Each
//! dimension's control is three bytes: the scheme (Table 9-30 `D`, `1`, `2`
//! or `3`; `I` columns are already projected out), then the low and the high
//! extrapolation character (Table 9-31 `C`, `L` or `E`).
//!
//! Contents:
//! - `pub const zTabVD = struct { v: f64, d: f64 }`
//! - `pub fn zTabRes(comptime ND: usize) type`
//! - `pub fn zTable(comptime S: type, comptime NP: usize, comptime NCOL: usize, comptime ND: usize, comptime dep: usize, comptime ext: []const u8, rows: [NP * NCOL]f64, pt: [ND]S) S`
//! - `pub fn zTabSort(comptime NCOL: usize, comptime ND: usize, data: []const f64, order: []u32) void`
//! - `pub fn zTabLess(comptime NCOL: usize, comptime ND: usize, data: []const f64, a: usize, b: usize) bool`
//! - `pub fn zTabAt(comptime NP: usize, comptime ND: usize, comptime NCOL: usize, comptime dep: usize, comptime ext: []const u8, data: []const f64, order: []const u32, dim: usize, x: [ND]f64) zTabRes(ND)`
//! - `pub fn zTabEnd(comptime NCOL: usize, data: []const f64, order: []const u32, dim: usize, start: usize) usize`
//! - `pub fn zTabSplineDim(comptime NP: usize, comptime ND: usize, comptime NCOL: usize, comptime dep: usize, comptime ext: []const u8, data: []const f64, order: []const u32, dim: usize, x: [ND]f64) zTabRes(ND)`
//! - `pub fn zTabSpline1(comptime NP: usize, scheme: u8, lo: u8, hi: u8, xs: []const f64, fs: []const f64, t: f64) zTabVD`

const ztstd = @import("std");

// ---- device text ----

/// One isoline's spline answer: the value and the slope along it.
pub const zTabVD = struct { v: f64, d: f64 };

/// One recursion level's answer: the interpolated value and its exact
/// gradient in the ND lookup coordinates. A residual hands the solver a
/// Jacobian row, and `$table_model` on a probe is a function of an unknown,
/// so a bare value would tell the solver the table is flat.
pub fn zTabRes(comptime ND: usize) type {
    return struct { v: f64, g: [ND]f64 };
}

/// Returns the §9.21 lookup at `pt`, in the solver's scalar interface: the
/// value, with the gradient folded in by one affine reconstruction per
/// coordinate (`pt[d].addC(-x[d])` is a zero here whose derivative is
/// ∂pt[d]/∂unknown, so scaling by ∂f/∂x[d] and summing is the chain rule).
/// `NP == 0` is the compiler saying the source could not be read: the error
/// belongs to the call that would have captured it (§9.21.1 "the state of
/// the data source is captured on the first call"), so it exits here. Two
/// samples with equal independents and different dependents also exit
/// here (§9.21: "then an error is generated"), since the dependents may be
/// expressions of the solution; an identical repeat is ignored, as the clause
/// allows, because the sort is stable and a leaf reads its block's first
/// row. A lookup beyond an `E` end exits too (Table 9-31).
pub fn zTable(
    comptime S: type,
    comptime NP: usize,
    comptime NCOL: usize,
    comptime ND: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    rows: [NP * NCOL]f64,
    pt: [ND]S,
) S {
    comptime ztstd.debug.assert(ext.len >= 3 * ND);
    comptime ztstd.debug.assert(dep < NCOL);
    if (NP == 0) ztMissingSource();
    if (NP > ztstd.math.maxInt(u32)) @compileError("$table_model: more than 2^32 samples");
    var order: [NP]u32 = undefined;
    for (0..NP) |i| order[i] = @intCast(i);
    zTabSort(NCOL, ND, &rows, &order);
    // `order` is sorted, so neighbours that are not strictly increasing are
    // equal in every independent.
    for (1..NP) |i| {
        if (zTabLess(NCOL, ND, &rows, order[i - 1], order[i])) continue;
        if (rows[order[i - 1] * NCOL + dep] != rows[order[i] * NCOL + dep]) ztDuplicateError();
    }
    var x: [ND]f64 = undefined;
    for (0..ND) |d| x[d] = pt[d].val();
    const r = zTabAt(NP, ND, NCOL, dep, ext, &rows, &order, 0, x);
    var out = S.con(r.v);
    for (0..ND) |d| out = out.add(pt[d].addC(-x[d]).scale(r.g[d]));
    return out;
}

/// Sorts `order`, a row-index permutation, lexicographically on the
/// independent columns: §9.21.1 "if the user provides the data in random
/// order the system will sort the data into isolines in each dimension",
/// which makes every isoline a contiguous run. Insertion sort: O(n) on the
/// sorted input the clause asks users to write, stable (so the duplicate
/// rule keeps source order), and allocation-free.
/// Asserts that `data` holds every row `order` names.
// ponytail: O(n²) on adversarial order, recomputed per lookup; cache the
// permutation beside the first-call snapshot if a table's size measures.
pub fn zTabSort(comptime NCOL: usize, comptime ND: usize, data: []const f64, order: []u32) void {
    ztstd.debug.assert(order.len * NCOL <= data.len);
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const v = order[i];
        var j = i;
        while (j > 0 and zTabLess(NCOL, ND, data, v, order[j - 1])) : (j -= 1) order[j] = order[j - 1];
        order[j] = v;
    }
    if (order.len > 1) ztstd.debug.assert(!zTabLess(NCOL, ND, data, order[1], order[0]));
}

/// Returns whether row `a` sorts before row `b` on the independent columns,
/// outermost first. Asserts that both rows are inside `data`.
pub fn zTabLess(comptime NCOL: usize, comptime ND: usize, data: []const f64, a: usize, b: usize) bool {
    comptime ztstd.debug.assert(ND <= NCOL);
    ztstd.debug.assert((@max(a, b) + 1) * NCOL <= data.len);
    for (0..ND) |d| {
        const x = data[a * NCOL + d];
        const y = data[b * NCOL + d];
        if (x != y) return x < y;
    }
    return false;
}

/// Returns §9.21's recursion at one level. `order` is the sorted row block
/// of the isoline the dimensions already consumed selected; `dim` is the
/// dimension to bracket next. A single isoline in `dim` is degenerate data
/// (§9.21 requires "at least two points per dimension"; E0815 reports the
/// shape it can see) and reads as constant in `dim`.
/// Asserts that `order` is non-empty and `dim <= ND`.
pub fn zTabAt(
    comptime NP: usize,
    comptime ND: usize,
    comptime NCOL: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    data: []const f64,
    order: []const u32,
    dim: usize,
    x: [ND]f64,
) zTabRes(ND) {
    ztstd.debug.assert(order.len > 0);
    ztstd.debug.assert(dim <= ND); // the recursion depth: one level per dimension
    // Every independent consumed: one sample point, its dependent the
    // answer, flat in every coordinate.
    if (dim == ND) return .{ .v = data[order[0] * NCOL + dep], .g = @splat(0.0) };

    var a_s: usize = 0;
    var a_e = zTabEnd(NCOL, data, order, dim, 0);
    if (a_e == order.len) return zTabAt(NP, ND, NCOL, dep, ext, data, order[a_s..a_e], dim + 1, x);

    var b_s = a_e;
    var b_e = zTabEnd(NCOL, data, order, dim, b_s);
    // Slide the pair up while the upper isoline is below the ordinate and
    // another follows: the bracketing pair when one exists, else the nearest
    // pair at whichever end it does not.
    while (b_e < order.len and data[order[b_s] * NCOL + dim] < x[dim]) {
        a_s = b_s;
        a_e = b_e;
        b_s = b_e;
        b_e = zTabEnd(NCOL, data, order, dim, b_s);
    }
    const xa = data[order[a_s] * NCOL + dim];
    const xb = data[order[b_s] * NCOL + dim];

    // Table 9-31 `E` is a condition on the point, checked before any scheme:
    // "an extrapolation error is reported if the $table_model function is
    // requested to evaluate a point beyond the interpolation region".
    // Strictly outside: an endpoint is the region's boundary.
    if (x[dim] < xa and ext[3 * dim + 1] == 'E') ztExtrapError();
    if (x[dim] > xb and ext[3 * dim + 2] == 'E') ztExtrapError();

    // Table 9-30 `2`/`3`: a spline fits the whole isoline set of `dim`.
    if (ext[3 * dim] == '2' or ext[3 * dim] == '3')
        return zTabSplineDim(NP, ND, NCOL, dep, ext, data, order, dim, x);

    if (ext[3 * dim] == 'D') {
        // §9.21.4 ties choose the sample farther from zero; discrete lookup
        // has zero slope in `dim`, at either exterior end too.
        const da = @abs(x[dim] - xa);
        const db = @abs(x[dim] - xb);
        const upper = x[dim] >= xb or (x[dim] > xa and
            (db < da or (db == da and @abs(xb) >= @abs(xa))));
        const selected = if (upper) order[b_s..b_e] else order[a_s..a_e];
        return zTabAt(NP, ND, NCOL, dep, ext, data, selected, dim + 1, x);
    }

    // Table 9-31 `C` "returns the table endpoint value": the end isoline,
    // with a zero slope in `dim`. §9.21.2: "the first character specifies the
    // extrapolation method used for the end with the lower coordinate value".
    if (x[dim] < xa and ext[3 * dim + 1] == 'C')
        return zTabAt(NP, ND, NCOL, dep, ext, data, order[a_s..a_e], dim + 1, x);
    if (x[dim] > xb and ext[3 * dim + 2] == 'C')
        return zTabAt(NP, ND, NCOL, dep, ext, data, order[b_s..b_e], dim + 1, x);

    const ra = zTabAt(NP, ND, NCOL, dep, ext, data, order[a_s..a_e], dim + 1, x);
    const rb = zTabAt(NP, ND, NCOL, dep, ext, data, order[b_s..b_e], dim + 1, x);
    // Linear interpolation and `L` extrapolation are the same affine segment
    // ("extends linearly ... using a slope consistent with the selected
    // interpolation method"), so `t` outside [0, 1] needs nothing of its own.
    const t = (x[dim] - xa) / (xb - xa);
    var r: zTabRes(ND) = .{ .v = ra.v + t * (rb.v - ra.v), .g = undefined };
    for (0..ND) |k| r.g[k] = ra.g[k] + t * (rb.g[k] - ra.g[k]);
    r.g[dim] = (rb.v - ra.v) / (xb - xa); // this dimension's own slope
    return r;
}

/// Returns the exclusive end of the run of rows in `order` that share row
/// `order[start]`'s value in column `dim`: one isoline. §9.21.1 reads "its
/// exact value from the file or array", so `==` with no tolerance ("any
/// noise on the isoline ordinate may cause the system to incorrectly
/// generate multiple isolines"). Asserts that `start` is inside `order`.
pub fn zTabEnd(comptime NCOL: usize, data: []const f64, order: []const u32, dim: usize, start: usize) usize {
    ztstd.debug.assert(start < order.len);
    ztstd.debug.assert(dim < NCOL);
    const key = data[order[start] * NCOL + dim];
    var i = start + 1;
    while (i < order.len and data[order[i] * NCOL + dim] == key) i += 1;
    return i;
}

/// Returns §9.21's recursion at a dimension whose scheme is a spline: every
/// isoline reduced through the lower dimensions first, the spline laid
/// through the results. `zTabSpline1` is linear in its `fs`, so applying it
/// to the k-th gradient component of the knot results is the k-th component
/// of the answer's gradient: ND + 1 solves, exact. Split out of `zTabAt` so
/// its NP-sized knot block is on the stack only for the calls that need it.
/// Asserts that `dim < ND`.
pub fn zTabSplineDim(
    comptime NP: usize,
    comptime ND: usize,
    comptime NCOL: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    data: []const f64,
    order: []const u32,
    dim: usize,
    x: [ND]f64,
) zTabRes(ND) {
    ztstd.debug.assert(dim < ND);
    ztstd.debug.assert(order.len <= NP);
    var kx: [NP]f64 = undefined;
    var kr: [NP]zTabRes(ND) = undefined;
    var n: usize = 0;
    var s: usize = 0;
    while (s < order.len) : (n += 1) {
        const e = zTabEnd(NCOL, data, order, dim, s);
        kx[n] = data[order[s] * NCOL + dim];
        kr[n] = zTabAt(NP, ND, NCOL, dep, ext, data, order[s..e], dim + 1, x);
        s = e;
    }
    var buf: [NP]f64 = undefined;
    for (0..n) |i| buf[i] = kr[i].v;
    const got = zTabSpline1(NP, ext[3 * dim], ext[3 * dim + 1], ext[3 * dim + 2], kx[0..n], buf[0..n], x[dim]);
    var r: zTabRes(ND) = .{ .v = got.v, .g = @splat(0.0) };
    r.g[dim] = got.d;
    for (0..ND) |c| {
        if (c == dim) continue;
        for (0..n) |i| buf[i] = kr[i].g[c];
        r.g[c] = zTabSpline1(NP, ext[3 * dim], ext[3 * dim + 1], ext[3 * dim + 2], kx[0..n], buf[0..n], x[dim]).v;
    }
    return r;
}

/// Returns §9.21.4's spline on one isoline at `t`: `xs` strictly increasing,
/// `fs` already reduced out of every lower dimension, `scheme` Table 9-30's
/// `2` or `3`, `lo`/`hi` Table 9-31's characters for the two ends, which
/// set the end conditions (§9.21.4: "if the user selects linear
/// extrapolation this leads to a natural spline. If constant extrapolation is
/// specified the end point derivative is set to zero"): `L` natural (S'' = 0
/// at that end), `C` clamped (S' = 0), `E` takes `L`'s condition (no
/// extrapolant to be continuous with; `L` is Table 9-31's default). Every
/// step is linear in `fs`, which `zTabSplineDim`'s gradient relies on.
/// Asserts that `xs` and `fs` are one non-empty isoline of at most `NP` knots.
pub fn zTabSpline1(
    comptime NP: usize,
    scheme: u8,
    lo: u8,
    hi: u8,
    xs: []const f64,
    fs: []const f64,
    t: f64,
) zTabVD {
    ztstd.debug.assert(xs.len == fs.len);
    ztstd.debug.assert(xs.len >= 1);
    ztstd.debug.assert(xs.len <= NP);
    // Two scratch rows: the quadratic's knot slopes and the cubic's Thomas
    // sweep share them, and the cubic back-substitutes into `dp` in place.
    var cp: [NP]f64 = undefined;
    var dp: [NP]f64 = undefined;
    const n = xs.len;
    if (n < 2) return .{ .v = fs[0], .d = 0.0 };

    // Table 9-31 `C` "returns the table endpoint value": flat out here.
    if (lo == 'C' and t < xs[0]) return .{ .v = fs[0], .d = 0.0 };
    if (hi == 'C' and t > xs[n - 1]) return .{ .v = fs[n - 1], .d = 0.0 };

    if (scheme == '2') {
        // A C¹ quadratic spline over k intervals has 3k coefficients against
        // 3k - 1 constraints: one end condition fits ("it is not always
        // possible in this case"). VerA gives it to the low end, the one
        // §9.21.2 names first, and marches the slopes upward; the high end is
        // whatever the march arrives at. With `L`/`E` the free slope is the
        // first secant, flattening the first segment's curvature.
        const z = &cp; // S' at each knot
        z[0] = if (lo == 'C') 0.0 else (fs[1] - fs[0]) / (xs[1] - xs[0]);
        for (1..n) |i| z[i] = 2.0 * (fs[i] - fs[i - 1]) / (xs[i] - xs[i - 1]) - z[i - 1];
        if (t < xs[0]) return .{ .v = fs[0] + z[0] * (t - xs[0]), .d = z[0] };
        if (t > xs[n - 1]) return .{ .v = fs[n - 1] + z[n - 1] * (t - xs[n - 1]), .d = z[n - 1] };
        var i: usize = 0;
        while (i + 2 < n and t > xs[i + 1]) i += 1;
        const h = xs[i + 1] - xs[i];
        const u = t - xs[i];
        const c = (z[i + 1] - z[i]) / (2.0 * h);
        return .{ .v = fs[i] + z[i] * u + c * u * u, .d = z[i] + 2.0 * c * u };
    }

    // Cubic, in the moment (M = S'') form. Interior rows:
    //   h₍ᵢ₋₁₎M₍ᵢ₋₁₎ + 2(h₍ᵢ₋₁₎+hᵢ)Mᵢ + hᵢM₍ᵢ₊₁₎ = 6[(f₍ᵢ₊₁₎−fᵢ)/hᵢ − (fᵢ−f₍ᵢ₋₁₎)/h₍ᵢ₋₁₎]
    // End rows: natural Mₑ = 0; clamped 2h₀M₀ + h₀M₁ = 6(f₁−f₀)/h₀ low and
    // h M₍ₙ₋₂₎ + 2h M₍ₙ₋₁₎ = −6(f₍ₙ₋₁₎−f₍ₙ₋₂₎)/h high. Tridiagonal and
    // diagonally dominant for strictly increasing `xs`: one Thomas sweep.
    {
        const h0 = xs[1] - xs[0];
        const b0: f64 = if (lo == 'C') 2.0 * h0 else 1.0;
        const c0: f64 = if (lo == 'C') h0 else 0.0;
        const r0: f64 = if (lo == 'C') 6.0 * (fs[1] - fs[0]) / h0 else 0.0;
        cp[0] = c0 / b0;
        dp[0] = r0 / b0;
    }
    for (1..n - 1) |i| {
        const hm = xs[i] - xs[i - 1];
        const hp = xs[i + 1] - xs[i];
        const r = 6.0 * ((fs[i + 1] - fs[i]) / hp - (fs[i] - fs[i - 1]) / hm);
        const den = 2.0 * (hm + hp) - hm * cp[i - 1];
        cp[i] = hp / den;
        dp[i] = (r - hm * dp[i - 1]) / den;
    }
    {
        const hl = xs[n - 1] - xs[n - 2];
        const an: f64 = if (hi == 'C') hl else 0.0;
        const bn: f64 = if (hi == 'C') 2.0 * hl else 1.0;
        const rn: f64 = if (hi == 'C') -6.0 * (fs[n - 1] - fs[n - 2]) / hl else 0.0;
        dp[n - 1] = (rn - an * dp[n - 2]) / (bn - an * cp[n - 2]);
    }
    var k = n - 1;
    while (k > 0) : (k -= 1) dp[k - 1] -= cp[k - 1] * dp[k];
    const m = dp[0..n]; // the moments, from here on

    // Table 9-31 `L` "extends linearly ... using a slope consistent with the
    // selected interpolation method": the spline's own end slope, not the
    // secant through the last two samples.
    if (t < xs[0]) {
        const e0 = ztSeg(m, xs, fs, 0, xs[0]);
        return .{ .v = fs[0] + e0.d * (t - xs[0]), .d = e0.d };
    }
    if (t > xs[n - 1]) {
        const en = ztSeg(m, xs, fs, n - 2, xs[n - 1]);
        return .{ .v = fs[n - 1] + en.d * (t - xs[n - 1]), .d = en.d };
    }
    var i: usize = 0;
    while (i + 2 < n and t > xs[i + 1]) i += 1;
    return ztSeg(m, xs, fs, i, t);
}

// ---- private ----

/// Segment `i` of the cubic interpolant with moments `mm`, and its slope, at
/// `u`.
fn ztSeg(mm: []const f64, ax: []const f64, af: []const f64, i: usize, u: f64) zTabVD {
    ztstd.debug.assert(i + 1 < ax.len);
    ztstd.debug.assert(mm.len == ax.len);
    const h = ax[i + 1] - ax[i];
    const a = ax[i + 1] - u;
    const b = u - ax[i];
    return .{
        .v = (mm[i] * a * a * a + mm[i + 1] * b * b * b) / (6.0 * h) +
            (af[i] - mm[i] * h * h / 6.0) * a / h +
            (af[i + 1] - mm[i + 1] * h * h / 6.0) * b / h,
        .d = (mm[i + 1] * b * b - mm[i] * a * a) / (2.0 * h) +
            (af[i + 1] - af[i]) / h - (mm[i + 1] - mm[i]) * h / 6.0,
    };
}

/// Table 9-31 `E`: "an extrapolation error is reported if the $table_model
/// function is requested to evaluate a point beyond the interpolation
/// region", and "error extrapolation results in a fatal error being raised".
/// The point is a run-time value, so the run ends here, as `$fatal` ends it.
fn ztExtrapError() noreturn {
    ztstd.debug.print("error: $table_model: LRM 9.21.2 `E`: lookup point is beyond the interpolation region\n", .{});
    ztstd.process.exit(1);
}

/// §9.21.1: this site's data source could not be read, or is not a data set
/// ("the numbers shall be real or integer"). A site that never runs captures
/// nothing and has nothing to be wrong about, so the report is at the call.
fn ztMissingSource() noreturn {
    ztstd.debug.print("error: $table_model: LRM 9.21.1: the data source of this call could not be read as a data set of real or integer numbers\n", .{});
    ztstd.process.exit(1);
}

/// §9.21: "If there are two or more data points with the same independent
/// values but different dependent values then an error is generated."
fn ztDuplicateError() noreturn {
    ztstd.debug.print("error: $table_model: LRM 9.21: two data points share their independent values and disagree on the dependent\n", .{});
    ztstd.process.exit(1);
}
