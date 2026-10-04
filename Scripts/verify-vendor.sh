#!/bin/bash
# Verifies that the vendored ISC-Core kernel artifacts are exactly the published ones.
#
# Phecda links the kernel through the versioned `libisc` C ABI, and nothing else.
# A silently mismatched dylib would be an ABI mismatch that the `isc_api_version`
# runtime check can only partially catch, so the pinned digests in
# Vendor/ISC/SHA256SUMS are checked before every build and bundle step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor/ISC"
SUMS="$VENDOR/SHA256SUMS"

[ -f "$SUMS" ] || { printf 'missing %s\n' "$SUMS" >&2; exit 1; }

if ! (cd "$VENDOR" && shasum -a 256 -c SHA256SUMS); then
    cat >&2 <<'EOF'

The vendored kernel does not match Vendor/ISC/SHA256SUMS.
Refresh both files from the ISC-Core release, which publishes them together:

    cp <ISC-Core>/dist/libisc.dylib <ISC-Core>/dist/libisc.h \
       <ISC-Core>/dist/SHA256SUMS Vendor/ISC/

Do not edit SHA256SUMS by hand; it is the record of what was shipped.
EOF
    exit 1
fi
