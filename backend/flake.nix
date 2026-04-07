{
  description = "System Control Centre — release orchestration with RBAC";

  nixConfig = {
    allow-import-from-derivation = true;
  };

  inputs = {
    common.url = "github:nammayatri/common";
    nixpkgs.follows = "common/nixpkgs";
    haskell-flake.follows = "common/haskell-flake";

    # Newer nixpkgs only used for nodejs_22 (frontend vite needs ≥ 20.19)
    nixpkgs-latest.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # Pinned to NammaYatri-compatible rev (newer versions break with common's process-compose-flake)
    services-flake.url = "github:juspay/services-flake/b93a612aa7057fbb395c79a915672f9b6567ffea";

    euler-hs = {
      url = "github:nammayatri/euler-hs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.haskell-flake.follows = "haskell-flake";
    };
  };

  outputs = inputs:
    inputs.common.lib.mkFlake { inherit inputs; } {
      perSystem = { self', pkgs, lib, config, system, ... }:
        let
          pkgsLatest = import inputs.nixpkgs-latest { inherit system; };
        in
        {
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

          # ─────────────────────────────────────────────────────────────
          # process-compose: one command starts everything
          #
          #   nix run .#dev
          #
          # Brings up:
          #   - PostgreSQL (port 5434, data in ./.local/data/pg)
          #   - DB init: creates schema + applies migrations
          #   - Backend (ghcid hot-reload on port 8012)
          #   - Frontend (vite dev server on port 5173)
          # ─────────────────────────────────────────────────────────────
          process-compose."dev" = { config, ... }: {
            imports = [
              inputs.services-flake.processComposeModules.default
            ];

            services.postgres."pg" = {
              enable = true;
              port = 5434;
              listen_addresses = "127.0.0.1";
              dataDir = "./.local/data/pg";
              createDatabase = false;
            };

            settings.processes = {
              # Create DB + run schema seed + apply migrations (idempotent)
              db-init = {
                command = pkgs.writeShellApplication {
                  name = "sc-db-init";
                  runtimeInputs = [ pkgs.postgresql ];
                  text = ''
                    export PGHOST="$PWD/.local/data/pg"
                    export PGPORT=5434
                    export PGDATABASE=postgres
                    if ! psql -lqt | cut -d \| -f 1 | grep -qw system_control; then
                      echo "[db-init] creating system_control database"
                      createdb system_control
                      export PGDATABASE=system_control
                      psql -v ON_ERROR_STOP=1 -f ${./dev/sql-seed/pre-init.sql}
                      psql -v ON_ERROR_STOP=1 -f ${./dev/sql-seed/system-control-seed.sql}
                      echo "[db-init] schema seeded"
                    else
                      echo "[db-init] system_control exists, skipping seed"
                      export PGDATABASE=system_control
                    fi
                    shopt -s nullglob
                    for f in ${./dev/migrations/system-control}/*.sql; do
                      echo "[migrate] $(basename "$f")"
                      psql -v ON_ERROR_STOP=0 -f "$f" 2>&1 | grep -v "^NOTICE:" || true
                    done
                    echo "[db-init] done"
                  '';
                };
                depends_on.pg.condition = "process_healthy";
              };

              # Backend with ghcid hot-reload.
              # Inherits PATH from the surrounding `nix develop` shell so it picks up
              # GHC, cabal-install, ghcid, fourmolu, etc. from haskell-flake's devShell.
              backend = {
                command = ''
                  user=$(whoami)
                  export SC_DATABASE_URL="postgres://$user@127.0.0.1:5434/system_control"
                  export PORT=8012
                  exec ghcid \
                    --command "cabal repl exe:namma-ap-exe" \
                    --test "Main.main" \
                    --restart=package.yaml \
                    --restart=dhall-configs/system-control.dhall \
                    --reload=src
                '';
                depends_on.db-init.condition = "process_completed_successfully";
              };

              # Frontend (vite dev server) — runs in ../frontend/
              frontend = {
                command = ''
                  export PATH="${pkgsLatest.nodejs_22}/bin:$PATH"
                  cd ../frontend
                  if [ ! -d node_modules ]; then
                    echo "[frontend] installing dependencies..."
                    npm install
                  fi
                  exec npm run dev
                '';
                depends_on.backend.condition = "process_started";
              };
            };
          };

          # Override treefmt: swap ormolu for fourmolu (this project uses .fourmolu.yaml)
          treefmt.config = {
            programs.ormolu.enable = lib.mkForce true;
            programs.ormolu.package = lib.mkForce pkgs.haskellPackages.fourmolu;
          };

          packages.default = self'.packages.namma-ap;

          # nix run .#dev → starts the full process-compose stack
          apps.dev = {
            type = "app";
            program = "${self'.packages.dev}/bin/dev";
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
              ghcid

              # Formatting
              haskellPackages.fourmolu

              # DB client (server is auto-started by process-compose)
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

              export SC_DATABASE_URL="postgres://$(whoami)@127.0.0.1:5434/system_control"
              export PORT=''${PORT:-8012}

              # Add bin/ scripts to PATH (works with direnv, unlike shell functions)
              export PATH="$PWD/bin:$PATH"

              sc-help
            '';
          });
        };
    };
}
