{
  description = "Namma AP release orchestration";

  inputs = {
    euler-hs.url = "github:nammayatri/euler-hs";
    common.follows = "euler-hs/common";
    nixpkgs.follows = "common/nixpkgs";
    flake-parts.follows = "common/flake-parts";
    haskell-flake.follows = "common/haskell-flake";
  };

  outputs = inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;
      imports = [
        inputs.common.flakeModules.ghc927
        inputs.haskell-flake.flakeModule
      ];
      perSystem = { self', config, pkgs, lib, ... }: {
        haskellProjects.default = {
          projectFlakeName = "namma-ap";
          imports = [ inputs.euler-hs.haskellFlakeProjectModules.output ];
          basePackages = config.haskellProjects.ghc927.outputs.finalPackages;
          settings = {
            int-cast.broken = false;
          };
          autoWire = [ "packages" "checks" "apps" "devShells" ];
        };
        devShells.default = lib.mkForce (pkgs.mkShell {
          inputsFrom = [ config.haskellProjects.default.outputs.devShell ];
          packages = with pkgs; [
            git
            cacert
            mariadb
            mysql80
            pcre
            openssl
            zlib
            zstd
            pkg-config
          ];
        });
        packages.default = self'.packages.namma-ap;
      };
    };
}
