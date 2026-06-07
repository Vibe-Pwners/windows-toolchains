# Patches

No patches are applied for the current pinned versions.

If a future version bump needs a source fix, drop a `*.patch` here (one file per
logical change, named `<component>-<short-desc>.patch`) and apply it in
`build/build-stages.sh` right after the relevant `tar -xf`, e.g.:

```sh
patch -d "$GCC_SRC" -p1 < "$EXECROOT/patches/gcc-fix-foo.patch"
```

Keep patches minimal and link the upstream bug/commit they correspond to in a
comment at the top of each file. Prefer a version bump over carrying a patch.
