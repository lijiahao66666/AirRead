$CONFIG_URL = "http://air-inc.top:9000/config"
$PROXY_URL  = "http://air-inc.top:9000"
$APP_VERSION = "1.0.0"
$API_KEY    = "f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73"

flutter build web --release `
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
Write-Host "  build output : build/web/"
Write-Host "  zip package  : $zipPath"
