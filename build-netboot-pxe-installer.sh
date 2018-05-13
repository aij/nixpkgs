#!/bin/sh
nix-build -A netboot_aij nixos/release.nix || exit

echo Success. Run
echo rsync -avPessh --copy-unsafe-links `readlink result`/ root@m1:/home/tftpd/nixos-custom-`date -I`
