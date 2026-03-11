. "$PSScriptRoot\build_config.ps1"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\client")
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
if (-not (Test-Path $pubspecPath)) {
  Write-Host "pubspec.yaml not found: $pubspecPath" -ForegroundColor Red
  exit 1
}

Push-Location $projectRoot
try {
  $env:GRADLE_USER_HOME = "$projectRoot\android\.gradle-cache"

  flutter build apk --release `
    --build-number $BUILD_NUMBER `
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
} finally {
  Pop-Location
}

Write-Host ""
Write-Host "APK build done." -ForegroundColor Green
Write-Host "  config: scripts/build_config.ps1 (UseIpMode=$UseIpMode)"
Write-Host "  output: client/build/app/outputs/flutter-apk/app-release.apk"

