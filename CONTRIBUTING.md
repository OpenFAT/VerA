# Contributing

**Status: maintained** by one person. Issues are read; there is no stale bot,
so an open issue stays open until it is fixed or answered.

## Branches

`main` is the only long-lived branch, and it is always green: every change
lands through a pull request whose merge result passed the required checks
(`test`, `cross`, `conformance`, `external`, `nix`). There is no `dev` branch.

## Which VerA to follow

- **Pinned**: a commit and hash in `build.zig.zon` (`zig fetch --save`). Nothing on `main` can move it.
- **Released**: a tag's tarballs with `SHA256SUMS`, `vera.wasm`, or the flake's `#latest`, which follows `sources.json` after every release.
- **Head**: `nix run github:OpenFAT/VerA`. It is `main` at that second, which is gated, but it is not a release.

Versions are 0.y.z: a minor bump may break, a patch may not. The Zig
VerA is built with is part of the release (`sources.json`), because `vera`
runs `zig` on the code it emits.

## A change

1. `nix develop -c zig build check --watch -fincremental` while editing.
2. A fix comes with the fixture that reproduces it, and with the oracle that
   would have caught its whole class (`TESTING.md`).
3. `nix develop -c zig build test` passes locally.
4. One line in `CHANGELOG.md`, citing the issue; numbers measured, not typed.

## A release

1. Run the `release-prep` workflow with `vX.Y.Z`
   (`gh workflow run release-prep.yaml -f version=vX.Y.Z`). It runs
   `tools/conformance.py --changelog vX.Y.Z`, which bumps `build.zig.zon` and
   `contract.vera_version` together, measures the VAMS Conformance Suite and
   dates the `## Unreleased` section, re-blesses the doc transcript that prints
   the version (`tools/doctest.py --update`), and opens `release: vX.Y.Z`.
2. That pull request is a bot's: approve its workflow runs, then the pull
   request, as in step 4. It auto-merges when its checks pass.
3. Tag `vX.Y.Z` on the merge commit and push the tag. `publish.yaml` re-checks
   the CHANGELOG score, builds every target, publishes the assets and opens
   `nix: sources.json for vX.Y.Z` as `github-actions[bot]`.
4. That pull request waits for a maintainer, twice: approve its workflow runs
   (they start `action_required`, being a bot's), then approve the pull request
   (the "main is green" ruleset requires a review of a bot's changes). It
   auto-merges when its checks pass; the flake's `#latest` and
   `tools/install.sh` follow it.

## Reporting a bug

The input that triggers it, the exact command, what `vera` printed, and
`vera --version`. A minimal input gets fixed first.
