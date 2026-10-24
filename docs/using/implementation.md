# Implementation-defined choices

The LRM leaves some things to the tool: what an octal escape above `\377`
does, which interpolation `absdelay` uses, the seed of an omitted-seed
`$random`, how long an identifier may be. A model that relies on one of them
behaves as its tool chose, and another conforming tool may choose
differently. This page is what VerA chooses, so you can tell a portable
model from one that works only here.

The tables below are the project's own record,
[`docs/specification/Vague_Decisions.md`](https://github.com/OmarSiwy/VerA/blob/main/specification/Vague_Decisions.md),
included here as it stands in the repository. Each row names the clause,
what it leaves open, VerA's choice, the code that makes it, and the fixture
that pins it, so a choice cannot change without a test failing. "AMS"
clauses are the Verilog-AMS LRM, "1364" clauses IEEE 1364-2005.

The five sections are:

- **6. Implementation-defined choices**: what VerA picks where the LRM says
  the choice is the implementation's.
- **7. Resource limits**: every fixed limit (a buffer, a depth, a count),
  the diagnostic that fires when a design crosses it, and the fixture that
  crosses it.
- **8. Unspecified behaviour**: where the LRM says nothing at all, and what
  VerA does anyway.
- **9. Open defects** and **10. Open gaps**: known places VerA does not yet
  do what the LRM says. They are listed so you meet them here and not in a
  simulation.

The first half of the same file records the questions where the LRM's text
is ambiguous and VerA had to pick a reading (the `VD-` entries); the rows
below cite them by number.

{{#include ../../specification/Vague_Decisions.md:implementation}}
