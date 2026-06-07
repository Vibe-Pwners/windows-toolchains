"""Canonical version + integrity lock for every pinned input.

This file is the single source of truth. `task lock` recomputes the SHA256s
here by streaming each URL, and `task lock-export` mirrors it to the plain-text
`versions.lock` for humans and non-Bazel tooling.

Do NOT let CI "discover latest" — releases must be boring and pinned.
"""

# Component versions baked into artifact names and manifest.json.
VERSIONS = {
    "gcc": "15.2.0",
    "binutils": "2.45",  # latest actually published on sourceware/ftp.gnu.org (no 2.46 exists yet)
    "mingw_w64": "14.0.0",
    "gmp": "6.3.0",
    "mpfr": "4.2.1",
    "mpc": "1.3.1",
}

# Host (build) compiler: a Bootlin x86-64 glibc *stable* toolchain. Building our
# cross-compilers with it (+ static host libstdc++/libgcc) makes them relocatable
# and independent of the CI image. IMPORTANT: the produced Linux executables
# require glibc >= GLIBC_FLOOR. Pin an older Bootlin release to lower the floor.
BOOTLIN = {
    "release": "2024.05-1",
    "host_gcc": "13.3.0",
    "host_binutils": "2.41",
}
GLIBC_FLOOR = "2.39"  # recorded into every tarball's manifest.json

# Each entry is fetched with http_file (raw tarball); the build action extracts
# it itself. `strip_prefix` is the top-level directory inside the tarball.
ARCHIVES = {
    "gcc_src": {
        "file": "gcc-15.2.0.tar.xz",
        "urls": [
            "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz",
            "https://gcc.gnu.org/pub/gcc/releases/gcc-15.2.0/gcc-15.2.0.tar.xz",
        ],
        "sha256": "438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e",
        "strip_prefix": "gcc-15.2.0",
    },
    "binutils_src": {
        "file": "binutils-2.45.tar.xz",
        "urls": [
            "https://ftp.gnu.org/gnu/binutils/binutils-2.45.tar.xz",
            "https://sourceware.org/pub/binutils/releases/binutils-2.45.tar.xz",
        ],
        "sha256": "c50c0e7f9cb188980e2cc97e4537626b1672441815587f1eab69d2a1bfbef5d2",
        "strip_prefix": "binutils-2.45",
    },
    "mingw_src": {
        "file": "mingw-w64-v14.0.0.tar.bz2",
        "urls": [
            "https://downloads.sourceforge.net/project/mingw-w64/mingw-w64/mingw-w64-release/mingw-w64-v14.0.0.tar.bz2",
        ],
        "sha256": "6eaf921d9eb987d3820b364ea9775bc19b965ec81490b6fdd716526c28e1995c",
        "strip_prefix": "mingw-w64-v14.0.0",
    },
    "gmp_src": {
        "file": "gmp-6.3.0.tar.xz",
        "urls": ["https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"],
        "sha256": "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
        "strip_prefix": "gmp-6.3.0",
    },
    "mpfr_src": {
        "file": "mpfr-4.2.1.tar.xz",
        "urls": ["https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz"],
        "sha256": "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2",
        "strip_prefix": "mpfr-4.2.1",
    },
    "mpc_src": {
        "file": "mpc-1.3.1.tar.gz",
        "urls": ["https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"],
        "sha256": "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8",
        "strip_prefix": "mpc-1.3.1",
    },
    "bootlin_host": {
        "file": "x86-64--glibc--stable-2024.05-1.tar.xz",
        "urls": [
            "https://toolchains.bootlin.com/downloads/releases/toolchains/x86-64/tarballs/x86-64--glibc--stable-2024.05-1.tar.xz",
        ],
        "sha256": "932823ca9a3e067e7e2a29810a666d20c9cc5bb550de947f6879e38ace1aa955",
        "strip_prefix": "x86-64--glibc--stable-2024.05-1",
    },
}

# The two shipped flavors. EH is encoded in the artifact name; never make users guess.
FLAVORS = {
    "x86_64": {"target": "x86_64-w64-mingw32", "exceptions": "seh"},
    "i686": {"target": "i686-w64-mingw32", "exceptions": "dw2"},
}
