//! The diagnostic catalogue's class 7 rows, events and timing:
//! `E0701` .. `W0750`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0701 = .{
        .title = "event expression outside '@()'",
        .lrm = "5.10",
        .explain =
        \\`cross`, `above`, `timer`, `initial_step` and `final_step` name
        \\events, not values. They belong in the parentheses of an event
        \\control statement:
        \\
        \\    @(initial_step) begin ... end
        ,
    },
    .E0702 = .{
        .title = "event control is not allowed in this context",
        .lrm = "5.2.1",
        .explain =
        \\An `@(...)` statement schedules work at instants, which only the
        \\analog block can do. LRM 4.7.2 keeps analog functions pure — see
        \\E0405.
        ,
    },
    .E0703 = .{
        .title = "nested event control statement",
        .lrm = "5.10",
        .explain =
        \\A.6.4 derives analog_event_statement with a plain statement body,
        \\so an event statement does not contain another one. Combine the
        \\conditions with `or` instead:
        \\
        \\    @(initial_step or cross(V(a) - 0.5, +1)) ...
        ,
    },
    .E0704 = .{
        .title = "posedge/negedge is digital-only",
        .lrm = "5.10.1",
        .explain =
        \\Edge events observe a discrete signal changing value. In an analog
        \\event control (§7.3.4) the operand must be a digital variable or
        \\net: one a discrete process or continuous assignment writes. The
        \\analog equivalent for a continuous signal is `cross`, which detects
        \\a continuous expression passing through zero in a stated direction:
        \\
        \\    @(cross(V(clk) - vth, +1)) ...    // rising
        ,
    },
    .E0705 = .{
        .title = "not a declared named event",
        .lrm = "5.10.4",
        .explain =
        \\`@ <identifier>` (A.6.5) and `-> <identifier>` (5.10.4) both name a
        \\hierarchical_event_identifier, and the only declaration that
        \\introduces one is A.2.1.3
        \\
        \\    event tick;
        \\
        \\A variable, net or parameter of the same name is not an event: 2.8
        \\gives an event a name but no value, so there is nothing for `@` to
        \\test on one. A misspelling lands here too.
        ,
    },
    .E0706 = .{
        .title = "unsupported event expression",
        .lrm = "5.10",
        .explain =
        \\The supported analog events are `initial_step`, `final_step`,
        \\`cross`, `above` and `timer`, combined with `or`.
        ,
    },
    .E0707 = .{
        .title = "event control statement under a runtime condition or in a loop",
        .lrm = "5.8",
        .explain =
        \\LRM 5.8: "Event control statements (e.g.: timer, cross) cannot be
        \\used inside conditional statements unless the conditional
        \\expression is a constant expression." LRM 5.9 bans them in
        \\`repeat`, `while` and non-genvar `for` outright, and LRM 5.10.3.1
        \\repeats it for `cross` specifically: "it shall not be used inside
        \\an if, case, casex, or casez statement unless the conditional
        \\expression is a genvar expression."
        \\
        \\A monitored event is not a test the residual performs — it is a
        \\detector the kernel advances once per accepted timestep, outside
        \\the Newton loop. Its `prev`/`hit` state therefore moves whether or
        \\not the branch that encloses it ran, so the detector's history and
        \\the code that reads it drift apart. Worse, the enclosing condition
        \\is evaluated inside the residual, where it is re-evaluated several
        \\times per step at different operating points.
        \\
        \\NOTE this is STRICTER than E0514: `if (analysis("dc"))` licenses
        \\an analog operator but NOT an event control statement, because
        \\LRM 5.8 asks for a constant expression here and 5.10.3.1 asks for
        \\a genvar expression.
        \\
        \\TO FIX: put the `@(...)` on the spine of the analog block and make
        \\the STATEMENT it guards do the conditional work —
        \\
        \\    @(cross(V(clk) - 0.5, +1))
        \\      if (en) held = V(in);
        \\
        \\`--deny=E0707` makes this the error the LRM says it is.
        ,
    },
    .E0708 = .{
        .title = "initial_step or final_step in the digital context",
        .lrm = "5.10",
        .explain =
        \\LRM 5.10: "The usage of initial_step and final_step analog events
        \\are not allowed in the digital context." The two events mark the
        \\first and last point of an analog analysis (5.10.2), which only the
        \\analog block runs at. An `initial` or `always` block has its own
        \\start: write `initial` for the first, or move the statement into
        \\the analog block:
        \\
        \\    always @(initial_step) r = 1.0;     // no
        \\    analog @(initial_step) r = 1.0;     // yes
        ,
    },
    // A monitored event under the fixed-grid testbench, which inserts no
    // timepoint at a crossing or timer.
    .W0750 = .{
        .title = "event fires on the testbench's fixed time grid, not at its own time",
        .lrm = "5.10.3",
        .explain =
        \\LRM 5.10.3.1 has cross() "control the timestep to accurately
        \\resolve the crossing", and 5.10.3.3 has timer() fire at its
        \\scheduled time. A host simulator does that by inserting a
        \\timepoint. The testbench `--run` and `--emit-exe` build for a
        \\model with no discrete half steps only the `//! time` points and
        \\inserts none, so a cross(), above() or timer() event whose time
        \\falls between two declared points fires at the next declared
        \\point, late by up to one grid step. It still fires once, in the
        \\step the crossing occurs in, and the event's statement sees the
        \\values at that point, not at the crossing.
        \\
        \\The device itself is unaffected: a host that places timepoints
        \\from its breakpoints (`nextBreakpoint`, `pendingBreakpoint`)
        \\resolves the event exactly.
        \\
        \\TO FIX: put a `//! time` point on (or just past) each event time
        \\the result depends on, or refine the grid until the lateness does
        \\not matter. `--allow=W0750` silences it.
        ,
    },
};
