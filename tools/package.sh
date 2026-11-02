#!/usr/bin/env bash
# The packages a release ships, from what publish.yaml's build loop leaves in
# the current directory: out/<target>/ (each target's `zig build install`
# prefix) and vera-v<VERSION>-<target>.tar.gz (each target's binary).
#
#   tools/package.sh 0.20.0           # build them
#   tools/package.sh --check 0.20.0   # install each x86_64 one with its own
#                                     # package manager in its distribution
#                                     # (docker) and require `vera <V>`
#
# writes, beside them:
#   vera_<V>-1_{amd64,arm64}.deb, vera-<V>-1.{x86_64,aarch64}.rpm and
#   vera-<V>-1-{x86_64,aarch64}.pkg.tar.zst   (nfpm, packaging/nfpm.yaml)
#   PKGBUILD                                  (AUR vera-bin, packaging/aur/)
#   vera.rb                                   (Homebrew, packaging/homebrew/)
# The PKGBUILD and the formula download the release tarballs, so their
# sha256 fields are those tarballs' own; the LICENSE field is this tree's file,
# which the tag serves from raw.githubusercontent.com, and the contract field is
# the tag's source archive (lib/contract.zig and the lib/contract/ it imports),
# downloaded here once the tag is pushed (all zeros before, on a pull request).
# Needs nfpm on PATH (`nix shell nixpkgs#nfpm`).
set -euo pipefail
check=; [ "${1:-}" = --check ] && { check=1; shift; }
v=${1:?usage: tools/package.sh [--check] VERSION}
v=${v#v}
root=$(cd "$(dirname "$0")/.." && pwd)

if [ -n "$check" ]; then
  run() { # image, install command
    got=$(docker run --rm -v "$PWD:/p:ro" "$1" sh -c "$2 >/dev/null 2>&1 && vera --version")
    echo "$1: ${got:-(no output)}"; [ "$got" = "vera $v" ]
  }
  run ubuntu:24.04 "apt-get install -y -qq /p/vera_${v}-1_amd64.deb"
  run fedora:latest "dnf install -y -q /p/vera-${v}-1.x86_64.rpm"
  run archlinux:latest "pacman -U --noconfirm /p/vera-${v}-1-x86_64.pkg.tar.zst"
  exit
fi

for t in x86_64-linux-gnu:amd64 aarch64-linux-gnu:arm64; do
  target=${t%%:*} arch=${t##*:}
  [ -d "out/$target" ] || { echo "package.sh: out/$target is missing" >&2; exit 1; }
  rm -rf pkg && cp -r "out/$target" pkg && cp "$root/LICENSE" pkg/LICENSE
  for p in deb rpm archlinux; do
    VERA_VERSION=$v NFPM_ARCH=$arch nfpm package -f "$root/packaging/nfpm.yaml" -p "$p" -t .
  done
done
rm -rf pkg

sha() { sha256sum "$1" | cut -d' ' -f1; }
tarball() { local f="vera-v$v-$1.tar.gz"; [ -f "$f" ] || { echo "package.sh: $f is missing" >&2; exit 1; }; sha "$f"; }
# Before the tag is pushed (a pull request's cross.yaml run) the archive does
# not exist yet: the recipes then carry an all-zero hash, which no download
# matches, and say so. publish.yaml runs on the pushed tag and hashes the real one.
if body=$(curl -fsSL "https://github.com/OpenFAT/VerA/archive/refs/tags/v$v.tar.gz" | sha256sum); then
  archive=${body%% *}
else
  archive=0000000000000000000000000000000000000000000000000000000000000000
  echo "package.sh: tag v$v is not pushed; the recipes' contract archive hash is all zeros" >&2
fi
zig=$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' "$root/build.zig.zon")
render() {
  sed -e "s|@VERSION@|$v|g" -e "s|@ZIG@|$zig|g" \
      -e "s|@X86_64_LINUX_SHA256@|$(tarball x86_64-linux-gnu)|g" \
      -e "s|@AARCH64_LINUX_SHA256@|$(tarball aarch64-linux-gnu)|g" \
      -e "s|@X86_64_MACOS_SHA256@|$(tarball x86_64-macos)|g" \
      -e "s|@AARCH64_MACOS_SHA256@|$(tarball aarch64-macos)|g" \
      -e "s|@CONTRACT_ARCHIVE_SHA256@|$archive|g" \
      -e "s|@LICENSE_SHA256@|$(sha "$root/LICENSE")|g" "$1"
}
render "$root/packaging/aur/PKGBUILD.in" > PKGBUILD
render "$root/packaging/homebrew/vera.rb.in" > vera.rb
if grep -n '@[A-Z0-9_]*@' PKGBUILD vera.rb; then echo "package.sh: a template field was left unfilled" >&2; exit 1; fi
ls -1 vera_*.deb vera-*.rpm vera-*.pkg.tar.zst PKGBUILD vera.rb
