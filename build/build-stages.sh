#!/usr/bin/env bash
# Staged Linux x86_64 -> Windows MinGW-w64/UCRT cross-toolchain bootstrap.
#
# Invoked by the Bazel `mingw_toolchain` rule (bazel/toolchain_build.bzl), which
# exports every input path and version as an environment variable. It can also be
# run by hand for debugging if those vars are set. Mirrors the official MinGW-w64
# how-to ordering: binutils -> headers -> core GCC -> CRT -> libgcc -> winpthreads
# -> finish GCC. UCRT is selected consistently on both headers and CRT.
set -euo pipefail

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

: "${TARGET:?}" "${EXCEPTIONS:?}" "${ROOT_NAME:?}" "${OUT_TAR:?}" "${OUT_SHA:?}"
: "${PACKAGE_SCRIPT:?}"

# Parallel make jobs. Each job can be a full cc1plus (hundreds of MB RSS), so an
# unbounded -j$(nproc) on a high-core/low-RAM box OOMs. Cap at 8 by default;
# override with BUILD_JOBS (CI: --action_env=BUILD_JOBS=N).
HWJOBS="$(nproc 2>/dev/null || echo 4)"
CAPJOBS="${BUILD_JOBS:-8}"
JOBS=$(( HWJOBS < CAPJOBS ? HWJOBS : CAPJOBS ))
EXECROOT="$PWD"

# Resolve every Bazel-provided path to an absolute one before we cd away.
abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$EXECROOT" "$1";; esac; }
for v in TARBALL_GCC TARBALL_BINUTILS TARBALL_MINGW TARBALL_GMP TARBALL_MPFR \
         TARBALL_MPC TARBALL_BOOTLIN PACKAGE_SCRIPT OUT_TAR OUT_SHA; do
  printf -v "$v" '%s' "$(abspath "${!v}")"
done

# Roomy scratch dir on REAL disk. Do NOT default to /tmp: it is frequently a
# RAM-backed tmpfs (here 7.6G), which a multi-GB GCC build tree overflows and
# which also steals RAM. Default to a dir under $HOME (real disk); override with
# MINGW_SCRATCH (CI: --action_env=MINGW_SCRATCH=/big/disk).
SCRATCH="${MINGW_SCRATCH:-${HOME:-/var/tmp}/.cache/mingw-toolchains-build}"
mkdir -p "$SCRATCH"
WORKDIR="$(mktemp -d "$SCRATCH/build.XXXXXX")"
BUILD_OK=0
# Keep the tree on failure for debugging (set MINGW_KEEP_WORKDIR=1 to always keep).
cleanup() {
  if [ "$BUILD_OK" = 1 ] && [ "${MINGW_KEEP_WORKDIR:-0}" != 1 ]; then
    rm -rf "$WORKDIR"
  else
    echo "WORKDIR preserved for debugging: $WORKDIR" >&2
  fi
}
trap cleanup EXIT
SRC="$WORKDIR/src"; BUILD="$WORKDIR/build"; PREFIX="$WORKDIR/out/$ROOT_NAME"
# No --with-sysroot: for x86_64/i686-w64-mingw32 GCC's native_system_header_dir is
# /usr/include, so a sysroot would send the header search to $PREFIX/usr/include.
# The standard cross layout puts headers/CRT under $PREFIX/$TARGET, which GCC
# searches via its built-in $prefix/$target/include path (relocatable: resolved
# relative to the gcc binary, so moving the tree still works).
TARGET_PREFIX="$PREFIX/$TARGET"
mkdir -p "$SRC" "$BUILD" "$PREFIX"

# ---------------------------------------------------------------------------
# Host compiler: the pinned Bootlin x86-64 toolchain. Relocate it (Bootlin SDKs
# bake absolute paths until relocate-sdk.sh is run). We use it for the HOST tools
# (binutils + GCC) so our cross-compiler binaries inherit Bootlin's older glibc
# floor. We do NOT export CC/CXX globally: the target-hosted configures (CRT,
# winpthreads, headers; --host=$TARGET) must use the freshly built
# $TARGET-gcc, and autotools honors an exported $CC over the --host triplet —
# which previously made the CRT compile with the host gcc and fail. So the host
# compiler is passed only on the binutils/GCC configure lines below.
# ---------------------------------------------------------------------------
log "Unpacking Bootlin host toolchain"
tar -C "$SRC" -xf "$TARBALL_BOOTLIN"
BOOTLIN_DIR="$SRC/$STRIP_BOOTLIN"
[ -x "$BOOTLIN_DIR/relocate-sdk.sh" ] && (cd "$BOOTLIN_DIR" && ./relocate-sdk.sh)
HOST_GCC="$(find "$BOOTLIN_DIR/bin" -maxdepth 1 -name '*-linux-*-gcc' ! -name '*.br_real' | sort | head -1)"
[ -n "$HOST_GCC" ] || die "no host gcc found under $BOOTLIN_DIR/bin"
HOST_CXX="${HOST_GCC%-gcc}-g++"
# Static-link the host C++/GCC runtimes into the cross-compiler executables so
# they don't drag Bootlin's libstdc++.so along; only glibc remains as a dep.
HOST_LDFLAGS="-static-libstdc++ -static-libgcc"
# $PREFIX/bin first so the just-built $TARGET-* tools win; Bootlin bin for host gcc.
export PATH="$PREFIX/bin:$BOOTLIN_DIR/bin:$PATH"
log "Host CC = $HOST_GCC"; "$HOST_GCC" --version | head -1 >&2

log "Unpacking sources"
tar -C "$SRC" -xf "$TARBALL_BINUTILS"
tar -C "$SRC" -xf "$TARBALL_GCC"
tar -C "$SRC" -xf "$TARBALL_MINGW"
tar -C "$SRC" -xf "$TARBALL_GMP"
tar -C "$SRC" -xf "$TARBALL_MPFR"
tar -C "$SRC" -xf "$TARBALL_MPC"
GCC_SRC="$SRC/$STRIP_GCC"
BINUTILS_SRC="$SRC/$STRIP_BINUTILS"
MINGW_SRC="$SRC/$STRIP_MINGW"
# In-tree GMP/MPFR/MPC (pinned, instead of contrib/download_prerequisites which
# would fetch unpinned at build time and break hermeticity).
ln -sfn "$SRC/$STRIP_GMP" "$GCC_SRC/gmp"
ln -sfn "$SRC/$STRIP_MPFR" "$GCC_SRC/mpfr"
ln -sfn "$SRC/$STRIP_MPC" "$GCC_SRC/mpc"

# Exception-handling model -> GCC configure flags.
case "$EXCEPTIONS" in
  seh)  EH_FLAGS=(--disable-sjlj-exceptions) ;;
  dw2)  EH_FLAGS=(--disable-sjlj-exceptions --with-dwarf2) ;;
  sjlj) EH_FLAGS=(--enable-sjlj-exceptions) ;;
  *)    die "unknown EXCEPTIONS=$EXCEPTIONS" ;;
esac
BUILD_TRIPLET="$("$HOST_GCC" -dumpmachine)"

# --- Stage 1: binutils -----------------------------------------------------
log "[1/7] binutils"
mkdir -p "$BUILD/binutils"; cd "$BUILD/binutils"
CC="$HOST_GCC" CXX="$HOST_CXX" LDFLAGS="$HOST_LDFLAGS" \
"$BINUTILS_SRC/configure" \
  --build="$BUILD_TRIPLET" --target="$TARGET" \
  --prefix="$PREFIX" \
  --disable-multilib --disable-nls --enable-lto --enable-plugins
make -j"$JOBS"
make install

# --- Stage 2: mingw-w64 headers (UCRT) -------------------------------------
log "[2/7] mingw-w64 headers"
mkdir -p "$BUILD/headers"; cd "$BUILD/headers"
"$MINGW_SRC/mingw-w64-headers/configure" \
  --build="$BUILD_TRIPLET" --host="$TARGET" \
  --prefix="$TARGET_PREFIX" \
  --with-default-msvcrt=ucrt \
  --with-default-win32-winnt=0x0601
make install
mkdir -p "$TARGET_PREFIX/lib"
ln -sfn "$TARGET" "$PREFIX/mingw"   # conventional $prefix/mingw mirror some tools expect

# --- Stage 3: core GCC (compiler only) -------------------------------------
log "[3/7] core GCC"
mkdir -p "$BUILD/gcc"; cd "$BUILD/gcc"
CC="$HOST_GCC" CXX="$HOST_CXX" LDFLAGS="$HOST_LDFLAGS" \
"$GCC_SRC/configure" \
  --build="$BUILD_TRIPLET" --target="$TARGET" \
  --prefix="$PREFIX" \
  --disable-multilib --enable-languages=c,c++ \
  --enable-threads=posix --enable-shared --enable-static \
  --disable-nls "${EH_FLAGS[@]}"
make -j"$JOBS" all-gcc
make install-gcc

# --- Stage 4: mingw-w64 CRT (UCRT, must match headers) ---------------------
log "[4/7] mingw-w64 CRT"
mkdir -p "$BUILD/crt"; cd "$BUILD/crt"
CRT_BITS=(); case "$TARGET" in
  i686-*)   CRT_BITS=(--enable-lib32 --disable-lib64) ;;
  x86_64-*) CRT_BITS=(--disable-lib32 --enable-lib64) ;;
esac
# No CC override: autotools derives the cross compiler ($TARGET-gcc) from --host.
# CC_FOR_BUILD points any build-time helpers at the Bootlin host gcc.
CC_FOR_BUILD="$HOST_GCC" \
"$MINGW_SRC/mingw-w64-crt/configure" \
  --build="$BUILD_TRIPLET" --host="$TARGET" \
  --prefix="$TARGET_PREFIX" \
  --with-default-msvcrt=ucrt "${CRT_BITS[@]}" \
  || { echo "==== mingw-w64-crt config.log (tail) ====" >&2; tail -120 config.log >&2; exit 1; }
make -j"$JOBS"
make install

# --- Stage 5: winpthreads --------------------------------------------------
# MUST precede libgcc: with --enable-threads=posix, libgcc's gthr-default.h
# #includes <pthread.h>, which winpthreads provides. (Ordering per the standard
# mingw-w64 posix recipe: crt -> winpthreads -> libgcc -> finish gcc.)
log "[5/7] winpthreads"
mkdir -p "$BUILD/winpthreads"; cd "$BUILD/winpthreads"
CC_FOR_BUILD="$HOST_GCC" \
"$MINGW_SRC/mingw-w64-libraries/winpthreads/configure" \
  --build="$BUILD_TRIPLET" --host="$TARGET" \
  --prefix="$TARGET_PREFIX" --enable-shared --enable-static \
  || { echo "==== winpthreads config.log (tail) ====" >&2; tail -120 config.log >&2; exit 1; }
make -j"$JOBS"
make install

# --- Stage 6: libgcc -------------------------------------------------------
log "[6/7] libgcc"
cd "$BUILD/gcc"
make -j"$JOBS" all-target-libgcc
make install-target-libgcc

# --- Stage 7: finish GCC (libstdc++ etc.) ----------------------------------
log "[7/7] finish GCC"
cd "$BUILD/gcc"
make -j"$JOBS"
make install

# Quick in-place sanity before packaging.
"$PREFIX/bin/$TARGET-gcc" -v 2>&1 | tail -1 >&2

# --- Package ---------------------------------------------------------------
log "Packaging $ROOT_NAME"
bash "$PACKAGE_SCRIPT" \
  --prefix "$PREFIX" \
  --src "$SRC" \
  --root-name "$ROOT_NAME" \
  --out-tar "$OUT_TAR" \
  --out-sha "$OUT_SHA"
BUILD_OK=1
log "Done: $OUT_TAR"
