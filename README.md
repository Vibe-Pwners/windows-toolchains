# windows-toolchains

Reproducible **Linux x86_64 → Windows** cross toolchains (GCC + MinGW-w64,
**UCRT** runtime, **POSIX** threads, C/C++), built by hand in GitHub Actions and
published to GitHub Releases. Two flavors:

| Flavor | Target              | Exceptions | Output  |
|--------|---------------------|------------|---------|
| 64-bit | `x86_64-w64-mingw32`| SEH        | PE32+   |
| 32-bit | `i686-w64-mingw32`  | DW2        | PE32    |

**Bazel drives the build**; a [Taskfile](https://taskfile.dev) is the human/CI
entrypoint. Everything is pinned by SHA256 (see [`bazel/versions.bzl`](bazel/versions.bzl)).

## Pinned versions

GCC `15.2.0` · binutils `2.45` · mingw-w64 `14.0.0` · GMP `6.3.0` · MPFR `4.2.1`
· MPC `1.3.1`. Host compiler: **Bootlin x86-64 glibc stable 2024.05-1**
(gcc 13.3 / glibc 2.39).

> **glibc floor.** The produced cross-compiler *executables* are Linux binaries
> linked against the host toolchain's glibc, so they require **glibc ≥ 2.39** on
> the machine that runs them. Host `libstdc++`/`libgcc` are static-linked, so
> glibc is the only floor. To lower it, pin an older Bootlin release in
> `bazel/versions.bzl` and re-run `task lock`. The floor is recorded in each
> tarball's `manifest.json`.

## Build it yourself

Requires `bazelisk`, `task`, and host build helpers (`task deps` installs them on
Debian/Ubuntu — the *compiler* is pinned, only autotools helpers come from the host).

```sh
task deps          # one-time: build-essential bison flex texinfo gawk gperf ...
task build         # build both tarballs -> bazel-bin/*.tar.xz
task test          # extract to a fresh dir, compile hello.c/.cc, assert PE + UCRT
task package       # copy tarballs + .sha256 into ./dist
task verify        # confirm every pinned SHA256 still matches upstream
task lock          # recompute pins, rewrite versions.bzl + versions.lock
```

Build a single flavor with `task build-x86_64` / `task build-i686`.

## How the build works

The bootstrap can't be a single `configure && make` (core GCC must exist before
the CRT, which must exist before libgcc/libstdc++). The custom Bazel rule
[`mingw_toolchain`](bazel/toolchain_build.bzl) runs one tracked action over
[`build/build-stages.sh`](build/build-stages.sh), which performs the standard
MinGW-w64 seven-stage sequence:

1. **binutils** → 2. **mingw-w64 headers** (`--with-default-msvcrt=ucrt`) →
3. **core GCC** (`all-gcc`) → 4. **mingw-w64 CRT** (UCRT, must match headers) →
5. **winpthreads** → 6. **libgcc** → 7. **finish GCC** (libstdc++ …).
winpthreads precedes libgcc because posix-threaded libgcc `#include`s `<pthread.h>`.

[`build/package.sh`](build/package.sh) then writes `manifest.json`, bundles the
GCC/binutils/mingw-w64 licenses, emits `SHA256SUMS`, and produces the tarball.

Headers/CRT install under `$PREFIX/$TARGET` (no `--with-sysroot`: mingw GCC's
`native_system_header_dir` is `/usr/include`, so a sysroot would misdirect the
header search; the built-in `$prefix/$target/include` path is used instead and
stays relocatable). 

**Hermeticity boundary (honest):** the compiler (Bootlin) and every source are
pinned and the action runs with no network. The autotools *build helpers*
(`make`, `bison`, `flex`, `m4`, `gawk`, `texinfo`, `rsync`, `xz`, `file`) come
from the runner.

## Releasing

The toolchains are built **only on a version tag**. Push a `v*` tag and
[`.github/workflows/release.yml`](.github/workflows/release.yml) runs three gated
phases: **build** each flavor → **smoke-test** the built tarballs → **publish**
the tarballs + `.sha256` to the GitHub Release. Branch/PR pushes run only the
fast [`checks.yml`](.github/workflows/checks.yml) (Bazel analysis + lint, no
toolchain build). Both build and smoke-test jobs run on `ubuntu-24.04` because
the produced cross gcc requires glibc ≥ 2.39 (the Bootlin floor) to execute.

```sh
git tag v0.1.0 && git push origin v0.1.0     # CI builds + publishes
# or locally, if you have gh + a pushed tag:
task release TAG=v0.1.0
```

Each release asset is named
`mingw-w64-gcc-15.2.0-ucrt-posix-<eh>-<target>-linux-x86_64.tar.xz`.

## Consuming from Bazel

Fetch a release asset and instantiate a `cc_toolchain` over it. In the consumer's
`MODULE.bazel`:

```python
bazel_dep(name = "windows_toolchains", version = "0.1.0")  # or git_override / archive_override

http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
http_archive(
    name = "mingw_x86_64_ucrt",
    url = "https://github.com/USER/windows-toolchains/releases/download/v0.1.0/mingw-w64-gcc-15.2.0-ucrt-posix-seh-x86_64-w64-mingw32-linux-x86_64.tar.xz",
    sha256 = "<from the .sha256 asset>",
    strip_prefix = "mingw-w64-gcc-15.2.0-ucrt-posix-seh-x86_64-w64-mingw32-linux-x86_64",
    build_file_content = """
load("@windows_toolchains//bazel:consume.bzl", "mingw_cc_toolchain")
mingw_cc_toolchain(name = "toolchain", target = "x86_64-w64-mingw32", cpu = "x86_64")
""",
)
register_toolchains("@mingw_x86_64_ucrt//:toolchain")
```

Then:

```sh
bazel build //:my_app --platforms=@windows_toolchains//platforms:windows_x64
```

Runtime linkage is **static by default** (`-static-libgcc -static-libstdc++
-static`, static winpthreads) so the produced `.exe` is self-contained. Pass
`static_runtime = False` to `mingw_cc_toolchain` if you'd rather ship the
`libstdc++-6.dll` / `libgcc_s_*.dll` / `libwinpthread-1.dll` that are also bundled
in the tarball.

## Layout

```
Taskfile.yml            orchestration
MODULE.bazel            bzlmod deps + source extension
bazel/versions.bzl      canonical pinned lock (URL + SHA256 + strip_prefix)
bazel/repositories.bzl  module extension (http_file per pinned tarball)
bazel/toolchain_build.bzl  the mingw_toolchain rule
bazel/consume.bzl       downstream cc_toolchain helper
build/build-stages.sh   the 7-stage bootstrap
build/package.sh        manifest + licenses + tar.xz
tests/                  hello.c / hello.cc + smoke-test.sh
platforms/              //platforms:windows_x64, :windows_x86
scripts/lock.py         recompute / verify pins
.github/workflows/      checks.yml (PR: analysis+lint), release.yml (tag: build→smoke→publish)
```

## License

Build scripts in this repo: see [`LICENSE`](LICENSE). The produced toolchains
bundle their own upstream licenses (GPLv3 + GCC Runtime Library Exception for
GCC; see `licenses/` inside each tarball). UCRT is a Windows component shipped
with Windows 10+/Server 2016+ and available via Windows Update on older systems.

## Not in the first release

i686-SJLJ variant, OpenMP/libgomp, Fortran, GDB, bundled CMake/pkg-config,
multilib, Bazel Central Registry publishing. See [`patches/`](patches/) for the
patching convention.
