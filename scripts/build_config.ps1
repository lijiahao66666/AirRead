# AirRead 构建配置 - Web / Android / iOS 共用
# 切换备案前/后：修改 $UseIpMode，所有打包脚本会同步使用
$UseIpMode = $true   # 备案前改为 $true

if ($UseIpMode) {
  $CONFIG_URL = "http://122.51.10.98/api/config"
  $PROXY_URL  = "http://122.51.10.98/api"
} else {
  $CONFIG_URL = "http://read-api.air-inc.top/config"
  $PROXY_URL  = "http://read-api.air-inc.top"
}

$APP_VERSION = "1.0.0"
$API_KEY     = "f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73"
