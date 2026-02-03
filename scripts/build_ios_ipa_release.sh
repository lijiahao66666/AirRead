#!/usr/bin/env bash
set -euo pipefail

SCF_URL="https://1256643821-j52mlcdvkt.ap-guangzhou.tencentscf.com"

flutter clean
flutter pub get

flutter build ipa --release \
  --dart-define=AIRREAD_TENCENT_SCF_URL="$SCF_URL" \
  --obfuscate \
  --split-debug-info=build/symbols/ios

