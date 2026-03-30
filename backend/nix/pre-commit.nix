{
  hooks = {
    # Haskell formatting
    fourmolu.enable = true;

    # Remove trailing whitespace from Haskell files
    trailing-whitespace = {
      enable = true;
      types = [ "haskell" ];
    };

    # Nix linting
    nil.enable = true;

    # Dhall formatting
    dhall-format.enable = true;
  };
}
