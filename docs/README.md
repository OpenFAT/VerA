# VerA

VerA is a Verilog-AMS compiler. It reads a Verilog-A device model (or a
digital IEEE 1364 design, or a mix of both) and writes **Zig source**: a
device with a residual, an exact Jacobian, charges, noise and state, which a
circuit simulator compiles into its own Newton loop. The same emitted file
builds for a CPU, as a shared library, as a self-checking testbench, or as an
NVPTX or AMDGCN kernel.

This book has four parts.

1. **[Learn Verilog-AMS](learn/getting-started.md)** teaches the language from
   nothing, the way *The Rust Programming Language* teaches Rust: one
   construct per chapter, each with a model you can run, and exercises at the
   end. Every chapter also shows how the same thing looks in VerA.
2. **[Using VerA](using/install.md)** is the reference for the tool: installing
   it, every command-line flag, the `//!` testbench directives, diagnostics,
   the attributes VerA reads, and the choices VerA makes where the standard
   leaves one open.
3. **[VerA devices in your own simulator](host/why.md)** is for simulator
   authors. It documents the device contract, `lib/contract.zig`, and walks
   through a small host that loads a VerA device and solves it.
4. **[Conformance and performance](conformance.md)** gives the measured
   numbers: how much of the standard VerA covers, and how fast it compiles.

## The examples are checked

Every command and every output in this book is real. Each example is a file
under `docs/examples/`, and each transcript shown after it (the lines starting
with `$`, and what follows them) is a `.out` file that CI re-runs with
`tools/doctest.py` on every push. If VerA's output changes, the build fails
until the page is updated. So the output you read is the output the current
VerA prints.

## The standard

VerA implements the Verilog-AMS Language Reference Manual 2023 (the "LRM"),
and through it IEEE 1364-2005, which the LRM inherits for the digital half.
The book cites clauses as `LRM §5.6.1` and `IEEE 1364-2005 §9.2`. The LRM is
in the repository as a PDF under
[`docs/specification/`](https://github.com/OmarSiwy/VerA/tree/main/docs/specification),
together with the record of every reading VerA chose where the text is vague.
