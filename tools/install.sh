#!/bin/sh
# Installs a VerA release from sources.json, the same catalogue the flake's
# versioned packages install from, without nix:
#
#   curl -fsSL https://raw.githubusercontent.com/OpenFAT/VerA/main/tools/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- 0.20.0      # a pinned version
#
# Each version lives in $VERA_HOME/<version> (bin/vera, share/vera/contract.zig)
# and $VERA_BIN/vera links to the one installed last. A tarball is kept in
# $VERA_CACHE and checked against sources.json's sha256 before it is unpacked,
# so installing a version again, or switching back to it, downloads nothing.
#
#   VERA_SOURCES  sources.json to read (URL or path; default: main's)
#   VERA_HOME     default ~/.local/share/vera
#   VERA_BIN      default ~/.local/bin
#   VERA_CACHE    default ${XDG_CACHE_HOME:-~/.cache}/vera
#
# Needs sh, curl, tar and sha256sum or shasum. vera runs `zig` to build what it
# simulates: the Zig a version needs is sources.json's "zig", printed at the end.
set -eu

VERA_SOURCES=${VERA_SOURCES:-https://raw.githubusercontent.com/OpenFAT/VerA/main/sources.json}
VERA_HOME=${VERA_HOME:-$HOME/.local/share/vera}
VERA_BIN=${VERA_BIN:-$HOME/.local/bin}
VERA_CACHE=${VERA_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/vera}

die() { echo "vera install: $*" >&2; exit 1; }

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) die "no release for $(uname -s); build from source (zig build install)" ;;
esac
case $(uname -m) in
  x86_64 | amd64) cpu=x86_64 ;;
  aarch64 | arm64) cpu=aarch64 ;;
  *) die "no release for $(uname -m)" ;;
esac
system="$cpu-$os"

fetch() { # fetch URL-or-path OUT
  case $1 in
    http://* | https://* | file://*) curl -fsSL "$1" -o "$2" ;;
    *) cp "$1" "$2" ;;
  esac
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$VERA_CACHE"
catalogue="$VERA_CACHE/sources.json"
fetch "$VERA_SOURCES" "$catalogue.part" || die "cannot read $VERA_SOURCES"
mv "$catalogue.part" "$catalogue"

# sources.json is written by tools/update-sources.py with json.dump(indent=2,
# sort_keys=True): a version's key at two spaces, a system's at four, its
# url and sha256 at six. `field VERSION KEY NAME` prints one value.
field() {
  awk -v ver="$1" -v key="$2" -v name="$3" '
    /^  "[^"]*": \{/      { split($0, a, "\""); v = a[2]; k = "" }
    /^    "[^"]*": \{/    { split($0, a, "\""); k = a[2] }
    /^    "[^"]*": "/     { split($0, a, "\""); if (v == ver && key == "" && a[2] == name) print a[4] }
    /^      "[^"]*": "/   { split($0, a, "\""); if (v == ver && k == key && a[2] == name) print a[4] }
  ' "$catalogue"
}

version=${1:-}
if [ -z "$version" ]; then
  version=$(awk '/^  "[^"]*": \{/ { split($0, a, "\""); print a[2] }' "$catalogue" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  [ -n "$version" ] || die "$VERA_SOURCES lists no release"
fi
version=${version#v}
url=$(field "$version" "$system" url)
want=$(field "$version" "$system" sha256)
[ -n "$url" ] && [ -n "$want" ] || die "sources.json has no $system build of $version"

tarball="$VERA_CACHE/vera-$version-$system.tar.gz"
if [ ! -f "$tarball" ] || [ "$(sha256 "$tarball")" != "$want" ]; then
  echo "vera install: downloading $version for $system"
  fetch "$url" "$tarball.part" || die "cannot download $url"
  got=$(sha256 "$tarball.part")
  [ "$got" = "$want" ] || { rm -f "$tarball.part"; die "$url: sha256 $got, sources.json says $want"; }
  mv "$tarball.part" "$tarball"
else
  echo "vera install: $version for $system is cached"
fi

dest="$VERA_HOME/$version"
mkdir -p "$dest/bin" "$dest/share/vera"
tar xzf "$tarball" -C "$dest/bin" vera
contract_url=$(field "$version" contract url)
contract_sha=$(field "$version" contract sha256)
if [ -n "$contract_url" ] && [ -n "$contract_sha" ]; then
  c="$dest/share/vera/contract.zig"
  if [ ! -f "$c" ] || [ "$(sha256 "$c")" != "$contract_sha" ]; then
    fetch "$contract_url" "$c.part" || die "cannot download $contract_url"
    [ "$(sha256 "$c.part")" = "$contract_sha" ] || { rm -f "$c.part"; die "$contract_url: sha256 mismatch"; }
    mv "$c.part" "$c"
  fi
fi

mkdir -p "$VERA_BIN"
ln -sf "$dest/bin/vera" "$VERA_BIN/vera"
echo "vera install: $VERA_BIN/vera -> $dest/bin/vera"
zig=$(field "$version" "" zig)
[ -n "$zig" ] && echo "vera install: $version runs designs with Zig $zig (zig on PATH, or VERA_ZIG)"
case ":$PATH:" in *":$VERA_BIN:"*) ;; *) echo "vera install: add $VERA_BIN to PATH" ;; esac
