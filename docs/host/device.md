# The device at a glance

A VerA device is one Zig source file. It declares types and functions at its
top level, and a simulator (the *host*) imports it as a module and calls
them. Nothing is behind a vtable: every entry point is a generic Zig
function the host instantiates at compile time with its own arithmetic.

The rules every device follows are one file, `lib/contract.zig` in the
repository, installed as `share/vera/contract.zig` by `zig build install`.
The generated device imports it as the module `contract`, and so does your
host. The rest of this part quotes it by declaration name; when this book
and that file disagree, the file is right.

Here is everything the diode from the [minimal host](minimal-host.md)
declares at its top level:

```verilog
{{#include ../examples/host/diode.va}}
```

```console
{{#include ../examples/host/device.out}}
```

## What is required

`contract.validate(D)` runs at compile time inside every generated device
(when the program opts in, see [linking](linking.md)) and turns a broken
device into a compile error naming the declaration. It requires five
declarations and checks the shape of every optional one it knows:

| Declaration | What it is |
|---|---|
| `U` | the unknowns, a dense enum `0..n-1` with an unsigned tag (`enum(u8)` up to 256 unknowns, as wide as the count needs past them). Ports come first (LRM §6.5), then internal nodes, then branch-flow unknowns. `contract.nU(D)` is its length |
| `num_ports` | how many members of `U` are ports, in port-list order. 0 is legal |
| `Model` | the card: one field per parameter (LRM §3.4) with its default, plus host-written fields ending in `__` |
| `Instance` | per-instance values `eval` reads (`mfactor`, held variables, `bound_step`, ...) |
| `eval` | `fn (comptime S: type, x: *const [n_u]S.V, model: *const Model, inst, sim: SimState) Rows(D, S)` |

Every field of `Model` and `Instance` has a default, so `.{}` is a valid card
and a valid instance. Any other public declaration must be one `validate`
knows (`AllowedPubDecl`), so a typo in a hand-written device is an error, not
an ignored hook.

## Model, Setup and the card

`Model` is flat: every parameter is a field you write directly. A `real`
parameter is an `f64`. An `integer` parameter is an `i64`, the carrier of its
32-bit value (write any integer; `derive` keeps the low 32 bits), or the
narrowest of `i8`, `u8`, `i16` and `u16` that holds its declared `from` range
and its default when nothing but the card writes it; write one of those with
a checked cast (`std.math.cast`), since a value the field cannot hold is
outside that range. LRM §9.19's given
flags are one bitset, `given__`: after writing a parameter your card names,
call `model.setGiven("name")` with the field's spelling. `Model.given_params`
lists the names that have a bit; any other name is a no-op. Some fields
are the host's to write, all `f64`, each defaulting to the SPICE value
(`host_model_fields`): `temperature__` (kelvin, 300.15), `nom_temp__`
(`$simparam("tnom")`, °C), `reltol__`, `abstol__`, `vntol__`, `gmin__` and
`source_scale__`. The temperature belongs to the `Model` row (since ABI 6),
so an instance at its own temperature gets its own row. A device whose source
calls LRM §9.19 `$port_connected` also has `port_connected__`, a `u64` mask
of the connected ports that defaults to all ones. Two more are `u32` indices into
your `contract.host_strings`, `cwd_idx__` and `analysis_name_idx__`, for
`$simparam$str` ([tables](tables.md)); 0, the default, means not written.
`noise_table_points__` is the device's, written by `derive`: the card's
noise-table knots, read through `contract.noiseTable`.

The order in which a host prepares a card is fixed:

1. Write the card's fields.
2. `derive(S, &model)`, when declared: fills parameters defined over other
   parameters (LRM §6.3.4) and every `localparam`.
3. `checkShape(&model)`, when declared: non-null names a parameter that sizes
   an array or picks a generate arm, which this device was compiled for a
   fixed value of. Refuse the card.
4. `checkCard(&model)`, optional: names a system parameter outside LRM
   Table 9-29's allowed values.
   `checkRange(&model)`, when declared: names a parameter the card puts
   outside its declared `from`/`exclude` ranges (LRM §3.4.2, "an error ...
   during simulation"). Refuse the card.
5. `setup(V, &model)`: fills `model.su`, the solve-invariant values `eval`
   would otherwise recompute every iterate (`Setup`), and a copy of every
   card value `eval` reads, so an evaluation (or a `say`) touches `su` alone
   and not the card's own cache lines. Once per `Model` row,
   and again after every write to the card, `temperature__`, or a
   `$simparam` named in `setup_simparams`. Until it runs, `su` holds NaN, so a
   forgotten call is a NaN residual, not a plausible wrong one.
6. `setupInstance(&model, &inst)`, when declared: per instance, after every
   `setup` and every instance write.

`V` in `setup(V, ...)` (and the `S` of `derive`) is a value-only scalar
family: a family whose values carry no derivative lanes. In the examples it
is `Val`, a `RefFamily` with every lane `contract.no_lane`.

## SimState

Every entry point that depends on the analysis takes a `SimState` by value
(`extern struct`, 24 bytes, the same on every target):

```zig
pub const SimState = extern struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: AnalysisKind = .dc,
    initial_step: bool = false,
    final_step: bool = false,
    analog_initial: bool = true,
    iteration: u32 = 1,
};
```

`t` is `$abstime`, `dt` the step since the last accepted point (0 marks a
static solve, which is what an operator's DC form keys on), `kind` is LRM
§4.6.1's `analysis()` (`static`, `ic`, `nodeset`, `dc`, `tran`, `ac`,
`noise`), the flags are LRM §5.10.2's global events and §5.2.1's `analog
initial`, and `iteration` is `$simparam("iteration")`. The defaults are a DC
operating point at t = 0. One value serves every instance.

## The evaluation functions

| Function | Returns |
|---|---|
| `eval(S, &x, &model, &inst, sim)` | `Rows(D, S)`: one value per unknown, the resistive residual of that row (LRM §5.6). Each row's value is the current leaving that node through the device, and its derivative lanes are that row of the Jacobian |
| `q(S, &x, &model, &inst, sim)` | `Sites(D, S)`: one charge per **charge site** (each `ddt` term), not per row. See [charges](state.md) |
| `evalQ(S, ...)` | `.{ .res = Rows, .q = Sites }` from one evaluation instead of two |

`Rows(D, S)` is a tuple whose row `r` has type `S.Of(rowMask(D, r))`: the
row carries exactly the derivative lanes its `jac_pattern` entry allows.
Rows can differ in type, so a host reads them with an `inline for`, and
`contract.denseRow(n, row)` spreads one into a matrix row, which is what the
minimal host does. [Scalar
families](families.md) explains the lanes.

The instance pointer is `*const Instance`, or `*Instance` when the device
declares `mutable_eval` (it fills table state on its first call, and the host
must give each evaluation exclusive access; `InstancePtr(D)`).

## Version stamp

`contract.vera_version` is the VerA release the contract file ships with
(semver, `vera --version`). Every generated device carries the release that
generated it as `pub const vera_version` (the `vera_version` line of the
listing above), and `validateHost` refuses, always, a device whose value is
not exactly the contract's, naming both: regenerate it with the VerA your
contract came from. Any contract change ships in a VerA release, and the
changelog under that version says what changed. A host that supports one
release pins it at compile time:

```zig
if (comptime !std.mem.eql(u8, D.vera_version, "0.13.0"))
    @compileError("regenerate " ++ @typeName(D) ++ " with VerA 0.13.0");
```

An optional declaration a later release adds stays optional: a host that
uses one checks it with `@hasDecl`.

## The optional declarations, by job

The remaining declarations are optional. A device declares only what its
source needs, and a host may ignore a hook only where the next pages say it
can.

| Job | Declarations | Page |
|---|---|---|
| sparsity and lanes | `jac_pattern`, `jac_rows`, `q_pattern`, `q_rows`, `deriv_reads`, `ddx_reads`, `jac_const`, `constant`, `lane_masks`, `jac_f32`, `jac_f32_host` | [families](families.md) |
| charges and state | `n_q`, `q_stamps`, `q_lte`, `q_site_pattern`, `State`, `state_class`, `initState`, `updateState`, `acceptQ`, `stateCtl`, `advanceIteration`, `checkConvergence` | [state](state.md) |
| limiting and start | `limit`, `limit_reads`, `limit_writes`, `seed`, `collapse`, `collapse_full`, `u_nodeset` | [state](state.md) |
| time | `nextBreakpoint`, `pendingBreakpoint`, `delays` | [state](state.md) |
| small signal | `noise_gens`, `noisePsd`, `noise_tables`, `noiseTablePoints`, `ac_gens`, `acStim`, `ac_dyn_slots`, `acDyn` | [tables](tables.md) |
| metadata and output | `u_kinds`, `u_abstol`, `decl_meta`, `mc_param`, `status_sites`, `say_sites`, `say`, `file_io`, `systf_calls`, `display` | [tables](tables.md) |
| analog VPI | `vpiContribs`, `vpi_contrib_access`, `vpi_contrib_hi`, `vpi_contrib_lo`, `vpi_contrib_flow_u`: the contribution rows an LRM chapter 12 analog VPI host reads, emitted only when a program that embeds VerA as a library sets `Options.vpi_contribs` (VerA's VPI host does; no command-line flag sets it). `vpiShares`, `vpi_share_row`: when two instances' unnamed branches over one node pair share a row, each instance's own share of it (the flow of that instance's branch), by row | none |
| batching | `batch_ok`, `batch_lead`, `batch_inst`, `mutable_eval` | [batching](batching.md) |
| card | `derive`, `checkShape`, `checkCard`, `checkRange`, `Setup`, `setup`, `setup_simparams`, `setup_chunks`, `setupInstance`, `attempt`, `precompute` | above, and [linking](linking.md) |
