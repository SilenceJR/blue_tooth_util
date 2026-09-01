# App Codex 戒指 OTA 实施交接

> 目标项目：Sublinur App  
> 依赖协议：《戒指BLE_OTA_App对接文档》v1.2.1  
> 本文只定义 App 调整和验收，不授权在 `blue_tooth_util` 内复制页面或网络逻辑。

## 1. 实施前核对

App Codex 开始修改前必须重新读取：

- App 项目的 `AGENTS.md` 和 BLE 项目记忆。
- `blue_tooth_util` README、OTA 对接文档和完整实施计划。
- `BlueToothServer`、设备详情页、设备列表页和现有网络 Repository。
- `RingBleSession`、`BlueToothSdk`、设备缓存和生命周期处理。

必须确认 BLE 包已经公开最终 OTA 类型，不能在 App 内重新实现 CRC、分区解析或 Bootloader 协议。

## 2. 架构调整

### 2.1 状态所有权

新增独立 `RingOtaCoordinator`，使用 GetX Service 管理跨页面和可恢复状态。不要把下载、升级状态机继续堆入 `BlueToothServer`。

`RingOtaCoordinator` 依赖：

- `RingFirmwareRepository`：固件清单、下载、SHA-256 和签名验证。
- `BlueToothServer`：业务会话交接、已绑定设备和 OTA 独占锁。
- `blue_tooth_util`：包解析、`RingOtaUpdateSession`、ACK 限流进度、跨连接恢复和 `0x0402` 最终确认。
- 原子持久化存储：升级意图和已验证包信息。

P0 恢复公开 API：`RingOtaInfo.toPayload()`、`RingOtaPackage.recoveryMetadata`、
`RingOtaRecoveryMetadata.decode(Map<String, Object?>)` 和
`RingOtaPackageParser.parseForRecovery(bytes, metadata: ...)`。恢复元数据使用稳定的
`versionPolicy` 字符串和首次 `0x0402` 精确 16 字节 payload；App 不得依赖 enum ordinal，
也不得访问或重建包/分区私有构造器。

`BlueToothServer` 保留普通 BLE 所有权，但需提供窄接口：

- 请求 OTA 独占权。
- 释放业务会话并停止自动业务同步。
- OTA 完成后恢复业务连接。
- OTA 期间拒绝时间同步、查询、寻找、翻转和设置类命令。

### 2.2 会话类型

移除连接成功后对 `RingBleSession` 的无条件强制转换。显式区分业务会话和 OTA 更新任务，不使用异常捕获维持兼容。App 在释放业务会话后，通过 `BlueToothSdk.createRingOtaUpdateSession(identity: ...)` 创建 BLE 更新会话；不要自行复制 OTA 扫描、重试或版本确认状态机。

同一时间只允许一个 OTA。新的升级请求应复用当前任务或返回“升级进行中”，不得创建嵌套状态机。

## 3. 固件清单和下载

新增独立 `RingFirmwareApi` 和 `RingFirmwareRepository`，不要复用 App 自身升级、设备绑定或推送注册接口。

固件检查在普通戒指连接及数据同步完成后异步执行：

- 不阻塞“已连接”状态和首页响应。
- 相同产品、设备版本和 App 版本缓存 24 小时。
- 设备详情页允许手动刷新。
- 网络失败只隐藏新提示或显示可重试状态，不影响普通戒指使用。

下载要求：

- 使用现有 Dio、取消令牌和 `Result`。
- 先写临时文件，刷新并校验后原子替换。
- 校验 HTTPS 来源、清单签名、SHA-256、文件长度和失效时间。
- 调用 BLE 包解析器校验产品、版本、分区和 CRC。
- 任一校验失败不得发送 `0x0401`。

BLE 包解析成功后，App 可保存 `RingOtaPackage.recoveryMetadata.toJson()` 作为进程重启恢复摘要。该摘要不是签名或来源真实性证明；每次恢复都必须重新读取原始固件并验证文件长度、SHA-256、签名、有效期和更新授权，再调用 `RingOtaRecoveryMetadata.decode()` 与 `RingOtaPackageParser.parseForRecovery()`，不得在 App 内手工重建 `RingOtaPackage` 或 `RingOtaPartition`。

## 4. 设备身份

持久化绑定设备的应用模式 MAC。进入 OTA 后计算派生 MAC：最低字节加一，按 8 位回绕。

扫描过程：

1. OTA Service UUID 或 `BS Ring OTA` 只筛选候选设备。
2. 必须解析 Manufacturer Data。
3. 只有其中 MAC 等于派生 MAC 才连接。
4. 多枚候选设备出现时继续等待目标，不能默认连接信号最强设备。

iOS 的 `deviceId` 是系统标识，不能用于关联业务模式和 OTA 模式。Android 地址只能辅助日志诊断。

## 5. 页面和交互

- 普通连接只显示轻量更新提示，不弹出阻塞式多层对话框。
- 设备详情页显示持久升级卡片。
- 用户确认后进入独立升级页。
- 升级页显示准备、下载、校验、切换模式、传输、重启和确认结果。
- BLE 包只在 ACK 增加至少 1% 或距上次纯进度通知至少 250 ms 时发布进度；Coordinator 只转发/持久化必要快照，页面不监听数据包。
- START_OTA 前允许取消。
- 开始写入后不显示普通取消按钮；返回和关闭 App 前显示单层风险提示。
- 升级页保持亮屏。
- 前台保证传输；短暂后台不主动断开，但不承诺持续执行。
- 回前台检查升级意图、目标设备和连接状态，必要时让用户确认恢复。
- 普通更新可稍后处理；服务端标记 `required` 时只限制戒指业务。
- App 其他页面、解绑和恢复入口继续可用。

避免页面套对话框、对话框再进入加载弹窗。所有错误归一成页面状态和一个可操作按钮。

## 6. 中断和恢复

原子保存：

- 应用模式 MAC 和派生 OTA MAC。
- 产品、当前版本和目标版本。
- 已验证包路径、文件长度和 SHA-256。
- 更新策略、阶段和尝试次数。
- 用户是否已确认升级。

发送 `0x0401` 前，升级意图、规范化应用模式 MAC、原始固件文件引用和
`RingOtaRecoveryMetadata` 必须作为一个持久化事务原子落盘。恢复元数据不是签名或来源
真实性证明；每次恢复仍须重新验证文件长度、SHA-256、签名、有效期和更新授权。
不保存分区数据、ACK 字节、burst 断点、平台 `deviceId` 或“已经验证”布尔值。协议在断连
或进程重启后要求从 Bootloader START_OTA 完整重传。

设备已停留 OTA 模式时，App 直接把 `parseForRecovery()` 结果交给已有的
`RingOtaUpdateSession.update(package)`，不要求先建立业务 Session，也不重新发送 `0x0401`。
BLE 包会扫描精确 OTA Manufacturer Data、连接后从 START_OTA 开始完整传输；
`OTA_COMPLETE` 后仍需回业务模式并用 `0x0402` 确认目标版本。

示例调用链（固件文件的长度、哈希、签名、有效期和授权校验由 App 完成）：

```dart
final metadataResult = RingOtaRecoveryMetadata.decode(
  Map<String, Object?>.from(persistedJson),
);
final packageResult = metadataResult.match(
  ok: (metadata) => const RingOtaPackageParser().parseForRecovery(
    firmwareBytes,
    metadata: metadata,
  ),
  err: (failure) => Result.err(failure),
);
if (packageResult case Ok(:final value)) {
  final session = sdk.createRingOtaUpdateSession(identity: identity);
  final result = await session.update(value);
  // 仅 result 成功且内部 0x0402 版本匹配时清理升级意图。
}
```

启动或回前台时：

- 有升级意图且发现目标 OTA 设备时，说明原因并询问是否恢复。
- 发现业务模式且版本已经匹配时，完成并清理升级意图。
- 发现业务模式但版本未变化时，允许重新开始。
- 找不到设备时保留意图，提供“重新扫描”和“稍后处理”。
- 连续自动恢复三次失败后停止自动重试，避免耗电和循环提示。

## 7. 成功和错误

OTA_COMPLETE 不能直接映射为 UI 成功。

成功条件：

1. 设备重启回 `BS Ring 2`。
2. App 重新连接业务会话。
3. `0x0402.fw_version` 等于目标版本。
4. 计数和提醒配置回读成功或明确给出独立同步错误。

错误至少区分：

- 电量不足或设备未充电。
- Bootloader 不在位或安全能力不足。
- 固件产品不匹配、包损坏或签名失败。
- 未发现目标 OTA 设备。
- 距离过远或蓝牙中断。
- 设备停留在 OTA 恢复模式。
- 升级写入完成但业务固件未启动。

所有文本维护中、英、阿 ARB，并验证 RTL、长文本和小屏幕。

## 8. 版本和安全策略

- 目标版本更高：普通升级。
- 目标版本相同：仅恢复入口允许签名包重刷。
- 目标版本更低：普通 UI 拒绝；服务工程包需服务端按工单和设备授权。
- `boot_flags` bit 1 为 1 时，明文包必须被拒绝。
- 生产策略要求的能力位缺失时，不得降级为明文兼容流程。
- App 验证服务端签名和 SHA-256；设备 AES-CCM/MIC 是独立的设备侧校验，两者均需通过。

## 9. 性能约束

- 固件检查不进入连接主路径。
- 文件校验放在异步任务中，不阻塞页面构建。
- 传输使用迭代状态机，不递归重试。
- UI 进度最多每 250 ms 或增加 1% 更新一次。
- Coordinator 只发布不可变快照，页面不直接处理 BLE Notify。
- 一次失败只产生一个用户可操作状态，不叠加 SnackBar、弹窗和路由跳转。

## 10. App 验收

- 普通 BLE 功能无回归。
- 多枚 OTA 戒指同时在场时只连接目标设备。
- 网络慢或失败不拖慢普通连接。
- 非法固件在切换 OTA 模式前被拒绝。
- 杀 App、锁屏、关闭蓝牙和断电后可以恢复。
- 强制更新失败不阻断整个 App。
- OTA_COMPLETE 后不会提前显示成功。
- Android 真机和 iPhone 真机均完成成功、断连和恢复场景。
- App README、项目记忆、协议副本和用户文档与实现状态一致。

## 11. 需回传本包确认的变更

App Codex 审查中如发现以下问题，应先回传方案，不写临时兼容代码：

- BLE 包公开类型不足。
- `BlueToothServer` 无法安全移交会话。
- iOS Manufacturer Data 无法稳定取得。
- 服务端清单缺少安全字段。
- 产品或版本编码与设备返回不一致。
- 后台持续升级需要 Android 前台服务或额外 iOS 原生能力。
