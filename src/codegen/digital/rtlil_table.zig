//! A module's names in, their rows out: one row per port, net, variable and
//! parameter `rtlil.emit` has declared, with its width and sign (`Sym`), a
//! parameter's folded value, a reg's `initial` constant and the temp of the
//! `always` block writing it. A name finds its row through a slot array as
//! long as the file's string table, so a lookup is two loads, not a hash.
//!
//! Clauses: IEEE 1364-2005 §4.10 (one declaration a name), §12.2 (a
//! parameter's value).
//!
//! Contents:
//! - `pub const Sym`
//! - `pub const Sig`
//! - `pub const none`
//! - `pub const Row`
//! - `pub const Table`: `init`, `reset`, `find`, `get`, `value`, `temp`, `put`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Integer = @import("kernels").Integer;
const Allocator = std.mem.Allocator;
const StrId = Ast.StrId;

/// What one name of a module is, for widths, signedness and lvalues.
pub const Sym = struct {
    width: u32,
    /// The declared `[msb:lsb]`: the right bound, and whether msb >= lsb.
    /// A bit `i` of the source is RTLIL position `i - lsb` when descending
    /// and `lsb - i` when not (Yosys's `upto`).
    lsb: i64 = 0,
    descending: bool = true,
    signed: bool = false,
    /// A parameter's value is its row's `value`, unless it is real.
    kind: enum { wire, reg, param },
};

/// One sigspec: its RTLIL spelling, width and §5.5 signedness.
pub const Sig = struct { s: []const u8, w: u32, signed: bool = false };

/// No row, and no process: the sentinel of `Table.slot`, `Row.temp_proc`
/// and `Row.redirect_proc`.
pub const none: u32 = std.math.maxInt(u32);

/// One declared name. `temp` is meaningful only while `temp_proc` is the
/// emitting process's index, so a new process needs no reset.
pub const Row = struct {
    name: StrId,
    sym: Sym,
    /// An integral parameter's value at its §12.2 type; null for a real
    /// parameter and for every name that is not a parameter.
    value: ?Integer.Literal = null,
    /// The reg's `initial` constant (the `init` attribute); null for none.
    init: ?Sig = null,
    /// `$<index>\name`, the temp the process `temp_proc` updates from.
    temp: Sig = undefined,
    temp_proc: u32 = none,
    /// The process whose blocking assignment wrote the reg: its reads after
    /// that take `temp` (§9.2.1).
    redirect_proc: u32 = none,
};

/// The rows of one module, found by name.
pub const Table = struct {
    /// Per `StrId` of the file, its row, or `none`.
    slot: []u32,
    rows: std.MultiArrayList(Row) = .empty,

    /// An empty table for a file of `names` interned strings.
    pub fn init(arena: Allocator, names: u32) Allocator.Error!Table {
        const slot = try arena.alloc(u32, names);
        @memset(slot, none);
        return .{ .slot = slot };
    }

    /// Empties the table for a module of at most `capacity` names: each
    /// row's slot is cleared, so the cost is the old rows, not the file.
    pub fn reset(self: *Table, arena: Allocator, capacity: usize) Allocator.Error!void {
        for (self.rows.items(.name)) |n| self.slot[@backingInt(n)] = none;
        self.rows.clearRetainingCapacity();
        try self.rows.ensureTotalCapacity(arena, capacity);
        assert(self.rows.len == 0);
    }

    /// The row of `name`, or null when the module does not declare it.
    pub fn find(self: *const Table, name: StrId) ?u32 {
        assert(name != .none);
        const r = self.slot[@backingInt(name)];
        if (r == none) return null;
        assert(self.rows.items(.name)[r] == name);
        return r;
    }

    /// `name`'s `Sym`, or null when the module does not declare it.
    pub fn get(self: *const Table, name: StrId) ?Sym {
        const r = self.find(name) orelse return null;
        return self.rows.items(.sym)[r];
    }

    /// An integral parameter's value, or null for any other name.
    pub fn value(self: *const Table, name: StrId) ?Integer.Literal {
        const r = self.find(name) orelse return null;
        return self.rows.items(.value)[r];
    }

    /// The temp of `name`, a reg the process `proc` writes. Asserts that
    /// `proc` declared it.
    pub fn temp(self: *const Table, name: StrId, proc: u32) Sig {
        assert(proc != none);
        const r = self.find(name).?;
        assert(self.rows.items(.temp_proc)[r] == proc);
        return self.rows.items(.temp)[r];
    }

    /// Declares `name` as `sym` and returns its row; a second declaration
    /// of the name replaces the first's `Sym` and keeps its other columns.
    pub fn put(self: *Table, arena: Allocator, name: StrId, sym: Sym) Allocator.Error!u32 {
        if (self.find(name)) |r| {
            self.rows.items(.sym)[r] = sym;
            return r;
        }
        const r: u32 = @intCast(self.rows.len);
        try self.rows.append(arena, .{ .name = name, .sym = sym });
        self.slot[@backingInt(name)] = r;
        assert(self.find(name) == r);
        return r;
    }
};
