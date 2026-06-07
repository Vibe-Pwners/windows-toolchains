#!/usr/bin/env bash
# Smoke-test a freshly built toolchain tarball: extract it to a *fresh* path
# (also proves relocatability), compile the C and C++ samples, and assert the
# outputs are the right PE class and link against UCRT (api-ms-win-crt-*), not
# the legacy msvcrt. Run via `bazel test //tests/...`.
set -euo pipefail

TARGET=""; EXPECT_CLASS=""; declare -a INPUTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2;;
    --target=*) TARGET="${1#*=}"; shift;;
    --expect-class) EXPECT_CLASS="$2"; shift 2;;  # "PE32" (i686) or "PE32+" (x86_64)
    --expect-class=*) EXPECT_CLASS="${1#*=}"; shift;;
    *) INPUTS+=("$1"); shift;;
  esac
done
: "${TARGET:?}" "${EXPECT_CLASS:?}"

# Resolve a runfiles-relative path to an absolute one.
rf() {
  local p="$1"
  if [ -e "$p" ]; then echo "$p"; return; fi
  if [ -n "${TEST_SRCDIR:-}" ] && [ -e "$TEST_SRCDIR/${TEST_WORKSPACE:-_main}/$p" ]; then
    echo "$TEST_SRCDIR/${TEST_WORKSPACE:-_main}/$p"; return
  fi
  # last resort: search runfiles for the basename
  find "${TEST_SRCDIR:-.}" -name "$(basename "$p")" -print -quit
}

TARBALL=""; HELLO_C=""; HELLO_CC=""
for raw in "${INPUTS[@]}"; do
  p="$(rf "$raw")"
  case "$p" in
    *.tar.xz) TARBALL="$p";;
    *hello.c) HELLO_C="$p";;
    *hello.cc) HELLO_CC="$p";;
  esac
done
[ -f "$TARBALL" ] || { echo "FAIL: no tarball among inputs" >&2; exit 1; }
[ -f "$HELLO_C" ] && [ -f "$HELLO_CC" ] || { echo "FAIL: missing samples" >&2; exit 1; }

WORK="$(mktemp -d "${TEST_TMPDIR:-/tmp}/smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
tar -C "$WORK" -xf "$TARBALL"
ROOT="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)"
GCC="$ROOT/bin/$TARGET-gcc"
GXX="$ROOT/bin/$TARGET-g++"
OBJDUMP="$ROOT/bin/$TARGET-objdump"
[ -x "$GCC" ] || { echo "FAIL: $GCC missing/!executable" >&2; exit 1; }

assert_pe() { # file, label
  local f="$1" label="$2" cls
  cls="$(file -b "$f")"
  echo "  $label: $cls"
  case "$EXPECT_CLASS" in
    "PE32+") echo "$cls" | grep -q "PE32+" || { echo "FAIL: $label not PE32+" >&2; exit 1; } ;;
    "PE32")  echo "$cls" | grep -qE "PE32 " || { echo "FAIL: $label not PE32" >&2; exit 1; } ;;
  esac
}
assert_ucrt() { # exe
  # Capture once: piping objdump into `grep -q` under `set -o pipefail` reports a
  # false failure when grep matches early and SIGPIPEs objdump (exit 141).
  local imports
  imports="$("$OBJDUMP" -p "$1")"
  grep -qiE 'api-ms-win-crt|ucrtbase' <<<"$imports" \
    || { echo "FAIL: $1 not linked against UCRT" >&2; exit 1; }
  if grep -qi 'msvcrt\.dll' <<<"$imports"; then
    echo "FAIL: $1 unexpectedly imports legacy msvcrt.dll" >&2; exit 1
  fi
  return 0
}

echo "== C =="
"$GCC" "$HELLO_C" -o "$WORK/hello-c.exe"
assert_pe "$WORK/hello-c.exe" "hello-c.exe"
assert_ucrt "$WORK/hello-c.exe"

echo "== C++ (threads + exceptions, static runtime) =="
"$GXX" "$HELLO_CC" -std=c++20 -static -static-libgcc -static-libstdc++ -o "$WORK/hello-cxx.exe"
assert_pe "$WORK/hello-cxx.exe" "hello-cxx.exe"
assert_ucrt "$WORK/hello-cxx.exe"

echo "PASS: $TARGET ($EXPECT_CLASS), UCRT-linked, relocatable build OK"
