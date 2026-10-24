# Scalar families and derivative lanes

A VerA device never computes in `f64` directly. Every function that touches
the solution takes `comptime S: type`, a **scalar family** your host
supplies, and computes every value as an `S.Of(mask)`: a value plus one
derivative lane for each unknown `mask` names. Each arithmetic operation
carries the derivatives along (forward-mode automatic differentiation), so
the residual and its Jacobian come from one evaluation of one expression and
cannot drift apart. There is no separately emitted Jacobian to get wrong.

Because the family is yours, so are its layout and its width: `f64` lanes or
`f32`, a dense array or exactly the lanes a row needs, one operating point or
a vector of them, CPU or GPU.

## What a family declares

`contract.family_fns` lists the declarations on the family type itself:

```zig
pub const family_fns = [_][]const u8{ "Of", "V", "con", "probe", "sel" };
```

| Declaration | Meaning |
|---|---|
| `Of(comptime m: u64) type` | the value type carrying the lanes of the unknowns in mask `m` (bit `u` is `@intFromEnum` value `u` of `U`) |
| `V` | the type of one unknown's value: `f64`, or a vector for a family that evaluates several operating points at once ([batching](batching.md)) |
| `con(c: f64) Of(0)` | a constant: no lanes. With a vector `V`, also `lift(V) Of(0)` |
| `probe(comptime u: usize, v: V) Of(1 << u)` | unknown `u` at value `v`: its own lane is 1 |
| `sel(c, a, b)` | `c != 0 ? a : b`, typed as the join of `a`'s and `b`'s masks |

Every `Of(m)` value carries `contract.family_primitives`:

```zig
pub const family_primitives = [_][]const u8{
    "addC",  "scale", "add",  "sub", "neg", "mul",   "div",  "exp",  "log",
    "expm1", "log1p", "sqrt", "pow", "sin", "cos",   "tanh", "sinh", "cosh",
    "atan",  "lt",    "le",   "eq",  "val", "ddxAt", "to",
};
```

A binary operation takes any `Of(m')` and returns `Of(m | m')`; a unary one
keeps `Of(m)`; the comparisons return `Of(0)` (1.0 or 0.0, no lanes);
`to(comptime m2)` widens and is a compile error unless `m ⊆ m2`; `val()`
reads the value and `ddxAt(comptime u)` lane `u`. Device code never opens a
value except through these, so your lanes may be narrower than `f64`.

The numerics of each primitive are pinned in the comment above
`family_fns` (values bit-exact except the transcendentals, whose last ulp is
yours; lanes with one rounding per listed operation, FMA optional). LRM
§4.3.1's `min`, `max` and `abs` are emitted as `lt` plus `sel`, so the
derivative at a tie is the one the clause's conditional spelling gives.

## Which unknowns need a lane

A device publishes masks so you carry no lane it never reads:

| Declaration | Meaning (absent means "all ones") |
|---|---|
| `deriv_reads` | the unknowns that need a derivative lane at all (`contract.derivReads`). For every other unknown, each partial is a compile-time constant |
| `jac_const` | those constants, exact, as `JacConst(U)` entries `{ row, col, g, c, when }`: `g` is ∂eval/∂x, `c` is ∂q/∂x. Stamp them yourself (`contract.jacConst`, `jacConstApplies`) |
| `jac_pattern`, `q_pattern` | per row, the columns whose partial can be nonzero (over-approximate: a set bit may be a zero, a clear bit is never a missing entry) |
| `jac_rows`, `q_rows` | which rows `eval`/`q` ever write. A clear bit is the only licence to skip a row: a row can be written with no column in it (a constant current source) |
| `ddx_reads` | the unknowns LRM §4.5.14 `ddx` reads, through `ddxAt` |
| `lane_masks` | every distinct mask the device declares values at, with a count (`LaneUse`): data for choosing a width, never a width |
| `constant` | `.{ .g, .c }`: dF/dx (or dQ/dx) does not depend on x, so a stamp built once may be reused. A wrong promise freezes the Jacobian |

`contract.rowMask(D, r)` is the mask row `r` is returned at:
`jac_pattern[r] & deriv_reads`. Up to 64 unknowns the masks are `u64`; past
64 they are `MaskOf(n)` (`u<n>`), and `contract.Mask(D)` is that type. Masks
are exact at any size: a value's mask names exactly the unknowns it depends on.
The n×n tables (`jac_pattern`, `q_pattern`, `q_site_pattern`) are emitted up to
about 2048 unknowns; past that a host takes each row's lanes from
`deriv_reads`.

The [minimal host](minimal-host.md) shows the stamping that `jac_const`
needs: lanes on the `deriv_reads` columns, constants on the rest.

## The reference family

`contract.RefFamily(L, lane, opts)` is the family VerA's own testbenches,
[ESPice](https://github.com/OmarSiwy/ESPice) (`src/device/eval.zig`) and
the examples use:

```zig
pub fn RefFamily(comptime L: type, comptime lane: anytype, comptime opts: RefOptions) type
```

- `L` is the lane float: `f64`, or `f32` for a device that declares
  `jac_f32` (the value stays `f64`).
- `lane` is a table (a slice, or a pointer to an array or vector) of any
  unsigned element type. `lane[u]` is the lane unknown `u` occupies, or the
  element type's maximum (`contract.no_lane` in a `u8` table) for an
  unknown the family does not carry. `std.simd.iota(u8, n)` is one lane per
  unknown up to 255 of them, `std.simd.iota(u32, n)` past them; all
  `no_lane` is the value-only family the card-time hooks (`setup`,
  `derive`) and the value-only state hooks take.
- `opts` is `.{ .collapse_applied = … }`, the family's trait (`family_fns`).

`Of(m)` carries exactly `m`'s lanes as a `@Vector(@popCount(m), L)`, so a row
with three live columns does three lanes of arithmetic. It serves any number
of unknowns, and refuses at compile time a mask naming an unknown `lane` does
not carry. A host whose matrix indexes a row at run time (a Newton plane, a
gate, an AC system) spreads it with `contract.denseRow(n, row)`: each lane at
its unknown's column, +0 elsewhere.

## jac_f32

`pub const jac_f32 = true` (from `vera --jac-f32`) is a **permission**, not
a different arithmetic: the device tolerates its derivative lanes in `f32`.
Absent, a host must assume `f64`. `jac_f32_host` (from `--jac-f32-host`, and
only together with `jac_f32`) asks the host to take it on its CPU path too.
The width stays your choice per target.

## Checking your own family

`contract.checkFamily(S)` checks at compile time that `S` declares
`family_fns` and that `Of(0)` and `Of(1)` carry every primitive (it runs only
when the program opts into the checks, see [linking](linking.md)).
`contract.expectFamily(S)` is the run-time test: every primitive over an
edge-value grid (signed zeros, denormals, ±1e300, infinities, NaN) against
`RefFamily` in `f64`, the pinned edge cases of `pow`, `div`, the comparisons
and `sel`, and the mask join of each binary operation. Put it in a `test`
block of your host.
