#!/bin/bash
# Fetch LibRetro NES and SNES cores for Android
# Downloads from: https://buildbot.libretro.com/nightly/android/latest/
#
# Run from project root: ./scripts/fetch_libretro_cores.sh

BASE_URL="https://buildbot.libretro.com/nightly/android/latest"
ABIS="armeabi-v7a arm64-v8a x86_64"
JNI_LIBS="android/app/src/main/jniLibs"

mkdir -p "$JNI_LIBS"

for abi in $ABIS; do
  mkdir -p "$JNI_LIBS/$abi"
  
  for core in fceumm_libretro_android.so snes9x2010_libretro_android.so; do
    echo "Downloading $core for $abi..."
    curl -sL "$BASE_URL/$abi/$core.zip" -o "/tmp/$core.zip"
    unzip -o -q "/tmp/$core.zip" -d "$JNI_LIBS/$abi"
    rm "/tmp/$core.zip"
  done
done

echo ""
echo "Done. Cores placed in $JNI_LIBS"
echo "Rebuild the app: flutter clean && flutter build apk"
