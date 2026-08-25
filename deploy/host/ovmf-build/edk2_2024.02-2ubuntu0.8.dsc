-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Format: 3.0 (quilt)
Source: edk2
Binary: ovmf, ovmf-ia32, ovmf-legacy, qemu-efi-arm, qemu-efi-aarch64, qemu-efi-riscv64, efi-shell-ia32, efi-shell-x64, efi-shell-arm, efi-shell-aa64, efi-shell-riscv64
Architecture: all
Version: 2024.02-2ubuntu0.8
Maintainer: Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>
Uploaders: Steve Langasek <vorlon@debian.org>, Serge Hallyn <serge.hallyn@ubuntu.com>, dann frazier <dannf@debian.org>
Homepage: http://www.tianocore.org
Standards-Version: 4.5.0
Vcs-Browser: https://salsa.debian.org/qemu-team/edk2
Vcs-Git: https://salsa.debian.org/qemu-team/edk2.git
Testsuite: autopkgtest
Testsuite-Triggers: dosfstools, grub-efi-amd64-signed, grub-efi-arm64-signed, mtools, openssl, python3-pexpect, qemu-system-arm, qemu-system-misc, qemu-system-x86, sbsigntool, shim-signed, xorriso
Build-Depends: bc, debhelper-compat (= 12), dh-exec, dosfstools, dpkg (>= 1.19.3), gcc-aarch64-linux-gnu, gcc-arm-linux-gnueabi, gcc-multilib [i386], gcc-riscv64-linux-gnu, iasl, lsb-release, mtools, nasm, python3, python3-pexpect, qemu-utils, qemu-system-arm (>= 1:2.12+dfsg), qemu-system-x86 (>= 1:2.12+dfsg), uuid-dev, xorriso
Package-List:
 efi-shell-aa64 deb misc optional arch=all
 efi-shell-arm deb misc optional arch=all
 efi-shell-ia32 deb misc optional arch=all
 efi-shell-riscv64 deb misc optional arch=all
 efi-shell-x64 deb misc optional arch=all
 ovmf deb misc optional arch=all
 ovmf-ia32 deb misc optional arch=all
 ovmf-legacy deb misc optional arch=all
 qemu-efi-aarch64 deb misc optional arch=all
 qemu-efi-arm deb misc optional arch=all
 qemu-efi-riscv64 deb misc optional arch=all
Checksums-Sha1:
 79eb3498977a8f22e03958314d0a8687acf0f60f 21761992 edk2_2024.02.orig.tar.xz
 9a96afa2814a816f208535b713be51f5b8cbb225 80960 edk2_2024.02-2ubuntu0.8.debian.tar.xz
Checksums-Sha256:
 3986e42620845cf799ed2cc863fe97603a433e64842e335fe8f4746d9b3b5b21 21761992 edk2_2024.02.orig.tar.xz
 5b08d3e703506db5a5fcfd35f33954561c86d34c2325652631486e5970e96612 80960 edk2_2024.02-2ubuntu0.8.debian.tar.xz
Files:
 ad9d5654f65fa6dddf40846d3275ca5b 21761992 edk2_2024.02.orig.tar.xz
 aaf068e835c447f56fcb154399a33435 80960 edk2_2024.02-2ubuntu0.8.debian.tar.xz
Build-Indep-Architecture: amd64
Original-Maintainer: Debian QEMU Team <pkg-qemu-devel@lists.alioth.debian.org>

-----BEGIN PGP SIGNATURE-----

iQIzBAEBCgAdFiEEktYY9mjyL47YC+71uj4pM4KAskIFAmnECpEACgkQuj4pM4KA
skItag/9FCAJvb0w539BDL16Ao8EjrI1jrtPCfzoKMhZWeoFm4UksQDfZYg7J2Oo
ZeqPX5UtC/NEKKY7pVcpJ2U5oO20KQ7K1T5LZZWgJGL7Bfp3cVgInfKDqdNSIss4
kdXzrQsLoOr31p1Z1lWmQlbCmrWCeeVSr5j+KCmwbmovSZXyA1xPI1+fDX7V92vU
FDeLPXzTSPyA9DlFQUdWkXadMNWvT4TPrL4rK4cO59O8wtD1VTWdmhvdToBjxB6L
AH39hWLDD4gX+yc5Vt/N0Y/FEOe6Gma38w9Hxa75RItry1A+zSFSToy+I5LpW5Al
OiXCfx7DclZlGWVSxvwMKYqWUQCCOHwS8EuHGtBrw2XSp2uVcW6BoYAKJvGdVmVC
Xf6HLL+jbUZMvFRxUpbRAbBuReZt5sq5NFjNqgpjEmX8ngEWdeqesdLAOt0Otm/2
StJmV6755d3+JJ4eGvXAM6mOYiVdk6bekGwyvtNRBboyYXAcJgP/IP5agahXxrUh
CEdSG69j//m77E+SxWwTXkF2tmPY5wO4rptJC2FowtfnL87o71vTq9mT7r4PMd4H
9N+NPZ1+PVP3NZ/veRqlTXWMcqAAqhhExPzuoYSPCkbnpr2QgsRzuoIXJiCEJkiH
LgW5+Yb52+6XlVkmBmhrkuGC73kSW/ptcrwc4EQAN2wPznhZnLA=
=UWVN
-----END PGP SIGNATURE-----
