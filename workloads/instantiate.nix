{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  drvOf =
    x:
    let
      r = builtins.tryEval (if lib.isDerivation x then x.drvPath else null);
    in
    if r.success && r.value != null then [ r.value ] else [ ];

  attr = path: lib.attrByPath (lib.splitString "." path) null pkgs;

  apps = map attr [
    "blender"
    "chromium"
    "firefox"
    "gimp"
    "gnome-shell"
    "haskellPackages.pandoc"
    "inkscape"
    "kdePackages.plasma-workspace"
    "libreoffice"
    "llvmPackages.clang"
    "nixos-install-tools"
    "python3Packages.torch"
    "qemu"
    "rustc"
    "texliveFull"
    "thunderbird"
  ];

  release = import (nixpkgs + "/nixos/release.nix") { supportedSystems = [ system ]; };

  closures = lib.concatMap (name: drvOf (release.closures.${name}.${system} or null)) (
    lib.attrNames release.closures
  );

  python = lib.concatMap drvOf (lib.attrValues pkgs.python3Packages);
in
toString (builtins.length (lib.concatMap drvOf apps ++ closures ++ python))
