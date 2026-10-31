//! The §4.3 math kernels as Zig source text: the value form of LRM Tables
//! 4-14/4-15 every device carries (`math_txt`), and the §4.3.2 domain guard
//! in its two artifacts' forms. Text in nothing, text out; `file.emitFile`
//! splices it.
//! Cites: §4.2.4, §4.3, §4.3.1, §4.3.2, §9.21.2.
//!
//! Contents:
//! - `pub const math_txt`
//! - `pub const domain_quiet_txt`
//! - `pub const domain_report_txt`

/// LRM Tables 4-14/4-15 in value form: a function the scalar family does
/// not provide (`contract.family_primitives`) is composed from the ones it
/// does, so forward-mode autodiff carries the analytic derivative, or, where
/// the composition loses accuracy the named C function keeps (#60, VD-123),
/// takes the folder's own value (`contract.gm`, `std.math`) with the
/// analytic derivative grafted on (`zGraft`).
/// File-scope helpers run in the default (strict) float mode, since
/// `@setFloatMode` does not cross a call: a `.optimized` unit loses fast-math
/// inside a helper and never gains unsound fast-math.
pub const math_txt =
    \\// ---- §4.3 math, value form (derivative propagates by composition) ----
    \\
    \\// §4.3.1 defines the derivative at equality using strict comparisons:
    \\// min(a,b) = (a < b) ? a : b; max(a,b) = (a > b) ? a : b.
    \\// Compose the contract's masks and winner-derivative selection rather
    \\// than inheriting a host min/max primitive's possibly different tie rule.
    \\fn zMin(comptime S: type, a: S, b: S) S { return a.lt(b).sel(a, b); }
    \\fn zMax(comptime S: type, a: S, b: S) S { return b.lt(a).sel(a, b); }
    \\// The plain-f64 form (`opcode_zig.host_f64`: derive, setup), the same
    \\// strict comparison: `@min`/`@max` drop a NaN and leave a zero's sign open.
    \\fn zMinF(a: f64, b: f64) f64 { return if (a < b) a else b; }
    \\fn zMaxF(a: f64, b: f64) f64 { return if (a > b) a else b; }
    \\
    \\// ---- per-operating-point decisions (`batch_lead`, contract.zig) ----
    \\// A real compared, rounded to an integer or stripped of its lanes is one
    \\// decision per call. A scalar family has one operating point and these
    \\// are the plain value forms. A batch family (`V` a vector of points)
    \\// implements the lead protocol: the leader point decides, every other
    \\// point that would have decided otherwise is marked diverged, and the
    \\// entry points re-run until every point has run on its own path.
    \\fn zCmp(comptime S: type, comptime op: std.math.CompareOperator, a: anytype, b: anytype) bool {
    \\    if (comptime @hasDecl(S, "decide")) return S.decide(op, a, b);
    \\    return std.math.compare(a.val(), op, b.val());
    \\}
    \\fn zRoundI(comptime S: type, a: anytype) i64 {
    \\    if (comptime @hasDecl(S, "decideI")) return S.decideI(a);
    \\    return std.math.lossyCast(i64, @round(a.val()));
    \\}
    \\fn zStrip(comptime S: type, a: anytype) @TypeOf(S.con(0.0)) {
    \\    if (comptime @hasDecl(S, "strip")) return S.strip(a);
    \\    return S.con(a.val());
    \\}
    \\/// `a * k`, `a + k`, `a - k` for a derivative-free `k` that differs per
    \\/// point: `scale`/`addC` of its value in a one-point family, which is
    \\/// what the device always emitted; in a batch, the same arithmetic per
    \\/// point (`sub` of `-k` keeps a -0 lane that `add` of a zero lane would not).
    \\fn zMulP(comptime S: type, a: anytype, k: anytype) @TypeOf(a) {
    \\    if (comptime @typeInfo(S.V) == .vector) return a.mul(k);
    \\    return a.scale(k.val());
    \\}
    \\fn zAddP(comptime S: type, a: anytype, k: anytype) @TypeOf(a) {
    \\    if (comptime @typeInfo(S.V) == .vector) return a.sub(k.neg());
    \\    return a.addC(k.val());
    \\}
    \\fn zSubP(comptime S: type, a: anytype, k: anytype) @TypeOf(a) {
    \\    if (comptime @typeInfo(S.V) == .vector) return a.sub(k);
    \\    return a.addC(-(k.val()));
    \\}
    \\/// Field `f` of the `Instance`, as a value: per point in a batch, whose
    \\/// points each have their own instance (`S.instLane(T, w)`, contract.zig
    \\/// `batch_inst`); a one-point family reads `inst`.
    \\fn zInst(comptime S: type, inst: anytype, comptime f: []const u8) @TypeOf(S.con(0.0)) {
    \\    if (comptime contract.instLanes(S)) {
    \\        var ls: [S.lane_count]@TypeOf(S.Lane.con(0.0)) = undefined;
    \\        inline for (0..S.lane_count) |w| ls[w] = S.Lane.con(@field(S.instLane(@TypeOf(inst.*), w), f));
    \\        return S.fromLanes(0, ls);
    \\    }
    \\    return S.con(@field(inst, f));
    \\}
    \\/// Integer field `f` of the `Instance`: one value per call, so in a batch
    \\/// a decision (the lead protocol) over each point's own instance.
    \\fn zInstI(comptime S: type, inst: anytype, comptime f: []const u8) i64 {
    \\    if (comptime contract.instLanes(S)) {
    \\        var ls: [S.lane_count]@TypeOf(S.Lane.con(0.0)) = undefined;
    \\        inline for (0..S.lane_count) |w| ls[w] = S.Lane.con(@floatFromInt(@field(S.instLane(@TypeOf(inst.*), w), f)));
    \\        return S.decideI(S.fromLanes(0, ls));
    \\    }
    \\    if (comptime @hasDecl(S, "decideI")) return S.decideI(S.con(@floatFromInt(@field(inst, f)))); // `region` hashes it
    \\    return @field(inst, f);
    \\}
    \\/// Whether `S` runs the lead protocol; a vector family that cannot is
    \\/// refused, since its points would follow point 0's branches.
    \\fn zLeads(comptime S: type) bool {
    \\    return contract.leads(S);
    \\}
    \\
    \\/// Device-routed f64 transcendentals for the SCALAR paths (the
    \\/// §4.5.15 limiters). Generated devices also
    \\/// compile for NVPTX/AMDGCN (the engine's GPU eval and StateKernel), and
    \\/// those targets have no libm — `@exp`/`@log` on an f64 die at PTX
    \\/// assembly with "no libcall available for fexp". `contract.gm`'s host
    \\/// branch IS the builtin, so host emission is numerically unchanged; its
    \\/// device branch is a self-contained soft port. sin/cos joined when the
    \\/// bjt reached tan through the StateKernel's scalar core (`fsin` cannot
    \\/// select on NVPTX).
    \\///
    \\/// expm1, log1p and atan are routed too, and NOT for a missing libcall --
    \\/// NVPTX takes them. Each raises the subnormal underflow flag through
    \\/// `std.mem.doNotOptimizeAway`, which for a float is
    \\/// `asm volatile ("" :: "rm" (v))`, and AMDGPU cannot match the `m`
    \\/// alternative: "Could not match memory address. Inline asm failure!".
    \\/// AMD-only, so a CUDA-only check never sees it.
    \\inline fn zDevExp(x: f64) f64 {
    \\    return contract.gm.exp(x);
    \\}
    \\inline fn zDevExpm1(x: f64) f64 {
    \\    return contract.gm.expm1(x);
    \\}
    \\inline fn zDevAtan(x: f64) f64 {
    \\    return contract.gm.atan(x);
    \\}
    \\inline fn zDevLog(x: f64) f64 {
    \\    return contract.gm.log(x);
    \\}
    \\inline fn zDevPow(x: f64, y: f64) f64 {
    \\    return contract.gm.pow(x, y);
    \\}
    \\inline fn zDevSin(x: f64) f64 {
    \\    return contract.gm.sin(x);
    \\}
    \\inline fn zDevCos(x: f64) f64 {
    \\    return contract.gm.cos(x);
    \\}
    \\inline fn zDevTanh(x: f64) f64 {
    \\    return contract.gm.tanh(x);
    \\}
    \\inline fn zDevSinh(x: f64) f64 {
    \\    return contract.gm.sinh(x);
    \\}
    \\inline fn zDevCosh(x: f64) f64 {
    \\    return contract.gm.cosh(x);
    \\}
    \\
    \\fn zTan(comptime S: type, a: S) S { // §4.3.2 tan = sin/cos
    \\    return a.sin().div(a.cos());
    \\}
    \\/// `val`, the value of f(a) at `v = a.val()`, with f's slope `g` grafted
    \\/// onto a's derivative through a zero-valued carrier (`zHypot`'s idiom).
    \\/// A non-finite slope (a pole, a branch point) has none worth
    \\/// propagating. At v = ±0 with f(±0) = ±0 (asin, asinh, atanh) the
    \\/// value is `a.scale(g)`, since -0 plus a +0 carrier would round to +0.
    \\fn zGraft(comptime S: type, a: S, v: f64, val: f64, g: f64) S {
    \\    if (v == 0.0 and val == 0.0) return a.scale(g);
    \\    var r = S.con(val);
    \\    if (std.math.isFinite(g) and g != 0.0) r = r.add(a.addC(-v).scale(g));
    \\    return r;
    \\}
    \\// §4.3.1/§4.3.2 the functions Tables 4-14/4-15 name a C equivalent for
    \\// and the family does not carry: the value is the one function the
    \\// compiler folds with (`contract.gm`, `std.math`), the derivative the
    \\// analytic one (#60; the ln/sqrt/atan compositions these replace lost up
    \\// to every digit, VD-123).
    \\fn zLog10(comptime S: type, a: S) S { // §4.3.1 log() is base 10, C log10
    \\    const v = a.val();
    \\    return zGraft(S, a, v, contract.gm.log10(v), 0.4342944819032518 / v);
    \\}
    \\/// #81: a GPU target gets the branch-free core. A select whose arms are
    \\/// costly runs both there (`render.zig`), and the checked kernels below
    \\/// inline, so no outlined call splits the core. A host CPU keeps the
    \\/// lazy arm and the call.
    \\const zSpec = switch (@import("builtin").target.cpu.arch) {
    \\    .nvptx64, .amdgcn => true,
    \\    else => false, // else: every other target is a host CPU
    \\};
    \\const zSpecCc: std.builtin.CallingConvention = if (zSpec) .@"inline" else .auto;
    \\/// `a` when `c`, else `b`. Both are arguments, so both are evaluated. A
    \\/// GPU picks with `S.sel`'s lane select: an `if` over two struct values
    \\/// joins them through a pointer phi, which pins both arms' copies in
    \\/// local memory (SROA cannot split them).
    \\inline fn zPick(comptime S: type, c: bool, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    \\    if (comptime zSpec) return S.sel(S.con(if (c) 1.0 else 0.0), a, b);
    \\    return if (c) a else b;
    \\}
    \\// §4.3.2 "Input values outside of the valid range for the operator shall
    \\// report an error", for Table 4-14's one-bound domains: each op with its
    \\// check in front (`opcode_zig.Row.checked`; the unchecked spelling is for
    \\// a value `setup` speculates outside its guard). The code is the one the
    \\// prover gives the same argument when it can see it.
    \\fn zSqrtD(comptime _: type, a: anytype) callconv(zSpecCc) @TypeOf(a) {
    \\    const v = a.val();
    \\    zDomain("E0604", "sqrt", "x >= 0", v, v >= 0.0);
    \\    return a.sqrt();
    \\}
    \\fn zLnD(comptime _: type, a: anytype) callconv(zSpecCc) @TypeOf(a) {
    \\    const v = a.val();
    \\    zDomain("E0602", "ln", "x > 0", v, v > 0.0);
    \\    return a.log();
    \\}
    \\fn zLn1pD(comptime _: type, a: anytype) callconv(zSpecCc) @TypeOf(a) {
    \\    const v = a.val();
    \\    zDomain("E0603", "ln1p", "x > -1", v, v > -1.0);
    \\    return a.log1p();
    \\}
    \\fn zLog10D(comptime S: type, a: S) callconv(zSpecCc) S {
    \\    const v = a.val();
    \\    zDomain("E0602", "log", "x > 0", v, v > 0.0);
    \\    return zLog10(S, a);
    \\}
    \\/// §4.3.1 Table 4-14 pow's domain, "if x > 0, all y; if x = 0, y > 0; if
    \\/// x < 0, all integer y", with the prover's E0609 leniency at x = 0,
    \\/// y = 0 (IEEE pow(0, 0) = 1).
    \\fn zPowOk(x: f64, y: f64) bool {
    \\    return x > 0.0 or (x == 0.0 and y >= 0.0) or (x < 0.0 and y == @trunc(y));
    \\}
    \\/// `a.pow(k)` for an exponent that does not move with the solve, checked.
    \\fn zPowK(comptime _: type, a: anytype, k: f64) callconv(zSpecCc) @TypeOf(a) {
    \\    const v = a.val();
    \\    zDomain("E0609", "pow", "x > 0, or x = 0 with y >= 0, or x < 0 with integer y", v, zPowOk(v, k));
    \\    return a.pow(k);
    \\}
    \\/// §4.3.1 Table 4-14 hypot names the C library function, which is
    \\/// overflow-free — a²+b² composed in S overflowed for legs ≳1e154. The
    \\/// value is the libm one; the derivative (a/h)·da + (b/h)·db is grafted on
    \\/// through zero-valued carriers, `a.addC(-av)` being an S whose VALUE is
    \\/// exactly 0 and whose derivative is da — the same idiom the §12.32 systf
    \\/// reassembly uses. Guarded: at h = 0 hypot has no derivative (a cone tip),
    \\/// and a non-finite h has no slope worth propagating.
    \\fn zHypot(comptime S: type, a: S, b: S) S {
    \\    const av = a.val();
    \\    const bv = b.val();
    \\    const h = std.math.hypot(av, bv);
    \\    var r = S.con(h);
    \\    if (h != 0.0 and std.math.isFinite(h))
    \\        r = r.add(a.addC(-av).scale(av / h)).add(b.addC(-bv).scale(bv / h));
    \\    return r;
    \\}
    \\// d asin = dx/sqrt(1-x^2) and d acos its negation, with 1-x^2 as
    \\// (1-x)(1+x): exact near ±1, where x*x rounds the gap away.
    \\fn zAsin(comptime S: type, a: S) S { // §4.3.2, C asin
    \\    const v = a.val();
    \\    zDomain("E0605", "asin", "-1 <= x <= 1", v, v >= -1.0 and v <= 1.0);
    \\    return zGraft(S, a, v, std.math.asin(v), 1.0 / @sqrt((1.0 - v) * (1.0 + v)));
    \\}
    \\fn zAcos(comptime S: type, a: S) S { // §4.3.2, C acos
    \\    const v = a.val();
    \\    zDomain("E0605", "acos", "-1 <= x <= 1", v, v >= -1.0 and v <= 1.0);
    \\    return zGraft(S, a, v, std.math.acos(v), -1.0 / @sqrt((1.0 - v) * (1.0 + v)));
    \\}
    \\// d asinh = dx/sqrt(x^2+1), as dx/|x| past 1e150 where x^2 overflows.
    \\fn zAsinh(comptime S: type, a: S) S { // §4.3.2, C asinh
    \\    const v = a.val();
    \\    const g = if (@abs(v) > 1e150) 1.0 / @abs(v) else 1.0 / @sqrt(v * v + 1.0);
    \\    return zGraft(S, a, v, contract.gm.asinh(v), g);
    \\}
    \\fn zAcosh(comptime S: type, a: S) S { // §4.3.2, C acosh
    \\    const v = a.val();
    \\    zDomain("E0607", "acosh", "x >= 1", v, v >= 1.0);
    \\    return zGraft(S, a, v, contract.gm.acosh(v), 1.0 / (@sqrt(v - 1.0) * @sqrt(v + 1.0)));
    \\}
    \\fn zAtanh(comptime S: type, a: S) S { // §4.3.2, C atanh
    \\    const v = a.val();
    \\    zDomain("E0606", "atanh", "-1 < x < 1", v, v > -1.0 and v < 1.0);
    \\    return zGraft(S, a, v, contract.gm.atanh(v), 1.0 / ((1.0 - v) * (1.0 + v)));
    \\}
    \\/// §4.3.2 atan2(y, x), C atan2: C99 F.10.1.4's signed zeros and quadrants
    \\/// (atan2(-0, -1) = -pi, atan2(+0, -0) = +pi; Table 4-15's "atan2(0,0) =
    \\/// 0" is +0, +0). d atan2 = (x dy - y dx)/(x^2 + y^2), on every axis,
    \\/// as (x/h)/h and (y/h)/h with h = hypot(x, y), which does not overflow;
    \\/// none at the origin. On the +x axis the value is y/x, which keeps
    \\/// y's signed zero and carries the same slope (dy/x).
    \\fn zAtan2(comptime S: type, y: S, x: S) S {
    \\    const yv = y.val();
    \\    const xv = x.val();
    \\    if (yv == 0.0 and xv > 0.0) return y.div(x);
    \\    const h = std.math.hypot(xv, yv);
    \\    var r = S.con(contract.gm.atan2(yv, xv));
    \\    if (h != 0.0 and std.math.isFinite(h))
    \\        r = r.add(y.addC(-yv).scale((xv / h) / h)).sub(x.addC(-xv).scale((yv / h) / h));
    \\    return r;
    \\}
    \\fn zFloor(comptime S: type, a: S) S { // §4.3.1 — derivative 0 a.e.
    \\    return S.con(@floor(a.val()));
    \\}
    \\fn zCeil(comptime S: type, a: S) S { // §4.3.1 — derivative 0 a.e.
    \\    return S.con(@ceil(a.val()));
    \\}
    \\/// §4.2.4 `%` keeps the sign of the first operand — C's fmod, which `@rem`
    \\/// on f64 is, EXACTLY. The composed `a − b·trunc(a/b)` this replaces lost
    \\/// the whole remainder to the subtraction's rounding once |a| ≳ 2^53·|b|.
    \\/// The derivative treatment is unchanged (k = trunc(a/b) is constant a.e.,
    \\/// so d = da − k·db), carried by zero-valued grafts so the exact value
    \\/// survives; a non-finite k (b = 0, or a/b overflowed) has no slope worth
    \\/// propagating and degrades to da alone.
    \\/// §4.2.4 "It shall be an error to pass zero (0) as the second argument
    \\/// to the modulus operator", real operands included: `zModZero` reports
    \\/// E0601 as the integer `%` does, rather than returning @rem's NaN.
    \\fn zFmod(comptime S: type, a: S, b: S) S {
    \\    const av = a.val();
    \\    const bv = b.val();
    \\    if (bv == 0.0) zModZero();
    \\    const k = @trunc(av / bv);
    \\    var r = S.con(@rem(av, bv)).add(a.addC(-av));
    \\    if (std.math.isFinite(k)) r = r.sub(b.addC(-bv).scale(k));
    \\    return r;
    \\}
    \\/// §4.3.1 pow with a non-constant exponent. The exp(y·ln x) composition
    \\/// this replaces was NaN on the clause's own legal domain "if x < 0, all
    \\/// integer y". The value is S's own pow, which handles the negative-base
    \\/// integral-y sign itself; the derivatives are grafted on zero-valued
    \\/// carriers:
    \\///   ∂/∂x = y·x^(y−1)  — valid for x > 0 and for integral y of either sign;
    \\///   ∂/∂y = x^y·ln(x)  — only for x > 0. For x ≤ 0 the legal y move in
    \\///   integer steps, so no continuous ∂/∂y exists and 0 is the honest slope.
    \\/// Non-finite slopes (x = 0 with y < 1, domain-error NaNs) are dropped the
    \\/// same way zHypot drops its cone tip.
    \\/// Both transcendentals go through `S.con(x)`, not `std.math.pow` and
    \\/// `@log`, for the reason `devSafe` exists: a unit body also compiles
    \\/// for nvptx, which has no libm, and a raw one is "no libcall available
    \\/// for flog/fexp" at PTX assembly. On a host S it is the same libm call,
    \\/// bit for bit, and the zero-derivative carriers fold away.
    \\fn zPow(comptime S: type, a: S, b: S, comptime varying_exponent: bool) S {
    \\    const x = a.val();
    \\    const y = b.val();
    \\    zDomain("E0609", "pow", "x > 0, or x = 0 with y >= 0, or x < 0 with integer y", x, zPowOk(x, y));
    \\    const v = S.con(x).pow(y).val();
    \\    // y·x^(y−1) = y·v/x — algebraically exact for x != 0, the negative-base
    \\    // integral-y clause included, and ONE pow instead of two. A second
    \\    // `S.con(x).pow(y - 1.0)` was half of the 828k pow calls on
    \\    // tran/fourbitadder and half of the 51% of instructions mos6_inverter
    \\    // spent under pow (callgrind, 2026-09-07): every junction exponent in
    \\    // every SPICE model is a model PARAMETER, so codegen's `.pow` arm sends
    \\    // all of them here rather than down `Dual.pow`'s own c·p/x.
    \\    //
    \\    // x == 0 keeps the second pow, and is NOT a rounding concern: at y == 1
    \\    // the true slope is 1, but v/x is 0/0 = NaN and the gate below would
    \\    // drop the term and flatten the Jacobian row. `mjs` defaults to 0 in
    \\    // bjt.va, so `1 - mjs` is exactly that exponent and the substrate base
    \\    // `1 - v/ps` reaches exactly 0 at v == ps. The branch is never taken on
    \\    // a normal bias point, so the hot path is still one pow, and where it
    \\    // IS taken the expression is the old one character for character.
    \\    // Elsewhere the two forms sit within 6 ulp of a 60-digit reference and
    \\    // neither is uniformly closer; the result is a Jacobian entry, and
    \\    // Newton converges to the accuracy of the RESIDUAL.
    \\    const gx = if (x != 0.0) y * v / x else y * S.con(x).pow(y - 1.0).val();
    \\    const gy: f64 = if (varying_exponent and x > 0.0) v * S.con(x).log().val() else 0.0;
    \\    var r = S.con(v);
    \\    if (std.math.isFinite(gx) and gx != 0.0) r = r.add(a.addC(-x).scale(gx));
    \\    if (std.math.isFinite(gy) and gy != 0.0) r = r.add(b.addC(-y).scale(gy));
    \\    return r;
    \\}
    \\/// §9.17.3 `$limit(access, user_function, args…)`: the value is what the
    \\/// user limiter returned, the DERIVATIVE is the access function's.
    \\///
    \\/// SPICE evaluates the device at the limited bias and stamps
    \\/// `I(vlim) + g(vlim)·(v − vlim)`, so the residual stays linear in the
    \\/// true unknown past the clamp point and the Jacobian entry never
    \\/// vanishes. Differentiating the limiter instead gives dv_lim/dv = 0
    \\/// inside the clamped region — a device contributing no conductance,
    \\/// which is a singular row for a floating internal node. So: shift the
    \\/// probe by the constant the clamp moved it, rather than replace it.
    \\fn zLimitUf(comptime S: type, vnew: S, vlim: S) S {
    \\    return vnew.addC(vlim.val() - vnew.val());
    \\}
    \\fn zIabs(a: i64) i64 { // §4.3.1 integer abs, §3.2's 32-bit result
    \\    return @as(i32, @truncate(if (a < 0) -%a else a));
    \\}
    \\/// §4.2.11 the shift COUNT reads as unsigned: a negative i64 count is a
    \\/// reinterpreted value ≥ 2^63, which vacates every one of §3.2.1's 32 bits
    \\/// — so the answer is 0, exactly like any other over-wide count. Without
    \\/// the guard `std.math.shl`/`shr` take a negative count as "shift the
    \\/// OTHER way" (8 << -1 came out 4, 8 >> -1 came out 16). Positive counts
    \\/// keep the std functions' verified over-wide-is-0 semantics untouched.
    \\fn zShl(a: i64, n: i64) i64 {
    \\    return if (n < 0) 0 else std.math.shl(i64, a, n);
    \\}
    \\fn zShr(a: i64, n: i64) i64 {
    \\    if (n == 0) return a; // preserve signed/unsigned operand identity
    \\    const bits: u32 = @bitCast(@as(i32, @truncate(a)));
    \\    return if (n < 0) 0 else std.math.shr(u32, bits, n);
    \\}
    \\fn zClog2(a: i64, width: i64) i64 { // §9.14 / IEEE 1364-2005 §17.11.1
    \\    if (width > 64 and a < 0) return width;
    \\    const mask: u64 = if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
    \\    const bits = @as(u64, @bitCast(a)) & mask;
    \\    return if (bits <= 1) 0 else 64 - @as(i64, @clz(bits - 1));
    \\}
    \\fn zStrCmp(a: []const u8, b: []const u8) i64 { // §3.3.1 string relations
    \\    return switch (std.mem.order(u8, a, b)) { .lt => -1, .eq => 0, .gt => 1 };
    \\}
    \\
    \\
;

/// `zDomain` for a solver device: an empty guard. §4.3.2: "Input values
/// outside of the valid range for the operator shall report an error."
/// `proof.checkDomain` refuses what it can prove from the source
/// (E0602-E0607, E0609); `math_txt`'s restricted-domain functions call
/// `zDomain` with that code for the rest. A device has no transcript (it
/// also compiles for NVPTX), so only the executable reports; one call site
/// keeps both artifacts agreeing on which values are out of range.
/// `zModZero` (§4.2.4 real `%` by zero) traps, as `render.imodFn` does for
/// the integer `%`.
pub const domain_quiet_txt =
    \\fn zDomain(comptime _: []const u8, comptime _: []const u8, comptime _: []const u8, _: f64, _: bool) void {}
    \\fn zModZero() noreturn { @trap(); }
    \\
    \\
;

/// `zDomain` for the printing executable: reports and stops, on the §9.21.2
/// `E` precedent, since the clause names no in-range value and libm's quiet
/// NaN would look like a converged answer. A NaN argument reports too. `tan`
/// is unguarded: its poles are irrational, so no f64 is ever at one. `code`
/// is the prover's for the same argument, so `//! reject-run` names it. The
/// testbench mutes it (`vera_domain_muted`, `tb/runner_text.zig` `point`)
/// while its self-checks evaluate perturbed points no analysis asked for.
pub const domain_report_txt =
    \\fn zDomain(comptime code: []const u8, comptime name: []const u8, comptime rule: []const u8, x: f64, in_range: bool) void {
    \\    if (in_range) return;
    \\    if (comptime @hasDecl(@import("root"), "vera_domain_muted")) {
    \\        if (@import("root").vera_domain_muted) return;
    \\    }
    \\    std.debug.print(
    \\        "error[" ++ code ++ "]: LRM 4.3.2: " ++ name ++ "() input value is outside the valid range " ++ rule ++ ": {d}\n",
    \\        .{x},
    \\    );
    \\    std.process.exit(1);
    \\}
    \\fn zModZero() noreturn {
    \\    std.debug.print("error[E0601]: LRM 4.2.4: real modulus divisor is zero\n", .{});
    \\    std.process.exit(1);
    \\}
    \\
    \\
;
