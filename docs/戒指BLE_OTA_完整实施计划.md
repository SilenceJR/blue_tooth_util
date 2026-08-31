# 戒指 BLE OTA 完整实施计划

> 记录日期：2026-08-31  
> 协议基线：《戒指BLE_OTA_App对接文档》v1.2.1  
> 状态：文档与方案已整理，代码尚未实施，设备真机尚未验证

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

真实样本 `ring_fw_0.1.0.rota` 已在本次评审中通过头部、长度和七个分区 CRC 校验。该文件和 `ota_tool.py` 均为临时附件，不复制到本仓库，也不成为测试依赖。

## 3. BLE 包方案

### 3.1 公共类型

计划新增：

- `RingOtaInfo`：设备版本、产品、Bootloader 版本和能力位。
- `RingDeviceIdentity`：MAC 标准化、派生和广播字节序。
- `RingOtaPackage`、`RingOtaPartition`、`RingOtaPackageParser`：升级包解析和拒绝规则。
- `RingOtaProtocolAdapter`、`RingOtaSession`：OTA 模式匹配、初始化和传输。
- `RingOtaTransferSnapshot`、`RingOtaTransferResult`：进度和最终结果。

`RingBleSession` 计划增加 `queryOtaInfo()` 和 `enterOtaMode()`。

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

重试规则：

- `68 87` 从上次确认的 burst 边界重发，最多三次。
- 其他设备错误从 START_OTA 完整重传，最多三轮。
- 控制命令超时重试一次，仍失败则重连。
- 格式、产品、签名和安全能力错误不重试。
- 进度按设备确认字节计算，每 250 ms 或增加 1% 才通知上层。

### 3.4 `universal_ble`

计划在同一 OTA 批次升级到 `>=2.2.0 <2.3.0`。

已在临时副本验证 BLE 包测试、BLE Example iOS Simulator 构建和完整 App iOS Simulator 构建，没有复现 2.1.0 的原生 Swift 文件缺失问题。Android 和 iPhone 真机仍是上线前置条件。

Apple 无响应写流控由 `universal_ble 2.2.0` 处理。BLE 业务层只依赖 `BleTransport` 返回的实际 MTU 和顺序 `await write()`，不复制 CoreBluetooth 或 Android GATT 回调。

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

## 7. 验收场景

- 普通 BLE 扫描、连接、Notify 和业务命令无回归。
- 多枚 OTA 戒指同时在场时不会连接错误设备。
- 非法包在发送 `0x0401` 前被拒绝。
- Android 和 iPhone 均使用实际 MTU 正确分包。
- 杀进程、关闭蓝牙、断电、拿远和低电量后可恢复。
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
