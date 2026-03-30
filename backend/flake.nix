{
  description = "System Control Centre — release orchestration with RBAC";

  nixConfig = {
    allow-import-from-derivation = true;
  };

  inputs = {
    common.url = "github:nammayatri/common";
    nixpkgs.follows = "common/nixpkgs";
    haskell-flake.follows = "common/haskell-flake";

    euler-hs = {
      url = "github:nammayatri/euler-hs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.haskell-flake.follows = "haskell-flake";
    };
  };

  outputs = inputs:
    inputs.common.lib.mkFlake { inherit inputs; } {
      perSystem = { self', pkgs, lib, config, ... }: {
        haskellProjects.default = {
          imports = [
            inputs.euler-hs.haskellFlakeProjectModules.output
          ];
          settings = {
            int-cast.broken = false;
            euler-hs = {
              check = false;
              jailbreak = true;
              haddock = false;
              libraryProfiling = false;
            };
          };
          autoWire = [ "packages" "checks" "apps" ];
        };

        process-compose = { };

        packages.default = self'.packages.namma-ap;

        devShells.default = lib.mkForce (pkgs.mkShell {
          name = "system-control-shell";
          inputsFrom = [
            config.haskellProjects.default.outputs.devShell
          ];
          packages = with pkgs; [
            # Dev tools
            git
            cacert
            hpack

            # DB
            postgresql

            # System libs
            pcre
            openssl
            zlib
            zstd
            pkg-config
          ];
          shellHook = ''
            export CABAL_DIR="$PWD/.cabal-dir"
            export CABAL_CONFIG="$CABAL_DIR/config"
            mkdir -p "$CABAL_DIR"
            if [ ! -f "$CABAL_CONFIG" ]; then
              cabal user-config init -f 2>/dev/null || true
            fi
            export NammaAP_DATABASE_URL="postgres://vijaygupta@localhost:5432/system_control"
            export PORT=8012
            echo ""
            echo "  System Control Centre"
            echo "  ─────────────────────"
            echo "  cabal build              — compile"
            echo "  cabal run namma-ap-exe   — start server on :$PORT"
            echo "  hpack                    — regenerate .cabal from package.yaml"
            echo "  DB: $NammaAP_DATABASE_URL"
            echo ""
          '';
        });
      };
    };
}
