# nix-optimized

Nix from nixpkgs-unstable, rebuilt with profile-guided optimization, plus a set of evaluation speedups on top of the latest release.

## How it works

The profile is just another derivation. It runs an instrumented Nix (`-fprofile-generate`) inside the build sandbox, against a throwaway store, on nixpkgs alone: `nix-env -qa` over the whole tree, then instantiating `python3Packages`, a handful of heavy applications and the NixOS closures from `nixos/release.nix`. The optimized Nix is built with `-fprofile-use` on that output. Its libraries then go through BOLT with a second profile, collected the same way from BOLT-instrumented copies, and the result runs its full test suite.

There is no training data in the repository, and Nix itself decides when to retrain: the profile is rebuilt only when one of its inputs changes, that is nixpkgs, the patches, the flags or the workload.

Renovate bumps nixpkgs-unstable whenever it moves. CI evaluates the checks, builds whatever is not in the binary cache yet for x86_64-linux and aarch64-linux and pushes it; the pull request merges itself once everything is built.

Two flavors:

- `plain`, for `nixVersions.latest` and `nixVersions.stable`: stock source, PGO only;
- `patched`, for `nixVersions.latest` when `patches/<version>/` exists for it: PGO plus two upstream fixes (NixOS/nix#16190, NixOS/nix#16244), the evaluation speedups in `patches/<version>/` and `madvise(MADV_HUGEPAGE)` for the Boehm GC heap.

| Package | What |
|---|---|
| `nix-optimized` | latest, patched; plain until patches for a new release land |
| `nix-optimized-plain` | latest, PGO only |
| `nix-optimized-2_35`, `nix-optimized-2_35-plain`, `nix-optimized-2_34-plain` | per release; the names follow `latest` and `stable` of the locked nixpkgs |

## Binary cache

```nix
nix.settings = {
  substituters = [ "https://elxreno.cachix.org" ];
  trusted-public-keys = [ "elxreno.cachix.org-1:ozSPSY5S3/TpbcXi+/DdtSj1JlK3CPz3G+F92yRBXDQ=" ];
};
```

## Usage

```nix
{
  inputs.nix-optimized.url = "github:ElXreno/nix-optimized";

  outputs = { nixpkgs, nix-optimized, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nix.package = nix-optimized.packages.${pkgs.stdenv.hostPlatform.system}.nix-optimized;
        })
      ];
    };
  };
}
```

The cache only has what was built against this repository's nixpkgs. With `inputs.nix-optimized.inputs.nixpkgs.follows = "nixpkgs"`, or through `overlays.default` (`pkgs.nix-optimized`, `pkgs.nix-optimized-plain`, `pkgs.nixOptimized.<name>`), Nix is built and trained locally.

Profile counters vary a little between runs, so a rebuild from source is not bit-identical to the cached one; the store path is the same.

## License

The Nix expressions, workloads and CI here are under the [MIT license](LICENSE). The patches are derivative works of the projects they modify and keep their licenses: `patches/<version>/` is LGPL-2.1-or-later like Nix, `patches/boehmgc/` is under the Boehm GC license. Nix built from this repository is LGPL-2.1-or-later.
