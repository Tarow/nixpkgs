{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  buildNpmPackage,
  makeWrapper,
  ffmpeg,
  git,
  pkg-config,
  sqlite,
  libvaSupport ? stdenv.hostPlatform.isLinux,
  libva,
  fetchpatch,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "dim";
  version = "0-unstable-2023-12-29";

  src = fetchFromGitHub {
    owner = "Dusk-Labs";
    repo = "dim";
    rev = "3ccb4ab05fc1d7dbd4ebbba9ff2de0ecc9139b27";
    hash = "sha256-1mgbrDnIkIdWy78uj4EjjgwBQxw/rIS1LCFNscXXPbk=";
  };

  frontend = buildNpmPackage {
    pname = "dim-ui";
    inherit (finalAttrs) version;
    src = "${finalAttrs.src}/ui";

    postPatch = ''
      ln -s ${./package-lock.json} package-lock.json
    '';

    npmDepsHash = "sha256-6oSm3H6RItHOrBIvP6uvR7sBboBRWFuP3VwU38GMfgQ=";

    installPhase = ''
      runHook preInstall

      cp -r build $out

      runHook postInstall
    '';
  };

  patches = [
    # Upstream uses a 'ffpath' function to look for config directory and
    # (ffmpeg) binaries in the same directory as the binary. Patch it to use
    # the working dir and PATH instead.
    ./relative-paths.diff

    # Bump the first‐party nightfall dependency to the latest Git
    # revision for FFmpeg >= 6 support.
    ./bump-nightfall.patch

    # Upstream has some unused imports that prevent things from compiling...
    # Remove for next release.
    (fetchpatch {
      name = "remove-unused-imports.patch";
      url = "https://github.com/Dusk-Labs/dim/commit/f62de1d38e6e52f27b1176f0dabbbc51622274cb.patch";
      hash = "sha256-Gk+RHWtCKN7McfFB3siIOOhwi3+k17MCQr4Ya4RCKjc=";
    })
  ];

  postPatch = ''
    substituteInPlace dim-core/src/lib.rs \
      --replace-fail "#![deny(warnings)]" "#![warn(warnings)]"
    substituteInPlace dim-events/src/lib.rs \
      --replace-fail "#![deny(warnings)]" "#![warn(warnings)]"
    substituteInPlace dim-database/src/lib.rs \
      --replace-fail "#![deny(warnings)]" "#![warn(warnings)]"
    ln -sf ${./Cargo.lock} Cargo.lock
  '';

  postConfigure = ''
    ln -ns $frontend ui/build
  '';

  nativeBuildInputs = [
    makeWrapper
    pkg-config
    git
  ];

  buildInputs = [ sqlite ] ++ lib.optional libvaSupport libva;

  buildFeatures = lib.optional libvaSupport "vaapi";

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "mp4-0.8.2" = "sha256-OtVRtOTU/yoxxoRukpUghpfiEgkKoJZNflMQ3L26Cno=";
      "nightfall-0.3.12-rc4" = "sha256-AbSuLe3ySOla3NB+mlfHRHqHuMqQbrThAaUZ747GErE=";
    };
  };

  checkFlags = [
    # Requires network
    "--skip=tmdb::tests::johhny_test_seasons"
    "--skip=tmdb::tests::once_upon_get_year"
    "--skip=tmdb::tests::tmdb_get_cast"
    "--skip=tmdb::tests::tmdb_get_details"
    "--skip=tmdb::tests::tmdb_get_episodes"
    "--skip=tmdb::tests::tmdb_get_seasons"
    "--skip=tmdb::tests::tmdb_search"
    # Broken doctest
    "--skip=dim-utils/src/lib.rs"
  ];

  postInstall = ''
    wrapProgram $out/bin/dim \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg ]}
  '';

  meta = {
    homepage = "https://github.com/Dusk-Labs/dim";
    description = "Self-hosted media manager";
    license = lib.licenses.agpl3Only;
    mainProgram = "dim";
    maintainers = [ lib.maintainers.misterio77 ];
    platforms = lib.platforms.unix;
  };
})
