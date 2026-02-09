#!/usr/bin/env bash
set -euo pipefail

MNN_ROOT="${MNN_ROOT:-/Users/wangjingjing/aiProjects/MNN-Source}"
AIRREAD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$AIRREAD_ROOT/.mnn_build}"

if [ ! -d "$MNN_ROOT" ]; then
  echo "MNN_ROOT not found: $MNN_ROOT"
  exit 1
fi

rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT/ios_device" "$OUT_ROOT/ios_sim"

cd "$OUT_ROOT/ios_device"
cmake "$MNN_ROOT" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$MNN_ROOT/cmake/ios.toolchain.cmake" \
  -DPLATFORM=OS64 -DARCHS="arm64" \
  -DENABLE_BITCODE=0 \
  -DMNN_AAPL_FMWK=1 -DMNN_SEP_BUILD=0 -DMNN_BUILD_SHARED_LIBS=false \
  -DMNN_USE_THREAD_POOL=OFF \
  -DMNN_METAL=ON -DMNN_ARM82=true \
  -DMNN_BUILD_LLM=ON \
  -DMNN_BUILD_DIFFUSION=ON -DMNN_IMGCODECS=ON
cmake --build . --target MNN -j 12

cd "$OUT_ROOT/ios_sim"
cmake "$MNN_ROOT" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$MNN_ROOT/cmake/ios.toolchain.cmake" \
  -DPLATFORM=SIMULATOR64 -DARCHS="arm64" \
  -DENABLE_BITCODE=0 \
  -DMNN_AAPL_FMWK=1 -DMNN_SEP_BUILD=0 -DMNN_BUILD_SHARED_LIBS=false \
  -DMNN_USE_THREAD_POOL=OFF \
  -DMNN_METAL=OFF \
  -DMNN_BUILD_LLM=ON \
  -DMNN_BUILD_DIFFUSION=ON -DMNN_IMGCODECS=ON
cmake --build . --target MNN -j 12

cd "$OUT_ROOT"
rm -rf MNN.xcframework
xcodebuild -create-xcframework \
  -framework "$OUT_ROOT/ios_device/MNN.framework" \
  -framework "$OUT_ROOT/ios_sim/MNN.framework" \
  -output "$OUT_ROOT/MNN.xcframework"

rm -rf "$AIRREAD_ROOT/ios/Frameworks/MNN.xcframework"
cp -R "$OUT_ROOT/MNN.xcframework" "$AIRREAD_ROOT/ios/Frameworks/MNN.xcframework"

cd "$AIRREAD_ROOT/ios"
pod install
