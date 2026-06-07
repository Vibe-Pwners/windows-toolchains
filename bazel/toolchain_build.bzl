"""`mingw_toolchain` rule: runs the staged binutils -> GCC -> CRT bootstrap.

rules_foreign_cc's configure_make is deliberately NOT used: it cannot express the
chicken-and-egg ordering between core GCC, the mingw-w64 CRT, libgcc and the final
GCC. Instead one tracked action runs build/build-stages.sh with the pinned Bootlin
host compiler and pinned source tarballs as declared inputs, then build/package.sh
produces the distributable tarball + checksum.

Hermeticity boundary (honest): the compiler and all sources are pinned. The
autotools *build helpers* (make/bison/flex/m4/gawk/texinfo/rsync/xz/file) come from
the host. The action runs with no network.
"""

load("//bazel:versions.bzl", "ARCHIVES", "BOOTLIN", "GLIBC_FLOOR", "VERSIONS")

_SRC_ATTRS = ["gcc_src", "binutils_src", "mingw_src", "gmp_src", "mpfr_src", "mpc_src"]

def _root_name(target, exceptions):
    return "mingw-w64-gcc-{gcc}-ucrt-posix-{eh}-{target}-linux-x86_64".format(
        gcc = VERSIONS["gcc"],
        eh = exceptions,
        target = target,
    )

def _impl(ctx):
    root = _root_name(ctx.attr.target, ctx.attr.exceptions)
    out_tar = ctx.actions.declare_file(root + ".tar.xz")
    out_sha = ctx.actions.declare_file(root + ".tar.xz.sha256")

    # Map each source/host tarball to its File and its strip_prefix.
    srcs = {
        "gcc": ctx.file.gcc_src,
        "binutils": ctx.file.binutils_src,
        "mingw": ctx.file.mingw_src,
        "gmp": ctx.file.gmp_src,
        "mpfr": ctx.file.mpfr_src,
        "mpc": ctx.file.mpc_src,
        "bootlin": ctx.file.bootlin_host,
    }
    strip = {
        "gcc": ARCHIVES["gcc_src"]["strip_prefix"],
        "binutils": ARCHIVES["binutils_src"]["strip_prefix"],
        "mingw": ARCHIVES["mingw_src"]["strip_prefix"],
        "gmp": ARCHIVES["gmp_src"]["strip_prefix"],
        "mpfr": ARCHIVES["mpfr_src"]["strip_prefix"],
        "mpc": ARCHIVES["mpc_src"]["strip_prefix"],
        "bootlin": ARCHIVES["bootlin_host"]["strip_prefix"],
    }

    env = {
        "TARGET": ctx.attr.target,
        "EXCEPTIONS": ctx.attr.exceptions,
        "ROOT_NAME": root,
        "GLIBC_FLOOR": GLIBC_FLOOR,
        "V_GCC": VERSIONS["gcc"],
        "V_BINUTILS": VERSIONS["binutils"],
        "V_MINGW": VERSIONS["mingw_w64"],
        "V_GMP": VERSIONS["gmp"],
        "V_MPFR": VERSIONS["mpfr"],
        "V_MPC": VERSIONS["mpc"],
        "BOOTLIN_RELEASE": BOOTLIN["release"],
        "PACKAGE_SCRIPT": ctx.file._package.path,
        "OUT_TAR": out_tar.path,
        "OUT_SHA": out_sha.path,
        # GIT_COMMIT is intentionally NOT set here so CI can inject the real SHA
        # via `--action_env=GIT_COMMIT=$GITHUB_SHA` (use_default_shell_env passes
        # it through); package.sh falls back to "unknown" locally.
    }
    for key, f in srcs.items():
        env["TARBALL_" + key.upper()] = f.path
        env["STRIP_" + key.upper()] = strip[key]

    inputs = [srcs[k] for k in srcs] + [ctx.file._build_stages, ctx.file._package]

    ctx.actions.run_shell(
        mnemonic = "MingwToolchain",
        progress_message = "Bootstrapping %s (UCRT, %s)" % (ctx.attr.target, ctx.attr.exceptions),
        inputs = inputs,
        outputs = [out_tar, out_sha],
        command = 'exec bash "%s"' % ctx.file._build_stages.path,
        env = env,
        use_default_shell_env = True,  # need PATH to host make/bison/flex/...
        execution_requirements = {
            # GCC bootstrap is heavy and not worth remote-caching across machines
            # with different host helpers; keep it local and don't sandbox-copy GBs.
            "no-remote-exec": "1",
        },
    )
    return [DefaultInfo(files = depset([out_tar, out_sha]))]

_mingw_toolchain = rule(
    implementation = _impl,
    attrs = {
        "target": attr.string(mandatory = True),
        "exceptions": attr.string(mandatory = True, values = ["seh", "dw2", "sjlj"]),
        "gcc_src": attr.label(default = "@gcc_src//file", allow_single_file = True),
        "binutils_src": attr.label(default = "@binutils_src//file", allow_single_file = True),
        "mingw_src": attr.label(default = "@mingw_src//file", allow_single_file = True),
        "gmp_src": attr.label(default = "@gmp_src//file", allow_single_file = True),
        "mpfr_src": attr.label(default = "@mpfr_src//file", allow_single_file = True),
        "mpc_src": attr.label(default = "@mpc_src//file", allow_single_file = True),
        "bootlin_host": attr.label(default = "@bootlin_host//file", allow_single_file = True),
        "_build_stages": attr.label(
            default = "//build:build-stages.sh",
            allow_single_file = True,
        ),
        "_package": attr.label(
            default = "//build:package.sh",
            allow_single_file = True,
        ),
    },
)

def mingw_toolchain(name, target, exceptions, **kwargs):
    """Build one MinGW-w64/UCRT cross toolchain tarball.

    Produces <root>.tar.xz and <root>.tar.xz.sha256 where <root> encodes the
    GCC version, runtime (ucrt), thread model (posix), exception model and target.
    """
    _mingw_toolchain(name = name, target = target, exceptions = exceptions, **kwargs)
