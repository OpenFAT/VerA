* LRM 3.6.3.2: a net initializer is a nodeset value the analog solver uses
* for the net's potential. VerA applies it as Newton's starting point and
* never holds it (Vague_Decisions.md VD-117), in this engine as in the
* testbench host.
*
* The device's internal net w carries f(V) = (V-1)(V-2)(V-3), roots 1, 2
* and 3, with the initializer `electrical w = 2.75;`, and copies V(w) onto
* its port, here `out`. The answer, by hand: Newton from 2.75 runs
* 3.2273, 3.0507, 3.0035, 3.00002, so V(out) = 3. A runner that ignored the
* nodeset starts at the cold 0 and lands on 1; one that clamped it gives
* 2.75. The circuit holds no charge, so every transient row repeats the
* operating point. At t = 0 the published point is Newton's last
* linearization point, inside SPICE's reltol of the root (atol 1e-3); each
* transient point re-solves from the last, so the samples inside the run
* are held to 1e-6.
* Expected results: spice_op_nodeset_root.expected.json
.hdl "spice_nodeset_cubic.va"
N1 out 0 spice_nodeset_cubic
.tran 1e-4 1e-3
.end
