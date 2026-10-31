//! The frontend's pre-rewrite public names, kept so the modules that import
//! `frontend` build unchanged while each stage is rewritten: old name in,
//! the rewritten declaration out. Nothing in `lib/frontend` imports this
//! file; `root.zig` re-exports it under the old names.
//! Cites: none (a migration shim).
//!
//! ponytail: delete in pass 2, once every caller uses the names in
//! scratchpad/api/frontend.md; each alias says which name replaces it.
//!
//! Contents:
//! - `pub const token = struct`: `Tag`, `Stored`, `isKeyword`, `KeywordSet`,
//!   `default_keyword_set`, `Sim`, `isReserved`, `lookupKeyword`,
//!   `isMathFunction`, `isFilterFunction`, `isSmallSignalFunction`, `isEventFunction`
//! - `pub const Lexer = struct`: `TokenList`, `tokenSpan`, `stringContents`,
//!   `scaleExp`, `parseReal`, `Lexer.Seed`, `Lexer.tokenize`, `Lexer.tokenizeSeeded`
//! - `pub const Preprocessor = struct`: every old `Preprocessor` name (`Options`,
//!   `protect`, `File`, `Error`, `Output`, `Directives`, `max_text_bytes`,
//!   `segment_levels`, `caller_levels`, `readText`, `Directive`, `Qualifier`,
//!   `DefaultDiscipline`, `DefaultTransition`, `TimescaleEvent`, `Timescale`,
//!   `Region`, `NetType`, `NetTypeRegion`, `CellRegion`, `Drive`, `DriveRegion`,
//!   `directive_map`, `predefined_macros`, `builtin_includes`, `process`,
//!   `preludeTokens`, `preludeAst`, `preludeSnapshot`, `disciplines_vams`,
//!   `Macro`, `Events`, `Pp`, `stripComments`, `scan_stops`, `findStop`, `scan`,
//!   `stringStop`, `Rest`, `isSpace`, `isIdentChar`, `identEnd`, `escapedEnd`,
//!   `isIdentStart`, `spice_primitives`, `spice_module_count`)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const token_file = @import("token.zig");
const keyword = @import("keyword.zig");
const lexer = @import("lexer.zig");
const token_value = @import("token_value.zig");
const preprocessor = @import("preprocessor.zig");
const events = @import("pp/events.zig");
const pp_directive = @import("pp/directive.zig");
const pp_scan = @import("pp/scan.zig");
const pp_prelude = @import("pp/prelude.zig");
const pp_annex_e = @import("pp/annex_e.zig");

/// The old `frontend.token`: token.zig and keyword.zig in one namespace.
pub const token = struct {
    pub const Tag = token_file.Tag;
    pub const Stored = token_file.Stored;
    pub const isKeyword = token_file.isKeyword;
    /// Use `frontend.keyword.KeywordSet`.
    pub const KeywordSet = keyword.KeywordSet;
    /// Use `frontend.keyword.default_keyword_set`.
    pub const default_keyword_set = keyword.default_keyword_set;
    /// Use `frontend.keyword.Sim`.
    pub const Sim = keyword.Sim;
    /// Use `frontend.keyword.isReserved`.
    pub const isReserved = keyword.isReserved;
    /// Use `frontend.keyword.lookupKeyword`.
    pub const lookupKeyword = keyword.lookupKeyword;

    /// Use `token.callGroup(tag) == .math`.
    pub fn isMathFunction(tag: Tag) bool {
        return token_file.callGroup(tag) == .math;
    }
    /// Use `token.callGroup(tag) == .filter`.
    pub fn isFilterFunction(tag: Tag) bool {
        return token_file.callGroup(tag) == .filter;
    }
    /// Use `token.callGroup(tag) == .small_signal`.
    pub fn isSmallSignalFunction(tag: Tag) bool {
        return token_file.callGroup(tag) == .small_signal;
    }
    /// Use `token.callGroup(tag) == .event`.
    pub fn isEventFunction(tag: Tag) bool {
        return token_file.callGroup(tag) == .event;
    }
};

/// The old `frontend.Lexer` file namespace.
pub const Lexer = struct {
    /// Use `frontend.lexer.TokenList`.
    pub const TokenList = lexer.TokenList;
    /// Use `frontend.lexer.tokenSpan`.
    pub const tokenSpan = lexer.tokenSpan;
    /// Use `frontend.token_value.stringContents`.
    pub const stringContents = token_value.stringContents;
    /// Use `frontend.token_value.scaleExp`.
    pub const scaleExp = token_value.scaleExp;
    /// Use `frontend.token_value.parseReal`.
    pub const parseReal = token_value.parseReal;

    /// The old cursor type's static entry points.
    pub const Lexer = struct {
        /// Use `frontend.lexer.Seed`.
        pub const Seed = lexer.Seed;

        /// Use `frontend.lexer.tokenize(gpa, src, null)`.
        pub fn tokenize(gpa: Allocator, src: []const u8) lexer.Error!lexer.TokenList {
            assert(src.len <= lexer.source_bytes_max);
            return lexer.tokenize(gpa, src, null);
        }

        /// Use `frontend.lexer.tokenize(gpa, src, seed)`.
        pub fn tokenizeSeeded(gpa: Allocator, src: []const u8, seed: ?Seed) lexer.Error!lexer.TokenList {
            assert(src.len <= lexer.source_bytes_max);
            return lexer.tokenize(gpa, src, seed);
        }
    };
};

/// The old `frontend.Preprocessor` (preprocessor.zig with every pp/ name in
/// it). Use `frontend.preprocessor` for the API, `frontend.directive_events`
/// for the published event types, `frontend.prelude`, `frontend.protect`,
/// `frontend.annex_d`, `frontend.annex_e`, and `frontend.pp_*` for the scan
/// internals the tests drive.
pub const Preprocessor = struct {
    pub const Options = preprocessor.Options;
    pub const protect = @import("pp/protect.zig");
    pub const File = preprocessor.File;
    pub const Error = preprocessor.Error;
    pub const Output = preprocessor.Output;
    pub const max_text_bytes = preprocessor.max_text_bytes;
    pub const segment_levels = preprocessor.segment_levels;
    pub const caller_levels = preprocessor.caller_levels;
    pub const readText = preprocessor.readText;
    pub const process = preprocessor.process;
    pub const predefined_macros = preprocessor.predefined_macros;
    pub const Directives = events.Directives;
    pub const Qualifier = events.Qualifier;
    pub const DefaultDiscipline = events.DefaultDiscipline;
    pub const DefaultTransition = events.DefaultTransition;
    pub const TimescaleEvent = events.TimescaleEvent;
    pub const Timescale = events.Timescale;
    pub const Region = events.Region;
    pub const NetType = events.NetType;
    pub const NetTypeRegion = events.NetTypeRegion;
    pub const CellRegion = events.CellRegion;
    pub const Drive = events.Drive;
    pub const DriveRegion = events.DriveRegion;
    pub const Events = events.Events;
    pub const Directive = pp_directive.Directive;
    pub const directive_map = pp_directive.directive_map;
    pub const builtin_includes = @import("pp/include.zig").builtin_includes;
    pub const preludeTokens = pp_prelude.preludeTokens;
    pub const preludeAst = pp_prelude.preludeAst;
    pub const preludeSnapshot = pp_prelude.preludeSnapshot;
    pub const disciplines_vams = @import("pp/annex_d.zig").disciplines_vams;
    pub const Pp = @import("pp/Pp.zig");
    pub const Macro = Pp.Macro;
    pub const stripComments = @import("pp/comments.zig").stripComments;
    pub const scan_stops = pp_scan.scan_stops;
    pub const findStop = pp_scan.findStop;
    pub const scan = pp_scan.scan;
    pub const stringStop = pp_scan.stringStop;
    pub const Rest = pp_scan.Rest;
    pub const isIdentStart = pp_scan.isIdentStart;
    pub const isSpace = lexer.isSpace;
    pub const isIdentChar = lexer.isIdentChar;
    pub const identEnd = lexer.identEnd;
    pub const escapedEnd = lexer.escapedEnd;
    pub const spice_primitives = pp_annex_e.spice_primitives;
    pub const spice_module_count = pp_annex_e.spice_module_count;
};
