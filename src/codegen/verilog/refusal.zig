//! Why `--emit-verilog` refused a model: one row of data per reason, rendered
//! to its one-line message only when the caller prints it. The messages are
//! user-visible and frozen; each names the construct and, where one applies,
//! its Verilog-AMS clause (§3.2.2, §5.6.1.3, §5.6.7, §5.10).
//!
//! Contents:
//! - `pub const Refusal = union(enum)`
//! - `pub fn Refusal.format(r: Refusal, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn Refusal.raise(slot: *Refusal, reason: Refusal) error{Refused}`

const std = @import("std");

/// The reason `emit` returned `error.Refused`. Every slice payload borrows
/// from the `Mir`, the `Lowered` or the `Options` handed to `emit` (a name, a
/// declaration's source text, a callee's spelling), so a `Refusal` must not
/// outlive them.
pub const Refusal = union(enum) {
    /// §5.10: a held variable or event, by name.
    held_state: []const u8,
    /// A vector net or port.
    vector_net,
    /// The module, by name, declares no port.
    no_ports: []const u8,
    /// A `vera_pin` whose value is not a string, by declaration text.
    bad_vera_pin: []const u8,
    /// A `vera_delay` that is not a finite constant >= 0 s, by declaration text.
    bad_vera_delay: []const u8,
    /// A `--digital-pins` name that is no port of the module.
    unknown_digital_pin: struct { pin: []const u8, module: []const u8 },
    /// A `vera_pin` string that is no pin kind.
    unknown_pin_kind: struct { port: []const u8, kind: []const u8 },
    /// §5.6.7 an indirect branch assignment.
    indirect_branch,
    /// A contribution between unknowns that are not nets (an `I()` probe, or
    /// `ddt`/`idt` outside a contribution), by unknown name.
    not_a_net: []const u8,
    /// `V(hi, lo) <+` with a supply or ground as `hi` and a signal as `lo`.
    potential_from_first: struct { hi: []const u8, lo: []const u8 },
    /// `V(hi, lo) <+` between two signals.
    potential_not_rail: struct { hi: []const u8, lo: []const u8 },
    /// More pins and driven nodes (`count`) than the truth tables enumerate (`max`).
    too_many_vars: struct { count: u32, max: u8 },
    /// §5.6.1.3 a node whose potential row's retention depends on the node.
    retention_self: []const u8,
    /// A node whose current does not move with its own potential.
    settles_nowhere: []const u8,
    /// A node whose settled potential is NaN or infinite.
    potential_not_finite: []const u8,
    /// A node whose derived delay (s) has no finite ns value, and no `vera_delay`.
    delay_not_finite: struct { node: []const u8, seconds: f64 },
    /// Every port is a supply hidden by `--power-pins`.
    only_supplies,
    /// The analog block ran past its step bound.
    no_finish,
    /// §3.2.2 a runtime-indexed array.
    runtime_array,
    /// A phi with no operand for the edge the run took.
    phi_no_edge,
    /// A probe of an unknown that is neither a pin nor a driven net.
    unknown_net: []const u8,
    /// A value read before the block defining it ran.
    read_before_run,
    /// A read of `Mir.Value.undef`.
    undefined_value,
    /// An operator with no value for these operands, by its opcode label.
    no_value: []const u8,
    /// A call with no static value per assignment, by its callee spelling.
    not_static: []const u8,

    /// Writes the reason as the one-line message `vera` prints after
    /// `--emit-verilog: `.
    pub fn format(r: Refusal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (r) {
            .held_state => |name| try w.print("`{s}` holds state across evaluations (§5.10 event or held variable); --emit-verilog abstracts only continuous models", .{name}),
            .vector_net => try w.writeAll("vector nets are not supported; declare the bits as scalar ports"),
            .no_ports => |module| try w.print("module `{s}` has no ports", .{module}),
            .bad_vera_pin => |decl| try w.print("`{s}`: vera_pin takes \"digital\", \"analog\", \"power\" or \"ground\"", .{decl}),
            .bad_vera_delay => |decl| try w.print("`{s}`: vera_delay takes a constant delay in seconds, >= 0", .{decl}),
            .unknown_digital_pin => |p| try w.print("--digital-pins: `{s}` is not a port of `{s}`", .{ p.pin, p.module }),
            .unknown_pin_kind => |p| try w.print("`{s}`: vera_pin = \"{s}\" is not digital, analog, power or ground", .{ p.port, p.kind }),
            .indirect_branch => try w.writeAll("§5.6.7 indirect branch assignments are not supported"),
            .not_a_net => |name| try w.print("`{s}` is not a net (an I() probe, or ddt/idt outside a contribution)", .{name}),
            .potential_from_first => |b| try w.print("`V({s}, {s}) <+`: a potential contribution drives its first node; write it as `V({s}, {s})` with the value negated", .{ b.hi, b.lo, b.lo, b.hi }),
            .potential_not_rail => |b| try w.print("`V({s}, {s}) <+`: a potential contribution must be referred to a supply or ground", .{ b.hi, b.lo }),
            .too_many_vars => |t| try w.print("{d} pins and driven nodes; the truth tables stop at {d}", .{ t.count, t.max }),
            .retention_self => |node| try w.print("node `{s}`: whether its potential contribution is retained (§5.6.1.3) depends on its own value", .{node}),
            .settles_nowhere => |node| try w.print("node `{s}`: its current does not depend on its own potential, so it settles nowhere", .{node}),
            .potential_not_finite => |node| try w.print("node `{s}`: its settled potential is not finite", .{node}),
            .delay_not_finite => |d| try w.print("node `{s}`: its delay is not finite (tau·ln2 + td = {d} s); give it a (* vera_delay *)", .{ d.node, d.seconds }),
            .only_supplies => try w.writeAll("every port is a supply; nothing to model"),
            .no_finish => try w.writeAll("the analog block did not finish (a loop over a node potential?)"),
            .runtime_array => try w.writeAll("§3.2.2 runtime-indexed arrays are not supported"),
            .phi_no_edge => try w.writeAll("a phi with no operand for the edge taken"),
            .unknown_net => |name| try w.print("`{s}` is read but is neither a pin nor a driven net", .{name}),
            .read_before_run => try w.writeAll("a value read before its block ran"),
            .undefined_value => try w.writeAll("an undefined value"),
            .no_value => |label| try w.print("`{s}` has no value here", .{label}),
            .not_static => |callee| try w.print("`{s}` has no static value; --emit-verilog cannot abstract it", .{callee}),
        }
    }

    /// Stores `reason` in `slot` and returns `error.Refused`, so a refusal
    /// is one `return slot.raise(...)`.
    pub fn raise(slot: *Refusal, reason: Refusal) error{Refused} {
        slot.* = reason;
        return error.Refused;
    }
};
