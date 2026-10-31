//! A source file that could not be read -> the one line `vera` prints for
//! it: E1013 for a file past `Preprocessor.max_text_bytes` (the u32 offsets
//! the lexer uses), else the error's name. The text is user-visible and
//! frozen; `vera`, its `.v` route and `--emit-verilog`'s pin file share it.
//!
//! Cites: none of the LRM's (E1013 is VerA's own limit).
//!
//! Contents:
//! - `pub const ReadError`
//! - `pub fn readFailed(w: *Io.Writer, path: []const u8, e: ReadError) Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Preprocessor = @import("frontend").Preprocessor;

/// What reading a source file can fail with (`Preprocessor.readText`).
pub const ReadError = @typeInfo(@typeInfo(@TypeOf(Preprocessor.readText)).@"fn".return_type.?).error_union.error_set;

/// Writes the line for `path` failing with `e` on `w`. `path` is the user's
/// text, so it may be anything, the empty string included.
pub fn readFailed(w: *Io.Writer, path: []const u8, e: ReadError) Io.Writer.Error!void {
    comptime assert(Preprocessor.max_text_bytes > 0);
    if (e == error.StreamTooLong)
        try w.print("error[E1013]: `{s}` is larger than {d} bytes; see `vera --explain E1013`\n", .{ path, Preprocessor.max_text_bytes })
    else
        try w.print("error: cannot read `{s}`: {t}\n", .{ path, e });
}

test readFailed {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // 2^32 - 1 is 4294967295 bytes.
    try readFailed(&w, "big.va", error.StreamTooLong);
    try readFailed(&w, "gone.va", error.FileNotFound);
    try std.testing.expectEqualStrings("error[E1013]: `big.va` is larger than 4294967295 bytes; see `vera --explain E1013`\n" ++
        "error: cannot read `gone.va`: FileNotFound\n", w.buffered());
}
