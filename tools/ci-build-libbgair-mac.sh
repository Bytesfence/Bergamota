#!/bin/bash
# Build libbgair.dylib (AIR -> NIR -> ir3 -> freedreno) for iOS arm64e on a macOS CI runner
# (CodeMagic). This is gpu/metal/build-host.sh + build-ios.sh merged, with the lost gpu-eagl
# cross file recreated against the real iphoneos SDK, and the freedreno-sweet libdrm stand-in
# + a static zlib built for target. Output: out-mac/libbgair.dylib (pacstrip --sign'ed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BG_GPU="$ROOT/gpu"
METAL="$BG_GPU/metal"
WORK="$HOME/mesa-air"
VENV="${GPU_EAGL_VENV:-$HOME/bgvenv}"
MESON="$VENV/bin/meson"
OUT="$ROOT/out-mac"
mkdir -p "$WORK" "$OUT" "$WORK/pc-ios" "$WORK/drm-ios-link"

# hard gate: replicate mesa's EXACT mako check (needs packaging on py>=3.12,
# where the distutils fallback no longer exists) + make it importable for any
# python meson spawns, regardless of how PATH resolves.
BG_SITE="$VENV/bin/python3 -c"
export PYTHONPATH="$("$VENV/bin/python3" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')${PYTHONPATH:+:$PYTHONPATH}"
"$VENV/bin/python3" - <<'GATE' || { echo "FATAL: mesa mako/packaging gate failed for $VENV (PYTHONPATH=$PYTHONPATH)"; exit 1; }
from packaging.version import Version
import mako, yaml
assert Version(mako.__version__) >= Version("0.8.0")
print("mako gate ok: mako", mako.__version__, "+ packaging + yaml")
GATE

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "== SDK: $SDK"
clang --version | head -1

# ---------------- 1. libdrm stand-in (arm64e, PAC-stripped + signed by the repo's own tool)
"$BG_GPU/freedreno-sweet/build.sh" "$WORK/drm-ios" >/dev/null
cp "$WORK/drm-ios/libdrm.2.dylib" "$WORK/drm-ios-link/libdrm.2.dylib"
ln -sf libdrm.2.dylib "$WORK/drm-ios-link/libdrm.dylib"

# ---------------- 2. static zlib for target
if [ ! -f "$WORK/libz-ios/libz.a" ]; then
  mkdir -p "$WORK/libz-ios"
  curl -sL https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz | tar xz -C "$WORK"
  ( cd "$WORK/zlib-1.3.1"
    for f in *.c; do
      # -include unistd.h: zlib's gzlib.c uses lseek without including it on the
      # Apple chain; clang >= 18 makes implicit declarations a hard error.
      xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=18.0 -isysroot "$SDK" -O2 -w -include unistd.h -c "$f" -o "${f%.c}.o"
    done
    libtool -static -o "$WORK/libz-ios/libz.a" *.o )
fi

# ---------------- 3. pkg-config files
cat > "$WORK/pc-ios/libdrm.pc" <<EOP
Name: libdrm
Description: Bergamota libdrm stand-in (gpu/freedreno-sweet)
Version: 2.4.124
Cflags: -I$METAL/libdrm/include/drm -I$METAL/libdrm
Libs: -L$WORK/drm-ios-link -ldrm
EOP
cat > "$WORK/pc-ios/zlib.pc" <<EOP
Name: zlib
Description: static zlib (iOS)
Version: 1.3.1
Cflags: -I$WORK/zlib-1.3.1
Libs: -L$WORK/libz-ios -lz
EOP

# ---------------- 4. the mesa-air tree (same prep as build-host.sh)
D="$WORK/mesa-air"
if [ ! -d "$D/mesa" ]; then
  mkdir -p "$D"
  ( cd "$D"
    git clone -q --shared "$METAL/mesa" mesa
    git -C mesa apply "$BG_GPU/eagl/mesa/bergamota-mesa-25.0.7.patch"
    for p in air-frontend air-ir3 ir3-round-default ir3-shift-split ir3-ssbo-subdword \
             fd-bo-cache-keep fd-bo-cache-skip-busy fd-bo-new-purge-retry fd6-fb-barrier-reorder \
             ir3-context-error-return ir3-disk-cache-macho fd-screen-trim; do
      git -C mesa apply "$METAL/patches/$p.patch" || echo "note: $p already applied"
    done
    mkdir -p mesa/src/compiler/air
    for f in "$METAL"/air/*; do ln -sf "$f" "mesa/src/compiler/air/$(basename "$f")"; done )
fi

# ---------------- 5. the cross file (recreated: gpu-eagl's ios-hw.cross is lost)
cat > "$D/ios-hw.cross" <<EOP
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
objc = ['xcrun', '--sdk', 'iphoneos', 'clang']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'
[properties]
pkg_config_path = ['$WORK/pc-ios']
c_args = ['-arch', 'arm64e', '-miphoneos-version-min=18.0', '-isysroot', '$SDK', '-Wno-unused-command-line-argument']
# NOTE: no -undefined dynamic_lookup here! With it, every meson has_function
# probe "links" and Mesa gets configured with Linux-isms (memfd_create,
# secure_getenv, posix_fallocate...) that would crash at runtime on iOS.
# Probes must resolve against the real SDK stubs so the feature set is truthful.
c_link_args = ['-arch', 'arm64e', '-miphoneos-version-min=18.0', '-isysroot', '$SDK']
cpp_args = ['-arch', 'arm64e', '-miphoneos-version-min=18.0', '-isysroot', '$SDK', '-Wno-unused-command-line-argument', '-fno-rtti', '-fno-exceptions']
cpp_link_args = ['-arch', 'arm64e', '-miphoneos-version-min=18.0', '-isysroot', '$SDK']
objc_args = ['-arch', 'arm64e', '-miphoneos-version-min=18.0', '-isysroot', '$SDK']
objc_link_args = ['-arch', 'arm64e', '-miphoneos-version-min=18.0', '-isysroot', '$SDK']
[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu = 'aarch64'
cpu_family = 'aarch64'
endian = 'little'
EOP

# ---------------- 6. meson setup + build the dylib
cd "$D"
export PATH="$(brew --prefix bison)/bin:$VENV/bin:$PATH"
if [ ! -d build-ios ]; then
  "$MESON" setup build-ios mesa --cross-file ios-hw.cross --buildtype=release \
    -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm \
    -Dgallium-xa=disabled -Dtools= -Dvulkan-drivers= -Dllvm=disabled -Dglx=disabled \
    -Degl=disabled -Dgbm=disabled -Dplatforms= \
    -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dxmlconfig=disabled \
    -Dbuild-tests=false -Dglvnd=disabled -Dlmsensors=disabled -Dgallium-rusticl=false \
    -Dshader-cache=enabled -Dprefix=/ > setup-ios.log 2>&1 || { tail -30 setup-ios.log; exit 1; }
fi
ninja -j"$(sysctl -n hw.ncpu)" -C build-ios src/gallium/drivers/freedreno/libbgair.dylib

# ---------------- 7. PAC-strip + ad-hoc sign (the repo tool, same as the author's flow)
python3 "$ROOT/tools/renegade/pacstrip.py" --sign \
  -o "$OUT/libbgair.dylib" build-ios/src/gallium/drivers/freedreno/libbgair.dylib
cp "$WORK/drm-ios/libdrm.2.dylib" "$OUT/"
cp setup-ios.log "$OUT/" 2>/dev/null || true
md5 "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib"
grep -c "get_read_sampler" "$OUT/libbgair.dylib" && echo "(get_read_sampler marker count above; >=1 expected)"
ls -la "$OUT"
