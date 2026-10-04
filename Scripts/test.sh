#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
"$ROOT/Scripts/verify-vendor.sh"
swift build
cp "$ROOT/Vendor/ISC/libisc.dylib" "$ROOT/.build/out/Products/Debug/libisc.dylib"
ISC_SECRET_STORE=file swift test
