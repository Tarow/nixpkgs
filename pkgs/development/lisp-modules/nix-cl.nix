# TODO:
# - faster build by using lisp with preloaded asdf?
# - dont include java libs unless abcl?
# - dont use build-asdf-system to build lispWithPackages?
# - make the lisp packages overridable? (e.g. buildInputs glibc->musl)
# - build asdf with nix and use that instead of one shipped with impls
#   (e.g. to fix build with clisp - does anyone use clisp?)
# - claspPackages ? (gotta package clasp with nix first)
# - hard one: remove unrelated sources ( of systems not being built)
# - figure out a less awkward way to patch sources
#   (have to build from src directly for SLIME to work, so can't just patch sources in place)

{
  pkgs,
  lib,
  stdenv,
  ...
}:

let

  inherit (lib)
    length
    filter
    foldl
    unique
    id
    concat
    concatMap
    mutuallyExclusive
    findFirst
    remove
    setAttr
    getAttr
    hasAttr
    attrNames
    attrValues
    filterAttrs
    mapAttrs
    splitString
    concatStringsSep
    concatMapStringsSep
    replaceStrings
    removeSuffix
    hasInfix
    optionalString
    makeBinPath
    makeLibraryPath
    makeSearchPath
    recurseIntoAttrs
    ;

  inherit (builtins)
    head
    tail
    elem
    split
    storeDir
    ;

  inherit (pkgs)
    replaceVars
    ;

  # Stolen from python-packages.nix
  # Actually no idea how this works
  makeOverridableLispPackage =
    f: origArgs:
    let
      ff = f origArgs;
      overrideWith =
        newArgs: origArgs // (if pkgs.lib.isFunction newArgs then newArgs origArgs else newArgs);
    in
    if builtins.isAttrs ff then
      (
        ff
        // {
          overrideLispAttrs = newArgs: makeOverridableLispPackage f (overrideWith newArgs);
        }
      )
    else if builtins.isFunction ff then
      {
        overrideLispAttrs = newArgs: makeOverridableLispPackage f (overrideWith newArgs);
        __functor = self: ff;
      }
    else
      ff;

  buildAsdf =
    {
      asdf,
      pkg,
      program,
      flags,
      faslExt,
    }:
    stdenv.mkDerivation {
      inherit (asdf) pname version;
      dontUnpack = true;
      buildPhase = ''
        cp -v ${asdf}/lib/common-lisp/asdf/build/asdf.lisp asdf.lisp
        ${pkg}/bin/${program} ${toString flags} < <(echo '(compile-file "asdf.lisp")')
      '';
      installPhase = ''
        mkdir -p $out
        cp -v asdf.${faslExt} $out
      '';
    };

  #
  # Wrapper around stdenv.mkDerivation for building ASDF systems.
  #
  build-asdf-system = makeOverridableLispPackage (
    {
      pname,
      version,
      src ? null,
      patches ? [ ],

      # Native libraries, will be appended to the library path
      nativeLibs ? [ ],

      # Java libraries for ABCL, will be appended to the class path
      javaLibs ? [ ],

      # Lisp dependencies
      # these should be packages built with `build-asdf-system`
      # TODO(kasper): use propagatedBuildInputs
      lispLibs ? [ ],

      # Derivation containing the CL implementation package
      pkg,

      # Name of the Lisp executable
      program ? pkg.meta.mainProgram or pkg.pname,

      # General flags to the Lisp executable
      flags ? [ ],

      # Extension for implementation-dependent FASL files
      faslExt,

      # ASDF amalgamation file to use
      # Created in build/asdf.lisp by `make` in ASDF source tree
      asdf,

      # Some libraries have multiple systems under one project, for
      # example, cffi has cffi-grovel, cffi-toolchain etc.  By
      # default, only the `pname` system is build.
      #
      # .asd's not listed in `systems` are removed in
      # installPhase. This prevents asdf from referring to uncompiled
      # systems on run time.
      #
      # Also useful when the pname is different than the system name,
      # such as when using reverse domain naming.
      systems ? [ pname ],

      # The .asd files that this package provides
      # TODO(kasper): remove
      asds ? systems,

      # Other args to mkDerivation
      ...
    }@args:

    (
      stdenv.mkDerivation (
        rec {
          inherit
            version
            nativeLibs
            javaLibs
            lispLibs
            systems
            asds
            pkg
            program
            flags
            faslExt
            ;

          # When src is null, we are building a lispWithPackages and only
          # want to make use of the dependency environment variables
          # generated by build-asdf-system
          dontUnpack = src == null;

          # Portable script to build the systems.
          #
          # `lisp` must evaluate this file then exit immediately. For
          # example, SBCL's --script flag does just that.
          #
          # NOTE:
          # Every other library worked fine with asdf:compile-system in
          # buildScript.
          #
          # cl-syslog, for some reason, signals that CL-SYSLOG::VALID-SD-ID-P
          # is undefined with compile-system, but works perfectly with
          # load-system. Strange.

          # TODO(kasper) portable quit
          asdfFasl = buildAsdf {
            inherit
              asdf
              pkg
              program
              flags
              faslExt
              ;
          };

          buildScript = replaceVars ./builder.lisp {
            asdf = "${asdfFasl}/asdf.${faslExt}";
          };

          configurePhase = ''
            runHook preConfigure

            source ${./setup-hook.sh}
            buildAsdfPath

            runHook postConfigure
          '';

          buildPhase = optionalString (src != null) ''
            runHook preBuild

            export CL_SOURCE_REGISTRY=$CL_SOURCE_REGISTRY:$src//
            export ASDF_OUTPUT_TRANSLATIONS="$src:$(pwd):${storeDir}:${storeDir}"
            ${pkg}/bin/${program} ${toString flags} < $buildScript

            runHook postBuild
          '';

          # Copy compiled files to store
          #
          # Make sure to include '$' in regex to prevent skipping
          # stuff like 'iolib.asdf.asd' for system 'iolib.asd'
          #
          # Same with '/': `local-time.asd` for system `cl-postgres+local-time.asd`
          installPhase =
            let
              mkSystemsRegex =
                systems: concatMapStringsSep "\\|" (replaceStrings [ "." "+" ] [ "[.]" "[+]" ]) systems;
            in
            ''
              runHook preInstall

              mkdir -pv $out
              cp -r * $out

              # Remove all .asd files except for those in `systems`.
              find $out -name "*.asd" \
              | grep -v "/\(${mkSystemsRegex systems}\)\.asd$" \
              | xargs rm -fv || true

              runHook postInstall
            '';

          dontPatchShebangs = true;

          # Not sure if it's needed, but caused problems with SBCL
          # save-lisp-and-die binaries in the past
          dontStrip = true;

        }
        // (
          args
          // (
            let
              isJVM = args.pkg.pname == "abcl";
              javaLibs = lib.optionals isJVM args.javaLibs or [ ];
            in
            {
              pname = "${args.pkg.pname}-${args.pname}";
              src =
                if args ? patches || args ? postPatch then
                  pkgs.applyPatches {
                    inherit (args) src;
                    patches = args.patches or [ ];
                    postPatch = args.postPatch or "";
                  }
                else
                  args.src;
              patches = [ ];
              inherit javaLibs;
              propagatedBuildInputs = args.propagatedBuildInputs or [ ] ++ lispLibs ++ javaLibs ++ nativeLibs;
              meta = (args.meta or { }) // {
                maintainers = args.meta.maintainers or [ ];
                teams = args.meta.teams or [ lib.teams.lisp ];
              };
            }
          )
        )
      )
      // {
        # Useful for overriding
        # Overriding code would prefer to use pname from the attribute set
        # However, pname is extended with the implementation name
        # Moreover, it is used in the default list of systems to load
        # So we pass the original pname
        pname = args.pname;
      }
    )
  );

  # Build the set of lisp packages using `lisp`
  # These packages are defined manually for one reason or another:
  # - The library is not in quicklisp
  # - The library that is in quicklisp is broken
  # - Special build procedure such as cl-unicode, asdf
  #
  # They can use the auto-imported quicklisp packages as dependencies,
  # but some of those don't work out of the box.
  #
  # E.g if a QL package depends on cl-unicode it won't build out of
  # the box.
  commonLispPackagesFor =
    spec:
    let
      build-asdf-system' = body: build-asdf-system (body // spec);
    in
    pkgs.callPackage ./packages.nix {
      inherit spec quicklispPackagesFor;
      build-asdf-system = build-asdf-system';
    };

  # Build the set of packages imported from quicklisp using `lisp`
  quicklispPackagesFor =
    spec:
    let
      build-asdf-system' = body: build-asdf-system (body // spec);
    in
    pkgs.callPackage ./ql.nix {
      build-asdf-system = build-asdf-system';
    };

  # Creates a lisp wrapper with `packages` installed
  #
  # `packages` is a function that takes `clpkgs` - a set of lisp
  # packages - as argument and returns the list of packages to be
  # installed
  # TODO(kasper): assert each package has the same lisp and asdf?
  lispWithPackages =
    clpkgs: packages:
    let
      first = head (lib.attrValues clpkgs);
    in
    (build-asdf-system {
      inherit (first)
        pkg
        program
        flags
        faslExt
        asdf
        ;
      # See dontUnpack in build-asdf-system
      src = null;
      pname = "with";
      version = "packages";
      lispLibs = packages clpkgs;
      systems = [ ];
    }).overrideAttrs
      (o: {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        installPhase = ''
          mkdir -pv $out/bin
          makeWrapper \
            ${o.pkg}/bin/${o.program} \
            $out/bin/${o.program} \
            --add-flags "${toString o.flags}" \
            --set ASDF "${o.asdfFasl}/asdf.${o.faslExt}" \
            --prefix CL_SOURCE_REGISTRY : "$CL_SOURCE_REGISTRY''${CL_SOURCE_REGISTRY:+:}" \
            --prefix ASDF_OUTPUT_TRANSLATIONS : "$(echo $CL_SOURCE_REGISTRY | sed s,//:,::,g):" \
            --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH" \
            --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH" \
            --prefix CLASSPATH : "$CLASSPATH" \
            --prefix GI_TYPELIB_PATH : "$GI_TYPELIB_PATH" \
            --prefix PATH : "${makeBinPath (o.propagatedBuildInputs or [ ])}"
        '';
      });

  wrapLisp =
    {
      pkg,
      faslExt,
      program ? pkg.meta.mainProgram or pkg.pname,
      flags ? [ ],
      asdf ? pkgs.asdf_3_3,
      packageOverrides ? (self: super: { }),
    }:
    let
      spec = {
        inherit
          pkg
          faslExt
          program
          flags
          asdf
          ;
      };
      pkgs = (commonLispPackagesFor spec).overrideScope packageOverrides;
      withPackages = lispWithPackages pkgs;
      withOverrides =
        packageOverrides:
        wrapLisp {
          inherit
            pkg
            faslExt
            program
            flags
            asdf
            ;
          inherit packageOverrides;
        };
      buildASDFSystem = args: build-asdf-system (args // spec);
    in
    pkg
    // {
      inherit
        pkgs
        withPackages
        withOverrides
        buildASDFSystem
        ;
    };

in
wrapLisp
