{ stdenv, fetchFromGitHub, autoconf, automake, libtool, pkgconfig, rdma-core, glib, opensm }:

stdenv.mkDerivation rec {
  name = "infiniband-diags-${version}";
  version = "2.0.0";

  src = fetchFromGitHub {
    owner = "linux-rdma";
    repo = "infiniband-diags";
    rev = version;
    sha256 = "06x8yy3ly1vzraznc9r8pfsal9mjavxzhgrla3q2493j5jz0sx76";
  };

  nativeBuildInputs = [ autoconf automake libtool pkgconfig ];

  buildInputs = [ rdma-core glib opensm ];

  preConfigure = ''
    export CFLAGS="-I${opensm}/include/infiniband"
    ./autogen.sh
  '';

  configureFlags = "--with-perl-installdir=\\\${out}/lib/perl";

  meta = with stdenv.lib; {
    description = "Utilities designed to help configure, debug, and maintain infiniband fabrics";
    homepage = http://linux-rdma.org/;
    license =  licenses.bsd2; # Or GPL 2
    maintainers = [ maintainers.aij ];
    platforms = [ "x86_64-linux" ];
  };
}
