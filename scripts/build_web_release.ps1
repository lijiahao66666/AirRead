. "$PSScriptRoot\build_config.ps1"

flutter build web --release `
  --no-web-resources-cdn `
  --pwa-strategy=none `
  --dart-define=AIRREAD_CONFIG_URL="$CONFIG_URL" `
  --dart-define=AIRREAD_API_PROXY_URL="$PROXY_URL" `
  --dart-define=AIRREAD_API_KEY="$API_KEY" `
  --dart-define=APP_VERSION="$APP_VERSION"

if ($LASTEXITCODE -ne 0) {
  Write-Host "Web build failed!" -ForegroundColor Red
  exit 1
}

$zipPath = Join-Path $PSScriptRoot "..\airread-web.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "build\web\*" -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Web build done." -ForegroundColor Green
Write-Host "  config : scripts/build_config.ps1 (UseIpMode=$UseIpMode)"
Write-Host "  output : build/web/"
Write-Host "  zip    : $zipPath"
