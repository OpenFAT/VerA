# Why a device contract, not OSDI

This part of the book is for people writing a circuit simulator, or adding
compact-model support to one. It explains how to run VerA's devices inside
your own solver.

The established way to load compiled Verilog-A models is OSDI, the C
interface of the shared objects [OpenVAF-Reloaded](https://github.com/OpenVAF/OpenVAF-Reloaded)
builds (its header is `openvaf/osdi/header/osdi_0_4.h`). An `.osdi` file
exports one descriptor per model: tables of nodes, parameters and Jacobian
entries, and function pointers (`setup_model`, `setup_instance`, `eval`,
`load_residual_resist`, `load_jacobian_resist`, ...) the simulator calls
through an opaque instance pointer. VerA can produce that too ([OSDI
interoperability](osdi.md)); `lib/osdi_dyn.zig` declares the whole 0.4
descriptor as a Zig `extern struct` (`Descriptor`), so you can read it there.

VerA's native form is different: the generated device is **Zig source** that
your simulator compiles into itself, against a contract that is one Zig file,
`lib/contract.zig`. This page says what that buys and what it costs, so you
can choose.

## What the contract gives a host

**You choose the arithmetic.** Every entry point is generic over a *scalar
family* your host passes at compile time ([scalar families](families.md)).
The family decides how a value carries its derivatives: `f64` or `f32`
derivative lanes, a dense array or exactly the lanes each row needs, one
operating point or a SIMD vector of them. The device publishes which
unknowns need a lane at all (`deriv_reads`) and the exact constant partials
of the rest (`jac_const`), so the family carries no lane the model never
reads.

**The Jacobian is the residual's.** Derivatives propagate through the same
arithmetic that computes the residual (forward-mode automatic
differentiation), so one evaluation returns both, and they cannot disagree.
OpenVAF's output is also exact; the difference is that here the derivative
arithmetic runs in your family, inlined into your loop.

**No indirect call per evaluation.** The device's `eval` is instantiated and
inlined at compile time. There is no descriptor to walk and no function
pointer per instance per iterate, and the compiler optimises the model
together with your stamping code. Under OSDI the same device evaluates into
a buffer inside the instance, and the simulator copies it out with a second
round of `load_*` calls (`lib/osdi_dyn.zig`'s header: "The residuals and
Jacobian are kept in the instance; the `load_*` calls stamp them").

**Plain data.** `Model` and `Instance` are structs of value fields with
defaults; the state a device carries across accepted points is a separate
`State`. You allocate them, in whatever layout your solver wants (arrays of
instances, one `Model` row shared by many).

**Many points per call.** A device that declares `batch_ok` evaluates a
vector of operating points exactly, point for point, through the same
generic code ([batching](batching.md)).

**GPUs from the same file.** The device imports only `std` and the contract
and calls no OS; its transcendental functions come from the contract's own
`gm`. The same `device.zig` compiles for NVPTX and AMDGCN
([linking](linking.md)).

**Mistakes fail the build.** `contract.validate` checks the device's every
declaration at compile time, and `contract.validateHost` checks your host
against what the device needs (it calls `setup`, it supplies the VPI
binding, it adds frequency-dependent partials back), when you opt in.

## What the contract carries that OSDI 0.4 cannot

`lib/osdi_dyn.zig` maps the contract onto OSDI 0.4, and its header lists
what does not map, "each because OSDI 0.4 has no slot for it":

- **Correlated noise.** A contract device says which noise rows share one
  generator (`NoiseGen.source`) and gives a correlation coefficient between
  two rows (`PsdTerm.corr_with`, `corr`), as LRM §4.6.4.6 requires. Under
  OSDI "each row is an independent source".
- **A step-rejection request.** `updateState` may return
  `request_reject_at`, asking the host to retry a step at an earlier time
  ([state](state.md)). OSDI has no way to say it.
- **Acceptance.** The contract has a call for an accepted point
  (`updateState`, then `stateCtl(.commit)`) and one for a rejected step
  (`stateCtl(.revert)`). "OSDI has no accept callback", so under OSDI a
  device's state advances at every iterate of a static solve and, in a
  transient, at the last point evaluated before the simulator moves time
  forward.
- **Operating-point variables** (opvars) are not mapped either.

A model whose behaviour depends on state across accepted points (events,
`idt`, held variables, `$vera_reject_step`) is exact under the contract and
approximate under OSDI.

## What OSDI gives that the contract does not

Be clear about these before choosing the contract:

- **Any language.** OSDI is a C ABI: a simulator in any language that can
  call C loads a `.osdi` file with `dlopen`. The contract is Zig source. A
  host in another language needs a Zig `dyn` module that exports the C
  functions it wants ([linking](linking.md)), and so a Zig toolchain in its
  build.
- **A stable binary format.** An `.osdi` built once loads into any simulator
  that speaks that OSDI version. A VerA device is regenerated with each VerA
  release (the generated file carries the release as `vera_version`, which
  [the device page](device.md) shows, and a contract from another release
  refuses it), and is compiled by the Zig release VerA targets (0.18.0-dev.349+d924f83bf).
- **Simulators that already support it.** ngspice loads OSDI libraries with
  its `pre_osdi` command. A simulator that speaks OSDI gets VerA's models
  through `vera --emit-osdi` without code changes ([OSDI
  interoperability](osdi.md)).
- **Separate compilation.** An OSDI model is compiled once, ahead of time.
  A contract device is compiled with your host, so a large model (BSIM4,
  PSP) adds its compile time to your build, especially in a release build
  through LLVM.

## What adopting it costs

A host in Zig, or a Zig shim in your build; a compile step per device (VerA,
then Zig); a matching contract (`share/vera/contract.zig` and the
`contract/` beside it, from the same VerA); and the hooks your devices need, which this part documents one at a
time. The [minimal host](minimal-host.md) is the place to start.
