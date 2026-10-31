#!/usr/bin/env python3
"""Mechanical rows of the code-style checklist, over every .zig and .rs file under a path.

Checks: `//!` header first, header Contents names every `pub` item, file-level order
(imports, pub types, private types, pub fns, separator, private fns, tests), separator
present before private fns, code lines before tests <= MAX_CODE_LINES, and no source
folder holding a single file. Prints `path:line: rule: message` per violation and exits 1
if any. `--self-test` runs the built-in cases.

Usage: check_style.py <dir-or-file>... | --self-test
"""

import os
import re
import sys
import tempfile

MAX_CODE_LINES = 500
SEPARATOR = re.compile(r"^// -+ private -+$")
SKIP_DIRS = {".git", "target", "zig-out", ".zig-cache", "zig-cache", "zig-pkg", "node_modules"}
CARGO_DIRS = {"src", "tests", "benches", "examples"}

IMPORT, PUB_TYPE, PRIV_TYPE, PUB_FN, SEP, PRIV_FN, TEST = range(7)
RANK_NAME = ["import", "pub type", "private type", "pub fn", "separator", "private fn", "test"]

RS_PUB_NAME = re.compile(r"^\s*pub(?:\([^)]*\))?\s+(?:unsafe\s+|async\s+|const\s+(?=fn))*"
                         r"(?:fn|struct|enum|trait|type|const|static|union)\s+(\w+)")
ZIG_PUB_NAME = re.compile(r"^\s*pub\s+(?:inline\s+|export\s+|extern\s+)*(?:fn|const|var)\s+(@?\w+)")


def classify_zig(line):
    if line.startswith("test ") or line.startswith("test{"):
        return TEST
    if re.match(r"^(pub\s+)?(const|var)\s+\w+(\s*:[^=]+)?\s*=\s*@import\(", line):
        return IMPORT
    if re.match(r"^const\s+\w+\s*=\s*[A-Za-z_]\w*(\.\w+)+;\s*$", line):  # alias: `const Allocator = std.mem.Allocator;`
        return IMPORT
    if re.match(r"^pub\s+(inline\s+|export\s+)*fn\b", line):
        return PUB_FN
    if re.match(r"^(inline\s+|export\s+)*fn\b", line):
        return PRIV_FN
    if line.startswith("pub "):
        return PUB_TYPE
    if re.match(r"^(const|var|threadlocal)\s", line):
        return PRIV_TYPE
    if re.match(r"^@?\w+\s*:", line):  # file-as-struct field
        return PUB_TYPE
    return None


def zig_items(lines):
    for n, line in enumerate(lines, 1):
        if SEPARATOR.match(line):
            yield n, SEP
        elif line and not line[0].isspace() and not line.startswith("//") and line[0] != "}":
            rank = classify_zig(line)
            if rank is not None:
                yield n, rank


def rs_block_end(lines, start):
    """Index of the line closing the column-0 block opened at `start`."""
    for i in range(start, len(lines)):
        if lines[i].startswith("}"):
            return i
        if i == start and lines[i].rstrip().endswith(";"):
            return i
    return len(lines) - 1


def rs_items(lines):
    i = 0
    pending_test = False
    while i < len(lines):
        line = lines[i]
        n = i + 1
        if SEPARATOR.match(line):
            yield n, SEP
        elif line.startswith("#[cfg(test)]"):
            pending_test = True
        elif not line or line[0].isspace() or line.startswith("//") or line.startswith("#") or line[0] == "}":
            pass
        else:
            rank = None
            if pending_test:
                rank = TEST
            elif re.match(r"^(pub(\([^)]*\))?\s+)?(use|extern\s+crate)\b", line) or re.match(r"^(pub(\([^)]*\))?\s+)?mod\s+\w+\s*;", line):
                rank = IMPORT
            elif re.match(r"^impl\b", line) or re.match(r"^unsafe\s+impl\b", line):
                end = rs_block_end(lines, i)
                body = lines[i:end + 1]
                is_trait = re.match(r"^(unsafe\s+)?impl\b[^{]*\bfor\b", line) is not None
                has_pub = any(re.match(r"^\s+pub(\([^)]*\))?\s", b) for b in body)
                rank = PUB_FN if (is_trait or has_pub) else PRIV_FN
                yield n, rank
                i = end + 1
                pending_test = False
                continue
            elif re.match(r"^pub(\([^)]*\))?\s+(const\s+|async\s+|unsafe\s+|extern\s+\S+\s+)*fn\b", line):
                rank = PUB_FN
            elif re.match(r"^(const\s+|async\s+|unsafe\s+|extern\s+\S+\s+)*fn\b", line):
                rank = PRIV_FN
            elif line.startswith("pub"):
                rank = PUB_TYPE
            elif re.match(r"^(struct|enum|union|trait|type|const|static|macro_rules!)", line):
                rank = PRIV_TYPE
            if rank is not None:
                yield n, rank
            pending_test = False
            end = rs_block_end(lines, i) if line.rstrip().endswith("{") else i
            i = end + 1
            continue
        i += 1


def check_file(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    lines = text.split("\n")
    zig = path.endswith(".zig")
    out = []

    first = next((k for k, l in enumerate(lines) if l.strip()), None)
    if first is None:
        return out
    if not lines[first].startswith("//!"):
        out.append((first + 1, "header", "file must open with a `//!` header (in -> out, cites, Contents)"))
    header = []
    for l in lines[first:]:
        if l.startswith("//!"):
            header.append(l)
        elif l.startswith("#!") or not l.strip():
            continue
        else:
            break
    header_text = "\n".join(header)

    items = list((zig_items if zig else rs_items)(lines))
    test_line = next((n for n, r in items if r == TEST), len(lines) + 1)

    pub_name = ZIG_PUB_NAME if zig else RS_PUB_NAME
    for n, l in enumerate(lines[:test_line - 1], 1):
        m = pub_name.match(l)
        if m and not re.search(r"\b" + re.escape(m.group(1).lstrip("@")) + r"\b", header_text):
            out.append((n, "contents", f"`{m.group(1)}` is pub but missing from the header's Contents"))

    highest = -1
    seen_sep = False
    for n, rank in items:
        if rank == SEP:
            seen_sep = True
        if rank == PRIV_FN and not seen_sep:
            out.append((n, "separator", "private fn above `// ---- private ----`"))
            seen_sep = True  # report once
        if rank < highest and not (rank == SEP and highest == SEP):
            out.append((n, "order", f"{RANK_NAME[rank]} after {RANK_NAME[highest]}"))
        highest = max(highest, rank)

    code = sum(1 for l in lines[:test_line - 1] if l.strip() and not l.lstrip().startswith("//"))
    if code > MAX_CODE_LINES:
        out.append((1, "size", f"{code} code lines before tests (max {MAX_CODE_LINES}): split along its transforms"))
    return out


def check_folders(root):
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not x.startswith(".")]
        src = [f for f in files if f.endswith((".zig", ".rs"))]
        if dirs or len(files) != 1 or not src or os.path.abspath(d) == os.path.abspath(root):
            continue
        parent = os.path.dirname(d)
        if os.path.basename(d) in CARGO_DIRS and os.path.exists(os.path.join(parent, "Cargo.toml")):
            continue
        if src[0] == "mod.rs" and "tests" in os.path.relpath(d, root).split(os.sep):
            continue  # tests/common/mod.rs: keeps Cargo from building the helpers as a test crate
        out.append((os.path.join(d, src[0]), 1, "folder", f"`{d}` holds one file: flatten it"))
    return out


def run(paths):
    found = []
    for p in paths:
        if os.path.isfile(p):
            found += [(p, n, r, m) for n, r, m in check_file(p)]
            continue
        found += check_folders(p)
        for d, dirs, files in os.walk(p):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not x.startswith(".")]
            for f in sorted(files):
                if f.endswith((".zig", ".rs")):
                    fp = os.path.join(d, f)
                    found += [(fp, n, r, m) for n, r, m in check_file(fp)]
    for fp, n, r, m in sorted(found):
        print(f"{fp}:{n}: {r}: {m}")
    return 1 if found else 0


def self_test():
    good_zig = """//! Demo: bytes -> count.
//! Contents: `pub const Count`, `pub fn count(src: []const u8) Count`
const std = @import("std");

pub const Count = struct { n: u32 };

const Scratch = struct { i: u32 };

pub fn count(src: []const u8) Count {
    return .{ .n = helper(src) };
}

// ---- private ----

fn helper(src: []const u8) u32 {
    return @intCast(src.len);
}

test "count" {}
"""
    bad_zig = """const std = @import("std");
//! late header
fn helper() void {}
pub fn count() void {}
"""
    good_rs = """//! Demo: bytes -> count.
//! Contents: `pub struct Count`, `pub fn count(src: &[u8]) -> Count`, `Count::get`

use std::fmt;

pub struct Count(u32);

pub fn count(src: &[u8]) -> Count {
    Count(helper(src))
}

impl Count {
    pub fn get(&self) -> u32 {
        self.0
    }
}

impl fmt::Display for Count {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ---- private ----

fn helper(src: &[u8]) -> u32 {
    src.len() as u32
}

impl Count {
    fn bump(&mut self) {
        self.0 += 1;
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {}
}
"""
    bad_rs = """//! Contents: `pub fn count`
pub fn count() {}
pub struct Hidden;
fn helper() {}
"""
    with tempfile.TemporaryDirectory() as t:
        def write(rel, body):
            p = os.path.join(t, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(body)
            return p

        assert check_file(write("good.zig", good_zig)) == [], check_file(os.path.join(t, "good.zig"))
        assert check_file(write("good.rs", good_rs)) == [], check_file(os.path.join(t, "good.rs"))
        bad = {r for _, r, _ in check_file(write("bad.zig", bad_zig))}
        assert bad == {"header", "contents", "separator", "order"}, bad
        bad = {r for _, r, _ in check_file(write("bad.rs", bad_rs))}
        assert bad == {"contents", "order", "separator"}, bad
        big = "//! Big.\n" + "".join(f"pub const c{i} = {i};\n" for i in range(MAX_CODE_LINES + 1))
        assert "size" in {r for _, r, _ in check_file(write("big.zig", big))}

        write("tree/lone/only.zig", good_zig)
        write("tree/pair/a.zig", good_zig)
        write("tree/pair/b.zig", good_zig)
        write("tree/crate/Cargo.toml", "")
        write("tree/crate/src/lib.rs", good_rs)
        write("tree/crate/tests/common/mod.rs", good_rs)
        write("tree/crate/tests/a.rs", good_rs)
        flagged = [m for _, _, _, m in check_folders(os.path.join(t, "tree"))]
        assert len(flagged) == 1 and "lone" in flagged[0], flagged
    print("check_style: self-test passed")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1])
        sys.exit(2)
    sys.exit(run(sys.argv[1:]))
