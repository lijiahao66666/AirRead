# AirRead 鏋勫缓閰嶇疆 - Web / Android / iOS 鍏辩敤
# 鍒囨崲澶囨鍓?鍚庯細淇敼 $UseIpMode锛屾墍鏈夋墦鍖呰剼鏈細鍚屾浣跨敤
$UseIpMode = $false   # 澶囨鍓嶆敼涓?$true

if ($UseIpMode) {
  $CONFIG_URL = "http://122.51.10.98/api/config"
  $PROXY_URL  = "http://122.51.10.98/api"
} else {
  $CONFIG_URL = "http://read.air-inc.top/api/config"
  $PROXY_URL  = "http://read.air-inc.top/api"
}

$APP_VERSION = "1.0.0"
$BUILD_NUMBER = $env:BUILD_NUMBER
if (-not $BUILD_NUMBER) { $BUILD_NUMBER = (Get-Date -Format "yyyyMMddHH") }
$API_KEY     = "f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73"
