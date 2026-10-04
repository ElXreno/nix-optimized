{
  pkgs,
  root,
}:
let
  inherit (pkgs) lib;

  system = pkgs.stdenv.hostPlatform.system;

  generateDir = "/tmp/nix-optimized-pgo";

  withFlags =
    flags: nix:
    nix.overrideAllMesonComponents (
      _: prevAttrs: {
        env = (prevAttrs.env or { }) // {
          NIX_CFLAGS_COMPILE = flags;
        };
      }
    );

  upstreamPatches = {
    "2.35" = [
      (pkgs.fetchpatch {
        name = "nix-16190-srctostore-on-fetcher-cache-hit.patch";
        url = "https://github.com/NixOS/nix/commit/30820a54b112f4842bdb7df28b61b2a607e54033.patch";
        hash = "sha256-Yvn9a059LvW9FkSGH20LRPlBIhmVqQxGMBXke+hxkgs=";
      })
      (pkgs.fetchpatch {
        name = "nix-16244-dedup-addtemproot.patch";
        url = "https://github.com/NixOS/nix/commit/d4c237e7216eea15fef6b8339889dbe7a0e1ad54.patch";
        hash = "sha256-Ef1Aj3Wrm8JttWfPzRpGjeC6t/uue5oX0rAiSCjlCZk=";
      })
    ];
  };

  inherit (pkgs.nixVersions) latest stable;

  latestVersion = lib.versions.majorMinor latest.version;

  patchDir = root + "/patches/${latestVersion}";

  patched =
    (latest.appendPatches (
      (upstreamPatches.${latestVersion} or [ ])
      ++ map (n: patchDir + "/${n}") (
        lib.attrNames (
          lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".patch" n) (builtins.readDir patchDir)
        )
      )
    )).overrideScope
      (
        _: _: {
          boehmgc = pkgs.nixDependencies.boehmgc.overrideAttrs (prevAttrs: {
            patches = (prevAttrs.patches or [ ]) ++ [ (root + "/patches/boehmgc/madvise-hugepage.patch") ];
          });
        }
      );

  optimize =
    name: nix:
    let
      instrumented = (withFlags "-fprofile-generate=${generateDir}" nix).overrideAttrs {
        doCheck = false;
      };
      profile = pkgs.runCommand "${name}-pgo-profile" { } ''
        export NIX_STATE_DIR=$TMPDIR/state
        export NIX_CONFIG="extra-experimental-features = nix-command"
        export GCOV_PREFIX=$TMPDIR/gcov
        ${instrumented}/bin/nix-env -qaP --json --meta -f ${pkgs.path} > /dev/null
        ${instrumented}/bin/nix eval --read-only --raw --impure --expr \
          'import ${root + "/workloads/instantiate.nix"} { nixpkgs = ${pkgs.path}; system = "${system}"; }'
        mkdir $out
        cp $GCOV_PREFIX${generateDir}/*.gcda $out/
      '';
    in
    (withFlags "-fprofile-use=${profile} -fprofile-partial-training" nix).overrideAttrs (prevAttrs: {
      passthru = (prevAttrs.passthru or { }) // {
        inherit instrumented profile;
      };
    });

  nameFor =
    nix: "nix-optimized-${lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor nix.version)}";

  versioned = lib.mapAttrs optimize (
    lib.listToAttrs (
      map (nix: lib.nameValuePair "${nameFor nix}-plain" nix) [
        stable
        latest
      ]
    )
    // lib.optionalAttrs (builtins.pathExists patchDir) { ${nameFor latest} = patched; }
  );
in
{
  checks = versioned;

  packages = versioned // rec {
    nix-optimized = versioned.${nameFor latest} or nix-optimized-plain;
    nix-optimized-plain = versioned."${nameFor latest}-plain";
    default = nix-optimized;
  };
}
