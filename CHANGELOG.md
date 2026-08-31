# Changelog

## Unreleased

- 将 `universal_ble` 升级到 `>=2.2.0 <2.3.0`，保持插件依赖位于 Transport 层。
- 补充普通 BLE Transport 回归，覆盖扫描映射、实际 MTU、服务发现、Notify 和两种写入模式。
- 增加 `RingOtaInfo`、`RingDeviceIdentity`、`0x0402` 查询和 `0x0401` 进入 OTA 模式的协议基础。
- OTA 目标身份必须同时满足候选名称或 Service 以及 `0x0504` Manufacturer Data 派生 MAC 匹配。
- Android 与 iPhone 真机的扫描、MTU、断连重连及无响应写仍需设备验证。
