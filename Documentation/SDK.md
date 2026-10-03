# Imported ISC SDK

This standalone GUI intentionally does not reference or build ISC-Core source code.

- Origin artifact: `libisc.dylib` and `libisc.h`
- Target: Mach-O arm64, macOS 27
- C ABI: `v1`
- SHA-256 `libisc.dylib`: `5d17cbe64f6b0d37996d21b7996ade55d563960bc2e4bcd70ad20f57c009acc2`
- SHA-256 `libisc.h`: `4a051d6a464392daf6374ae41a2a9b7c3784ab1b6c49732491747a9078f6b609`

The Swift client uses JSON in/out through the public C ABI, releases every returned string with `isc_free_string`, and uses the documented endpoint paths. The imported library is GPLv3; this GUI is developed under the same license.
