{ stdenv, fetchFromGitHub, cmake, ninja, pkgconfig, valgrind, libudev, libnl, python, systemd, linuxHeaders }:

stdenv.mkDerivation rec {
  name = "rdma-core-${version}";
  version = "16";

  src = fetchFromGitHub {
    owner = "linux-rdma";
    repo = "rdma-core";
    rev = "v${version}";
    sha256 = "131gckfnb0flcyy27nc6kjpk17cmadjwv7rpsg1g0lbrx83b7irl";
  };

  nativeBuildInputs = [ cmake ninja pkgconfig valgrind python ];

  buildInputs = [ libudev libnl systemd linuxHeaders ];

  cmakeFlags = "-GNinja";

  meta = with stdenv.lib; {
    description = "Userspace libraries and daemons for Infiniband on Linux";
    homepage = http://linux-rdma.org/;
    # Mostly dual license gpl2 or mit, w/ various bsd variants for subcomponents.
    license =  licenses.free;
    maintainers = [ maintainers.aij ];
    platforms = [ "x86_64-linux" ];
  };
}
