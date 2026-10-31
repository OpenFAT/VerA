//! The diagnostic system: stage events in, one `Bag` of coded rows, then
//! terminal text, JSON Lines or an `--explain` entry out.
//!
//! Every stage reports into one bag in one location currency (`Span`, a byte
//! range in the preprocessed text), so diagnostics from different stages
//! sort into source order. A code's severity is its first letter (`E`/`W`).
//!
//! The spine, one diagnostic at a time: `Bag.build` -> `Builder` parts ->
//! `Builder.emit` (level, dedupe, cap) -> `Bag.rows` and its children; once
//! per compilation: `Bag.detach` (optional) -> `render` / `renderJson`, which
//! sort the rows and resolve spans through `Bag.map` and `Bag.files`.
//!
//! Cites no LRM clause: the clause a diagnostic enforces is cited where the
//! stage reports it, and in its catalogue row (`info(code).lrm`).
//!
//! Contents: only re-exports; this list IS the API.
//! - catalogue: `Code`, `Info`, `info`
//! - levels: `Severity`, `severityOf`, `Level`, `Levels`, `SetError`
//! - locations: `Span`, `Loc`, `FileId`, `files_max`, `Segment`, `File`,
//!   `StripMark`, `SourceMap`, `LineIndex`, `toSourceOffset`
//! - entries: `Stage`, `String`, `max_children`, `Fix`, `Note`, `Label`, `Entry`
//! - the bag: `Bag`, `Builder`, `max_entries`, `AddFileError`
//! - suggestions: `editDistance`, `didYouMean`, `didYouMeanMap`, `Nearest`, `name_len_max`
//! - rendering: `render`, `renderJson`, `explain`, `RenderOptions`, `RenderError`, `Palette`

const code = @import("code.zig");
const level = @import("level.zig");
const location = @import("location.zig");
const entry = @import("entry.zig");
const bag = @import("bag.zig");
const builder = @import("builder.zig");
const suggest = @import("suggest.zig");
const render_text = @import("render.zig");
const render_json = @import("json.zig");

pub const Code = code.Code;
pub const Info = code.Info;
pub const info = code.info;

pub const Severity = level.Severity;
pub const severityOf = level.severityOf;
pub const Level = level.Level;
pub const Levels = level.Levels;
pub const SetError = level.SetError;

pub const Span = location.Span;
pub const Loc = location.Loc;
pub const FileId = location.FileId;
pub const files_max = location.files_max;
pub const Segment = location.Segment;
pub const File = location.File;
pub const StripMark = location.StripMark;
pub const SourceMap = location.SourceMap;
pub const LineIndex = location.LineIndex;
pub const toSourceOffset = location.toSourceOffset;

pub const Stage = entry.Stage;
pub const String = entry.String;
pub const max_children = entry.max_children;
pub const Fix = entry.Fix;
pub const Note = entry.Note;
pub const Label = entry.Label;
pub const Entry = entry.Entry;

pub const Bag = bag.Bag;
pub const Builder = builder.Builder;
pub const max_entries = bag.max_entries;
pub const AddFileError = bag.AddFileError;

pub const editDistance = suggest.editDistance;
pub const didYouMean = suggest.didYouMean;
pub const didYouMeanMap = suggest.didYouMeanMap;
pub const Nearest = suggest.Nearest;
pub const name_len_max = suggest.name_len_max;

pub const render = render_text.render;
pub const renderJson = render_json.renderJson;
pub const explain = render_text.explain;
pub const RenderOptions = render_text.RenderOptions;
pub const RenderError = render_text.RenderError;
pub const Palette = render_text.Palette;

test {
    _ = code;
    _ = level;
    _ = location;
    _ = entry;
    _ = bag;
    _ = builder;
    _ = suggest;
    _ = render_text;
    _ = render_json;
}
