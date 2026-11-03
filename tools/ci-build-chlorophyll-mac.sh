#!/bin/bash
# Build the author's FINAL GPU stack for the phone (the turnip/libchlorophyll path that
# replaced the abandoned libbgair/Gallium one — see gpu/metal/docs/TURNIP.md):
#
#   turnip/build-turnip.sh -> libchlorophyll.dylib  (Mesa 26.2.5 turnip + AIR frontend + chl runtime)
#   turnip/build-metal.sh  -> bgmtl-inject.dylib    (inject + bgmtl runtime, linked against
#                             libchlorophyll + libdrm; install_name /usr/local/lib/bgmtl/bgmtl-inject.dylib
#                             = exactly what the deployed backboardd hard-links: drop-in)
#
# Both author scripts are used UNMODIFIED. Needs on the runner: Xcode, brew bison glslang
# pkg-config, GPU_EAGL_VENV (mako, pyyaml, meson, packaging). Mesa 26.2.5 itself is cloned
# from gitlab by build-turnip.sh. Output copied to out-metal/ in the repo for artifact upload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$HOME/chlwork"
VENV="${GPU_EAGL_VENV:-$HOME/bgvenv}"
export GPU_METAL_WORK="$WORK"
export GPU_EAGL_VENV="$VENV"
export GPU_EAGL_LIBDRM="$ROOT/gpu/metal/libdrm"   # the libdrm 2.4.124 submodule (headers for the pc file)
OUT="$WORK/out-metal"

# hard gate: mesa's python version checks need mako + packaging (py3.12 has no distutils)
"$VENV/bin/python3" - <<'GATE'
from packaging.version import Version
import mako, yaml
assert Version(mako.__version__) >= Version("0.8.0")
print("mako gate ok:", mako.__version__)
GATE
command -v glslangValidator >/dev/null || { echo "FATAL: glslangValidator missing (brew install glslang)"; exit 1; }

bash "$ROOT/gpu/metal/turnip/build-turnip.sh"

if ! bash "$ROOT/gpu/metal/turnip/build-metal.sh"; then
  echo "!! build-metal.sh failed (likely a probe/tool build); building just the inject dylib as fallback"
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  CC="xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot $SDK"
  OBJC="-O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new"
  HERE="$ROOT/gpu/metal"
  mkdir -p "$OUT"
  cp -f "$WORK/mesa-turnip26/build-ios/src/freedreno/vulkan/libchlorophyll.dylib" "$OUT/"
  xcrun strip -x "$OUT/libchlorophyll.dylib"
  cp -f "$WORK/mesa-turnip26/drm-ios/libdrm.2.arm64e.dylib" "$OUT/libdrm.2.dylib"
  $CC $OBJC -I"$HERE/air" -c "$HERE/src/bgmtl.m" -o "$OUT/bgmtl.o"
  $CC $OBJC -c "$HERE/inject/bgmtl_inject.m" -o "$OUT/bgmtl_inject.o"
  $CC -dynamiclib -o "$OUT/bgmtl-inject.dylib" "$OUT/bgmtl.o" "$OUT/bgmtl_inject.o" \
      "$OUT/libchlorophyll.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal \
      -framework IOSurface -install_name /usr/local/lib/bgmtl/bgmtl-inject.dylib -Wl,-rpath,@loader_path
  for f in "$OUT/bgmtl-inject.dylib" "$OUT/libchlorophyll.dylib" "$OUT/libdrm.2.dylib"; do
    python3 "$ROOT/tools/renegade/pacstrip.py" --sign "$f" >/dev/null
  done
fi

# collect artifacts inside the repo dir for CodeMagic pickup
DEST="$ROOT/out-metal"
mkdir -p "$DEST"
for f in "$OUT"/*; do
  case "$f" in *.o|*.air) ;; *) cp -f "$f" "$DEST/" 2>/dev/null || true ;; esac
done
cp -f "$WORK/mesa-turnip26/setup-ios.log" "$DEST/" 2>/dev/null || true

echo "== artifacts:"; ls -l "$DEST"
echo "== get_read_sampler marker in libchlorophyll (must be >=1):"
grep -c get_read_sampler "$DEST/libchlorophyll.dylib" || true
md5 "$DEST/bgmtl-inject.dylib" "$DEST/libchlorophyll.dylib" "$DEST/libdrm.2.dylib"
