# Changelog

## Unreleased

- 将 `universal_ble` 升级到 `>=2.2.0 <2.3.0`，保持插件依赖位于 Transport 层。
- 补充普通 BLE Transport 回归，覆盖扫描映射、实际 MTU、服务发现、Notify 和两种写入模式。
- 增加 `RingOtaInfo`、`RingDeviceIdentity`、`0x0402` 查询和 `0x0401` 进入 OTA 模式的协议基础。
- OTA 目标身份必须同时满足候选名称或 Service 以及 `0x0504` Manufacturer Data 派生 MAC 匹配。
- 增加 `.rota v1` 解析器和不可变包/分区模型，校验 seed 0 CRC、长度、物理 Flash 地址、产品和版本策略。
- 明文包遇到要求加密的设备会被拒绝；未增加 AES-CCM、服务工程降级入口或真实固件测试制品。
- 增加绑定目标身份的 `RingOtaProtocolAdapter`、OTA GATT 协议、`RingOtaSession` 和单轮迭代传输状态。
- 单轮流程使用延迟 REBOOT `04 01`/`00 8A` 后主动断开；传输结果明确仍需业务模式版本确认。
- 初始化失败会释放会话并断开；取消使用稳定的 `BleFailureCode.cancelled`，不递归重试。
- 增加 `RingOtaUpdateSession`、更新快照和最终结果，按目标 Manufacturer Data 在 OTA/业务模式间精确重扫。
- 控制命令超时同链重发一次，`68 87` 从当前 burst 边界最多重发三次；可恢复错误最多执行三轮 START_OTA。
- 进度只按设备确认字节以 250 ms 或 1% 门槛发布；只有业务模式 `0x0402` 版本匹配才返回最终成功。
- Android 与 iPhone 真机的扫描、MTU、断连重连及无响应写仍需设备验证。
