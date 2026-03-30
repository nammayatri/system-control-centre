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
            git
            cacert
            pcre
            openssl
            zlib
            zstd
            pkg-config
            postgresql
          ];
        });
      };
    };
}
