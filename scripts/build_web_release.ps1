$CONFIG_URL = "http://air-inc.top:9000/config"
$PROXY_URL  = "http://air-inc.top:9000"
$APP_VERSION = "1.0.0"
$API_KEY    = "f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73"

flutter clean
flutter pub get

flutter build web --release `
  --dart-define=AIRREAD_CONFIG_URL="$CONFIG_URL" `
  --dart-define=AIRREAD_API_PROXY_URL="$PROXY_URL" `
  --dart-define=AIRREAD_API_KEY="$API_KEY" `
  --dart-define=APP_VERSION="$APP_VERSION"

Write-Host ""
Write-Host "Web build output: build/web/"
Write-Host "Deploy this folder to your web server or CDN."
