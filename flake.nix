{
  description = "Nix built with profile-guided optimization and evaluation speedups";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      optimizedFor =
        pkgs:
        import ./nix {
          inherit pkgs;
          root = ./.;
        };
      forSystems = f: lib.genAttrs systems (system: f (optimizedFor nixpkgs.legacyPackages.${system}));
    in
    {
      packages = forSystems (o: o.packages);

      checks = forSystems (o: o.checks);

      overlays.default =
        final: _prev:
        let
          o = optimizedFor final;
        in
        {
          inherit (o.packages) nix-optimized nix-optimized-plain;
          nixOptimized = removeAttrs o.packages [ "default" ];
        };

      formatter = lib.genAttrs systems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
