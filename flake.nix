{
  description = "VerA";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # nixpkgs 26.11 dropped x86_64-darwin; 26.05 still builds it.
    nixpkgs-x86_64-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    # The conformance suite: its `conform` harness and OpenVAF-Reloaded.
    conformance.url = "github:OmarSiwy/VAMS-Conformance-Suite";
    conformance.inputs.nixpkgs.follows = "nixpkgs";
    conformance.inputs.flake-utils.follows = "flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-x86_64-darwin,
      flake-utils,
      zig-overlay,
      conformance,
    }:
    let
      lib = nixpkgs.lib;

      # Release binaries by version, written by tools/update-sources.py.
      sources = lib.importJSON ./sources.json;
      latest = if sources == { } then null else lib.last (lib.sort lib.versionOlder (lib.attrNames sources));
      treeVersion = builtins.head (
        builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon)
      );

      # vera spawns zig on the code it generates.
      wrapZig = zig: "wrapProgram $out/bin/vera --prefix PATH : ${zig}/bin";

      fromSource =
        {
          lib,
          stdenv,
          makeWrapper,
          zig,
          zigJobs ? 2,
        }:
        stdenv.mkDerivation {
          pname = "vera";
          version = "${treeVersion}-unstable-${builtins.substring 0 8 (self.lastModifiedDate or "19700101")}";
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./lib
              ./src
              ./tools
            ];
          };
          nativeBuildInputs = [
            zig
            makeWrapper
          ];
          dontConfigure = true;
          dontBuild = true;
          # Zig's ad-hoc Mach-O signature does not survive strip.
          dontStrip = stdenv.hostPlatform.isDarwin;
          installPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build install -j${toString zigJobs} -Doptimize=ReleaseFast -Dcpu=baseline --prefix "$out"
            ${wrapZig zig}
          '';
          meta = {
            description = "Verilog-AMS compiler: Verilog-A to Zig device code";
            homepage = "https://github.com/OmarSiwy/VerA";
            license = lib.licenses.asl20;
            mainProgram = "vera";
          };
        };

      fromRelease =
        {
          lib,
          stdenvNoCC,
          fetchurl,
          makeWrapper,
          zig,
          version,
          source,
          contract,
        }:
        stdenvNoCC.mkDerivation {
          pname = "vera";
          inherit version;
          src = fetchurl { inherit (source) url sha256; };
          sourceRoot = ".";
          nativeBuildInputs = [ makeWrapper ];
          dontStrip = true;
          installPhase = ''
            install -Dm755 vera $out/bin/vera
            install -Dm644 ${fetchurl { inherit (contract) url sha256; }} $out/share/vera/contract.zig
            ${wrapZig zig}
          '';
          meta = {
            description = "Verilog-AMS compiler: Verilog-A to Zig device code (release binary)";
            homepage = "https://github.com/OmarSiwy/VerA";
            license = lib.licenses.asl20;
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
            mainProgram = "vera";
          };
        };

      # zig-overlay built from the consumer's pkgs.
      zigsFor =
        pkgs:
        import "${zig-overlay}/default.nix" {
          inherit pkgs;
          system = pkgs.stdenv.hostPlatform.system;
          nixpkgs = pkgs.path;
        };

      veraFor =
        pkgs:
        let
          zigs = zigsFor pkgs;
          system = pkgs.stdenv.hostPlatform.system;
          releases = lib.mapAttrs (
            version: s:
            pkgs.callPackage fromRelease {
              inherit version;
              inherit (s) contract;
              # A dev Zig is keyed by date in zig-overlay; find it by version.
              zig =
                zigs.${s.zig} or (lib.findFirst (z: lib.isDerivation z && z.version == s.zig) (throw "zig-overlay has no Zig ${s.zig}") (
                  lib.attrValues zigs
                ));
              source = s.${system};
            }
          ) (lib.filterAttrs (_: s: s ? ${system}) sources);
        in
        {
          vera = pkgs.callPackage fromSource { zig = zigs.master; };
          veraPackages =
            releases // lib.optionalAttrs (latest != null && releases ? ${latest}) { latest = releases.${latest}; };
        };

      smoke =
        pkgs: vera:
        pkgs.runCommand "vera-smoke-${vera.version}" { nativeBuildInputs = [ vera ]; } ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          vera --help > /dev/null
          test -s ${vera}/share/vera/contract.zig
          cat > r.va <<'EOF'
          module r(p, n);
            inout p, n;
            electrical p, n;
            parameter real R = 1k;
            analog I(p, n) <+ V(p, n) / R;
          endmodule
          EOF
          vera --emit-zig r.va > r.zig
          grep -q . r.zig
          vera --check r.va
          touch $out
        '';
    in
    {
      overlays.default = final: _: veraFor final;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import (if system == "x86_64-darwin" then nixpkgs-x86_64-darwin else nixpkgs) {
          inherit system;
          config.allowUnfree = true;
          config.allowDeprecatedx86_64Darwin = true;
        };
        built = veraFor pkgs;
        zig = (zigsFor pkgs).master;
        # One global cache per toolchain: two builds of the same dev version
        # from different store paths share ~/.cache/zig's build-runner entry
        # and rebuild it on every `zig build` (about a minute each).
        zigCache = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';

        # Drop what this system cannot build (availableOn alone misses `broken`).
        available = lib.filter (p: lib.meta.availableOn pkgs.stdenv.hostPlatform p && !(p.meta.broken or false));

        # OpenVAF-Reloaded, the reference Verilog-A compiler, and the suite's
        # harness, both from the conformance suite's flake.
        openvaf = conformance.packages.${system}.openvaf-r or null;
        conform = conformance.packages.${system}.conform;

        # yosys gated by hand: its check inputs hold iverilog, refused on 26.05's x86_64-darwin.
        referenceTools =
          available (
            [
              pkgs.iverilog
              pkgs.verilator
              pkgs.ngspice
              pkgs.xyce
              pkgs.python3
              conform
            ]
            ++ lib.optional (system != "x86_64-darwin") pkgs.yosys
          )
          ++ lib.optional (system == "x86_64-linux") openvaf;
      in
      {
        devShells = rec {
          default = pkgs.mkShell {
            shellHook = zigCache;
            packages = [ zig ] ++ available [
              pkgs.iverilog
              pkgs.verilator
            ];
          };
          external = pkgs.mkShell {
            shellHook = zigCache;
            packages = [ zig ] ++ referenceTools;
          };
          benchmarking = pkgs.mkShell {
            inputsFrom = [ external ];
            packages = available [
              pkgs.perf
              pkgs.inferno
            ];
          };
          docs = pkgs.mkShell {
            shellHook = zigCache;
            packages = [
              zig
              pkgs.mdbook
              pkgs.python3
            ];
          };
        };

        packages = built.veraPackages // {
          default = built.vera;
          inherit (built) vera;
        };

        checks = {
          smoke = smoke pkgs built.vera;
        }
        // lib.optionalAttrs (built.veraPackages ? latest) {
          release-smoke = smoke pkgs built.veraPackages.latest;
        };

        formatter = pkgs.nixfmt;
      }
    );
}
