#!/bin/bash
# Fetch LibRetro cores for Android (NES, SNES, mGBA)
# Downloads from: https://buildbot.libretro.com/nightly/android/latest/
#
# Run from project root: ./scripts/fetch_libretro_cores.sh

BASE_URL="https://buildbot.libretro.com/nightly/android/latest"
ABIS="armeabi-v7a arm64-v8a x86_64"
JNI_LIBS="android/app/src/main/jniLibs"

mkdir -p "$JNI_LIBS"

for abi in $ABIS; do
  mkdir -p "$JNI_LIBS/$abi"
  
  for core in fceumm_libretro_android.so snes9x2010_libretro_android.so mgba_libretro_android.so; do
    echo "Downloading $core for $abi..."
    curl -sL "$BASE_URL/$abi/$core.zip" -o "/tmp/$core.zip"
    unzip -o -q "/tmp/$core.zip" -d "$JNI_LIBS/$abi"
    rm "/tmp/$core.zip"
  done
done

echo ""
echo "Done. Cores placed in $JNI_LIBS"

# ── 16 KB page-size alignment check ──────────────────────────────────
echo ""
echo "Checking 16 KB page-size alignment (arm64-v8a only)..."
HAS_READELF=true
if ! command -v readelf &>/dev/null; then
  # Try Android NDK's llvm-readelf
  READELF=$(find "$ANDROID_HOME/ndk" -name "llvm-readelf" 2>/dev/null | head -1)
  if [ -z "$READELF" ]; then
    echo "  ⚠ readelf not found — skipping alignment check."
    echo "  Install Android NDK or add llvm-readelf to PATH to verify."
    HAS_READELF=false
  fi
else
  READELF="readelf"
fi

if [ "$HAS_READELF" = true ]; then
  MISALIGNED=0
  for so in "$JNI_LIBS/arm64-v8a"/*.so; do
    ALIGN=$("$READELF" -l "$so" 2>/dev/null | grep -m1 'LOAD' | awk '{print $NF}')
    if [ -n "$ALIGN" ]; then
      ALIGN_DEC=$((ALIGN))
      if [ "$ALIGN_DEC" -lt 16384 ]; then
        echo "  ✗ $(basename "$so"): aligned to $ALIGN (needs 0x4000 for 16 KB)"
        MISALIGNED=$((MISALIGNED + 1))
      else
        echo "  ✓ $(basename "$so"): aligned to $ALIGN"
      fi
    fi
  done
  if [ "$MISALIGNED" -gt 0 ]; then
    echo ""
    echo "⚠ $MISALIGNED library(ies) are NOT 16 KB aligned."
    echo "  These may need to be rebuilt from source with: -Wl,-z,max-page-size=16384"
  else
    echo "  All libraries are 16 KB aligned ✓"
  fi
fi

echo ""
echo "Rebuild the app: flutter clean && flutter build apk"
