//! The positional directive events the preprocessor publishes: each
//! directive whose state outlives its own line, as an event list in
//! text-stream order (`Directives`), and the value types of those lists. A
//! later stage looks its own output offset up (`Region.inForce`,
//! `DefaultDiscipline.inForce`). Data only: the handlers that record the
//! events are pp/directive_events.zig.
//! Cites: LRM §10.2 Syntax 10-1, §10.3; IEEE 1364-2005 §19.1, §19.2, §19.6,
//! §19.8, §19.9.
//!
//! Contents:
//! - `pub const Directives = struct`, `Directives.timescale(self: Directives) ?Timescale`
//! - `pub const Qualifier = enum(u8)`
//! - `pub const DefaultDiscipline = struct`, `DefaultDiscipline.inForce(events: []const DefaultDiscipline, at: u32, qualifier: ?Qualifier) ?[]const u8`
//! - `pub const DefaultTransition = Region(?f64)`
//! - `pub const TimescaleEvent = Region(?Timescale)`
//! - `pub const Timescale = base.Timescale`
//! - `pub const Region = base.Region`
//! - `pub const NetType = enum(u8)`, `NetType.default: NetType`
//! - `pub const NetTypeRegion = Region(NetType)`
//! - `pub const CellRegion = Region(bool)`
//! - `pub const Drive = enum(u8)`, `Drive.default: Drive`
//! - `pub const DriveRegion = Region(Drive)`
//! - `pub const Events = struct`

const std = @import("std");
const assert = std.debug.assert;
const base = @import("base");

/// Every directive whose state outlives its own line, as `Region` event lists
/// in text-stream order. Only a later stage can apply them, so each consumer
/// looks up its own output offset.
pub const Directives = struct {
    /// §10.2 `default_discipline, for §7.4 discipline resolution.
    disciplines: []const DefaultDiscipline = &.{},
    /// §10.3 `default_transition, for §4.5.8's rise/fall defaulting.
    transitions: []const DefaultTransition = &.{},
    /// IEEE 1364 §19.8 `timescale; a null value is §19.6's `resetall.
    timescales: []const TimescaleEvent = &.{},
    /// IEEE 1364 §19.2 `default_nettype, for §3.6.5 implicit-net creation
    /// (`Lower.rejectImplicitNet`).
    nettypes: []const NetTypeRegion = &.{},
    /// IEEE 1364 §19.1 `celldefine/`endcelldefine (`Mir.is_cell`).
    cells: []const CellRegion = &.{},
    /// IEEE 1364 §19.9 `unconnected_drive/`nounconnected_drive, for §6.2.2's
    /// blank port connections (`Lower.applyUnconnectedDrive`).
    drives: []const DriveRegion = &.{},

    /// Returns the `timescale in force at the end of the stream, or null if
    /// none is. Read by §9.15 Table 9-27's "timeUnit" and "timePrecision".
    ///
    /// ponytail: the last one wins, so every module of one file shares it,
    /// although the directive scopes to the design elements that follow it.
    /// Look the module's own offset up with `TimescaleEvent.inForce` once a
    /// fixture puts a `timescale between two modules.
    pub fn timescale(self: Directives) ?Timescale {
        const last = if (self.timescales.len == 0) return null else self.timescales[self.timescales.len - 1];
        // Events are in text-stream order: the last is at the largest offset.
        if (self.timescales.len > 1) assert(self.timescales[self.timescales.len - 2].at <= last.at);
        return last.value;
    }
};

/// §10.2 Syntax 10-1:
///
///   default_discipline_directive ::=
///       `default_discipline [ discipline_identifier [ qualifier ] ]
///   qualifier ::= integer | real | reg | wreal | wire | tri | wand | triand
///               | wor | trior | trireg | tri0 | tri1 | supply0 | supply1
///
/// A closed list of fifteen names, so anything else in that slot is a syntax
/// error, not a second discipline (E0127).
pub const Qualifier = enum(u8) { integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1 };

/// One `default_discipline, or the `resetall or bare form that withdraws one.
/// §10.2 applies it "to all discrete signals without a discipline declaration
/// that appear in the text stream following the use of the directive", so §7.4
/// discipline resolution looks each net's declaration offset up against the
/// events.
///
/// `at` is an offset into the preprocessed output, the unit every later stage
/// reports in, so it compares directly against a token start.
pub const DefaultDiscipline = struct {
    at: u32,
    /// Syntax 10-1's optional qualifier; null when the directive named none.
    qualifier: ?Qualifier,
    /// "" withdraws every default in force from `at` on. §10.2: "In addition
    /// to `resetall, if this directive is used without a discipline name,
    /// discipline resolution will not use a default discipline for nets
    /// declared after this directive is encountered in the text stream."
    discipline: []const u8,

    /// The default in force at offset `at` of `events` for a signal of type
    /// `qualifier`, or null. The most recent directive wins, and one naming
    /// `qualifier` wins over an unqualified one however old it is ("the more
    /// specific directives have higher precedence"). A directive naming
    /// another qualifier does not apply: "more than one `default_discipline
    /// directive can be in force simultaneously, provided each differs in
    /// qualifier".
    pub fn inForce(events: []const DefaultDiscipline, at: u32, qualifier: ?Qualifier) ?[]const u8 {
        // Text-stream order is what makes "the most recent" the last one found.
        if (events.len > 1) assert(events[0].at <= events[events.len - 1].at);
        var fallback: ?[]const u8 = null;
        var i = events.len;
        return while (i > 0) {
            i -= 1;
            const e = events[i];
            if (e.at > at) continue;
            // §10.2: the bare form and `resetall withdraw the default outright,
            // so nothing older than one of those is still in force.
            if (e.discipline.len == 0) break fallback;
            if (e.qualifier != null and e.qualifier == qualifier) break e.discipline;
            if (e.qualifier == null and fallback == null) fallback = e.discipline;
        } else fallback;
    }
};

/// One §10.3 `` `default_transition ``. `value` is the transition time in
/// seconds, used for both rise and fall; null after `resetall. A filter takes
/// its default from "the directive which immediately precedes the transition
/// filter" (§10.3), which is `Region.inForce` at the filter's offset.
pub const DefaultTransition = Region(?f64);

/// One IEEE 1364 §19.8 `` `timescale <unit> / <precision> ``; null after
/// `resetall. Nothing rescales time (§9.10 `$abstime` is always seconds); the
/// operands exist to be read back by §9.15 Table 9-27.
pub const TimescaleEvent = Region(?Timescale);

/// A `timescale's two operands, in seconds (`base`'s).
pub const Timescale = base.Timescale;

/// One positional directive event: the output offset where its value
/// changed, and the new value (`base`'s, so `Lowered` holds the lists
/// without importing the frontend).
pub const Region = base.Region;

/// IEEE 1364 §19.2 `default_nettype_value`, a closed list. `supply0` and
/// `supply1` are net types but not ones §19.2 lets an implicit net have.
/// `.none` withdraws implicit nets, so an undeclared identifier used as a net
/// is an error instead of a new wire.
pub const NetType = enum(u8) {
    wire,
    tri,
    tri0,
    tri1,
    wand,
    triand,
    wor,
    trior,
    trireg,
    uwire,
    none,

    /// IEEE 1364 §19.2: "If no `default_nettype directive is present or if the
    /// `resetall directive is used, implicit nets are of type wire."
    pub const default: NetType = .wire;
};

/// One IEEE 1364 §19.2 `default_nettype (or the `resetall that restores
/// `.wire`).
pub const NetTypeRegion = Region(NetType);

/// IEEE 1364 §19.1 `` `celldefine ``/`` `endcelldefine ``: whether the design
/// elements at this point are cell modules. The tag is metadata only; it does
/// not change what a module means.
pub const CellRegion = Region(bool);

/// IEEE 1364 §19.9 `` `unconnected_drive pull1 | pull0 `` and
/// `` `nounconnected_drive ``: how an unconnected input port of a module
/// declared in this region is driven.
pub const Drive = enum(u8) {
    /// `` `nounconnected_drive ``, and the state before either directive: the
    /// port is left floating.
    float,
    pull0,
    pull1,

    pub const default: Drive = .float;
};

/// One IEEE 1364 §19.9 drive directive (or the `resetall that restores
/// `.float`).
pub const DriveRegion = Region(Drive);

/// The `Directives` lists while they fill, in text-stream order, on
/// `Pp.scratch`. Field for field the names of `Directives`, which `process`
/// publishes by name.
/// The comptime block below holds the two field lists together.
pub const Events = struct {
    disciplines: std.ArrayList(DefaultDiscipline) = .empty,
    transitions: std.ArrayList(DefaultTransition) = .empty,
    timescales: std.ArrayList(TimescaleEvent) = .empty,
    nettypes: std.ArrayList(NetTypeRegion) = .empty,
    cells: std.ArrayList(CellRegion) = .empty,
    drives: std.ArrayList(DriveRegion) = .empty,

    comptime {
        const want = @typeInfo(Directives).@"struct".field_names;
        const have = @typeInfo(Events).@"struct".field_names;
        assert(want.len == have.len);
        for (want, have) |w, h| assert(std.mem.eql(u8, w, h));
    }
};
