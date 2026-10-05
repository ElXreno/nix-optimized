{
  pkgs,
  root,
}:
let
  inherit (pkgs) lib;

  system = pkgs.stdenv.hostPlatform.system;

  generateDir = "/tmp/nix-optimized-pgo";

  bolt = pkgs.llvmPackages.bolt;

  withFlags =
    flags: nix:
    nix.overrideAllMesonComponents (
      _: prevAttrs: {
        env = (prevAttrs.env or { }) // {
          NIX_CFLAGS_COMPILE = flags;
        };
      }
    );

  withRelocs =
    nix:
    nix.overrideAllMesonComponents (
      _: prevAttrs: {
        env = (prevAttrs.env or { }) // {
          NIX_LDFLAGS = "--emit-relocs";
        };
        stripDebugFlags = [
          "-S"
          "-p"
          "--keep-file-symbols"
        ];
      }
    );

  withBolt =
    profile: nix:
    nix.overrideAllMesonComponents (
      _: prevAttrs: {
        postFixup = (prevAttrs.postFixup or "") + ''
          for so in $out/lib/libnix*.so.*; do
            fdata=${profile}/$(basename $so).fdata
            if [ -e $fdata ]; then
              ${bolt}/bin/llvm-bolt $so -o $so.bolt -data=$fdata \
                -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
                -split-all-cold -split-eh -no-huge-pages -bolt-info=false
              mv $so.bolt $so
            fi
          done
        '';
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

  train = nix: ''
    export NIX_STATE_DIR=$TMPDIR/state
    export NIX_CONFIG="extra-experimental-features = nix-command"
    ${nix}/bin/nix-env -qaP --json --meta -f ${pkgs.path} > /dev/null
    ${nix}/bin/nix eval --read-only --raw --impure --expr \
      'import ${root + "/workloads/instantiate.nix"} { nixpkgs = ${pkgs.path}; system = "${system}"; }'
  '';

  optimize =
    name: nix:
    let
      instrumented = (withFlags "-fprofile-generate=${generateDir}" nix).overrideAttrs {
        doCheck = false;
      };
      pgoProfile = pkgs.runCommand "${name}-pgo-profile" { } ''
        export GCOV_PREFIX=$TMPDIR/gcov
        ${train instrumented}
        mkdir $out
        cp $GCOV_PREFIX${generateDir}/*.gcda $out/
      '';
      pgo = withRelocs (
        withFlags "-fprofile-use=${pgoProfile} -fprofile-partial-training -fno-reorder-blocks-and-partition" nix
      );
      boltProfile = pkgs.runCommand "${name}-bolt-profile" { } ''
        mkdir lib fdata $out
        for so in ${lib.concatMapStringsSep " " (p: "${p}/lib/libnix*.so.*") (lib.attrValues pgo.libs)}; do
          ${bolt}/bin/llvm-bolt $so -o lib/$(basename $so) -instrument \
            -instrumentation-file=$PWD/fdata/$(basename $so) -instrumentation-file-append-pid
        done
        export LD_LIBRARY_PATH=$PWD/lib
        ${train (pgo.overrideAttrs { doCheck = false; })}
        for n in $(ls fdata | sed 's/\.[0-9]*\.fdata$//' | sort -u); do
          ${bolt}/bin/merge-fdata fdata/$n.*.fdata > $out/$n.fdata
        done
      '';
    in
    (withBolt boltProfile pgo).overrideAttrs (prevAttrs: {
      passthru = (prevAttrs.passthru or { }) // {
        inherit instrumented pgoProfile boltProfile;
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
