# blue_tooth_util example

用于验证 `blue_tooth_util` 普通 BLE 扫描、连接和业务命令的调试 App。

## 构建

```bash
flutter pub get
flutter test
flutter build apk --debug --no-pub
flutter build ios --simulator --debug --no-pub
flutter build ios --debug --no-codesign --no-pub
```

iOS Example 最低目标为 15.0。真机安装还需要本机 Xcode 登录有效 Apple Developer 账户，并为 `com.silence.bluetoothutilexample.example` 提供开发描述文件。

## 验证边界

Example 当前不提供固件选择、`.rota` 解析入口或 `RingOtaUpdateSession` 操作页。构建、安装和启动只能证明平台容器与插件集成，不能证明真实戒指 OTA、MTU、无响应写流控、断连恢复或最终版本确认。
