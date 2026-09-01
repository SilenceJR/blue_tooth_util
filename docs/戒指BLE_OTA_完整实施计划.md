# 戒指 BLE OTA 完整实施计划

> 记录日期：2026-09-01
> 协议基线：《戒指BLE_OTA_App对接文档》v1.6；BLE/App 版本契约迁移待实施
> 状态：B0 至 B6 的 BLE 代码与构建集成已完成；P0 跨进程恢复包重建契约已实现；Android Example 启动通过，iPhone 签名安装及双平台真实戒指 OTA 联调仍受外部设备、制品和签名条件阻断

## 1. 目标与边界

本计划用于协调戒指固件、`blue_tooth_util`、固件分发服务和 Sublinur App。实施遵循以下边界：

- 戒指固件和 Bootloader 负责 OTA 模式、烧写、设备侧真实性校验、产品限制和最低版本限制。
- `blue_tooth_util` 负责 BLE 协议、`.rota` 解析、OTA 会话和传输状态机。
- App 负责固件清单、下载、签名校验、升级意图、用户交互和业务互斥。
- 服务端负责版本策略、灰度、强制级别、签名清单和固件制品。
- 首轮只完成文档和方案；代码实施需在设备、App 和服务端完成协议核对后开始。

设计按低耦合、高内聚执行。不得把下载、页面状态和 OTA 字节协议集中到同一个 Service，也不得用临时版本判断维持多个协议分支。

## 2. 已确认的协议

### 2.1 模式和身份

- 应用模式广播名为 `BS Ring 2`，业务服务为 `0x56FF`。
- OTA 模式广播名为 `BS Ring OTA`，服务为 `5833ff01-9b8b-5191-6142-22a4536ef123`。
- OTA MAC 等于应用 MAC 最低字节加一，按 8 位回绕。
- Service UUID 和广播名只筛选 OTA 候选设备。
- Manufacturer Data 中的派生 MAC 是确认目标戒指的必要条件。
- iOS 不使用 `deviceId` 关联两种模式。

### 2.2 应用模式命令

- `0x0402` 查询 `fw_version`、`product`、`boot_flags` 和 `boot_ver`。
- `0x0401` 在校验完成后触发进入 OTA 模式。
- `0x0101` 保持 52 B 布局，不承载 patch 版本。

上游《BLE协议.md》位置为 `0x0401` §4.14、`0x0402` §4.15。两条空 Payload 请求的完整业务帧分别为：

- `0x0402`：`89 56 02 04 01 00 01 00 00 00 84 3F B5 3A`；目标响应为 `00 01 00 00 | Ring2 | 01 | 03 01 03`。
- `0x0401`：`89 56 01 04 01 00 01 00 00 00 C4 2A B5 3A`。

v1.5 固件方称已修复 `boot_flags=0` 导致 `0x0401` 返回 `FF 05` 的 AON 寄存器初始化问题；本仓库没有相应真机证据。`0x0401` 成功响应 `01` 后，设备应主动断链、软复位并广播 `BS Ring OTA`。

### 2.2.1 v1.6 版本契约迁移（待实施）

v1.6 将 OTA 版本定义从旧 `major<<16 | minor<<8 | patch` 改为 `ver16 = major<<8 | minor`。`0x0402` 仍返回 16 B，但偏移 0~1 是 `ver16`、偏移 2~3 必须为零；`.rota` 头偏移 8 的 4 B 槽位同样仅允许低 2 B `ver16`。`0x0101` 偏移 22 已是同编码，因此三处值必须相等。

这不是单纯文档更新：`RingOtaInfo`、`RingOtaPackage`、版本策略、跨进程恢复摘要、测试夹具、App 固件清单和显示都必须采用同一契约。旧 0.1.x 制品与恢复意图不可与 v1.6 混用；迁移方案确认前，当前 BLE 实现不接受作为 v1.6 已完成。

OTA 模式的 START_OTA、PARTITION_INFO、数据流和 REBOOT 属于 PhyPlus OTA Service 协议，只保留在 OTA 对接文档，不并入通用业务协议文档。

`boot_flags` 定义：

- bit 0：Bootloader 在位。
- bit 1：支持并要求 AES-CCM/MIC。
- bit 2：Bootloader 校验产品号。
- bit 3：Bootloader 执行最低版本检查。

### 2.3 `.rota v1`

- 固定头 32 B，分区表项 16 B。
- 固件版本编码为 `major << 16 | minor << 8 | patch`。
- 产品号为 8 B ASCII。
- 打包分区长度不超过 16,384 B。
- `hdr_crc` 覆盖 `[0, 28)` 和完整分区表，CRC 初值为 0。
- 明文 `.rota v1` 只允许开发和内测。

真实样本 `ring_fw_0.1.0.rota` 已在本次评审中通过头部、长度和七个分区 CRC 校验。外部 `ring_fw_0.1.1.rota` 已核验为 76,464 B、7 个分区、`fw_version = 0x000101`、`hdr_crc = 0x3A35`，且全部分区 CRC 匹配；其 SHA-256 为 `a0c73b790fa4b46f81123f6f52f55d2fd62302b18824d9089bb42f690f4c501c`。两者和 `ota_tool.py` 均为外部制品，不复制到本仓库，也不成为测试依赖。

## 3. BLE 包方案

### 3.1 公共类型

分阶段新增：

- `RingOtaInfo`：设备版本、产品、Bootloader 版本和能力位。B2 已实现。
- `RingDeviceIdentity`：MAC 标准化、派生和广播字节序。B2 已实现。
- `RingOtaPackage`、`RingOtaPartition`、`RingOtaPackageParser`：升级包解析和拒绝规则。B3 已实现。
- `RingOtaProtocolAdapter`、`RingOtaSession`：OTA 模式匹配、初始化和传输。B4 已实现单轮正常路径。
- `RingOtaTransferSnapshot`、`RingOtaTransferResult`：协议确认边界状态和 Bootloader 传输结果。B4 已实现，B5 已增加 ACK 进度限流。
- `RingOtaUpdateSession`、`RingOtaUpdateSnapshot`、`RingOtaUpdateResult`：B5 已实现跨连接恢复和业务模式最终版本确认。
- `RingOtaRecoveryMetadata`：P0 已实现版本化、不可变的跨进程恢复摘要；`RingOtaPackage.recoveryMetadata` 只能由已解析包生成，App 通过 `RingOtaRecoveryMetadata.decode()` 和 `RingOtaPackageParser.parseForRecovery()` 重建包。

`RingBleSession.queryOtaInfo()` 和 `enterOtaMode()` 已在 B2 实现。后者只等待设备主动断链并返回 `RingOtaEntryState`，不负责主动断开、重新扫描或 OTA 传输。

### 3.2 解析器

解析器必须独立于 Python 工具，拒绝以下输入：

- 魔数、格式版本或保留字段错误。
- 分区数不在 1 至 32。
- 文件长度、`total_size` 或分区长度之和不一致。
- 头 CRC、分区 CRC 或 checksum 高 16 位错误。
- 产品不匹配或版本策略不允许。
- 分区为空、超过 16,384 B、未按 4 B 对齐。
- SRAM、XIP、应用 bank、loader 或持久化区越界。
- 分区地址重叠或数据被截断。

B3 只拒绝规范化后的物理 Flash 区间重叠；协议没有规定 SRAM `run_addr` overlay 禁令，因此未擅自增加该限制。地址也未增加文档之外的 4 B 或 4 KB 对齐规则。`RingOtaVersionPolicy.normalUpgrade` 只接受更高版本，`sameVersionRecovery` 只接受同版本；低版本没有无签名放行开关。要求 AES-CCM 的设备会拒绝明文 `.rota v1`，加密格式和握手仍需单独方案确认。

测试使用合成小包和确定性 CRC，不提交真实固件。

### 3.3 状态机

状态机保持单层、迭代执行：

1. 查询 OTA 信息并校验包。
2. 发送 `0x0401`，等待设备主动断链。
3. 扫描候选设备并用派生 MAC 确认目标。
4. 连接，取得实际 MTU，发现服务并订阅 Response Notify。
5. 发送 Bootloader START_OTA。
6. 按原始顺序发送全部分区。
7. 收到 OTA_COMPLETE 后发送 REBOOT。
8. 重新连接业务模式并用 `0x0402` 验证目标版本。

B4 已实现步骤 4 至 7 的单轮正常路径，使用 `burst_size = 8` 默认值、严格顺序 `await write()` 和延迟 REBOOT `04 01 → 00 8A → 主动断开`。`OTA_COMPLETE` 与 `RingOtaTransferResult` 均不代表最终升级成功。B5 在不改变该单轮结果语义的前提下实现步骤 8、断连恢复和以下重试规则。

重试规则：

- `68 87` 从上次确认的 burst 边界重发，最多三次。
- 其他设备错误从 START_OTA 完整重传，最多三轮。
- 控制命令超时重试一次，仍失败则重连。
- 格式、产品、签名和安全能力错误不重试。
- 进度按设备确认字节计算，每 250 ms 或增加 1% 才通知上层。

B5 的自动整轮重试仅覆盖连接/写入/超时、`0x17`、`0x64`、`0x66` 和耗尽 burst 重发的 `0x68`。`0x05`、`0x06`、`0x0C`、`0x10`、`0x65`、`0x6A` 及未知错误直接失败。每一轮都创建新 Session，并从 START_OTA 和第一个分区开始；三轮是包含首次在内的总上限，不保存分区断点。最终扫描同时识别精确 OTA 和业务身份：再次出现 OTA 身份会在剩余轮次内恢复，业务身份则必须由 `0x0402` 返回目标版本才能完成。

#### 3.3.1 P0 跨进程恢复契约

`RingOtaInfo.toPayload()` 对称编码首次业务模式 `0x0402` 的精确 16 字节响应，返回独立防御性副本。已通过完整解析的 `RingOtaPackage` 暴露只读 `recoveryMetadata`，其中仅包含：`schemaVersion`、原始 `0x0402` 16 字节 payload、稳定字符串版本策略、目标固件版本、8 字节产品号、`totalSize`、头 CRC 和分区数量。对象及其字节 getter 均不可变；不包含包对象、分区数据、文件路径、SHA-256、签名结果、ACK、burst 断点、平台 `deviceId` 或“已经验证”标记。

`RingOtaRecoveryMetadata.decode()` 要求 v1 精确字段集合，严格检查字段类型、字节长度、数值范围、未知 schema 和未知版本策略，并再次调用 `RingOtaInfo.fromPayload()`；不会信任 JSON 中展开的产品、版本或能力位。`parseForRecovery()` 先从持久化原始 payload 重建设备信息，再调用完整 `parse()`，重新执行 Bootloader/安全能力、magic、格式、保留位、长度、头 CRC、分区 CRC、地址、重叠、顺序、产品和版本策略门禁，最后逐项比较目标版本、`totalSize`、8 字节产品号、头 CRC 和分区数量；任一差异均返回结构化失败，不提供宽松绕过参数。

进程重启时，App 必须先重新读取固件并校验长度、SHA-256、签名、有效期和更新授权，再解码元数据和调用 `parseForRecovery()`。升级意图、规范化应用模式 MAC、原始固件文件引用和恢复元数据必须在发送 `0x0401` 前原子落盘；不得落盘分区断点。设备已经停留 OTA 模式时，现有 `RingOtaUpdateSession.update(package)` 无需业务 Session、不会发送 `0x0401`，直接扫描精确 OTA Manufacturer Data、从 START_OTA 完整重传；`OTA_COMPLETE` 后仍须重启并通过业务 `0x0402` 确认目标版本。

控制命令超时重发没有协议序号。若重发后可能存在的同码重复 ACK 已在后续不同应答等待期间被消费，会话继续；若到下一条同码控制命令前仍无法证明旧 ACK 已排空，会话不会猜测 ACK 代际，而是要求新连接并从 START_OTA 整轮恢复。

### 3.4 `universal_ble`

BLE 包已将依赖升级并锁定到 `universal_ble 2.2.0`，约束为 `>=2.2.0 <2.3.0`。B2 在业务协议层增加 `0x0402`、`0x0401`、OTA 信息和身份模型；Adapter、Session 和模型仍不直接导入平台插件。

BLE 包 B5 根包阶段性测试总数为 72 项；P0 补充 `RingOtaInfo` 精确 payload 往返、恢复 metadata 严格解码/摘要篡改、完整重新解析和无业务 Session 直接 OTA 恢复后，定向测试为 50 项、全量根包测试为 78 项。测试覆盖身份 Adapter、命令字节、MTU/GATT 初始化、burst 与尾包重发、控制超时及迟到/同码 ACK 消歧、多分区、连续 Notify 缓冲、最多三轮 START 恢复、不可重试错误、精确业务身份、最终 `0x0402` 版本门禁、取消、互斥和资源释放，全部使用 fake transport 与合成包。BLE Example widget test、Example iOS Simulator debug 构建和 Android debug APK 构建沿用 B1 证据。完整 App 编译、Android 真机和 iPhone 真机仍是后续验收项。

BLE 业务层只依赖 `BleTransport` 返回的实际 MTU 和顺序 `await write()`，不复制 CoreBluetooth 或 Android GATT 回调。Apple central 模式的高吞吐无响应写仍需 iPhone 真机验证，不能仅凭插件版本或模拟器构建判定流控通过。

`universal_ble 2.2.0` 的 Apple 实现没有向本包公开写前 `canSendWriteWithoutResponse` 检查。B4 只依赖其顺序 Future，不在 Session 内加入延时兼容层；iPhone 真机若出现首包或队列超时，必须先提出 Transport/插件修正方案再改动原生边界。

### 3.5 B6 构建与设备证据

在 BLE commit `14ab90e` 上取得以下新鲜证据：

- 根包 `flutter test`：72 项通过；全仓 `flutter analyze` 仍只有 6 条阶段前既有问题。
- Example `flutter test`：1 项通过；Example analyze 仍为既有的 `common` 直接依赖提示和未使用局部变量两项。
- `flutter build apk --debug --no-pub`：通过。
- `flutter build ios --simulator --debug --no-pub`：通过。
- `flutter build ios --debug --no-codesign --no-pub`：通过。
- Pixel 8 Pro / Android 17：debug APK 安装成功，`MainActivity` 前台运行。
- iPhone / iOS 15.8.5：设备可发现，签名构建因本机没有 Apple Developer 账户和对应 Provisioning Profile 失败，未安装启动。

当前 Flutter 工具链要求 Example iOS 最低目标 15.0；B6 保留该迁移和 CocoaPods workspace/lock，使 clean checkout 能复现本次构建。Example 没有 OTA 操作入口，本阶段也没有受控 `.rota`、目标戒指或密钥，所以没有发送 `0x0401`/START_OTA。真实 Manufacturer Data、实际 MTU、无响应写流控、成功升级、`68 87`、断连恢复和重启后的 `0x0402` 均未执行，不能标记为真机 OTA 通过或生产可用。

## 4. 分发和安全

### 4.1 内部联调

- 只使用明文 `.rota v1`。
- 只允许开发构建、本地导入或受控测试服务。
- App 校验结构、产品、版本、CRC 和下载哈希。
- 不进入普通用户升级入口。

### 4.2 量产

设备侧采用芯片 AES-CCM/MIC，并补充产品号和最低版本检查。App 侧验证 HTTPS、服务端清单签名和 SHA-256。

量产启用条件：

- `boot_flags` bit 0 至 bit 3 符合生产策略。
- AES-CCM 包格式、握手、错误码和密钥生产流程已有独立版本文档。
- AES 密钥、IV 和产线资料不进入 App、仓库或服务端响应。
- App 签名算法、`keyId` 轮换和制品失效策略已确定。
- 普通用户不得降级；同版本只用于受控恢复；服务降级必须绑定签名、工单和设备授权。

## 5. App 和服务端边界

App 的详细改动见《APP_CODEX_戒指OTA实施交接》。服务端需提供独立戒指固件接口，请求不上传 MAC，至少包含产品、硬件版本、当前固件、Bootloader 版本、能力位、App 平台和 App 版本。

响应至少包含：

- `none`、`optional` 或 `required` 更新策略。
- 目标版本、产品和硬件范围。
- HTTPS 下载地址、文件长度和 SHA-256。
- 签名、算法、`keyId` 和失效时间。
- 发布说明和最低电量。

强制更新只限制戒指业务，不阻断 App 其他模块、解绑和 OTA 恢复。

## 6. 实施阶段

1. 同步协议、计划、App 交接和 README。
2. 固件、服务端和 App Codex 完成协议评审。
3. 升级 `universal_ble` 并回归普通 BLE。
4. 实现 `.rota v1` 解析器、OTA Adapter 和会话状态机。
5. 完成内部明文联调和异常注入。
6. 实现 AES-CCM、产品校验和最低版本限制。
7. App Codex 实现清单、下载、签名、恢复和页面。
8. Android 与 iPhone 真机联合验收。
9. 安全门槛全部通过后启用生产升级。

P0 在 B6 之后作为独立修复阶段完成跨进程恢复包重建，仍遵循“只读协议/调用链分析 → 主任务实现 → 测试代理 → 主任务复核 → 只读 Reviewer → 独立提交”。P0 不改变 OTA 传输状态机，不新增分区断点恢复，也不实现 App 下载、页面或 GetX Coordinator。

## 7. 验收场景

- 普通 BLE 扫描、连接、Notify 和业务命令无回归。
- 多枚 OTA 戒指同时在场时不会连接错误设备。
- 非法包在发送 `0x0401` 前被拒绝。
- Android 和 iPhone 均使用实际 MTU 正确分包。
- 杀进程、关闭蓝牙、断电、拿远和低电量后可恢复。
- 进程重启且设备已停留 OTA 模式时，App 可用重新校验的原始固件和恢复元数据重建包；不要求业务 Session、不发送 `0x0401`，从 START_OTA 完整重传。
- 恢复元数据未知 schema、缺失字段、错类型、未知策略、非法 16 字节 `0x0402` payload 或摘要篡改都会被拒绝。
- 发 START_OTA 前等待三分钟能回业务模式。
- 发 START_OTA 后等待三分钟仍能回到 OTA 模式。
- OTA_COMPLETE 后只有业务模式 `0x0402` 版本匹配才显示成功。
- 明文包不能进入生产分发。
- 不满足安全能力位的设备不能执行生产升级。
- 升级后计数、提醒配置和绑定关系不丢失。

## 8. 需再次确认的大型改动

以下内容在编码前单独提交方案，由用户确认：

- AES-CCM 包格式及产线密钥流程。
- 服务端固件清单和签名合同。
- App OTA Coordinator 对 `BlueToothServer` 会话所有权的调整。
- 需要原生 Android 前台服务时的后台升级方案。首版默认前台保证、后台可恢复，不新增前台服务。
- `blue_tooth_util` 公开接口大改，必须先给出方案、影响范围和回退方式并等待确认。

## 9. Codex 和分支执行

BLE 包与 Sublinur App 是两个独立 Git 仓库，不能由一个分支统一承载修改。采用分仓实现、统一门禁审查：BLE 基于 `main` 使用 `codex/ring-ota-ble-core`，App 基于 `dev_347` 使用 `codex/ring-ota-app`，各自在独立 worktree 中执行。

模型分工、阶段依赖、仓库元数据前置问题和可复制提示词见《戒指BLE_OTA_Codex协作执行方案》。BLE 公共 API 和验证 commit 完成前，App 不得编写推测性兼容层。

仓库元数据提交 `7c13ecbc6586b631295ed79022d4b74fe8949672` 已快进合入 `dev_347`。App OTA 持久 worktree 已创建并能初始化固定版本的 BLE submodule；开始 App 实现前仍需将 gitlink 更新到 BLE OTA 分支交付的已验证 commit。
