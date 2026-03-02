# 同站部署：API 通过 HTML 站点的 /api 代理，无 CORS
# 需先在 HTML 站点 nginx 配置中增加 /api 反向代理（见 docs/nginx_html_site_with_api.conf）
$BASE_URL = "http://122.51.10.98"  
$CONFIG_URL = "$BASE_URL/api/config"
$PROXY_URL  = "$BASE_URL/api"
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
Write-Host "Web build done (同站模式)." -ForegroundColor Green
Write-Host "  base url    : $BASE_URL"
Write-Host "  build output: build/web/"
Write-Host "  zip package: $zipPath"
