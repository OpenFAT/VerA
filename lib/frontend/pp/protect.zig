//! IEEE 1364-2005 §28 decryption envelopes: a `pragma protect begin_protected
//! … end_protected` region in, its cleartext out, which the preprocessor then
//! scans in place of the region (§28.2: tools "shall perform envelope
//! decryption for all decryption envelopes contained in the source text,
//! where the proper key is supplied by the user").
//!
//! The keys come from `Keys`, the host's key provider (`vera
//! --protect-keys FILE`). VerA decrypts `des-cbc` (§28.4.11 Table 28-2's
//! required method) with the base64, uuencode and raw encodings (§28.4.3),
//! a §28.4.10 key block carrying the session key, and a §28.4.12 digest block
//! over md5 or sha1. The CBC IV and the PKCS#7 padding are the key provider's
//! profile, since §28 standardizes neither.
//!
//! Three failures stay apart, as a key-provider adapter needs them apart:
//! E0146 an envelope VerA cannot process (an encryption envelope, a method or
//! encoding it does not implement, a malformed envelope), E0152 no key for
//! the owner and name the envelope asks for, E0153 a key that does not open
//! it (bad padding, a digest mismatch, a block whose length is not its
//! `bytes`).

const std = @import("std");
const diag = @import("diag");
const Preprocessor = @import("../preprocessor.zig");
const identEnd = Preprocessor.identEnd;
const isIdentStart = Preprocessor.isIdentStart;

/// The file a decrypted envelope's cleartext is registered under in the bag:
/// its declarations' location, which IEEE 1364-2005 §26.3.5's
/// vpiIsProtected reads.
pub const file_name = "<protected envelope>";

/// One key the host provides, found by the envelope's `*_keyowner` and
/// `*_keyname` (§28.4.6, §28.4.7).
pub const Key = struct { owner: []const u8, name: []const u8, key: [8]u8 };

/// The host's key provider: the keys, and the CBC IV every envelope uses.
pub const Keys = struct {
    iv: [8]u8 = @splat(0),
    keys: []const Key = &.{},

    fn find(self: Keys, owner: []const u8, name: []const u8) ?[8]u8 {
        for (self.keys) |k| if (std.mem.eql(u8, k.owner, owner) and std.mem.eql(u8, k.name, name)) return k.key;
        return null;
    }
};

/// Reads a key file: JSON with `profile.iv_hex` and
/// `keys: [{owner, name, key_hex}]`, the VAMS Conformance Suite's
/// `known_keys.json` layout. Every slice is on `arena`.
pub fn parseKeys(arena: std.mem.Allocator, json: []const u8) !Keys {
    const File = struct {
        profile: struct { iv_hex: []const u8 },
        keys: []const struct { owner: []const u8, name: []const u8, key_hex: []const u8 },
    };
    const f = try std.json.parseFromSliceLeaky(File, arena, json, .{ .ignore_unknown_fields = true });
    var out: Keys = .{ .keys = try arena.alloc(Key, f.keys.len) };
    if ((try std.fmt.hexToBytes(&out.iv, f.profile.iv_hex)).len != 8) return error.InvalidLength;
    const keys: []Key = @constCast(out.keys);
    for (f.keys, keys) |k, *o| {
        o.* = .{ .owner = k.owner, .name = k.name, .key = undefined };
        if ((try std.fmt.hexToBytes(&o.key, k.key_hex)).len != 8) return error.InvalidLength;
    }
    return out;
}

/// What `open` makes of an envelope: the cleartext, or the diagnostic.
pub const Opened = union(enum) {
    text: []const u8,
    fail: struct { code: diag.Code, why: []const u8 },
};

/// The envelope whose `begin_protected` line holds the pragma expression list
/// `head` and whose body starts at `text[from..]`. Returns where the
/// `end_protected` line ends (its newline, or `text.len`) and the result.
pub fn open(arena: std.mem.Allocator, keys: Keys, head: []const u8, text: []const u8, from: usize) !struct { end: usize, opened: Opened } {
    var b: Body = .{};
    try b.items(arena, head);
    const end = (try b.lines(arena, text, from, true)) orelse
        return .{ .end = text.len, .opened = try failf(arena, .E0146, "no `pragma protect end_protected closes the envelope", .{}) };
    if (b.bad) |why| return .{ .end = end, .opened = .{ .fail = .{ .code = .E0146, .why = why } } };
    return .{ .end = end, .opened = try decrypt(arena, keys, &b) };
}

const Kind = enum { data_block, key_block, digest_block, data_decrypt_key };

/// One encoded block and the §28.4.3 encoding in force where it started.
const Block = struct {
    kind: Kind,
    enctype: []const u8,
    bytes: ?usize,
    text: std.ArrayList(u8) = .empty,
};

/// An envelope's pragma keywords (§28.4: a later value replaces an earlier
/// one) and its blocks, in order.
const Body = struct {
    fields: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// The first structural error, reported after the end is found.
    bad: ?[]const u8 = null,

    fn get(b: *const Body, name: []const u8) []const u8 {
        return b.fields.get(name) orelse "";
    }

    fn block(b: *const Body, kind: Kind) ?*const Block {
        for (b.blocks.items) |*k| if (k.kind == kind) return k;
        return null;
    }

    /// Reads one line's pragma expression list: the values first, then any
    /// block keyword, so `data_block encoding=(...)` opens its block with the
    /// encoding it names.
    fn items(b: *Body, arena: std.mem.Allocator, list: []const u8) !void {
        var opens: ?Kind = null;
        var it: Items = .{ .s = list };
        while (it.next()) |item| {
            if (std.meta.stringToEnum(Kind, item.name)) |k| {
                opens = k;
            } else if (std.mem.eql(u8, item.name, "begin") or std.mem.eql(u8, item.name, "begin_protected")) {
                // The envelope's own opener; a second one inside it is not
                // §28's nesting, which is encrypted.
                if (b.fields.contains("begin_protected") and b.bad == null) b.bad = "`pragma protect begin_protected inside an envelope";
                try b.fields.put(arena, "begin_protected", "");
            } else {
                try b.fields.put(arena, item.name, item.value);
            }
        }
        const kind = opens orelse return;
        var enc: Items = .{ .s = b.get("encoding") };
        var block_: Block = .{ .kind = kind, .enctype = "", .bytes = null };
        while (enc.next()) |e| {
            if (std.mem.eql(u8, e.name, "enctype")) block_.enctype = e.value;
            if (std.mem.eql(u8, e.name, "bytes")) block_.bytes = std.fmt.parseInt(usize, e.value, 10) catch null;
        }
        try b.blocks.append(arena, block_);
    }

    /// Reads `text[from..]` line by line: a `pragma protect line feeds
    /// `items`, any other line is the current block's encoded text. With
    /// `need_end`, stops at `end_protected` and returns where its line ends,
    /// or null when the text ends first; without, reads to the end.
    fn lines(b: *Body, arena: std.mem.Allocator, text: []const u8, from: usize, need_end: bool) !?usize {
        var i = from;
        while (i < text.len) {
            const nl = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
            const line = std.mem.trim(u8, text[i..nl], " \t\r");
            const was = i;
            i = @min(nl + 1, text.len);
            if (protectList(line)) |list| {
                if (std.mem.find(u8, list, "end_protected") != null) {
                    if (need_end) return nl;
                    continue;
                }
                try b.items(arena, list);
                continue;
            }
            if (line.len == 0) continue;
            if (b.blocks.items.len == 0) {
                if (b.bad == null) b.bad = "text inside the envelope before any data_block";
                continue;
            }
            const cur = &b.blocks.items[b.blocks.items.len - 1];
            if (std.mem.eql(u8, cur.enctype, "uuencode") or std.mem.eql(u8, cur.enctype, "raw")) {
                // Line structure is part of these encodings.
                try cur.text.appendSlice(arena, text[was..i]);
                if (i == text.len and (i == 0 or text[i - 1] != '\n')) try cur.text.append(arena, '\n');
            } else {
                try cur.text.appendSlice(arena, line);
            }
        }
        return if (need_end) null else text.len;
    }
};

/// Does `line` (from its `` ` `` to its end) open a §28.4.3 encoded block,
/// whose following lines are data up to the next directive?
pub fn opensBlock(line: []const u8) bool {
    var it: Items = .{ .s = protectList(line) orelse return false };
    while (it.next()) |item| if (std.meta.stringToEnum(Kind, item.name) != null) return true;
    return false;
}

/// The expression list of a `` `pragma protect `` line, or null.
fn protectList(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "`pragma")) return null;
    const rest = std.mem.trimStart(u8, line["`pragma".len..], " \t");
    if (!std.mem.startsWith(u8, rest, "protect")) return null;
    const after = rest["protect".len..];
    if (after.len != 0 and after[0] != ' ' and after[0] != '\t') return null;
    return after;
}

/// §28.4's `pragma_expression ::= pragma_keyword [ = pragma_value ]` items of
/// a comma-separated list. A string value comes without its quotes, a
/// parenthesized one without its parentheses.
const Items = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *Items) ?struct { name: []const u8, value: []const u8 } {
        const s = it.s;
        while (it.i < s.len and !isIdentStart(s[it.i])) it.i += 1;
        if (it.i >= s.len) return null;
        const start = it.i;
        it.i = identEnd(s, start);
        const name = s[start..it.i];
        while (it.i < s.len and (s[it.i] == ' ' or s[it.i] == '\t')) it.i += 1;
        if (it.i >= s.len or s[it.i] != '=') return .{ .name = name, .value = "" };
        it.i += 1;
        while (it.i < s.len and (s[it.i] == ' ' or s[it.i] == '\t')) it.i += 1;
        if (it.i >= s.len) return .{ .name = name, .value = "" };
        const v = it.i;
        switch (s[v]) {
            '"' => {
                const close = std.mem.findScalarPos(u8, s, v + 1, '"') orelse s.len;
                it.i = @min(close + 1, s.len);
                return .{ .name = name, .value = s[v + 1 .. close] };
            },
            '(' => {
                var depth: usize = 0;
                while (it.i < s.len) : (it.i += 1) {
                    if (s[it.i] == '"') it.i = std.mem.findScalarPos(u8, s, it.i + 1, '"') orelse s.len - 1;
                    if (s[it.i] == '(') depth += 1;
                    if (s[it.i] == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                const close = @min(it.i, s.len);
                it.i = @min(it.i + 1, s.len);
                return .{ .name = name, .value = s[v + 1 .. close] };
            },
            else => {
                while (it.i < s.len and s[it.i] != ',' and s[it.i] != ' ' and s[it.i] != '\t') it.i += 1;
                return .{ .name = name, .value = s[v..it.i] };
            },
        }
    }
};

fn failf(arena: std.mem.Allocator, code: diag.Code, comptime fmt: []const u8, args: anytype) !Opened {
    return .{ .fail = .{ .code = code, .why = try std.fmt.allocPrint(arena, fmt, args) } };
}

fn decrypt(arena: std.mem.Allocator, keys: Keys, b: *const Body) !Opened {
    const data = b.block(.data_block) orelse return failf(arena, .E0146, "the envelope has no data_block", .{});
    // §28.4.11's method names: VerA implements the required one. A key
    // block may carry the data_method with its session key (§28.4.10).
    var method = b.get("data_method");
    // §28.4.10: a key block carries the session key, under the key provider's
    // key; else the data key is the provider's own.
    var data_key: [8]u8 = undefined;
    if (b.block(.key_block)) |kb| {
        if (!std.mem.eql(u8, b.get("key_method"), "des-cbc"))
            return failf(arena, .E0146, "key_method=\"{s}\": VerA decrypts \"des-cbc\" only", .{b.get("key_method")});
        const k = keys.find(b.get("key_keyowner"), b.get("key_keyname")) orelse
            return failf(arena, .E0152, "no key for key_keyowner=\"{s}\", key_keyname=\"{s}\"", .{ b.get("key_keyowner"), b.get("key_keyname") });
        const session = switch (try clear(arena, keys, k, kb, "key_block")) {
            .text => |t| t,
            .fail => |f| return .{ .fail = f },
        };
        var sb: Body = .{};
        _ = try sb.lines(arena, session, 0, false);
        const dk = sb.block(.data_decrypt_key) orelse return failf(arena, .E0153, "the key_block holds no data_decrypt_key", .{});
        const raw = switch (try decode(arena, dk, "data_decrypt_key")) {
            .text => |t| t,
            .fail => |f| return .{ .fail = f },
        };
        if (raw.len != 8) return failf(arena, .E0153, "the session key is {d} bytes, not 8", .{raw.len});
        data_key = raw[0..8].*;
        if (method.len == 0) method = sb.get("data_method");
    } else {
        // An unknown method is refused before the key is looked up.
        if (!std.mem.eql(u8, method, "des-cbc"))
            return failf(arena, .E0146, "data_method=\"{s}\": VerA decrypts \"des-cbc\" only", .{method});
        data_key = keys.find(b.get("data_keyowner"), b.get("data_keyname")) orelse
            return failf(arena, .E0152, "no key for data_keyowner=\"{s}\", data_keyname=\"{s}\"", .{ b.get("data_keyowner"), b.get("data_keyname") });
    }
    if (!std.mem.eql(u8, method, "des-cbc"))
        return failf(arena, .E0146, "data_method=\"{s}\": VerA decrypts \"des-cbc\" only", .{method});
    const plain = switch (try clear(arena, keys, data_key, data, "data_block")) {
        .text => |t| t,
        .fail => |f| return .{ .fail = f },
    };

    // §28.4.12: the digest block is the digest of the cleartext, encrypted.
    if (b.block(.digest_block)) |db| {
        if (!std.mem.eql(u8, b.get("digest_key_method"), "des-cbc"))
            return failf(arena, .E0146, "digest_key_method=\"{s}\": VerA decrypts \"des-cbc\" only", .{b.get("digest_key_method")});
        const k = keys.find(b.get("digest_keyowner"), b.get("digest_keyname")) orelse
            return failf(arena, .E0152, "no key for digest_keyowner=\"{s}\", digest_keyname=\"{s}\"", .{ b.get("digest_keyowner"), b.get("digest_keyname") });
        const got = switch (try clear(arena, keys, k, db, "digest_block")) {
            .text => |t| t,
            .fail => |f| return .{ .fail = f },
        };
        const digest = b.get("digest_method");
        var want_buf: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        const want: []const u8 = if (std.mem.eql(u8, digest, "sha1")) blk: {
            std.crypto.hash.Sha1.hash(plain, &want_buf, .{});
            break :blk &want_buf;
        } else if (std.mem.eql(u8, digest, "md5")) blk: {
            std.crypto.hash.Md5.hash(plain, want_buf[0..16], .{});
            break :blk want_buf[0..16];
        } else return failf(arena, .E0146, "digest_method=\"{s}\": VerA checks \"md5\" and \"sha1\"", .{digest});
        if (!std.mem.eql(u8, got, want)) return failf(arena, .E0153, "the digest_block does not match the decrypted data_block ({s})", .{digest});
    }
    // §28.4.28.2/§28.4.29.2: a model that needs a license is not decrypted
    // or run unless "the application is licensed". VerA loads no license
    // library, so it is never licensed.
    // ponytail: refused outright; a host-provided license provider is the
    // upgrade (the front end also builds for wasm, so no dlopen here).
    if (licenseNeeded(plain)) |which|
        return failf(arena, .E0146, "{s}: VerA loads no license library, so the model is not licensed", .{which});
    return .{ .text = plain };
}

/// The §28.4.28/§28.4.29 license pragma keyword in `plain`'s first
/// `` `pragma protect `` line naming one, or null.
fn licenseNeeded(plain: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, plain, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        const rest = std.mem.cutPrefix(u8, line, "`pragma") orelse continue;
        const body = std.mem.cutPrefix(u8, std.mem.trimStart(u8, rest, " \t"), "protect") orelse continue;
        for ([_][]const u8{ "decrypt_license", "runtime_license" }) |kw|
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, body, " \t"), kw)) return kw;
    }
    return null;
}

/// Decodes `blk` and decrypts it under `key`, removing the padding.
fn clear(arena: std.mem.Allocator, keys: Keys, key: [8]u8, blk: *const Block, what: []const u8) !Opened {
    const cipher = switch (try decode(arena, blk, what)) {
        .text => |t| t,
        .fail => |f| return .{ .fail = f },
    };
    if (cipher.len == 0 or cipher.len % 8 != 0) return failf(arena, .E0153, "the {s} is {d} bytes, not a whole number of DES blocks", .{ what, cipher.len });
    const out = try arena.alloc(u8, cipher.len);
    desCbcDecrypt(key, keys.iv, cipher, out);
    // PKCS#7: the last byte n, 1 to 8, and n bytes of it. A wrong key leaves
    // this check failing 255 times in 256.
    const n = out[out.len - 1];
    if (n == 0 or n > 8) return failf(arena, .E0153, "the {s} does not decrypt under this key (bad padding)", .{what});
    for (out[out.len - n ..]) |p| if (p != n) return failf(arena, .E0153, "the {s} does not decrypt under this key (bad padding)", .{what});
    return .{ .text = out[0 .. out.len - n] };
}

/// §28.4.3's encodings, checked against the block's `bytes`.
fn decode(arena: std.mem.Allocator, blk: *const Block, what: []const u8) !Opened {
    const t = blk.text.items;
    const out: []const u8 = if (std.mem.eql(u8, blk.enctype, "base64")) blk64: {
        const d = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const buf = try arena.alloc(u8, d.calcSizeUpperBound(t.len));
        const n = d.decode(buf, t) catch return failf(arena, .E0153, "the {s} is not base64", .{what});
        break :blk64 buf[0..n];
    } else if (std.mem.eql(u8, blk.enctype, "uuencode"))
        (uudecode(arena, t) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return failf(arena, .E0153, "the {s} is not uuencoded", .{what}),
        })
    else if (std.mem.eql(u8, blk.enctype, "raw"))
        t
    else
        return failf(arena, .E0146, "enctype=\"{s}\": VerA reads \"base64\", \"uuencode\" and \"raw\"", .{blk.enctype});
    if (blk.bytes) |n| if (n != out.len) return failf(arena, .E0153, "the {s} decodes to {d} bytes, and its encoding says bytes={d}", .{ what, out.len, n });
    return .{ .text = out };
}

/// Historical uuencode lines: a length character, then four characters per
/// three bytes, each `(c - 32) & 63`. A zero-length line (`` ` ``) ends it.
fn uudecode(arena: std.mem.Allocator, text: []const u8) error{ OutOfMemory, Invalid }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const n: usize = (line[0] -% 32) & 63;
        if (n == 0) break;
        const groups = (n + 2) / 3;
        if (line.len < 1 + groups * 4) return error.Invalid;
        var got: usize = 0;
        for (0..groups) |g| {
            var v: u24 = 0;
            for (line[1 + g * 4 ..][0..4]) |c| v = (v << 6) | ((c -% 32) & 63);
            for (0..3) |k| if (got < n) {
                try out.append(arena, @truncate(v >> @intCast(16 - 8 * k)));
                got += 1;
            };
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// DES (FIPS 46-3), decryption only. The tables are the standard's, 1-based
// from the most significant bit.
// ---------------------------------------------------------------------------

const ip = [64]u8{ 58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7 };
const fp = [64]u8{ 40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25 };
const expansion = [48]u8{ 32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1 };
const pbox = [32]u8{ 16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25 };
const pc1 = [56]u8{ 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4 };
const pc2 = [48]u8{ 14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32 };
const shifts = [16]u5{ 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 };
const sbox = [8][64]u4{
    .{ 14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13 },
    .{ 15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9 },
    .{ 10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12 },
    .{ 7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14 },
    .{ 2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3 },
    .{ 12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13 },
    .{ 4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12 },
    .{ 13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11 },
};

/// Bit `table[k]` of the `width`-bit `in` (1 = most significant) becomes
/// bit k of the result, most significant first.
fn permute(in: u64, comptime width: u7, table: []const u8) u64 {
    var out: u64 = 0;
    for (table) |t| out = (out << 1) | ((in >> @intCast(width - t)) & 1);
    return out;
}

fn subkeys(key: u64) [16]u64 {
    const cd = permute(key, 64, &pc1);
    var c: u28 = @truncate(cd >> 28);
    var d: u28 = @truncate(cd);
    var ks: [16]u64 = undefined;
    for (shifts, &ks) |s, *k| {
        c = std.math.rotl(u28, c, s);
        d = std.math.rotl(u28, d, s);
        k.* = permute((@as(u64, c) << 28) | d, 56, &pc2);
    }
    return ks;
}

fn feistel(r: u64, k: u64) u64 {
    const x = permute(r, 32, &expansion) ^ k;
    var out: u64 = 0;
    for (sbox, 0..) |s, n| {
        const six: u6 = @truncate(x >> @intCast(42 - 6 * n));
        const row = ((six >> 4) & 2) | (six & 1);
        const col = (six >> 1) & 15;
        out = (out << 4) | s[@as(usize, row) * 16 + col];
    }
    return permute(out, 32, &pbox);
}

fn desDecryptBlock(ks: *const [16]u64, block: u64) u64 {
    const x = permute(block, 64, &ip);
    var l = x >> 32;
    var r = x & 0xffff_ffff;
    for (0..16) |i| {
        const t = r;
        r = l ^ feistel(r, ks[15 - i]);
        l = t;
    }
    return permute((r << 32) | l, 64, &fp);
}

/// CBC decryption of `in` (a whole number of blocks) into `out`.
fn desCbcDecrypt(key: [8]u8, iv: [8]u8, in: []const u8, out: []u8) void {
    std.debug.assert(in.len % 8 == 0 and out.len == in.len);
    const ks = subkeys(std.mem.readInt(u64, &key, .big));
    var prev = std.mem.readInt(u64, &iv, .big);
    var i: usize = 0;
    while (i < in.len) : (i += 8) {
        const c = std.mem.readInt(u64, in[i..][0..8], .big);
        std.mem.writeInt(u64, out[i..][0..8], desDecryptBlock(&ks, c) ^ prev, .big);
        prev = c;
    }
}

test "FIPS 46 DES: the textbook vector decrypts" {
    // Oracle: the worked example of FIPS 46 (key 133457799BBCDFF1,
    // 0123456789ABCDEF encrypts to 85E813540F0AB405), and openssl
    // des-ecb agrees.
    const ks = subkeys(0x133457799BBCDFF1);
    try std.testing.expectEqual(@as(u64, 0x0123456789ABCDEF), desDecryptBlock(&ks, 0x85E813540F0AB405));
}

test "uudecode reads the historical lines" {
    // Oracle: Python's binascii.b2a_uu(b"Cat") is "#0V%T\n".
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Cat", try uudecode(arena.allocator(), "#0V%T\n`\n"));
}
