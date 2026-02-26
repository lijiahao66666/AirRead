$env:GRADLE_USER_HOME="$pwd\android\.gradle-cache"

$configUrl = "http://air-inc.top:9000/config"
$proxyUrl = "http://air-inc.top:9000"
$appVersion = "1.0.0"
$apiKey = "f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73"

flutter build appbundle --release `
  --dart-define=AIRREAD_CONFIG_URL=$configUrl `
  --dart-define=AIRREAD_API_PROXY_URL=$proxyUrl `
  --dart-define=AIRREAD_API_KEY=$apiKey `
  --dart-define=APP_VERSION=$appVersion `
  --obfuscate `
  --split-debug-info=build/symbols/android
