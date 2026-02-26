#!/usr/bin/env bash
set -euo pipefail

CONFIG_URL="http://air-inc.top:9000/config"
PROXY_URL="http://air-inc.top:9000"
APP_VERSION="1.0.0"

flutter clean
flutter pub get

flutter build ipa --release \
  --dart-define=AIRREAD_CONFIG_URL="$CONFIG_URL" \
  --dart-define=AIRREAD_API_PROXY_URL="$PROXY_URL" \
  --dart-define=APP_VERSION="$APP_VERSION" \
  --obfuscate \
  --split-debug-info=build/symbols/ios

