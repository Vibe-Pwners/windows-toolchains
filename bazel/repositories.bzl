"""Module extension that fetches every pinned tarball as a raw file.

We use `http_file` (not `http_archive`) on purpose: the toolchain build action
extracts the tarballs itself, so the staged build sees plain, well-known
filenames instead of bzlmod-mangled extracted trees. Every download is pinned by
sha256 (see //bazel:versions.bzl) — omitting a checksum would be non-hermetic.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load(":versions.bzl", "ARCHIVES")

def _sources_impl(_ctx):
    for name, spec in ARCHIVES.items():
        http_file(
            name = name,
            urls = spec["urls"],
            sha256 = spec["sha256"],
            downloaded_file_path = spec["file"],
        )

sources = module_extension(
    implementation = _sources_impl,
    doc = "Pinned upstream source + Bootlin host-toolchain tarballs.",
)
