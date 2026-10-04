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
