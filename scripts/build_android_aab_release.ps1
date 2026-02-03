$env:GRADLE_USER_HOME="$pwd\android\.gradle-cache"

$scfUrl = "https://1256643821-j52mlcdvkt.ap-guangzhou.tencentscf.com"

flutter build appbundle --release `
  --dart-define=AIRREAD_TENCENT_SCF_URL=$scfUrl `
  --obfuscate `
  --split-debug-info=build/symbols/android
