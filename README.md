# blue_tooth_util

Sublinur 的 BLE 协议包。包内负责扫描、连接、GATT 传输、协议适配和戒指会话；页面、网络下载、用户交互及跨页面业务状态由主 App 管理。

## 架构边界

- `BleTransport` 隔离 `universal_ble`，协议和测试不直接依赖平台插件。
- `BlueToothSdk` 负责权限、扫描、连接和协议 Adapter 选择。
- `RingProtocolAdapter` 和 `RingBleSession` 负责智能戒指业务协议；业务会话已公开 OTA 信息查询和进入 OTA 模式命令。
- 主 App 页面通过 `BlueToothServer` 使用 BLE，不直接操作 GATT。
- OTA 计划继续沿用 Adapter、Session 和 Transport 分层，不在 App 内复制字节协议。

## 协议文档

- [BLE 协议 App 对接实现版](docs/BLE协议_App对接_实现版.md)
- [戒指 BLE OTA App 对接文档](docs/戒指BLE_OTA_App对接文档.md)
- [戒指 BLE OTA 完整实施计划](docs/戒指BLE_OTA_完整实施计划.md)
- [App Codex 戒指 OTA 实施交接](docs/APP_CODEX_戒指OTA实施交接.md)
- [戒指 BLE OTA Codex 协作执行方案](docs/戒指BLE_OTA_Codex协作执行方案.md)

文档中的“协议已定义”“固件已实现”和“真机已验证”是不同状态。OTA 功能在 Android 与 iPhone 真机完成成功、断连和恢复测试前，不得标记为可量产。

## 使用原则

- App 只依赖公开模型、Session 和 `Result`，不解析原始 Notify。
- 协议命令在 Session 内处理等待、DONE 和错误映射。
- UI 禁用用于改善交互，不能代替 Session 层的互斥和状态校验。
- iOS 的平台设备标识不能代替戒指 Manufacturer Data 身份。
- 真实固件、产线密钥、AES IV 和服务端私钥不得提交到本包。

## 验证

Flutter 包使用：

```bash
flutter analyze
flutter test
```

依赖基线为 `universal_ble >=2.2.0 <2.3.0`。自动化回归覆盖扫描参数和广播映射、权限与可用状态、实际 MTU、服务能力、Notify、带响应写、无响应写顺序和断开调用。

OTA B2 协议基础已实现：`RingOtaInfo` 严格解析 `0x0402` 的 16 字节响应，`RingDeviceIdentity` 负责应用 MAC 标准化、OTA MAC 派生和 `0x0504` Manufacturer Data 身份确认；`RingBleSession.enterOtaMode()` 在收到 `0x0401` 确认后等待设备主动断链，5 秒未断链只返回明确状态，不自动扫描或宣告成功。

OTA B3 包门禁已实现：`RingOtaPackageParser` 只接受通过设备能力、`.rota v1` 结构、seed 0 CRC、分区长度与物理 Flash 范围、8 字节产品和显式版本策略校验的合成或受控包。普通升级只允许更高版本，同版本必须使用 `sameVersionRecovery`，低版本和要求加密的设备一律拒绝；本包未实现 AES-CCM。OTA 模式 Session、传输状态机和最终版本确认仍待后续阶段。

OTA B4 单轮正常路径已实现：调用方用绑定目标身份的 `RingOtaProtocolAdapter` 连接，`RingOtaSession` 按实际 MTU、GATT 能力和 Notify 初始化，迭代执行 START_OTA、分区声明、burst 数据、OTA_COMPLETE、延迟 REBOOT 应答和主动断开。`RingOtaTransferResult` 只表示 Bootloader 传输与重启命令完成，`requiresVersionConfirmation` 固定为 true，不能直接显示升级成功。断连重连、设备错误重试、恢复、进度限流和业务模式 `0x0402` 最终确认属于 B5。

BLE、MTU、无响应写和 OTA 恢复必须在 Android 与 iPhone 真机验证；模拟器构建只证明编译和原生依赖集成通过。
