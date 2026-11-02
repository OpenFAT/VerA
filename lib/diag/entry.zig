//! Entries: the rows `Bag` stores for each diagnostic and the by-value views a
//! reader decodes from them. In: a `Builder`'s parts. Out: one `Row` per
//! diagnostic plus its `LabelRow`s and `NoteRow`s, their text in the bag's
//! string pool, and the `Entry`/`Label`/`Note` views of them.
//!
//! Cites no LRM clause: the stage that reports a diagnostic cites it.
//!
//! Contents:
//! - `pub const Stage = enum(u8) { preprocess, parse, lower, proof, codegen, run }`
//! - `pub const String = enum(u32) { none = 0, _ }`
//! - `pub const max_children: u8`
//! - `pub const Children = struct { start: u16, len: u8 }`
//! - `pub const Row = struct`, `pub const LabelRow = struct`, `pub const NoteRow = struct`
//! - `pub const Fix = struct`, `pub const Note = struct` (`Kind`), `pub const Label = struct`
//! - `pub const Entry = struct`

const std = @import("std");
const assert = std.debug.assert;
const Code = @import("code.zig").Code;
const Severity = @import("level.zig").Severity;
const location = @import("location.zig");
const Span = location.Span;
const FileId = location.FileId;

/// Which stage produced the diagnostic: what a person debugging the engine
/// filters on, and the JSON `stage`. `run`: raised while a design runs (the
/// digital interpreter), after it compiled, so the renderer's "could not
/// compile" summary does not count it.
pub const Stage = enum(u8) { preprocess, parse, lower, proof, codegen, run };

/// Handle of a NUL-terminated string in `Bag.strings`. Byte 0 of the pool is
/// a sentinel NUL, so no real string starts at 0 and `none` costs no byte.
pub const String = enum(u32) { none = 0, _ };

/// Most labels, and most notes, on ONE diagnostic. More than four of either
/// is not clearer for it; later ones are dropped by `Builder`.
pub const max_children: u8 = 4;

/// A diagnostic's run of rows in `Bag.label_rows` or `Bag.note_rows`.
/// Children are appended at `emit`, all at once, so a run is contiguous.
pub const Children = struct {
    start: u16 = 0,
    len: u8 = 0,
};

/// One diagnostic as `Bag.rows` stores it (one column per field). Handles,
/// not pointers, so `detach` copies the tables and fixes nothing up.
pub const Row = struct {
    code: Code,
    severity: Severity,
    stage: Stage,
    /// A file only for a preprocessor diagnostic, whose offsets are
    /// file-local because it fails before a preprocessed text exists.
    file: FileId,
    span: Span,
    message: String,
    point: String,
    labels: Children,
    notes: Children,
};

/// A stored secondary label: `Label` with its text as a handle.
pub const LabelRow = struct {
    span: Span,
    text: String,

    comptime {
        assert(@sizeOf(LabelRow) == 12);
    }
};

/// A stored note. `fix_replacement == .none` means "no fix": a fix whose
/// replacement is EMPTY is a deletion and is interned, so it stays
/// distinguishable from no fix at all.
pub const NoteRow = struct {
    kind: Note.Kind,
    text: String,
    fix_replacement: String,
    fix_span: Span,

    comptime {
        assert(@sizeOf(NoteRow) == 20);
    }
};

/// A machine-applicable rewrite. `span` is what to replace; a zero-width
/// span inserts. The renderer draws `+` under an insertion and `~` under a
/// replacement, like rustc.
pub const Fix = struct {
    span: Span,
    replacement: []const u8,
};

/// A `= note:` or `= help:` line under a diagnostic, optionally with a fix.
/// Its strings borrow the bag's pool (see `Bag.str`).
pub const Note = struct {
    /// Which word the line is rendered with; also the JSON `kind`.
    pub const Kind = enum(u8) { note, help };

    kind: Kind,
    text: []const u8,
    fix: ?Fix = null,
};

/// A secondary span with its own text ("this is the parameter that is
/// unconstrained"), pointing somewhere other than the primary span.
pub const Label = struct {
    span: Span,
    text: []const u8,
};

/// One diagnostic as a reader sees it: `Bag.at` decodes it from a `Row`, and
/// `Bag.labels`/`Bag.notes` read its children through `index`. Its strings
/// borrow the bag's pool (see `Bag.str`).
pub const Entry = struct {
    /// The row in `Bag.rows`. Valid until the next `Bag.sort`.
    index: u32,
    code: Code,
    severity: Severity,
    stage: Stage,
    /// The primary span, where the caret goes. `Span.none` only for a
    /// whole-file condition such as E1001.
    span: Span,
    /// `.none` but for a preprocessor diagnostic; see `Row.file`.
    file: FileId = .none,
    /// The headline after `Info.title`; when empty the title stands alone.
    message: []const u8,
    /// Short text beside the primary caret; usually empty, because repeating
    /// the headline beside the caret is noise.
    point: []const u8 = "",
    label_count: u8 = 0,
    note_count: u8 = 0,
};
