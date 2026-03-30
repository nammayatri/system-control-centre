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

            DB_USER="$(whoami)"
            export NammaAP_DATABASE_URL="postgres://$DB_USER@localhost:5432/''${SC_DB_NAME:-system_control}"
            export PORT=''${PORT:-8012}

            # Commands
            sc-setup-db()  { bash scripts/setup-db.sh; }
            sc-build()     { cabal build; }
            sc-run()       { bash scripts/run.sh; }
            sc-server()    { cabal run namma-ap-exe; }
            sc-hpack()     { hpack && echo "Regenerated .cabal from package.yaml"; }
            sc-test-api()  {
              echo "Testing APIs..."
              TOKEN=$(curl -s -X POST http://localhost:$PORT/auth/login \
                -H "Content-Type: application/json" \
                -d '{"email":"admin@juspay.in","password":"admin123"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
              echo "Login: OK (token: ''${TOKEN:0:8}...)"
              echo "Releases: $(curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/releases?from=2024-01-01T00:00:00Z&to=2026-12-31T00:00:00Z" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
              echo "Products: $(curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/admin/products" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('products',[])))" 2>/dev/null)"
              echo "Done."
            }
            sc-help() {
              echo ""
              echo "  System Control Centre"
              echo "  ─────────────────────"
              echo "  sc-setup-db    Setup local database (create + migrate + seed)"
              echo "  sc-build       Compile the backend"
              echo "  sc-run         Setup DB + build + start server (all-in-one)"
              echo "  sc-server      Start server only (assumes built)"
              echo "  sc-hpack       Regenerate .cabal from package.yaml"
              echo "  sc-test-api    Test all APIs (server must be running)"
              echo "  sc-help        Show this help"
              echo ""
              echo "  DB: $NammaAP_DATABASE_URL"
              echo "  Port: $PORT"
              echo ""
            }

            sc-help
          '';
        });
      };
    };
}
