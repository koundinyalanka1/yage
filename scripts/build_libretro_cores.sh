#!/bin/bash
# ── Build LibRetro cores from source with 16 KB page-size alignment ───
#
# This script clones and builds the libretro cores (fceumm, snes9x2010,
# mgba) for Android using the NDK standalone toolchain, with correct
# 16 KB ELF segment alignment for Google Play compliance.
#
# Prerequisites:
#   - Android NDK r28+ installed (set ANDROID_NDK or ANDROID_HOME)
#   - git, cmake, make
#
# Usage (from project root):
#   chmod +x scripts/build_libretro_cores.sh
#   ./scripts/build_libretro_cores.sh
#
# The built .so files are placed directly into android/app/src/main/jniLibs/

set -euo pipefail

# ── Locate the Android NDK ────────────────────────────────────────────
if [ -n "${ANDROID_NDK:-}" ]; then
  NDK="$ANDROID_NDK"
elif [ -n "${ANDROID_HOME:-}" ]; then
  NDK=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
elif [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  NDK=$(ls -d "$ANDROID_SDK_ROOT/ndk/"* 2>/dev/null | sort -V | tail -1)
else
  echo "ERROR: Set ANDROID_NDK, ANDROID_HOME, or ANDROID_SDK_ROOT."
  exit 1
fi

if [ ! -d "$NDK" ]; then
  echo "ERROR: NDK not found at $NDK"
  exit 1
fi
echo "Using NDK: $NDK"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
if [ ! -d "$TOOLCHAIN" ]; then
  # macOS x86_64 fallback
  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
fi
READELF="$TOOLCHAIN/bin/llvm-readelf"

# ── Configuration ─────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_LIBS="$PROJECT_ROOT/android/app/src/main/jniLibs"
BUILD_DIR="$PROJECT_ROOT/build/libretro-cores"
API_LEVEL=24  # matches minSdk

# ABIs to build.  16 KB pages only matter for arm64-v8a, but we build
# all supported ABIs for consistency.
declare -A ABI_TRIPLES=(
  ["armeabi-v7a"]="armv7a-linux-androideabi"
  ["arm64-v8a"]="aarch64-linux-android"
  ["x86_64"]="x86_64-linux-android"
)

# Cores to build: array of  "repo_url  core_name  makefile_target  output_so_name"
CORES=(
  "https://github.com/libretro/libretro-fceumm.git   fceumm      fceumm_libretro     libfceumm_libretro_android.so"
  "https://github.com/libretro/snes9x2010.git         snes9x2010  snes9x2010_libretro libsnes9x2010_libretro_android.so"
  "https://github.com/mgba-emu/mgba.git               mgba        mgba_libretro       libmgba_libretro_android.so"
  "https://github.com/libretro/Genesis-Plus-GX.git     genesis_plus_gx genesis_plus_gx_libretro libgenesis_plus_gx_libretro_android.so"
)

mkdir -p "$BUILD_DIR"

# ── Clone / update repos ─────────────────────────────────────────────
clone_or_pull() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "  Updating $dir..."
    git -C "$dir" pull --ff-only 2>/dev/null || true
  else
    echo "  Cloning $url..."
    git clone --depth 1 "$url" "$dir"
  fi
}

# ── Build one core for one ABI ────────────────────────────────────────
build_core() {
  local src_dir="$1" core_name="$2" make_target="$3" output_so="$4" abi="$5"
  local triple="${ABI_TRIPLES[$abi]}"
  local cc="$TOOLCHAIN/bin/${triple}${API_LEVEL}-clang"
  local ar="$TOOLCHAIN/bin/llvm-ar"

  echo "  Building $core_name for $abi..."

  local core_build_dir="$BUILD_DIR/${core_name}_${abi}"
  rm -rf "$core_build_dir"
  cp -r "$src_dir" "$core_build_dir"

  local makefile_dir="$core_build_dir"

  # Some cores have Makefile in a subdirectory
  if [ "$core_name" = "mgba" ]; then
    # mgba libretro core uses cmake — handle separately
    build_mgba_cmake "$core_build_dir" "$output_so" "$abi"
    return
  fi

  if [ -f "$core_build_dir/Makefile.libretro" ]; then
    makefile_dir="$core_build_dir"
  elif [ -f "$core_build_dir/src/Makefile.libretro" ]; then
    makefile_dir="$core_build_dir/src"
  fi

  # Build with libretro Makefile
  make -C "$makefile_dir" -f Makefile.libretro \
    platform=android \
    CC="$cc" \
    AR="$ar" \
    LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) \
    clean >/dev/null 2>&1 || true

  make -C "$makefile_dir" -f Makefile.libretro \
    platform=android \
    CC="$cc" \
    AR="$ar" \
    LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) 2>&1

  # Find the built .so and copy it
  local built_so
  built_so=$(find "$makefile_dir" -name "*.so" | head -1)
  if [ -n "$built_so" ]; then
    mkdir -p "$JNI_LIBS/$abi"
    cp "$built_so" "$JNI_LIBS/$abi/$output_so"
    echo "  ✓ Copied to $JNI_LIBS/$abi/$output_so"
  else
    echo "  ✗ Build produced no .so file!"
    return 1
  fi
}

# ── Build mGBA via cmake ──────────────────────────────────────────────
build_mgba_cmake() {
  local src_dir="$1" output_so="$2" abi="$3"
  local cmake_build="$src_dir/build_$abi"
  mkdir -p "$cmake_build"

  cmake -S "$src_dir" -B "$cmake_build" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DANDROID_LD=lld \
    -DCMAKE_C_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DBUILD_LIBRETRO=ON \
    -DBUILD_QT=OFF \
    -DBUILD_SDL=OFF \
    -DBUILD_SHARED=OFF \
    -DBUILD_STATIC=OFF \
    -DUSE_EPOXY=OFF \
    -DUSE_SQLITE3=OFF \
    -DUSE_PNG=OFF \
    -DUSE_ZLIB=ON \
    -DM_CORE_GBA=ON \
    -DM_CORE_GB=ON 2>&1

  cmake --build "$cmake_build" \
    --config Release \
    -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) 2>&1

  local built_so
  built_so=$(find "$cmake_build" -name "*mgba*libretro*.so" -o -name "mgba_libretro.so" | head -1)
  if [ -n "$built_so" ]; then
    mkdir -p "$JNI_LIBS/$abi"
    cp "$built_so" "$JNI_LIBS/$abi/$output_so"
    echo "  ✓ Copied to $JNI_LIBS/$abi/$output_so"
  else
    echo "  ✗ mGBA cmake build produced no .so file!"
    return 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────
echo ""
echo "═══ Building LibRetro Cores with 16 KB Alignment ═══"
echo ""

for core_line in "${CORES[@]}"; do
  read -r repo_url core_name make_target output_so <<< "$core_line"
  echo "── $core_name ──"
  clone_or_pull "$repo_url" "$BUILD_DIR/$core_name"

  for abi in "${!ABI_TRIPLES[@]}"; do
    build_core "$BUILD_DIR/$core_name" "$core_name" "$make_target" "$output_so" "$abi"
  done
  echo ""
done

# ── Verify alignment ─────────────────────────────────────────────────
echo ""
echo "═══ Verifying 16 KB Alignment ═══"
echo ""
FAIL=0
for abi in "${!ABI_TRIPLES[@]}"; do
  echo "── $abi ──"
  for so in "$JNI_LIBS/$abi"/*.so; do
    [ -f "$so" ] || continue
    ALIGN=$("$READELF" -l "$so" 2>/dev/null | grep -m1 'LOAD' | awk '{print $NF}')
    ALIGN_DEC=$((ALIGN))
    if [ "$ALIGN_DEC" -ge 16384 ]; then
      echo "  ✓ $(basename "$so"): $ALIGN"
    else
      echo "  ✗ $(basename "$so"): $ALIGN (NOT 16 KB aligned!)"
      FAIL=1
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "✓ All libraries are 16 KB aligned!"
else
  echo ""
  echo "✗ Some libraries failed alignment check."
  exit 1
fi

echo ""
echo "Rebuild the app: flutter clean && flutter build appbundle --release"
