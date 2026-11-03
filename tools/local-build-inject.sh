#!/bin/bash
# LOCAL (Linux) rebuild of bgmtl-inject.dylib — no CI, ~seconds.
#
#   tools/local-build-inject.sh [linked-dylibs-dir]
#
# Needs (one-time):
#   - sdk-headers.tar.gz from the "sdk headers (dump only)" CodeMagic workflow; unpacked to
#     $SDKROOT (default /tmp/opencode/iossdk) with usr/include and System/Library/Frameworks
#     at its root (the tarball unpacks to sdk-headers/ — move or symlink its contents).
#   - libchlorophyll.dylib + libdrm.2.dylib from any recent full build (they change rarely);
#     pass their directory as $1, default /tmp/opencode/art6/out-metal.
#   - clang + ld64.lld (Debian: llvm-14 + lld packages).
#
# Apple framework symbols are NOT linked here: -undefined dynamic_lookup leaves them to be
# resolved at load time on the phone, exactly like the inject expects (Foundation/Metal/
# IOSurface live in the process already). pacstrip.py --sign finishes the arm64e ad-hoc
# signature, sigcheck.py verifies it, and the md5 is printed for the deploy ladder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDKROOT="${BG_IOS_SDKROOT:-/tmp/opencode/iossdk}"
LIBS_DIR="${1:-/tmp/opencode/art6/out-metal}"
OUT="${2:-/tmp/opencode/out-local}"
[ -d "$SDKROOT/usr/include" ] || { echo "FATAL: no SDK at $SDKROOT (unpack sdk-headers.tar.gz, see header of this script)"; exit 1; }
for f in libchlorophyll.dylib libdrm.2.dylib; do
  [ -f "$LIBS_DIR/$f" ] || { echo "FATAL: $LIBS_DIR/$f missing (pass a full-build out-metal dir)"; exit 1; }
done
command -v ld64.lld-14 >/dev/null || command -v ld64.lld >/dev/null || { echo "FATAL: no ld64.lld (apt install lld)"; exit 1; }
LD="$(command -v ld64.lld-14 || command -v ld64.lld)"
mkdir -p "$OUT"

# mirrors build-metal.sh's flags for the inject (arm64e, iOS 18, non-ARC).
# TARGET_OS_*: the iOS 26 SDK's TargetConditionals.h only feeds Apple clang's __is_target_* builtins
# (and its static fallback wants __APPLE_CPP__/__MACOS_CLASSIC__), so vanilla clang gets no target
# macros at all — Foundation then skips <objc/NSObjCRuntime.h> and NSInteger disappears.
CFLAGS="-target arm64e-apple-ios18.0 -isysroot $SDKROOT -I$ROOT/gpu/metal/air \
  -DTARGET_OS_MAC=1 -DTARGET_OS_IPHONE=1 -DTARGET_OS_IOS=1 \
  -O1 -fno-objc-arc -fno-modules -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
  -Wno-availability"

echo "== compile"
/usr/bin/clang $CFLAGS -c "$ROOT/gpu/metal/src/bgmtl.m" -o "$OUT/bgmtl.o"
/usr/bin/clang $CFLAGS -c "$ROOT/gpu/metal/inject/bgmtl_inject.m" -o "$OUT/bgmtl_inject.o"

echo "== link"
"$LD" -dylib -arch arm64e -platform_version ios 18.0 18.0 \
  -install_name /usr/local/lib/bgmtl/bgmtl-inject.dylib \
  -rpath @loader_path -undefined dynamic_lookup \
  -o "$OUT/bgmtl-inject.dylib" \
  "$OUT/bgmtl.o" "$OUT/bgmtl_inject.o" \
  "$LIBS_DIR/libchlorophyll.dylib" "$LIBS_DIR/libdrm.2.dylib"

echo "== sign"
python3 "$ROOT/tools/renegade/pacstrip.py" --sign "$OUT/bgmtl-inject.dylib" >/dev/null
python3 "$ROOT/tools/sigcheck.py" "$OUT/bgmtl-inject.dylib"
md5sum "$OUT/bgmtl-inject.dylib"
ls -l "$OUT/bgmtl-inject.dylib"
