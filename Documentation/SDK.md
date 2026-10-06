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

## How the library is found

`libisc.dylib` has the install name `@rpath/libisc.dylib`, so it has to be findable at run time.
There are two situations now, and they resolve differently on purpose.

### The app (Xcode project)

The library is **embedded in the bundle** at `Contents/Frameworks/libisc.dylib` and re-signed with
the app's own identity (`CodeSignOnCopy`). The rpath `@executable_path/../Frameworks` finds it
there.

Keeping the dylib outside the bundle behind an absolute rpath into `Vendor/ISC` is what this
project used to do. That stops working the moment the app is signed for distribution:

```
Library not loaded: @rpath/libisc.dylib
... mapping process and mapped file (non-platform) have different Team IDs
```

That is **library validation**, not the sandbox, and it is why the dylib is embedded now. Ad-hoc
signatures carry no Team ID, so the old arrangement kept working locally and hid the problem
until a real certificate was used.

### Tests and `swift build` (`ISCCore`)

The `ISCCore` target still puts `Vendor/ISC` on its linker search path and adds the repository
paths as rpaths, computed from `#filePath` when the manifest is evaluated. That is what lets a
bare `swift test` link and run with no bundle involved.

Consequences worth knowing:

- Nothing to configure for tests; they work after cloning.
- Moving the repository is fine — the manifest recomputes the paths on the next build.
- If you see `Library not loaded: @rpath/libisc.dylib` while running the **app**, the answer is
  the embedding phase, not rpath flags. Check `Contents/Frameworks/` and `otool -l` first.
