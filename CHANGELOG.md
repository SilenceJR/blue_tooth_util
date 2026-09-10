# Changelog

## 2026-09-10 OTA v1.7

- 统一 ver16、严格拒绝版本槽高字节非零，恢复摘要升级至 schema 2；保留 V0.16 的 0x0112 支持。
- 调试解析支持逐次授权的同版本重刷/降级，保持产品、CRC、Bootloader、加密与地址门禁。
- 按 v1.7 应用 bank 物理布局限制 SRAM 分区为 56 KB，补充协议冲突说明及测试。


## Unreleased

- 增加 `0x0112` 每日诵经提醒与 `queryPrayerReminder/setPrayerReminder/disablePrayerReminder`；模型改为明确的起止小时/分钟及分钟间隔，严格校验和串行应答处理，旧固定提醒表不再用于业务。

- 自定义赞念适配专用协议 v1.2 / 固件 0.15：进入必须传入 16 位 taskId；查询与通知精确 15 B，包含首按/完成 UTC 秒。旧 5 B 查询明确返回协议错误，不做兼容解析。
- 增加完整任务结果比较和事件转状态，清零校验覆盖全部字段；金标准帧与边界自动化测试通过，真机联调另行记录。

- 文档同步 v1.6 版本契约：OTA 版本迁移为两段 `ver16`，`0x0402` 与 `.rota` 的高 2 B 固定为零。
  该公开语义尚未在 BLE/App 代码中实施，旧三段版本制品不可作为 v1.6 制品使用。
- 文档同步 v1.5 固件修复结论：`0x0402` 请求 CRC 确认为 `84 3F`，目标响应为
  `00 01 00 00 | Ring2 | 01 | 03 01 03`；`0x0401` 成功响应 `01` 后由设备主动断链并进入
  `BS Ring OTA`。已外部核验新版 `ring_fw_0.1.1.rota` 的版本、长度、头及分区 CRC；制品
  未纳入本仓库，未更新测试夹具或宣称真机验证。
- 文档同步：记录 `0x0401` / `0x0402` 在上游《BLE协议.md》的 §4.14 / §4.15 位置，以及
  固件方提供的 `0x0402` 原始帧 CRC 与当前 CRC16/MODBUS 编码器不一致的阻断项；OTA Service
  数据帧仍不纳入通用业务协议。
- 修复 `0x010B` 查找戒指 start/stop 的 DONE 匹配与并发停止等待，避免停止响应排队或超时。
- 增加自定义赞念公开模型和 `RingBleSession` API：严格处理 `0x0111` 的进入、退出、查询，
  提供 `0x0307` 进度/达标事件和 `0x0306` 52 B 日数据、13 B 批次结束帧；查询操作串行，
  超时后的对账只接受精确 15 B 状态响应。
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
