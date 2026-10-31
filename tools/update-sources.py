#!/usr/bin/env python3
"""Regenerates sources.json, the release binaries the flake's versioned
packages install (`nix build '.#"0.9.0"'`), from the GitHub releases.

Shape, after mitchellh/zig-overlay's sources.json:

    { "<version>": { "date": "YYYY-MM-DD", "zig": "<the Zig it drives>",
                     "contract": { "url": ..., "sha256": <hex>[, "archive": true] },
                     "<nix system>": { "url": ..., "sha256": <hex> }, ... } }

The hashes are the release's own SHA256SUMS, so a tarball that does not match
what publish.yaml uploaded fails the Nix fetch. `zig` is the tag's
build.zig.zon `minimum_zig_version`: the Zig that `vera` spawns to build a
device must be the one its generated code was written for. `contract` is the
tag's lib/contract.zig, which the tarball (the binary alone) does not carry:
the package installs it as share/vera/contract.zig, as `zig build install` does.
From 0.21.0 that root imports lib/contract/ beside it, so `contract` is the
tag's source archive (`"archive": true`), and the package installs both from it.

Usage: tools/update-sources.py [OUT]   (default: sources.json beside tools/)
GITHUB_TOKEN, when set, lifts the API's anonymous rate limit.
"""

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = "OpenFAT/VerA"
# Nix system -> the target publish.yaml names the tarball after.
SYSTEMS = {
    "x86_64-linux": "x86_64-linux-gnu",
    "aarch64-linux": "aarch64-linux-gnu",
    "x86_64-darwin": "x86_64-macos",
    "aarch64-darwin": "aarch64-macos",
}
# v0.0.1's `vera` reads lib/contract.zig from a checkout; from v0.9.0 the
# binary embeds the sources it compiles devices against, so it runs alone.
FIRST = (0, 9, 0)


def get_bytes(url):
    req = urllib.request.Request(url)
    if "api.github.com" in url and os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    with urllib.request.urlopen(req) as r:
        return r.read()


def get(url):
    return get_bytes(url).decode()


def raw(tag, path):
    return f"https://raw.githubusercontent.com/{REPO}/{tag}/{path}"


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "sources.json")
    sources = {}
    for rel in json.loads(get(f"https://api.github.com/repos/{REPO}/releases?per_page=100")):
        tag = rel["tag_name"]
        m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
        if rel["draft"] or rel["prerelease"] or not m or tuple(map(int, m.groups())) < FIRST:
            continue
        assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
        if "SHA256SUMS" not in assets:
            continue
        sums = dict(reversed(line.split()) for line in get(assets["SHA256SUMS"]).splitlines() if line.strip())
        zon = get(raw(tag, "build.zig.zon"))
        contract = raw(tag, "lib/contract.zig")
        try:
            contract_text = get(contract)
        except urllib.error.HTTPError:  # releases before the lib/ layout (v0.11 and earlier)
            contract = raw(tag, "tools/contract.zig")
            contract_text = get(contract)
        entry = {
            "date": rel["published_at"][:10],
            "zig": re.search(r'minimum_zig_version\s*=\s*"([^"]+)"', zon).group(1),
            "contract": {"url": contract, "sha256": hashlib.sha256(contract_text.encode()).hexdigest()},
        }
        if '@import("contract/' in contract_text:  # the root and lib/contract/: the flake untars both
            archive = f"https://github.com/{REPO}/archive/refs/tags/{tag}.tar.gz"
            entry["contract"] = {"url": archive, "sha256": hashlib.sha256(get_bytes(archive)).hexdigest(), "archive": True}
        for system, target in SYSTEMS.items():
            name = f"vera-{tag}-{target}.tar.gz"
            if name in assets and name in sums:
                entry[system] = {"url": assets[name], "sha256": sums[name]}
        sources[tag[1:]] = entry
    if not sources:
        # No release since FIRST yet: the flake then has no versioned package.
        print("update-sources: no release with SHA256SUMS since v0.9.0", file=sys.stderr)
    with open(out, "w") as f:
        json.dump(sources, f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
