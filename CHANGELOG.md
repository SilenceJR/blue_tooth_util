# Changelog

## Unreleased

- 增加版本化不可变的 `RingOtaRecoveryMetadata`、`RingOtaPackage.recoveryMetadata` 和
  `RingOtaPackageParser.parseForRecovery()`；进程重启后可用首次 `0x0402` 原始 16 字节
  payload 安全重建包，并重新执行全部格式、能力、产品、版本、地址和 CRC 门禁。
- `RingOtaInfo.toPayload()` 支持 `0x0402` 信息精确往返；恢复元数据不包含分区数据或断点，
  也不证明固件来源或签名，App 仍须重新校验文件长度、SHA-256、签名、有效期和授权。
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
- 更新 Example iOS 构建配置到当前 Flutter 要求的 iOS 15.0，并记录 CocoaPods workspace/lock 以复现 Simulator 与 iPhoneOS 构建。
- B6 重新通过 Android debug APK、iOS Simulator 和 iPhoneOS no-codesign 构建；Pixel 8 Pro 已启动 Example，iPhone 签名安装仍受本机账户和描述文件阻断。
- Android 与 iPhone 真机的扫描、MTU、断连重连及无响应写仍需设备验证。
