# Imported ISC SDK

This standalone GUI intentionally does not reference or build ISC-Core source code.

- Origin artifact: `libisc.dylib` and `libisc.h`
- Target: Mach-O arm64, macOS 27
- C ABI: `v2`
- Pinned digests: **`Vendor/ISC/SHA256SUMS`** — do not copy hashes into this file.
  That file is the single source of truth, it is copied verbatim from the ISC-Core release,
  and `Scripts/verify-vendor.sh` fails the build when `Vendor/ISC` disagrees with it.
  (These values used to be duplicated here, which is how this page ended up advertising a
  digest that no longer matched the vendored library.)

Run `Scripts/verify-vendor.sh` to print and check the current digests.

The Swift client uses JSON in/out through the public C ABI, releases every returned string with `isc_free_string`, and uses the documented endpoint paths. The imported library is GPLv3; this GUI is developed under the same license — see `LICENSE`.

## Running from Xcode

`libisc.dylib` has the install name `@rpath/libisc.dylib`, so the client has to find it at
run time. That works out differently under the two build systems:

- **SwiftPM** (`.build/out/Products/<config>/`) copies the dylib next to the executable, which
  is what the `@loader_path` rpath is for.
- **Xcode** puts products under `DerivedData`, which has **no relative relationship to the
  source tree** — `Build/Products/Debug` can be walked up any number of levels and never
  reach the repository.

`Package.swift` therefore also adds the **absolute** path of `Vendor/ISC` as an rpath,
computed from `#filePath` when the manifest is evaluated. Consequences worth knowing:

- Nothing to configure in Xcode; Run works after cloning.
- Moving the repository is fine — the manifest recomputes the path on the next build.
- It does not affect a distributed binary: on a machine without that path, dyld falls through
  to the relative rpaths, which is what the packaged layout uses.

If you ever see `Library not loaded: @rpath/libisc.dylib`, check
`otool -l <binary> | grep -A2 LC_RPATH` first — the answer is almost always that the expected
rpath is missing rather than that the file is missing.
