# Installing

VerA is one executable, `vera`. To build devices it runs the Zig compiler,
so whatever you install, `vera` needs **Zig master (0.18.0-dev)** on its `PATH` (or named
with `--zig PATH`) for `--check`, `--emit-exe`, `--run` and `--emit-so`. The
front-end modes (`--lint`, `--emit-zig`, `--emit-verilog`, `--explain`) need
nothing but `vera`.

## With Nix

```sh
nix run github:OmarSiwy/VerA -- model.va --lint     # build from source and run
nix profile add github:OmarSiwy/VerA                # install it (`nix profile install` on older Nix)
nix profile add 'github:OmarSiwy/VerA#"0.13.0"'     # a release binary, pinned
```

The packaged `vera` is wrapped with the Zig it generates code for, so
`--run` and `--emit-so` work with no Zig of your own, and it installs the
device contract of its own version as `share/vera/contract.zig`. As a flake
input, take `vera.packages.${system}.default` (built from source) or
`."0.13.0"` and `latest` (release binaries, listed in the repository's
`sources.json`), or apply `vera.overlays.default` to get `pkgs.vera` and
`pkgs.veraPackages.<version>`. The flake covers x86_64 and aarch64 Linux and
macOS.

`vera` writes its scratch tree under `.zig-cache/` in the working directory
and uses Zig's global cache, so inside a Nix build sandbox (no `$HOME`), run
it in a writable directory with
`export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.

## A release binary

Each GitHub release attaches a `vera` for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-macos`, `aarch64-macos` and `x86_64-windows`,
with a `SHA256SUMS` file:

```sh
curl -LO https://github.com/OmarSiwy/VerA/releases/download/v0.13.0/vera-v0.13.0-x86_64-linux-gnu.tar.gz
tar xzf vera-v0.13.0-x86_64-linux-gnu.tar.gz      # one file: vera
./vera --help
```

Install the Zig that release targets beside it, from
<https://ziglang.org/download/>: 0.18.0-dev.349+d924f83bf for v0.13.0 (the repository's
`sources.json` records each release's). The release's device contract is
`lib/contract.zig` at its tag.

## From source

```sh
git clone https://github.com/OmarSiwy/VerA && cd VerA
zig build -Doptimize=ReleaseFast
```

The binary is `zig-out/bin/vera`. The build also installs the device
contract your simulator compiles against at
`zig-out/share/vera/contract.zig` (`--prefix DIR` installs both under
`DIR`). The repository's `nix develop` shell has the exact Zig.

## Checking the install

`vera --help` lists every flag ([the command line](cli.md) explains them).
A model with no errors lints silently and exits 0; the [first chapter of the
tutorial](../learn/getting-started.md) goes on from there.

## Editor support

There is no VerA language server. Verilog-AMS editor modes that highlight
`.va` files work unchanged, and `vera --lint --diagnostics=json` gives a
machine-readable list of diagnostics for an editor integration
([Diagnostics](diagnostics.md)).
