# Imported ISC SDK

This standalone GUI intentionally does not reference or build ISC-Core source code.

- Origin artifact: `libisc.dylib` and `libisc.h`
- Target: Mach-O arm64, macOS 27
- C ABI: `v1`
- SHA-256 `libisc.dylib`: `c963ed7c130ba0e1c9c1f87fa95ed53796ebedfbaef034cf1c83e57a0ec8c0c2`
- SHA-256 `libisc.h`: `4a051d6a464392daf6374ae41a2a9b7c3784ab1b6c49732491747a9078f6b609`

The Swift client uses JSON in/out through the public C ABI, releases every returned string with `isc_free_string`, and uses the documented endpoint paths. The imported library is GPLv3; this GUI is developed under the same license.
