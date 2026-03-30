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

        # Quick-run app: nix run .#run
        apps.run = {
          type = "app";
          program = "${pkgs.writeShellScript "run-system-control" ''
            cd ${builtins.toString ./.}
            exec bash scripts/run.sh "$@"
          ''}";
        };

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
            gnumake

            # Formatting
            haskellPackages.fourmolu

            # DB
            postgresql

            # Dhall
            dhall
            dhall-json

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

            DB_USER="$(whoami)"
            export NammaAP_DATABASE_URL="postgres://$DB_USER@localhost:5432/''${SC_DB_NAME:-system_control}"
            export PORT=''${PORT:-8012}

            # Add bin/ scripts to PATH (works with direnv, unlike shell functions)
            export PATH="$PWD/bin:$PATH"

            sc-help
          '';
        });
      };
    };
}
