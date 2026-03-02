#!/usr/bin/env bash
set -euo pipefail

CONFIG_URL="http://read-api.air-inc.top/config"
PROXY_URL="http://read-api.air-inc.top"
APP_VERSION="1.0.0"
API_KEY="f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73"

flutter clean
flutter pub get

flutter build ipa --release \
  --dart-define=AIRREAD_CONFIG_URL="$CONFIG_URL" \
  --dart-define=AIRREAD_API_PROXY_URL="$PROXY_URL" \
  --dart-define=AIRREAD_API_KEY="$API_KEY" \
  --dart-define=APP_VERSION="$APP_VERSION" \
  --obfuscate \
  --split-debug-info=build/symbols/ios

