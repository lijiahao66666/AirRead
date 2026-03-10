. "$PSScriptRoot\build_config.ps1"

$env:GRADLE_USER_HOME = "$pwd\android\.gradle-cache"

flutter build apk --release `
  --target-platform android-arm64 `
  --dart-define=AIRREAD_CONFIG_URL=$CONFIG_URL `
  --dart-define=AIRREAD_API_PROXY_URL=$PROXY_URL `
  --dart-define=AIRREAD_API_KEY=$API_KEY `
  --dart-define=APP_VERSION=$APP_VERSION `
  --obfuscate `
  --split-debug-info=build/symbols/android

if ($LASTEXITCODE -ne 0) {
  Write-Host "APK build failed!" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "APK build done." -ForegroundColor Green
Write-Host "  config: scripts/build_config.ps1 (UseIpMode=$UseIpMode)"
Write-Host "  output: build\app\outputs\flutter-apk\app-release.apk"
