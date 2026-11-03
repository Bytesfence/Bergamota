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
"$VENV/bin/ninja" --version >/dev/null 2>&1 || { echo "FATAL: $VENV/bin/ninja missing (pip install ninja into the venv)"; exit 1; }
echo "ninja ok: $("$VENV/bin/ninja" --version) at $VENV/bin/ninja (build-turnip.sh puts it on PATH)"

# --- pre-create the mesa-turnip26 tree ourselves.
# build-turnip.sh's `git clone --shared` from the tag-only shallow source yields an EMPTY
# repo on some git versions (reproduced locally: no refs/heads in a --branch <tag> clone,
# so the shared clone has nothing to check out and every patch fails with "No such file").
# We clone directly from gitlab and PIN the tag's commit; build-turnip.sh then skips its
# own tree-prep block entirely ([ ! -d mesa ]).
TURNIP_D="$WORK/mesa-turnip26"
MESA_SRC="$WORK/mesa-src-26.2.5"
MESA_URL=https://gitlab.freedesktop.org/mesa/mesa.git
# mesa-26.2.5^{tag} (verified 2026-11-03 via ls-remote; all 6 mesa-26.2 patches apply cleanly)
MESA_TAG_COMMIT=ddaf85e353442d9d7f192fdcf1823e652e3f2ee3
if [ ! -f "$MESA_SRC/meson.build" ]; then
  git clone -q --depth 1 --branch mesa-26.2.5 "$MESA_URL" "$MESA_SRC"
fi
if [ ! -f "$TURNIP_D/mesa/src/compiler/air/air_to_nir.c" ]; then
  rm -rf "$TURNIP_D/mesa"
  git clone -q --depth 1 --branch mesa-26.2.5 "$MESA_URL" "$TURNIP_D/mesa"
  [ "$(git -C "$TURNIP_D/mesa" rev-parse HEAD)" = "$MESA_TAG_COMMIT" ] || { echo "FATAL: mesa-26.2.5 tag moved (expected $MESA_TAG_COMMIT)"; exit 1; }
  for p in air-frontend ir3-round-default ir3-ssbo-subdword ir3-context-error-return ir3-disk-cache-macho turnip-ios; do
    git -C "$TURNIP_D/mesa" apply "$ROOT/gpu/metal/patches/mesa-26.2/$p.patch" || { echo "FATAL: mesa-26.2 patch $p does not apply"; exit 1; }
    echo "mesa patched: $p"
  done
  mkdir -p "$TURNIP_D/mesa/src/compiler/air"
  for f in "$ROOT"/gpu/metal/air/*; do ln -sf "$f" "$TURNIP_D/mesa/src/compiler/air/$(basename "$f")"; done
  echo "mesa tree prepped: $(git -C "$TURNIP_D/mesa" rev-parse --short HEAD) + 6 patches + air/ symlinked"
fi

# meson >=1.11 (pip-latest on CI) rejects `pkg_config_libdir` as a cross-file option, which
# kills build-turnip.sh's meson setup SILENTLY (its error goes to setup-ios.log). The submodule
# is cloned pristine from upstream, so neutralize the line here and keep the same Homebrew
# SPIRV-Tools guard via the PKG_CONFIG_LIBDIR env var (exported below).
sed -i '' "/^pkg_config_libdir = /d" "$ROOT/gpu/metal/turnip/build-turnip.sh"
grep -q "^pkg_config_libdir = " "$ROOT/gpu/metal/turnip/build-turnip.sh" && { echo "FATAL: sed did not remove pkg_config_libdir"; exit 1; }
echo "build-turnip.sh patched for meson >=1.11 (pkg_config_libdir line removed)"

export PKG_CONFIG_LIBDIR="$TURNIP_D/pc-ios"   # the guard build-turnip.sh's cross file used to carry
bash "$ROOT/gpu/metal/turnip/build-turnip.sh" || {
  echo "== build-turnip.sh FAILED =="
  echo "== setup-ios.log tail:"; tail -80 "$TURNIP_D/setup-ios.log" 2>/dev/null
  echo "== meson-log.txt tail:"; tail -120 "$TURNIP_D/build-ios/meson-logs/meson-log.txt" 2>/dev/null
  exit 1
}

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
