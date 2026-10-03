# Imported ISC SDK

This standalone GUI intentionally does not reference or build ISC-Core source code.

- Origin artifact: `libisc.dylib` and `libisc.h`
- Target: Mach-O arm64, macOS 27
- C ABI: `v1`
- SHA-256 `libisc.dylib`: `749c01ef5620f9712254f2d034dfb0944429a82b287f3e09870c6ad54e9a5b4c`
- SHA-256 `libisc.h`: `4a051d6a464392daf6374ae41a2a9b7c3784ab1b6c49732491747a9078f6b609`

The Swift client uses JSON in/out through the public C ABI, releases every returned string with `isc_free_string`, and uses the documented endpoint paths. The imported library is GPLv3; this GUI is developed under the same license.
