# blue_tooth_util

Sublinur 的 BLE 协议包。包内负责扫描、连接、GATT 传输、协议适配和戒指会话；页面、网络下载、用户交互及跨页面业务状态由主 App 管理。

## 架构边界

- `BleTransport` 隔离 `universal_ble`，协议和测试不直接依赖平台插件。
- `BlueToothSdk` 负责权限、扫描、连接和协议 Adapter 选择。
- `RingProtocolAdapter` 和 `RingBleSession` 负责智能戒指业务协议；业务会话已公开 OTA 信息查询和进入 OTA 模式命令。
- 主 App 页面通过 `BlueToothServer` 使用 BLE，不直接操作 GATT。
- OTA 沿用 Adapter、Session 和 Transport 分层；跨连接恢复由 BLE 包管理，页面、下载和升级意图仍归 App。
- 进程重启后的包恢复只通过 `RingOtaRecoveryMetadata`；`RingOtaPackage` 和
  `RingOtaPartition` 构造器保持私有，App 不手工重建包或分区。

## 协议文档

- [BLE 协议 App 对接实现版](docs/BLE协议_App对接_实现版.md)
- [戒指自定义赞念模式 App 对接文档](docs/戒指_自定义赞念模式_App对接文档.md)
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

自定义赞念（专用协议 v1.2，固件 0.15）由 `RingBleSession` 提供严格校验的
`enterCustomZikr(target, taskId: taskId)`、`exitCustomZikr`、`queryCustomZikr` 以及状态/事件流；
主 App 的 `BlueToothServer` 负责连接生命周期、重连对账、显式结束、忙状态和
本地任务元数据。页面返回、后台或进程终止不发送退出命令；没有可验证的本地任务
元数据时只显示通用“自定义赞念”。进入载荷固定 5 B，查询/上报固定 15 B，
状态和事件均包含任务序号、首按/完成 UTC 秒；时间 0 表示未知。
进入前须确认时间同步成功，完成结果保存后才能退出，退出后查询必须全部清零。
不支持 5 B 状态响应。真实固件升级和硬件验收未由协议单元测试证明。

## 验证

Flutter 包使用：

```bash
flutter analyze
flutter test
```

依赖基线为 `universal_ble >=2.2.0 <2.3.0`。自动化回归覆盖扫描参数和广播映射、权限与可用状态、实际 MTU、服务能力、Notify、带响应写、无响应写顺序和断开调用。

OTA B2 协议基础已实现：`RingOtaInfo` 严格解析 `0x0402` 的 16 字节响应，`RingDeviceIdentity` 负责应用 MAC 标准化、OTA MAC 派生和 `0x0504` Manufacturer Data 身份确认；`RingBleSession.enterOtaMode()` 在收到 `0x0401` 确认后等待设备主动断链，5 秒未断链只返回明确状态，不自动扫描或宣告成功。

OTA B3 包门禁已实现：`RingOtaPackageParser` 只接受通过设备能力、`.rota v1` 结构、seed 0 CRC、分区长度与物理 Flash 范围、8 字节产品和显式版本策略校验的合成或受控包。普通升级只允许更高版本，同版本必须使用 `sameVersionRecovery`，低版本和要求加密的设备一律拒绝；本包未实现 AES-CCM。

OTA B4 单轮正常路径已实现：调用方用绑定目标身份的 `RingOtaProtocolAdapter` 连接，`RingOtaSession` 按实际 MTU、GATT 能力和 Notify 初始化，迭代执行 START_OTA、分区声明、burst 数据、OTA_COMPLETE、延迟 REBOOT 应答和主动断开。`RingOtaTransferResult` 只表示 Bootloader 传输与重启命令完成，`requiresVersionConfirmation` 固定为 true，不能直接显示升级成功。

OTA B5 恢复与最终确认已实现：`RingOtaSession` 对控制命令超时只重发一次，对 `68 87` 从未确认 burst 边界最多重发三次，并只按设备 ACK 字节以 250 ms 或 1% 门槛发布纯进度。`RingOtaUpdateSession` 用最多三轮的迭代流程精确重扫目标 OTA 设备、重新连接并从 START_OTA 整包恢复；只有精确业务 Manufacturer Data 目标重连且 `0x0402.fw_version` 等于包版本时，才返回 `RingOtaUpdateResult`。格式、参数、地址、分包、安全和未知设备错误不自动重试。

P0 跨进程恢复契约已实现：`RingOtaInfo.toPayload()` 精确返回首次业务模式
`0x0402` 的 16 字节 payload；解析成功的 `RingOtaPackage.recoveryMetadata`
保存版本化的设备原始 payload、稳定版本策略字符串、目标版本、总长度、8 字节产品号、
头 CRC 和分区数量。App 重启后重新读取并验证固件文件，再调用
`RingOtaRecoveryMetadata.decode()` 和
`RingOtaPackageParser.parseForRecovery()`；该方法重建 `RingOtaInfo`，复用完整
`.rota` 解析路径并重新执行能力、产品、版本、长度、地址和 CRC 门禁，再对比所有摘要字段。
它不接受跳过校验的参数，也不保存分区数据或断点。已有的
`RingOtaUpdateSession.update(package)` 可以在没有业务 Session、没有发送 `0x0401` 的情况下，
直接扫描 OTA 身份、从 START_OTA 完整重传，并在 `OTA_COMPLETE` 后通过业务 `0x0402` 确认版本。

恢复元数据是包摘要，不是签名或来源真实性证明；App 必须重新验证文件长度、SHA-256、
签名、有效期和更新授权。发送 `0x0401` 前，升级意图、规范化应用模式 MAC、原始固件文件
引用和恢复元数据必须原子落盘；不得持久化分区断点、ACK 字节、平台 `deviceId` 或“已经验证”标记。

协议文档 v1.6 已将 OTA 版本改为两段 `ver16`（`major << 8 | minor`），并要求
`0x0402` 与 `.rota` 原 4 B 版本槽的高 2 B 为零。当前公开类型、版本策略、恢复摘要和测试
仍采用旧三段版本语义；在迁移完成前，本包不能视为 v1.6 兼容。

BLE、MTU、无响应写和 OTA 恢复必须在 Android 与 iPhone 真机验证；模拟器构建只证明编译和原生依赖集成通过。

## B6 构建与设备边界

在 B5 commit `14ab90e` 上重新验证：根包 72 项测试通过；Example widget test 通过；Android debug APK、iOS Simulator debug 和 iPhoneOS debug no-codesign 构建通过。Pixel 8 Pro（Android 17）已安装并以前台 Activity 启动 Example。iOS 15.8.5 iPhone 可被 Flutter 发现，但本机没有对应 Apple Developer 账户和 Provisioning Profile，签名安装失败。

上述证据不包含目标戒指、受控 `.rota`、真实 Manufacturer Data、MTU、无响应写、断连恢复或最终 `0x0402` 验证。Example 当前也没有 OTA 操作入口；因此 B6 只完成构建集成和 Android 容器启动，Android/iPhone 完整 OTA 真机联合验收仍是 App/固件联调门禁。
