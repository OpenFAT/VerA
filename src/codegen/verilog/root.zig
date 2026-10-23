//! Proven MIR in, a behavioural IEEE 1364-2005 module out (`vera
//! --emit-verilog`): the digital stand-in a gate-level or RTL simulation
//! uses for an analog macro, derived from the same `.va` the analog side is
//! verified against. Same module name, same port order.
//!
//! The abstraction. Every net the model drives (one with a contribution) is
//! one bit: high when its potential is above VDD/2. For every assignment of
//! the input pins and node bits, each pin or node at 0 or VDD, the analog
//! block is run once (an interpreter over the MIR whose arithmetic is
//! `opcode.fold`, the compiler's own constant kernel). A node's §5.6 KCL
//! residual S and §5.6.1.2 charge Q, read with its own potential at 0 and at
//! VDD, give the potential it settles to, F = -S(0)·VDD/(S(VDD)-S(0)), and
//! its time constant, tau = ΔQ/ΔS: exact for an RC, a secant for anything
//! else. The node's next value is F > VDD/2, reached tau·ln2 later (the 50 %
//! crossing of a rail-to-rail RC step) plus the `td` of every §4.5.8
//! `transition` / §4.5.7 `absdelay` the residual read through. A §5.6
//! `V(n) <+ F` contribution sets F directly.
//!
//! Each node becomes a truth table over the bits it depends on and a
//! `assign #(rise, fall)` (inertial, §6.1.3), so a pulse shorter than the
//! node's delay is swallowed as an RC would. An input that is x or z selects
//! no row and drives x.
//!
//! Pins (§2.9 attributes on a port declaration, `--digital-pins` wins):
//!   `(* vera_pin = "digital" *)`  logic: `input` if the model never drives it,
//!                                 else `output`
//!   `(* vera_pin = "analog" *)`   undriven `inout wire`; read as its logic level
//!   `(* vera_pin = "power" *)`    supply, VDD;  `(* vera_pin = "ground" *)`, 0 V
//! Undecorated: `vdd*`/`vcc*`/`vpwr`/`vpb`/`avdd`/`dvdd` are power,
//! `vss*`/`gnd*`/`vgnd`/`vnb`/`vee*`/`avss`/`dvss` ground, the rest analog.
//! `(* vera_delay = <seconds> *)` on a net's declaration replaces its derived
//! delay (both edges). On a port, both go on the direction declaration
//! (`inout`): a port's discipline declaration carries no attribute to it.
//! `--power-pins` moves the supply pins under `` `ifdef USE_POWER_PINS ``.
//!
//! Refused with a message, never emitted half-right: §5.10 events and held
//! variables, `I()` probes and `ddt`/`idt` outside a contribution (their
//! unknowns are not nets), arrays, vector ports, `$abstime` and any call with
//! no static value, more than `max_vars` pins plus nodes, and a node whose
//! derived delay is not finite (a NaN or infinite charge or `td`) and has no
//! `vera_delay`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Const = Lowered.Const;

/// What `emit` reads besides the model.
pub const Options = struct {
    /// `--digital-pins`: port names that are logic, whatever their attributes say.
    digital: []const []const u8 = &.{},
    /// `--power-pins`: declare the supply pins only under `ifdef USE_POWER_PINS`.
    power_pins: bool = false,
    /// The logic-high potential (V) a pin or node is evaluated at.
    vdd: f64 = 1.8,
    /// The `.va` path, for the header comment.
    source: []const u8 = "",
};

/// `Refused`: the model is outside the abstraction (the header lists what
/// is); `emit`'s `why` names the construct and its clause.
pub const Error = error{ OutOfMemory, Refused };

/// The largest pins-plus-nodes count the truth tables enumerate: `emit`
/// runs the analog block 2^n times and keeps three f64 per run and node.
const max_vars = 20;
comptime {
    // `run` shifts 1 by up to `max_vars` to count the assignments.
    assert(max_vars > 0);
    assert(max_vars < @bitSizeOf(usize));
}

const Pin = enum { digital, analog, power, ground };

/// A node's settled logic value; `x` when it settles at exactly VDD/2.
const Bit = enum { @"0", @"1", x };

/// Returns the module text, or `error.Refused` with `why.*` set to the reason.
/// Everything is allocated in `arena`.
pub fn emit(arena: Allocator, mir: *const Mir, lw: *const Lowered, o: Options, why: *[]const u8) Error![]const u8 {
    var e: Emitter = .{ .arena = arena, .mir = mir, .lw = lw, .o = o, .why = why };
    return e.run();
}

const Emitter = struct {
    arena: Allocator,
    mir: *const Mir,
    lw: *const Lowered,
    o: Options,
    why: *[]const u8,
    /// Each port's kind, set once `run` has classified them.
    pins: []const Pin = &.{},
    /// Which `nodes` rows a contribution drives.
    driven: []const bool = &.{},

    fn refuse(self: *Emitter, comptime fmt: []const u8, args: anytype) Error {
        self.why.* = try self.arena.print(fmt, args);
        return error.Refused;
    }

    fn run(self: *Emitter) Error![]const u8 {
        const lw = self.lw;
        const n_nodes = lw.nodes.len;
        const names = lw.nodes.items(.name);
        const kinds = lw.nodes.items(.kind);

        if (lw.held_vars.items.len != 0) return self.refuse("`{s}` holds state across evaluations (§5.10 event or held variable); --emit-verilog abstracts only continuous models", .{lw.held_vars.items[0].name});
        if (lw.vectors.count() != 0) return self.refuse("vector nets are not supported; declare the bits as scalar ports", .{});
        if (lw.num_ports == 0) return self.refuse("module `{s}` has no ports", .{self.mir.name});

        // Attributes on declarations, by declared name.
        var pin_attr: std.StringHashMapUnmanaged([]const u8) = .empty;
        var delay_attr: std.StringHashMapUnmanaged(f64) = .empty;
        for (lw.decl_attrs) |s| {
            const span = lw.tokenSpan(s.tok);
            const decl = lw.src[span.start..span.end];
            const an = s.name;
            const v: ?Const = s.value;
            if (std.mem.eql(u8, an, "vera_pin")) {
                if (v == null or v.? != .str) return self.refuse("`{s}`: vera_pin takes \"digital\", \"analog\", \"power\" or \"ground\"", .{decl});
                try pin_attr.put(self.arena, decl, v.?.str);
            } else if (std.mem.eql(u8, an, "vera_delay")) {
                const d = if (v) |c| c.asReal() else -1;
                // Finite in ns too: the module prints it in ns (`node`).
                if (v == null or v.? == .str or !(d >= 0) or !std.math.isFinite(d * 1e9)) return self.refuse("`{s}`: vera_delay takes a constant delay in seconds, >= 0", .{decl});
                try delay_attr.put(self.arena, decl, d);
            }
        }

        // Pin kinds, ports only.
        const pins = try self.arena.alloc(Pin, lw.num_ports);
        for (self.o.digital) |d| {
            for (names[0..lw.num_ports]) |n| {
                if (std.mem.eql(u8, n, d)) break;
            } else return self.refuse("--digital-pins: `{s}` is not a port of `{s}`", .{ d, self.mir.name });
        }
        for (pins, names[0..lw.num_ports]) |*p, n| {
            p.* = for (self.o.digital) |d| {
                if (std.mem.eql(u8, n, d)) break .digital;
            } else if (pin_attr.get(n)) |a|
                std.meta.stringToEnum(Pin, a) orelse return self.refuse("`{s}`: vera_pin = \"{s}\" is not digital, analog, power or ground", .{ n, a })
            else
                guessSupply(n) orelse .analog;
        }
        self.pins = pins;

        // Which rows a contribution drives, and the rail each supply sits at.
        const driven = try self.arena.alloc(bool, n_nodes);
        @memset(driven, false);
        const potential = try self.arena.alloc(?u32, n_nodes); // the `V(n) <+` contribution
        @memset(potential, null);
        for (lw.contributions.items, 0..) |c, ci| {
            if (c.kind != .direct) return self.refuse("§5.6.7 indirect branch assignments are not supported", .{});
            for ([_]u32{ c.hi, c.lo }) |r| {
                if (r == Lowered.ground) continue;
                if (kinds[r] != .net) return self.refuse("`{s}` is not a net (an I() probe, or ddt/idt outside a contribution)", .{names[r]});
            }
            if (c.access == .potential) {
                // §5.6.1.3: a row discarded on every path is no source; the
                // flow rows over its pair govern.
                const kept = staticRetention(self.mir, c.wrote_val) orelse true;
                if (!kept) continue;
                const hi_rail = c.hi == Lowered.ground or self.isSupply(c.hi);
                const lo_rail = c.lo == Lowered.ground or self.isSupply(c.lo);
                // A rail against a rail is the supply itself.
                if (hi_rail and lo_rail) continue;
                if (hi_rail) return self.refuse("`V({s}, {s}) <+`: a potential contribution drives its first node; write it as `V({s}, {s})` with the value negated", .{ lw.nodeName(c.hi), names[c.lo], names[c.lo], lw.nodeName(c.hi) });
                if (!lo_rail) return self.refuse("`V({s}, {s}) <+`: a potential contribution must be referred to a supply or ground", .{ names[c.hi], names[c.lo] });
                potential[c.hi] = @intCast(ci);
                driven[c.hi] = true;
            } else for ([_]u32{ c.hi, c.lo }) |r| {
                if (r != Lowered.ground and !self.isSupply(r)) driven[r] = true;
            }
        }

        self.driven = driven;

        // The variables: undriven signal ports (inputs), then driven nets (states).
        var vars: std.ArrayList(u32) = .empty;
        for (0..lw.num_ports) |r| if (!driven[r] and !self.isSupply(@intCast(r))) try vars.append(self.arena, @intCast(r));
        const n_inputs = vars.items.len;
        for (0..n_nodes) |r| if (driven[r]) try vars.append(self.arena, @intCast(r));
        const nv = vars.items.len;
        if (nv > max_vars) return self.refuse("{d} pins and driven nodes; the truth tables stop at {d}", .{ nv, max_vars });
        const states = vars.items[n_inputs..];
        assert(n_inputs <= nv);
        assert(states.len == nv - n_inputs);

        // One analog evaluation per assignment: each state's residual, charge,
        // transition delay and, for a potential-driven node, its target.
        const n_masks = @as(usize, 1) << @intCast(nv);
        const S = try self.arena.alloc(f64, n_masks * states.len);
        const Q = try self.arena.alloc(f64, n_masks * states.len);
        const TD = try self.arena.alloc(f64, n_masks * states.len);
        // Whether the node's potential row is retained (§5.6.1.3) in that run:
        // then S is its target, else the flow residual.
        const P = try self.arena.alloc(bool, n_masks * states.len);
        assert(n_masks <= @as(usize, 1) << max_vars);
        // Supplies sit at their rails and the variables are set per run;
        // every other row is NaN, which `Interp.get` refuses to read.
        const volts = try self.arena.alloc(f64, n_nodes);
        for (volts, 0..) |*v, r| v.* = if (r < lw.num_ports) switch (pins[r]) {
            .power => self.o.vdd,
            .ground => 0,
            .digital, .analog => std.math.nan(f64),
        } else std.math.nan(f64);
        var in: Interp = .{ .e = self, .volts = volts, .env = try self.arena.alloc(?Val, Mir.Value.first_dynamic + self.mir.defs.len) };
        for (0..n_masks) |m| {
            for (vars.items, 0..) |r, k| volts[r] = if (m >> @intCast(k) & 1 == 1) self.o.vdd else 0;
            try in.run();
            for (states, 0..) |r, si| {
                var s: f64 = 0;
                var q: f64 = 0;
                var td: f64 = 0;
                const pot = if (potential[r]) |ci| (try in.get(lw.contributions.items[ci].wrote_val)).c.isTrue() else false;
                if (pot) {
                    const c = lw.contributions.items[potential[r].?];
                    const f = try in.get(c.resist_val);
                    s = f.c.asReal() + if (c.lo == Lowered.ground) 0 else volts[c.lo];
                    td = f.d;
                } else for (lw.contributions.items) |c| {
                    if (c.access != .flow or (c.hi != r and c.lo != r)) continue;
                    const sign: f64 = if (c.hi == r) 1 else -1;
                    const rv = try in.get(c.resist_val);
                    const qv = try in.get(c.react_val);
                    s += sign * rv.c.asReal();
                    q += sign * qv.c.asReal();
                    td = later(td, later(rv.d, qv.d));
                }
                S[m * states.len + si] = s;
                Q[m * states.len + si] = q;
                TD[m * states.len + si] = td;
                P[m * states.len + si] = pot;
            }
        }

        // Per node: the target bit for each assignment, the rise/fall delays
        // and the variables the target depends on.
        const targets = try self.arena.alloc([]Bit, states.len);
        const rises = try self.arena.alloc(f64, states.len);
        const falls = try self.arena.alloc(f64, states.len);
        const supports = try self.arena.alloc([]const usize, states.len);
        const ln2 = @log(2.0);
        for (states, 0..) |r, si| {
            const bit = @as(usize, 1) << @intCast(n_inputs + si);
            const target = try self.arena.alloc(Bit, n_masks);
            const fixed = delay_attr.get(names[r]);
            var rise: f64 = 0;
            var fall: f64 = 0;
            for (0..n_masks) |m| {
                // This node's row in the run with its own bit as `m`, low, high.
                const at = m * states.len + si;
                const lo = (m & ~bit) * states.len + si;
                const hi = (m | bit) * states.len + si;
                var f: f64 = undefined;
                var tau: f64 = 0;
                if (P[at]) {
                    f = S[at];
                } else if (P[lo] or P[hi]) {
                    // The secant needs one constitutive law at both ends.
                    return self.refuse("node `{s}`: whether its potential contribution is retained (§5.6.1.3) depends on its own value", .{names[r]});
                } else {
                    const a = (S[hi] - S[lo]) / self.o.vdd;
                    if (!(a != 0) or !std.math.isFinite(a)) return self.refuse("node `{s}`: its current does not depend on its own potential, so it settles nowhere", .{names[r]});
                    f = -S[lo] / a;
                    tau = @abs((Q[hi] - Q[lo]) / self.o.vdd / a);
                }
                if (!std.math.isFinite(f)) return self.refuse("node `{s}`: its settled potential is not finite", .{names[r]});
                // Settling at VDD/2 (a comparator with equal inputs) is no logic level.
                target[m] = if (@abs(f - self.o.vdd / 2) <= 1e-9 * self.o.vdd) .x else if (f > self.o.vdd / 2) .@"1" else .@"0";
                const d = tau * ln2 + TD[at];
                // A NaN or infinite charge or td (a `--param c=inf`) has no
                // delay to print; a `vera_delay` replaces it, so is not asked.
                // Finite in ns, as `node` prints it.
                if (target[m] != .x and fixed == null and !std.math.isFinite(d * 1e9))
                    return self.refuse("node `{s}`: its delay is not finite (tau·ln2 + td = {d} s); give it a (* vera_delay *)", .{ names[r], d });
                switch (target[m]) {
                    .@"1" => rise = @max(rise, d),
                    .@"0" => fall = @max(fall, d),
                    .x => {},
                }
            }
            if (fixed) |d| {
                rise = d;
                fall = d;
            }
            var support: std.ArrayList(usize) = .empty;
            for (0..nv) |k| {
                const b = @as(usize, 1) << @intCast(k);
                for (0..n_masks) |m| if (target[m] != target[m ^ b]) {
                    try support.append(self.arena, k);
                    break;
                };
            }
            assert(support.items.len <= nv);
            targets[si] = target;
            rises[si] = rise;
            falls[si] = fall;
            supports[si] = support.items;
        }

        // Only what reaches a digital output is emitted: a driven analog
        // port or an internal net nothing logic reads is dead.
        const live = try self.arena.alloc(bool, states.len);
        for (live, states) |*l, r| l.* = r < lw.num_ports and pins[r] == .digital;
        var grew = true;
        var rounds: usize = 0;
        while (grew) : (rounds += 1) {
            // Each round that continues marks at least one more state live.
            assert(rounds <= states.len);
            grew = false;
            for (states, 0..) |_, si| if (live[si]) for (supports[si]) |k| if (k >= n_inputs and !live[k - n_inputs]) {
                live[k - n_inputs] = true;
                grew = true;
            };
        }
        var out: std.ArrayList(u8) = .empty;
        var body: std.ArrayList(u8) = .empty;
        for (states, 0..) |r, si| if (live[si])
            try self.node(&body, vars.items, targets[si], supports[si], r, rises[si], falls[si]);

        // Header and ports.
        const w = &out;
        const A = self.arena;
        try w.print(A, "// GENERATED BY VerA --emit-verilog from {s} - DO NOT EDIT.\n", .{self.o.source});
        try w.print(A,
            \\// Behavioural model of `{s}` for digital simulation: a driven net is high
            \\// above VDD/2 = {d} V; its switching delay is the model's own RC (tau*ln2) plus
            \\// any transition()/absdelay() td, or its (* vera_delay *). Analog pins are
            \\// undriven and read as their logic level.
            \\`timescale 1ns/1ps
            \\module {s} (
            \\
        , .{ self.mir.name, self.o.vdd / 2, self.mir.name });
        const first_signal = for (pins, 0..) |p, i| {
            if (!self.hidden(p)) break i;
        } else return self.refuse("every port is a supply; nothing to model", .{});
        assert(first_signal < pins.len);
        var in_ifdef = false;
        for (pins, names[0..lw.num_ports], 0..) |p, n, i| {
            try self.powerIfdef(w, p, &in_ifdef);
            if (i < first_signal) {
                try w.print(A, "    {f},\n", .{ident(n)});
            } else try w.print(A, "    {s}{f}\n", .{ if (i == first_signal) "  " else ", ", ident(n) });
        }
        if (in_ifdef) try w.appendSlice(A, "`endif\n");
        try w.appendSlice(A, ");\n");

        in_ifdef = false;
        for (pins, names[0..lw.num_ports], 0..) |p, n, i| {
            try self.powerIfdef(w, p, &in_ifdef);
            const dw: [2][]const u8 = switch (p) {
                .digital => if (driven[i]) .{ "output", "digital" } else .{ "input ", "digital" },
                .analog => .{ "inout ", "analog, undriven" },
                .power => .{ "inout ", "power" },
                .ground => .{ "inout ", "ground" },
            };
            try w.print(A, "    {s} wire {f}; // {s}\n", .{ dw[0], ident(n), dw[1] });
        }
        if (in_ifdef) try w.appendSlice(A, "`endif\n");

        // Internal nets: every driven row that is not a digital port.
        for (states, live) |r, l| if (l and !(r < lw.num_ports and pins[r] == .digital))
            try w.print(A, "    wire {f}; // {s}\n", .{ self.net(r), names[r] });
        try w.appendSlice(A, body.items);
        try w.appendSlice(A, "endmodule\n");
        return out.items;
    }

    /// Opens or closes `` `ifdef USE_POWER_PINS `` as the port list crosses
    /// from signal pins to hidden supply pins or back.
    fn powerIfdef(self: *const Emitter, w: *std.ArrayList(u8), p: Pin, in_ifdef: *bool) Error!void {
        const h = self.hidden(p);
        if (h == in_ifdef.*) return;
        try w.appendSlice(self.arena, if (h) "`ifdef USE_POWER_PINS\n" else "`endif\n");
        in_ifdef.* = h;
    }

    fn isSupply(self: *const Emitter, r: u32) bool {
        assert(self.pins.len == self.lw.num_ports);
        return r < self.lw.num_ports and (self.pins[r] == .power or self.pins[r] == .ground);
    }

    fn hidden(self: *const Emitter, p: Pin) bool {
        return self.o.power_pins and (p == .power or p == .ground);
    }

    /// The Verilog net that carries row `r`'s bit: a digital or an undriven
    /// port itself, else an internal `vera_n_*` (a driven analog port stays
    /// undriven outside).
    fn net(self: *const Emitter, r: u32) Name {
        assert(self.pins.len == self.lw.num_ports);
        assert(self.driven.len == self.lw.nodes.len);
        const n = self.lw.nodes.items(.name)[r];
        if (r < self.lw.num_ports and (self.pins[r] == .digital or !self.driven[r])) return ident(n);
        return .{ .prefix = "vera_n_", .text = n };
    }

    /// Emits row `r`'s target table and its delayed assignment.
    fn node(self: *Emitter, w: *std.ArrayList(u8), vars: []const u32, target: []const Bit, support: []const usize, r: u32, rise: f64, fall: f64) Error!void {
        // One target per assignment of every variable; the support is a
        // subset of the variables, in ascending order.
        assert(vars.len <= max_vars);
        assert(target.len == @as(usize, 1) << @intCast(vars.len));
        assert(support.len <= vars.len);
        for (support, 0..) |k, j| {
            assert(k < vars.len);
            if (j > 0) assert(k > support[j - 1]);
        }
        // `run` refused a delay with no finite ns value.
        assert(std.math.isFinite(rise * 1e9));
        assert(std.math.isFinite(fall * 1e9));
        const A = self.arena;
        const lw = self.lw;
        const name = lw.nodes.items(.name)[r];
        const t: Name = .{ .prefix = "vera_t_", .text = name };
        const rise_name: Name = .{ .prefix = "vera_rise_", .text = name };
        const fall_name: Name = .{ .prefix = "vera_fall_", .text = name };
        try w.print(A, "\n    // {s}\n", .{name});
        try w.print(A, "    parameter real {f} = {d:.6}; // ns\n", .{ rise_name, rise * 1e9 });
        try w.print(A, "    parameter real {f} = {d:.6}; // ns\n", .{ fall_name, fall * 1e9 });
        if (support.len == 0) {
            try w.print(A, "    wire {f} = 1'b{t};\n", .{ t, target[0] });
        } else {
            try w.print(A, "    reg {f};\n    always @* begin\n        case ({{", .{t});
            var k = support.len;
            while (k > 0) {
                k -= 1;
                try w.print(A, "{f}{s}", .{ self.net(vars[support[k]]), if (k == 0) "" else ", " });
            }
            try w.appendSlice(A, "})\n");
            for (0..@as(usize, 1) << @intCast(support.len)) |sub| {
                var m: usize = 0;
                for (support, 0..) |v, j| if (sub >> @intCast(j) & 1 == 1) {
                    m |= @as(usize, 1) << @intCast(v);
                };
                try w.print(A, "            {d}'b", .{support.len});
                var j = support.len;
                while (j > 0) {
                    j -= 1;
                    try w.append(A, if (sub >> @intCast(j) & 1 == 1) '1' else '0');
                }
                try w.print(A, ": {f} = 1'b{t};\n", .{ t, target[m] });
            }
            try w.print(A, "            default: {f} = 1'bx;\n        endcase\n    end\n", .{t});
        }
        try w.print(A, "    assign #({f}, {f}) {f} = {f};\n", .{ rise_name, fall_name, self.net(r), t });
    }
};

/// A Verilog name: `prefix` then `text`, or (no prefix) `text` itself, as one
/// legal identifier, escaped (§3.7.1) when it is not a simple one. Distinct
/// texts under one prefix are distinct names.
const Name = struct {
    prefix: ?[]const u8 = null,
    text: []const u8,

    /// Writes the name as an IEEE 1364-2005 §3.7 identifier.
    pub fn format(n: Name, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const plain = for (n.text) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) break false;
        } else true;
        if (n.prefix) |p| {
            assert(p.len > 0);
            // The prefix starts the identifier, so any text of identifier
            // bytes keeps it simple. Any other text escapes the whole name
            // rather than map its bytes onto `_`, which two texts could share.
            if (plain) return w.print("{s}{s}", .{ p, n.text });
            return w.print("\\{s}{s} ", .{ p, n.text });
        }
        if (plain and n.text.len != 0 and !std.ascii.isDigit(n.text[0]) and n.text[0] != '$') return w.writeAll(n.text);
        try w.print("\\{s} ", .{n.text});
    }
};

fn ident(text: []const u8) Name {
    return .{ .text = text };
}

/// The supply a port's name conventionally is, or null.
fn guessSupply(name: []const u8) ?Pin {
    for ([_][]const u8{ "vdd", "vcc", "vpwr", "vpb", "avdd", "dvdd" }) |p| if (std.ascii.startsWithIgnoreCase(name, p)) return .power;
    for ([_][]const u8{ "vss", "gnd", "vgnd", "vnb", "vee", "avss", "dvss" }) |p| if (std.ascii.startsWithIgnoreCase(name, p)) return .ground;
    return null;
}

// §5.6.1.3 a direct row's retention when it is the same on every path, or
// null when it is decided per evaluation (`codegen/plan/topology.zig`'s
// `retention`, read off the MIR alone).
fn staticRetention(mir: *const Mir, v: Mir.Value) ?bool {
    return switch (mir.valueDef(mir.resolveAlias(v))) {
        .float_const => |x| x != 0,
        .int_const => |x| x != 0,
        .undef, .str_const, .param_ref, .block_param, .inst_result => null,
    };
}

/// A MIR value under one assignment: the number, and the longest
/// `transition`/`absdelay` delay (s) on any path into it.
const Val = struct { c: Const, d: f64 = 0 };
comptime {
    // `Interp.env` holds one `?Val` per MIR value and is cleared every run:
    // a 24-byte `Const` (16-byte slice payload plus tag), the delay, the
    // optional's flag padded to 8.
    if (@sizeOf(usize) == 8) {
        assert(@sizeOf(Val) == 32);
        assert(@sizeOf(?Val) == 40);
    }
}

/// The later of two delays, NaN if either is: `@max` returns the other
/// operand of a NaN, which would drop a NaN `td` to 0 ns and print it (#47).
fn later(a: f64, b: f64) f64 {
    return if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else @max(a, b);
}

/// Runs the analog block once over `volts` (one potential per `nodes` row).
const Interp = struct {
    e: *Emitter,
    volts: []const f64,
    env: []?Val,
    // One block's phi results, read before any is written; reused.
    phis: std.ArrayList(struct { res: Mir.Value, v: Val }) = .empty,

    fn run(self: *Interp) Error!void {
        const mir = self.e.mir;
        // One slot per Value and one potential per `nodes` row.
        assert(self.env.len == Mir.Value.first_dynamic + mir.defs.len);
        assert(self.volts.len == self.e.lw.nodes.len);
        @memset(self.env, null);
        var block: Mir.Block = .entry;
        var prev: ?Mir.Block = null;
        var steps: usize = 0;
        while (true) {
            steps += 1;
            if (steps > 1 << 20) return self.e.refuse("the analog block did not finish (a loop over a node potential?)", .{});
            // Phis read the edge just taken, all at once (they are parallel),
            // wherever each sits in the chain (`ssa.zig` mints them anywhere):
            // every operand is read before any result is written.
            self.phis.clearRetainingCapacity();
            var it = mir.blockInsts(block);
            while (it.next()) |inst| {
                if (mir.instOp(inst) == .phi) try self.phis.append(self.e.arena, .{ .res = mir.instResult(inst), .v = try self.phi(inst, prev) });
            }
            for (self.phis.items) |p| {
                if (p.res != .undef) self.env[@backingInt(p.res)] = p.v;
            }
            // Then every other row in chain order, and the terminator last:
            // `Mir` allows rows after it, which codegen emits before it.
            var term: ?Mir.Inst = null;
            it = mir.blockInsts(block);
            while (it.next()) |inst| {
                const v: Val = switch (mir.instData(inst)) {
                    // §5.6.1.2 `A*ddt(B)` is charged as path_acc + A·(B - path_prev(B)):
                    // with both latches at 0 the charge is A·B, whose secant is A·ΔB.
                    .unary => |u| if (u.op == .path_prev or u.op == .path_acc) .{ .c = .{ .real = 0 } } else try self.op(u.op, &.{u.operand}),
                    .binary => |b| try self.op(b.op, &.{ b.lhs, b.rhs }),
                    .ternary => |t| try self.get(if ((try self.get(t.cond)).c.isTrue()) t.then_val else t.else_val),
                    .phi => continue,
                    .branch, .jump => {
                        term = inst;
                        continue;
                    },
                    .call => |c| try self.call(c.callee, c.name, c.args),
                    .anew, .load, .store => return self.e.refuse("§3.2.2 runtime-indexed arrays are not supported", .{}),
                };
                const res = mir.instResult(inst);
                if (res != .undef) self.env[@backingInt(res)] = v;
            }
            const last = term orelse return;
            prev = block;
            block = switch (mir.instData(last)) {
                .branch => |b| if ((try self.get(b.cond)).c.isTrue()) b.then_block else b.else_block,
                .jump => |j| j.target,
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => unreachable,
            };
        }
    }

    // The value phi `inst` takes on the edge from `prev`.
    fn phi(self: *Interp, inst: Mir.Inst, prev: ?Mir.Block) Error!Val {
        const mir = self.e.mir;
        const from = prev orelse return self.e.refuse("a phi with no operand for the edge taken", .{});
        for (0..mir.instData(inst).phi.count) |i| {
            const pair = mir.phiPair(inst, @intCast(i));
            if (pair.block == from) return self.get(pair.value);
        }
        return self.e.refuse("a phi with no operand for the edge taken", .{});
    }

    fn get(self: *Interp, value: Mir.Value) Error!Val {
        const mir = self.e.mir;
        const v = mir.resolveAlias(value);
        return switch (mir.valueDef(v)) {
            .float_const => |x| .{ .c = .{ .real = x } },
            .int_const => |x| .{ .c = .{ .int = x } },
            .str_const => |s| .{ .c = .{ .str = s } },
            .param_ref => |p| blk: {
                const info = self.e.lw.params.items[p];
                if (info.folded) |c| break :blk .{ .c = c };
                break :blk self.get(info.default);
            },
            .block_param => |u| blk: {
                assert(u < self.volts.len);
                const x = self.volts[u];
                if (std.math.isNan(x)) return self.e.refuse("`{s}` is read but is neither a pin nor a driven net", .{self.e.lw.nodes.items(.name)[u]});
                break :blk .{ .c = .{ .real = x } };
            },
            .inst_result => self.env[@backingInt(v)] orelse self.e.refuse("a value read before its block ran", .{}),
            .undef => self.e.refuse("an undefined value", .{}),
        };
    }

    fn op(self: *Interp, o: Mir.Opcode, operands: []const Mir.Value) Error!Val {
        var cs: [2]Const = undefined;
        // `run` passes a unary's or a binary's operands.
        assert(operands.len > 0);
        assert(operands.len <= cs.len);
        var d: f64 = 0;
        for (operands, 0..) |x, i| {
            const v = try self.get(x);
            cs[i] = v.c;
            d = later(d, v.d);
        }
        const c = Mir.opcode.fold(o, cs[0..operands.len]) orelse
            return self.e.refuse("`{s}` has no value here", .{Mir.opcode.label(o)});
        return .{ .c = c, .d = d };
    }

    fn call(self: *Interp, callee: Mir.Callee, name: []const u8, args: []const Mir.Value) Error!Val {
        return switch (callee) {
            // §4.5.8/§4.5.7: the settled value, `td` later.
            .transition, .absdelay, .@"absdelay$quad" => blk: {
                assert(args.len > 0);
                const x = try self.get(args[0]);
                const td = if (args.len > 1) (try self.get(args[1])).c.asReal() else 0;
                // A NaN td stays NaN (`@max` would drop it to 0) so `run`
                // refuses it; `later` carries it through every operator.
                break :blk .{ .c = x.c, .d = x.d + if (std.math.isNan(td)) td else @max(td, 0) };
            },
            // §4.5.9: the settled value; a slew's time depends on the swing.
            .slew => blk: {
                assert(args.len > 0);
                break :blk self.get(args[0]);
            },
            .limexp => blk: {
                assert(args.len > 0);
                const x = try self.get(args[0]);
                break :blk .{ .c = .{ .real = @exp(x.c.asReal()) }, .d = x.d };
            },
            // A transient's point, not its DC solve.
            .@"op$static" => .{ .c = .{ .int = 0 } },
            .@"$mfactor" => .{ .c = .{ .real = 1 } },
            .@"$temperature" => .{ .c = .{ .real = 300.15 } },
            .@"$vt" => blk: {
                const t = if (args.len > 0) (try self.get(args[0])).c.asReal() else 300.15;
                break :blk .{ .c = .{ .real = 1.380649e-23 * t / 1.602176634e-19 } };
            },
            // Every other callee is time-dependent, an event, a noise or host
            // query, or a task: none has one static value per assignment.
            else => self.e.refuse("`{s}` has no static value; --emit-verilog cannot abstract it", .{name}), // else: a new callee is refused until it is given a static value here
        };
    }
};

// ---- tests ------------------------------------------------------------------
// Each model is a hand-built MIR (`Fixture`), so the test states the residual
// it hands `emit`. The expected values follow from the header's formulas:
// F = -S(0)·VDD/(S(VDD)-S(0)), tau = ΔQ/ΔS, delay = tau·ln2 + td.

const Fixture = @import("prove").Fixture;

/// Pins `a`, `y`, `vdd`, `vss`, in that order, all ports.
const four = [_][]const u8{ "a", "y", "vdd", "vss" };
const logic: Options = .{ .digital = &.{ "a", "y" }, .source = "buf.va" };

/// Appends the unconditional direct contribution `I(hi, lo) <+ resist +
/// ddt(react)`.
fn addFlow(f: *Fixture, hi: u32, lo: u32, resist: Mir.Value, react: Mir.Value) !void {
    try f.lowered.contributions.append(f.alloc(), .{ .access = .flow, .hi = hi, .lo = lo, .resist_val = resist, .react_val = react, .wrote_val = .f_one });
}

/// Builds `four` with `I(y, vss) <+ V(y) - V(a)`: y settles at V(a).
fn buffer(f: *Fixture) !void {
    try f.init(&four);
    f.lowered.num_ports = 4;
    const r = try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), try f.probe(0) });
    try addFlow(f, 1, 3, r, .f_zero);
}

/// Runs `emit`, printing the refusal if there is one.
fn emitOk(f: *Fixture, o: Options) ![]const u8 {
    var why: []const u8 = "";
    return emit(f.alloc(), &f.mir, &f.lowered, o, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
}

/// Fails unless `emit` refuses with a reason holding `part`.
fn expectRefused(f: *Fixture, o: Options, part: []const u8) !void {
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, emit(f.alloc(), &f.mir, &f.lowered, o, &why));
    if (std.mem.find(u8, why, part) == null) {
        std.debug.print("refused: {s}\nexpected: {s}\n", .{ why, part });
        return error.TestUnexpectedResult;
    }
}

test "emit: a buffer is a one-input truth table with no delay" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    // S(V(y)) = V(y) - V(a), so F = V(a): y copies a. No charge and no
    // transition, so both delays are 0.
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA --emit-verilog from buf.va - DO NOT EDIT.
        \\// Behavioural model of `mymod` for digital simulation: a driven net is high
        \\// above VDD/2 = 0.9 V; its switching delay is the model's own RC (tau*ln2) plus
        \\// any transition()/absdelay() td, or its (* vera_delay *). Analog pins are
        \\// undriven and read as their logic level.
        \\`timescale 1ns/1ps
        \\module mymod (
        \\      a
        \\    , y
        \\    , vdd
        \\    , vss
        \\);
        \\    input  wire a; // digital
        \\    output wire y; // digital
        \\    inout  wire vdd; // power
        \\    inout  wire vss; // ground
        \\
        \\    // y
        \\    parameter real vera_rise_y = 0.000000; // ns
        \\    parameter real vera_fall_y = 0.000000; // ns
        \\    reg vera_t_y;
        \\    always @* begin
        \\        case ({a})
        \\            1'b0: vera_t_y = 1'b0;
        \\            1'b1: vera_t_y = 1'b1;
        \\            default: vera_t_y = 1'bx;
        \\        endcase
        \\    end
        \\    assign #(vera_rise_y, vera_fall_y) y = vera_t_y;
        \\endmodule
        \\
    , try emitOk(&f, logic));
}

test "emit: an RC's delay is tau·ln2, a transition's is its td" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    // I(y) <+ (V(y) - V(a))/1k + ddt(1p·V(y)): tau = R·C = 1 ns, so the 50 %
    // crossing is ln2 ns = 0.693147 ns on both edges.
    const vy = try f.probe(1);
    const diff = try f.mir.emit(a, .entry, .fsub, &.{ vy, try f.probe(0) });
    const i_r = try f.mir.emit(a, .entry, .fdiv, &.{ diff, try f.mir.addFloatConst(a, 1000) });
    const q = try f.mir.emit(a, .entry, .fmul, &.{ try f.mir.addFloatConst(a, 1e-12), vy });
    try addFlow(&f, 1, 3, i_r, q);
    const rc = try emitOk(&f, logic);
    try std.testing.expect(std.mem.find(u8, rc, "parameter real vera_rise_y = 0.693147; // ns\n") != null);
    try std.testing.expect(std.mem.find(u8, rc, "parameter real vera_fall_y = 0.693147; // ns\n") != null);

    // I(y) <+ V(y) - transition(V(a), 2n): no charge, td = 2 ns.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&four);
    g.lowered.num_ports = 4;
    const b = g.alloc();
    const tr = try g.call("transition", &.{ try g.probe(0), try g.mir.addFloatConst(b, 2e-9) });
    try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), tr }), .f_zero);
    const td = try emitOk(&g, logic);
    try std.testing.expect(std.mem.find(u8, td, "parameter real vera_rise_y = 2.000000; // ns\n") != null);
    try std.testing.expect(std.mem.find(u8, td, "parameter real vera_fall_y = 2.000000; // ns\n") != null);
}

test "emit: a non-finite charge or td is refused by node, not printed (#47)" {
    // The RC above with C = inf: Q(V(y) = 0) = inf·0 = NaN, so tau is NaN.
    // Before #47 `@max` dropped the NaN delay and printed 0 ns.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    const vy = try f.probe(1);
    const diff = try f.mir.emit(a, .entry, .fsub, &.{ vy, try f.probe(0) });
    const i_r = try f.mir.emit(a, .entry, .fdiv, &.{ diff, try f.mir.addFloatConst(a, 1000) });
    const q = try f.mir.emit(a, .entry, .fmul, &.{ try f.mir.addFloatConst(a, std.math.inf(f64)), vy });
    try addFlow(&f, 1, 3, i_r, q);
    try expectRefused(&f, logic, "node `y`: its delay is not finite");

    // `transition(V(a), td)` with td = inf (printed `inf` before #47) and
    // td = NaN (dropped to 0 before #47).
    for ([_]f64{ std.math.inf(f64), std.math.nan(f64) }) |td| {
        var g: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer g.deinit();
        try g.init(&four);
        g.lowered.num_ports = 4;
        const b = g.alloc();
        const tr = try g.call("transition", &.{ try g.probe(0), try g.mir.addFloatConst(b, td) });
        try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), tr }), .f_zero);
        try expectRefused(&g, logic, "node `y`: its delay is not finite");
    }
    // The legal neighbours are the finite RC and td of the test above.
}

test "emit: a node settling at exactly VDD/2 is x, and a constant needs no table" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    // I(y) <+ V(y) - 0.9: F = 0.9 = VDD/2 whatever a is.
    const r = try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), try f.mir.addFloatConst(f.alloc(), 0.9) });
    try addFlow(&f, 1, 3, r, .f_zero);
    const text = try emitOk(&f, logic);
    try std.testing.expect(std.mem.find(u8, text, "    wire vera_t_y = 1'bx;\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "case") == null);
}

test "emit: --power-pins puts every supply under USE_POWER_PINS, before and after the signals" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&.{ "vdd", "a", "y", "vss" });
    f.lowered.num_ports = 4;
    const r = try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(2), try f.probe(1) });
    try addFlow(&f, 2, 3, r, .f_zero);
    var o = logic;
    o.power_pins = true;
    const text = try emitOk(&f, o);
    // A leading supply carries its own comma inside the `ifdef`; a trailing
    // one, its leading comma.
    const ports =
        \\module mymod (
        \\`ifdef USE_POWER_PINS
        \\    vdd,
        \\`endif
        \\      a
        \\    , y
        \\`ifdef USE_POWER_PINS
        \\    , vss
        \\`endif
        \\);
        \\`ifdef USE_POWER_PINS
        \\    inout  wire vdd; // power
        \\`endif
        \\    input  wire a; // digital
        \\    output wire y; // digital
        \\`ifdef USE_POWER_PINS
        \\    inout  wire vss; // ground
        \\`endif
        \\
    ;
    try std.testing.expect(std.mem.find(u8, text, ports) != null);
}

test "emit: an internal net is declared only when a digital output reads it" {
    const five = [_][]const u8{ "a", "y", "vdd", "vss", "n" };
    // Live: y follows n, n follows a.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&five);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    try addFlow(&f, 1, 3, try f.mir.emit(a, .entry, .fsub, &.{ try f.probe(1), try f.probe(4) }), .f_zero);
    try addFlow(&f, 4, 3, try f.mir.emit(a, .entry, .fsub, &.{ try f.probe(4), try f.probe(0) }), .f_zero);
    const live = try emitOk(&f, logic);
    try std.testing.expect(std.mem.find(u8, live, "    wire vera_n_n; // n\n") != null);
    try std.testing.expect(std.mem.find(u8, live, "        case ({vera_n_n})\n") != null);
    try std.testing.expect(std.mem.find(u8, live, "    assign #(vera_rise_n, vera_fall_n) vera_n_n = vera_t_n;\n") != null);

    // Dead: y follows a, and nothing reads n.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&five);
    g.lowered.num_ports = 4;
    const b = g.alloc();
    try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), try g.probe(0) }), .f_zero);
    try addFlow(&g, 4, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(4), try g.probe(0) }), .f_zero);
    const dead = try emitOk(&g, logic);
    try std.testing.expect(std.mem.find(u8, dead, "vera_n_n") == null);
    try std.testing.expect(std.mem.find(u8, dead, "// n\n") == null);
}

test "emit refuses what it cannot abstract, naming it" {
    const gpa = std.testing.allocator;
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&.{"y"});
        try expectRefused(&f, .{}, "has no ports");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        try f.lowered.held_vars.append(f.alloc(), .{ .name = "q", .ty = .real, .init = .f_zero, .seed = .f_zero });
        try expectRefused(&f, logic, "`q` holds state");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        try f.lowered.vectors.put(f.alloc(), "bus", .{ .msb = 1, .lsb = 0 });
        try expectRefused(&f, logic, "vector nets");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        try expectRefused(&f, .{ .digital = &.{"nope"} }, "`nope` is not a port");
    }
    {
        // §5.6.7 indirect assignment.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        f.lowered.contributions.items[0].kind = .indirect;
        try expectRefused(&f, logic, "indirect");
    }
    {
        // V(y, a) <+ 0: referred to a signal, not a rail.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 1, .lo = 0, .wrote_val = .f_one });
        try expectRefused(&f, logic, "must be referred to a supply or ground");
    }
    {
        // V(vdd, y) <+ 0.2 drives y (V(y) = VDD - 0.2), but from its second
        // node: refused rather than silently left undriven.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 2, .lo = 1, .resist_val = try f.mir.addFloatConst(f.alloc(), 0.2), .wrote_val = .f_one });
        try expectRefused(&f, logic, "drives its first node");
    }
    {
        // Every assignment enumerated: 21 undriven ports are 2^21 runs.
        const many = comptime blk: {
            var n: [max_vars + 1][]const u8 = undefined;
            for (&n, 0..) |*s, i| s.* = std.fmt.comptimePrint("p{d}", .{i});
            break :blk n;
        };
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&many);
        f.lowered.num_ports = many.len;
        try expectRefused(&f, .{}, "21 pins and driven nodes; the truth tables stop at 20");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&.{ "vdd", "vss" });
        f.lowered.num_ports = 2;
        try expectRefused(&f, .{ .power_pins = true }, "every port is a supply");
    }
    {
        // I(y) <+ V(a): y's current does not move with V(y).
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try addFlow(&f, 1, 3, try f.probe(0), .f_zero);
        try expectRefused(&f, logic, "settles nowhere");
    }
    {
        // `$abstime` moves with time: no one value per assignment.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        const t = try f.call("$abstime", &.{});
        try addFlow(&f, 1, 3, try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), t }), .f_zero);
        try expectRefused(&f, logic, "`$abstime` has no static value");
    }
    {
        // An internal net nothing drives has no potential to read.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&.{ "a", "y", "vdd", "vss", "n" });
        f.lowered.num_ports = 4;
        try addFlow(&f, 1, 3, try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), try f.probe(4) }), .f_zero);
        try expectRefused(&f, logic, "`n` is read but is neither a pin nor a driven net");
    }
}

test guessSupply {
    for ([_][]const u8{ "vdd", "VDD", "vdda", "vcc", "vpwr", "vpb", "avdd", "dvdd" }) |n|
        try std.testing.expectEqual(@as(?Pin, .power), guessSupply(n));
    for ([_][]const u8{ "vss", "gnd", "GND", "vgnd", "vnb", "vee", "avss", "dvss" }) |n|
        try std.testing.expectEqual(@as(?Pin, .ground), guessSupply(n));
    for ([_][]const u8{ "", "a", "vd", "out_vdd" }) |n|
        try std.testing.expectEqual(@as(?Pin, null), guessSupply(n));
    // The header's rule is `vdd*`, whatever the length: 17 bytes is still a
    // supply.
    try std.testing.expectEqual(@as(?Pin, .power), guessSupply("vdd_core_supply_1"));
    try std.testing.expectEqual(@as(?Pin, .ground), guessSupply("gnd_of_the_analog_core"));
}

test Name {
    // A simple identifier (IEEE 1364-2005 §3.7) is written as is, `$` inside
    // included; anything else is escaped: `\`, the text, a space (§3.7.1).
    try std.testing.expectFmt("a$b", "{f}", .{ident("a$b")});
    try std.testing.expectFmt("\\1a ", "{f}", .{ident("1a")});
    try std.testing.expectFmt("\\$a ", "{f}", .{ident("$a")});
    try std.testing.expectFmt("\\a.b ", "{f}", .{ident("a.b")});
    // A prefixed name keeps a simple text as it is ...
    try std.testing.expectFmt("vera_n_a_b", "{f}", .{Name{ .prefix = "vera_n_", .text = "a_b" }});
    // ... and two texts never meet in one name: `a.b` is not `a_b`.
    try std.testing.expectFmt("\\vera_n_a.b ", "{f}", .{Name{ .prefix = "vera_n_", .text = "a.b" }});
    try std.testing.expectFmt("vera_n_a$b", "{f}", .{Name{ .prefix = "vera_n_", .text = "a$b" }});
}

test "emit: a potential row §5.6.1.3 discards on every path leaves the flow in charge" {
    // Metamorphic: the buffer plus a `V(y, vss)` row whose retention folded
    // to 0 (its accumulators to 0 with it) is the buffer.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&four);
    g.lowered.num_ports = 4;
    try g.lowered.contributions.append(g.alloc(), .{ .access = .potential, .hi = 1, .lo = 3, .wrote_val = .f_zero });
    try addFlow(&g, 1, 3, try g.mir.emit(g.alloc(), .entry, .fsub, &.{ try g.probe(1), try g.probe(0) }), .f_zero);
    try std.testing.expectEqualStrings(want, try emitOk(&g, logic));
}

test "emit: a §5.6.5 switch branch follows whichever quantity this assignment retains" {
    // if (V(a) > 0.9) V(y) <+ 1.8; else I(y) <+ V(y);
    // a = 1: the potential holds y at 1.8; a = 0: the flow I = V(y) settles
    // it at 0. Either way y copies a with no delay: the buffer's text.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&four);
    g.lowered.num_ports = 4;
    const b = g.alloc();
    const on = try g.mir.emit(b, .entry, .fgt, &.{ try g.probe(0), try g.mir.addFloatConst(b, 0.9) });
    try g.lowered.contributions.append(b, .{ .access = .potential, .hi = 1, .lo = 3, .resist_val = try g.mir.addFloatConst(b, 1.8), .wrote_val = on });
    try addFlow(&g, 1, 3, try g.probe(1), .f_zero);
    try std.testing.expectEqualStrings(want, try emitOk(&g, logic));
}

test "emit: phis read the edge taken all at once" {
    // p, q = 0, 1; for (i = 0; i < 1; i++) p, q = q, p;  then I(y) <+ V(y) - 1.8·q.
    // One swap leaves q = 0, so y settles at 0. Reading q's operand after p
    // was overwritten would give q = 1 and y = 1.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    const m = &f.mir;
    const header = try m.addBlock(a);
    const body = try m.addBlock(a);
    const exit = try m.addBlock(a);
    _ = try m.emitJump(a, .entry, header);
    const p = try m.emitPhi(a, header, &.{});
    const p_inst = m.blockLast(header);
    const q = try m.emitPhi(a, header, &.{});
    const q_inst = m.blockLast(header);
    const i = try m.emitPhi(a, header, &.{});
    const i_inst = m.blockLast(header);
    const go = try m.emit(a, header, .flt, &.{ i, .f_one });
    _ = try m.emitBranch(a, header, go, body, exit);
    const i_next = try m.emit(a, body, .fadd, &.{ i, .f_one });
    _ = try m.emitJump(a, body, header);
    try m.setPhiPairs(a, p_inst, &.{ .{ .block = .entry, .value = .f_zero }, .{ .block = body, .value = q } });
    try m.setPhiPairs(a, q_inst, &.{ .{ .block = .entry, .value = .f_one }, .{ .block = body, .value = p } });
    try m.setPhiPairs(a, i_inst, &.{ .{ .block = .entry, .value = .f_zero }, .{ .block = body, .value = i_next } });
    const scaled = try m.emit(a, exit, .fmul, &.{ try m.addFloatConst(a, 1.8), q });
    try addFlow(&f, 1, 3, try m.emit(a, exit, .fsub, &.{ try f.probe(1), scaled }), .f_zero);

    try std.testing.expect(std.mem.find(u8, try emitOk(&f, logic), "    wire vera_t_y = 1'b0;\n") != null);
}

test "emit: a row placed after its block's terminator still runs, before it" {
    // `Mir` allows rows after a branch (`lower_var.hiddenHeldInt`); codegen
    // runs them before the terminator, and so must the interpreter.
    // x = 1 + 1 sits after entry's jump; I(y) <+ V(y) - 0.9·x settles at 1.8.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    const m = &f.mir;
    const next = try m.addBlock(a);
    _ = try m.emitJump(a, .entry, next);
    const x = try m.emit(a, .entry, .fadd, &.{ .f_one, .f_one });
    const scaled = try m.emit(a, next, .fmul, &.{ try m.addFloatConst(a, 0.9), x });
    try addFlow(&f, 1, 3, try m.emit(a, next, .fsub, &.{ try f.probe(1), scaled }), .f_zero);

    try std.testing.expect(std.mem.find(u8, try emitOk(&f, logic), "    wire vera_t_y = 1'b1;\n") != null);
}

test "emit refuses a vera_pin or vera_delay whose value is not one" {
    // Only the attribute's value is judged here; `attrs.va` in
    // test-external runs the accepted ones by name.
    const bad = [_]struct { name: []const u8, value: ?Const, says: []const u8 }{
        .{ .name = "vera_pin", .value = null, .says = "vera_pin takes" },
        .{ .name = "vera_pin", .value = .{ .real = 1 }, .says = "vera_pin takes" },
        .{ .name = "vera_delay", .value = null, .says = "vera_delay takes" },
        .{ .name = "vera_delay", .value = .{ .str = "1n" }, .says = "vera_delay takes" },
        .{ .name = "vera_delay", .value = .{ .real = -1e-9 }, .says = "vera_delay takes" },
        .{ .name = "vera_delay", .value = .{ .real = std.math.nan(f64) }, .says = "vera_delay takes" },
        // Finite in seconds, infinite in the ns `node` prints.
        .{ .name = "vera_delay", .value = .{ .real = 1e300 }, .says = "vera_delay takes" },
    };
    for (bad) |b| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try buffer(&f);
        const attrs = [_]Lowered.DeclAttr{.{ .tok = 0, .name = b.name, .value = b.value }};
        f.lowered.decl_attrs = &attrs;
        try expectRefused(&f, logic, b.says);
    }
    // The neighbours that pass: a zero delay, and an attribute VerA ignores.
    for ([_]Lowered.DeclAttr{ .{ .tok = 0, .name = "vera_delay", .value = .{ .int = 0 } }, .{ .tok = 0, .name = "other", .value = null } }) |ok| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try buffer(&f);
        f.lowered.decl_attrs = &.{ok};
        _ = try emitOk(&f, logic);
    }
}

test "emit: a driven analog port stays an undriven inout, its bit an internal net" {
    // `a` analog; y digital follows it, and I(a) <+ V(a) - V(vdd) drives a high.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const m = f.alloc();
    try addFlow(&f, 0, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(0), try f.probe(2) }), .f_zero);
    try addFlow(&f, 1, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(1), try f.probe(0) }), .f_zero);
    const text = try emitOk(&f, .{ .digital = &.{"y"} });
    for ([_][]const u8{
        "    inout  wire a; // analog, undriven\n",
        "    wire vera_n_a; // a\n",
        "    wire vera_t_a = 1'b1;\n",
        "        case ({vera_n_a})\n",
        "    assign #(vera_rise_a, vera_fall_a) vera_n_a = vera_t_a;\n",
    }) |want| try std.testing.expect(std.mem.find(u8, text, want) != null);
}

test "emit: a supply contribution against a supply is the supply itself" {
    // Metamorphic: the buffer plus V(vdd, vss) <+ 1.8 is the buffer.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);
    try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 2, .lo = 3, .resist_val = try f.mir.addFloatConst(f.alloc(), 1.8), .wrote_val = .f_one });
    try std.testing.expectEqualStrings(want, try emitOk(&f, logic));
}

test "emit: the static callees fold to the values the header gives them" {
    // I(y) <+ V(y) - k·V(a) with k a callee that is 1 here: the buffer's text.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);
    for ([_][]const u8{ "$mfactor", "limexp", "slew" }) |name| {
        var g: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer g.deinit();
        try g.init(&four);
        g.lowered.num_ports = 4;
        const b = g.alloc();
        // limexp(0) = 1, slew(1) = 1.
        const arg: []const Mir.Value = if (std.mem.eql(u8, name, "limexp")) &.{.f_zero} else if (std.mem.eql(u8, name, "slew")) &.{.f_one} else &.{};
        const k = try g.call(name, arg);
        const scaled = try g.mir.emit(b, .entry, .fmul, &.{ k, try g.probe(0) });
        try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), scaled }), .f_zero);
        try std.testing.expectEqualStrings(want, try emitOk(&g, logic));
    }
    // Over a 2 ns transition: absdelay's td adds like transition's, a
    // negative td adds 0 (not -1 ns), and no td argument adds nothing.
    for ([_]struct { name: []const u8, td: ?f64, ns: []const u8 }{
        .{ .name = "absdelay", .td = 2e-9, .ns = "4.000000" },
        .{ .name = "transition", .td = -1e-9, .ns = "2.000000" },
        .{ .name = "transition", .td = null, .ns = "2.000000" },
    }) |c| {
        var g: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer g.deinit();
        try g.init(&four);
        g.lowered.num_ports = 4;
        const b = g.alloc();
        const x = try g.call("transition", &.{ try g.probe(0), try g.mir.addFloatConst(b, 2e-9) });
        const tr = if (c.td) |td| try g.call(c.name, &.{ x, try g.mir.addFloatConst(b, td) }) else try g.call(c.name, &.{x});
        try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), tr }), .f_zero);
        const text = try emitOk(&g, logic);
        const line = try std.fmt.allocPrint(b, "parameter real vera_rise_y = {s}; // ns\n", .{c.ns});
        try std.testing.expect(std.mem.find(u8, text, line) != null);
    }
}

test "emit refuses a node whose law or value it cannot pin down" {
    const gpa = std.testing.allocator;
    {
        // if (V(y) > 0.9) V(y) <+ 1.8; else I(y) <+ V(y): which law holds
        // depends on y itself, so there is no one secant.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        const b = f.alloc();
        const on = try f.mir.emit(b, .entry, .fgt, &.{ try f.probe(1), try f.mir.addFloatConst(b, 0.9) });
        try f.lowered.contributions.append(b, .{ .access = .potential, .hi = 1, .lo = 3, .resist_val = try f.mir.addFloatConst(b, 1.8), .wrote_val = on });
        try addFlow(&f, 1, 3, try f.probe(1), .f_zero);
        try expectRefused(&f, logic, "depends on its own value");
    }
    {
        // V(y, vss) <+ inf.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 1, .lo = 3, .resist_val = try f.mir.addFloatConst(f.alloc(), std.math.inf(f64)), .wrote_val = .f_one });
        try expectRefused(&f, logic, "its settled potential is not finite");
    }
    {
        // A phi in the entry block has no edge to read.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        const p = try f.mir.emitPhi(f.alloc(), .entry, &.{});
        try addFlow(&f, 1, 3, try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), p }), .f_zero);
        try expectRefused(&f, logic, "a phi with no operand for the edge taken");
    }
    // The 2^20-step bound on a block that never finishes is not run here:
    // reaching it takes 4 s in Debug.
}

fn emitUnderFailure(gpa: Allocator, rc: bool) !void {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&.{ "a", "y", "vdd", "vss", "n" });
    f.lowered.num_ports = 4;
    const m = f.alloc();
    // y follows n, n follows a; with `rc`, n is an RC so its delay is non-zero.
    try addFlow(&f, 1, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(1), try f.probe(4) }), .f_zero);
    const q = if (rc) try f.mir.emit(m, .entry, .fmul, &.{ try f.mir.addFloatConst(m, 1e-12), try f.probe(4) }) else .f_zero;
    try addFlow(&f, 4, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(4), try f.probe(0) }), q);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var why: []const u8 = "";
    _ = try emit(arena.allocator(), &f.mir, &f.lowered, logic, &why);
}

test "emit: an allocation failure anywhere is OutOfMemory, never a refusal or a crash" {
    for ([_]bool{ false, true }) |rc| try std.testing.checkAllAllocationFailures(std.testing.allocator, emitUnderFailure, .{rc});
}
