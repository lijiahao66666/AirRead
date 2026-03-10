#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/../client"
if [ ! -f "${PROJECT_ROOT}/pubspec.yaml" ]; then
  echo "pubspec.yaml not found: ${PROJECT_ROOT}/pubspec.yaml" >&2
  exit 1
fi
cd "${PROJECT_ROOT}"

# 与 build_config.ps1 保持一致，备案前改为 1
USE_IP_MODE=0

if [ "$USE_IP_MODE" = "1" ]; then
  CONFIG_URL="http://122.51.10.98/api/config"
  PROXY_URL="http://122.51.10.98/api"
else
  CONFIG_URL="http://read.air-inc.top/api/config"
  PROXY_URL="http://read.air-inc.top/api"
fi

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

echo ""
echo "IPA build done. (UseIpMode=$USE_IP_MODE)"
echo "  output: client/build/ios/ipa/*.ipa"
