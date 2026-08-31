# Changelog

## Unreleased

- 将 `universal_ble` 升级到 `>=2.2.0 <2.3.0`，保持插件依赖位于 Transport 层。
- 补充普通 BLE Transport 回归，覆盖扫描映射、实际 MTU、服务发现、Notify 和两种写入模式。
- Android 与 iPhone 真机的扫描、MTU、断连重连及无响应写仍需设备验证。
