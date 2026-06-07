#!/usr/bin/env bash
# Assemble the installed toolchain tree into a distributable tarball:
#   manifest.json + bundled licenses + SHA256SUMS, then <root>.tar.xz (+ .sha256).
# Invoked by build/build-stages.sh; version/ABI facts are read from the environment.
set -euo pipefail

PREFIX=""; SRC=""; ROOT_NAME=""; OUT_TAR=""; OUT_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    --src) SRC="$2"; shift 2;;
    --root-name) ROOT_NAME="$2"; shift 2;;
    --out-tar) OUT_TAR="$2"; shift 2;;
    --out-sha) OUT_SHA="$2"; shift 2;;
    *) echo "package.sh: unknown arg $1" >&2; exit 1;;
  esac
done
: "${PREFIX:?}" "${ROOT_NAME:?}" "${OUT_TAR:?}" "${OUT_SHA:?}"

# --- bundle licenses (required for a public redistribution) ----------------
LIC="$PREFIX/licenses"; mkdir -p "$LIC"
copy_first() { # dest, candidate paths...
  local dest="$1"; shift
  for c in "$@"; do [ -f "$c" ] && { cp "$c" "$LIC/$dest"; return; }; done
}
copy_first GCC-COPYING3        "$SRC/${STRIP_GCC:-}/COPYING3" "$SRC"/gcc-*/COPYING3
copy_first GCC-COPYING.RUNTIME "$SRC/${STRIP_GCC:-}/COPYING.RUNTIME" "$SRC"/gcc-*/COPYING.RUNTIME
copy_first BINUTILS-COPYING3   "$SRC"/binutils-*/COPYING3
copy_first MINGW-W64-COPYING   "$SRC"/mingw-w64-*/COPYING "$SRC"/mingw-w64-*/COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt

# --- manifest --------------------------------------------------------------
cat > "$PREFIX/manifest.json" <<EOF
{
  "name": "$ROOT_NAME",
  "host": "x86_64-linux-gnu",
  "target": "${TARGET:-unknown}",
  "crt": "ucrt",
  "threads": "posix",
  "exceptions": "${EXCEPTIONS:-unknown}",
  "glibc_floor": "${GLIBC_FLOOR:-unknown}",
  "components": {
    "gcc": "${V_GCC:-?}",
    "binutils": "${V_BINUTILS:-?}",
    "mingw_w64": "${V_MINGW:-?}",
    "gmp": "${V_GMP:-?}",
    "mpfr": "${V_MPFR:-?}",
    "mpc": "${V_MPC:-?}"
  },
  "host_toolchain": "bootlin-x86-64-glibc-stable-${BOOTLIN_RELEASE:-?}",
  "built_from_commit": "${GIT_COMMIT:-unknown}"
}
EOF

# --- per-file checksums inside the tree ------------------------------------
( cd "$PREFIX" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )

# --- archive ---------------------------------------------------------------
PARENT="$(dirname "$PREFIX")"
mkdir -p "$(dirname "$OUT_TAR")"
# Deterministic-ish tar: stable sort, numeric owner, pinned mtime.
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='@1700000000' \
    -C "$PARENT" -cJf "$OUT_TAR" "$ROOT_NAME"

( cd "$(dirname "$OUT_TAR")" && sha256sum "$(basename "$OUT_TAR")" ) > "$OUT_SHA"
echo "packaged $(basename "$OUT_TAR") -> $(cut -d' ' -f1 "$OUT_SHA")" >&2
