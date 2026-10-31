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

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const token_file = @import("token.zig");
const keyword = @import("keyword.zig");
const lexer = @import("lexer.zig");
const token_value = @import("token_value.zig");

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
