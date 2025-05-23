{
  lib,
  stdenv,
  fetchurl,
  libpcap,
  tcpdump,
}:

stdenv.mkDerivation rec {
  pname = "tcpreplay";
  version = "4.5.1";

  src = fetchurl {
    url = "https://github.com/appneta/tcpreplay/releases/download/v${version}/tcpreplay-${version}.tar.gz";
    sha256 = "sha256-Leeb/Wfsksqa4v+1BFbdHVP/QPP6cbQixl6AYgE8noU=";
  };

  buildInputs = [ libpcap ];

  configureFlags = [
    "--disable-local-libopts"
    "--disable-libopts-install"
    "--enable-dynamic-link"
    "--enable-shared"
    "--enable-tcpreplay-edit"
    "--with-libpcap=${libpcap}"
    "--with-tcpdump=${tcpdump}/bin/tcpdump"
  ];

  meta = with lib; {
    description = "Suite of utilities for editing and replaying network traffic";
    homepage = "https://tcpreplay.appneta.com/";
    license = with licenses; [
      bsdOriginalUC
      gpl3Only
    ];
    maintainers = with maintainers; [ eleanor ];
    platforms = platforms.unix;
  };
}
