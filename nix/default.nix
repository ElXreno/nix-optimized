{
  pkgs,
  root,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.llvmPackages) bolt;
  inherit (pkgs.nixVersions) latest stable;
  inherit (pkgs.stdenv.hostPlatform) system;

  generateDir = "/tmp/nix-optimized-pgo";

  latestVersion = lib.versions.majorMinor latest.version;

  patchDir = root + "/patches/${latestVersion}";

  upstreamPatches = {
    "2.35" = [
      {
        rev = "d4c237e7216eea15fef6b8339889dbe7a0e1ad54";
        hash = "sha256-Ef1Aj3Wrm8JttWfPzRpGjeC6t/uue5oX0rAiSCjlCZk=";
      }
    ];
  };

  fetchUpstream =
    { rev, hash }:
    pkgs.fetchpatch {
      url = "https://github.com/NixOS/nix/commit/${rev}.patch";
      inherit hash;
    };

  patched =
    (latest.appendPatches (
      map fetchUpstream (upstreamPatches.${latestVersion} or [ ])
      ++ lib.filesystem.listFilesRecursive patchDir
    )).overrideScope
      (
        _: _: {
          boehmgc = pkgs.nixDependencies.boehmgc.overrideAttrs (prevAttrs: {
            patches = (prevAttrs.patches or [ ]) ++ [ (root + "/patches/boehmgc/madvise-hugepage.patch") ];
          });
        }
      );

  components = f: nix: nix.overrideAllMesonComponents (_: f);

  compile =
    flags:
    components (prevAttrs: {
      env = (prevAttrs.env or { }) // {
        NIX_CFLAGS_COMPILE = flags;
      };
    });

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
      generate = "-fprofile-generate=${generateDir}";
      use = "-fprofile-use=${pgoProfile} -fprofile-partial-training";

      instrumented = (compile generate nix).overrideAttrs { doCheck = false; };

      pgoProfile = pkgs.runCommand "${name}-pgo-profile" { } ''
        export GCOV_PREFIX=$TMPDIR/gcov
        ${train instrumented}
        mkdir $out
        cp $GCOV_PREFIX${generateDir}/*.gcda $out/
      '';

      pgo = components (prevAttrs: {
        env = (prevAttrs.env or { }) // {
          NIX_LDFLAGS = "--emit-relocs";
        };
        stripDebugFlags = [
          "-S"
          "-p"
          "--keep-file-symbols"
        ];
      }) (compile "${use} -fno-reorder-blocks-and-partition" nix);

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

      bolted = components (prevAttrs: {
        postFixup = (prevAttrs.postFixup or "") + ''
          for so in $out/lib/libnix*.so.*; do
            fdata=${boltProfile}/$(basename $so).fdata
            if [ -e $fdata ]; then
              ${bolt}/bin/llvm-bolt $so -o $so.bolt -data=$fdata \
                -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
                -split-all-cold -split-eh -no-huge-pages -bolt-info=false
              mv $so.bolt $so
            fi
          done
        '';
      }) pgo;
    in
    bolted.overrideAttrs (prevAttrs: {
      passthru = (prevAttrs.passthru or { }) // {
        inherit instrumented pgoProfile boltProfile;
      };
    });

  nameFor =
    nix: "nix-optimized-${lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor nix.version)}";

  versioned = lib.mapAttrs optimize (
    lib.listToAttrs (
      map (nix: lib.nameValuePair "${nameFor nix}-plain" nix) [
        latest
        stable
      ]
    )
    // lib.optionalAttrs (builtins.pathExists patchDir) { ${nameFor latest} = patched; }
  );
in
{
  checks = versioned;

  packages = versioned // rec {
    nix-optimized =
      versioned.${nameFor latest}
      or (lib.warn "nix-optimized: no patches for Nix ${latestVersion}, building it unpatched" nix-optimized-plain);
    nix-optimized-plain = versioned."${nameFor latest}-plain";
    default = nix-optimized;
  };
}
