#!/bin/bash
# 安装并启动应用，然后断开连接

echo "Building and installing app..."
flutter build ios --debug

echo "Launching app on device..."
# 使用 flutter run 启动应用，然后在2秒后发送 'q' 断开连接
(flutter run -d 00008101-000A29A23A12001E --no-hot &) 
PID=$!

# 等待应用启动
sleep 15

# 发送 'q' 断开连接
kill $PID 2>/dev/null

echo "App installed and launched. You can now manually open it."
