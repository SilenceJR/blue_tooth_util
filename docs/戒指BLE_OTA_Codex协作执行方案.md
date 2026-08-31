# 戒指 BLE OTA Codex 协作执行方案

> 记录日期：2026-08-31
> 状态：BLE B0、B1 和 B2 已完成；`.rota`、OTA 模式状态机、恢复和真机阶段继续按独立提交执行

## 1. 目录和仓库边界

本机项目由两个 Git 仓库组成：

```text
/Users/silence/projects/flutter/
└── sublinur/                              # Sublinur App 仓库
    ├── .git/                              # 当前基线分支 dev_347
    ├── lib/                               # App、BlueToothServer、页面和网络层
    └── packages/
        └── blue_tooth_util/               # 独立 BLE 仓库
            ├── .git/                      # 当前基线分支 main
            ├── lib/                       # BLE Transport、Adapter、Session、协议
            ├── test/
            └── docs/
```

主 App 的 `pubspec.yaml` 通过 `path: packages/blue_tooth_util` 使用 BLE 包。`dev_347` 原基线把该目录记录为 Git mode `160000` 的 gitlink，但没有 `.gitmodules`。提交 `7c13ecbc6586b631295ed79022d4b74fe8949672` 已补充正式映射并快进合入 `dev_347`。持久 App OTA worktree 已成功检出 gitlink 固定的 BLE commit 并完成 `flutter pub get`。

因此不能让一个 Codex 分支同时承载两个仓库的修改。推荐采用“两个主任务、受控子代理、一个统一审查门禁”：

* BLE Codex 只修改 `blue_tooth_util` 仓库。
* App Codex 只修改 `sublinur` 仓库，不在 App 任务中直接修改嵌套 BLE 仓库。
* App 只消费经过验证的 BLE commit，并在主仓库记录对应 gitlink。
* 固件和服务端不在当前目录中，必须由各自项目的 Codex 执行，不能把模拟实现放进 App 或 BLE 包。

每个仓库由一个主 Codex 对最终结果负责。子代理不直接跨仓协调，只向本仓库主 Codex返回证据或限定范围的改动；跨仓状态由协调任务通过 commit ID 和公开接口传递。

## 2. 分支和 worktree

建议分支：

* BLE 仓库：基于 `main` 创建 `codex/ring-ota-ble-core`。
* App 仓库：基于 `dev_347` 创建 `codex/ring-ota-app`。
* 如需单独处理子模块配置，在 App 仓库先创建 `codex/ble-submodule-metadata`，评审通过后合入 `dev_347`，再创建 OTA App 分支。

每个分支使用独立 worktree。不要让两个 Codex 任务同时操作 `/Users/silence/projects/flutter/sublinur/packages/blue_tooth_util`。

建议 worktree 目录：

```text
/Users/silence/projects/flutter/
├── blue_tooth_util-worktrees/
│   └── ring-ota-ble-core/          # BLE 主任务，codex/ring-ota-ble-core
└── sublinur-worktrees/
    └── ring-ota-app/               # App 主任务，codex/ring-ota-app
```

协调任务不共享可写工作目录，只记录两个 worktree 的绝对路径、分支和 commit。最终审查任务只读打开这两个目录。

分支开发前必须先确认以下仓库结构决策：

1. 推荐补齐 `.gitmodules`，把 `packages/blue_tooth_util` 正式声明为 submodule。
2. 若不采用 submodule，应将 BLE 源码正式并入 App 仓库；这是较大的仓库迁移，需要单独方案。
3. 不建议继续保留“有 gitlink、无 `.gitmodules`”的状态，因为新 worktree、CI 和其他 Codex 无法可靠复现依赖。

未确认该决策前，可以开发 BLE 分支，但不要启动 App worktree 的 OTA 集成。

## 3. 模型分工

### 3.1 协调和架构审查

使用 `gpt-5.6-sol`，推理强度 `high`。

职责：

* 核对协议、目录所有权、公开接口和跨仓依赖。
* 维护阶段门禁、BLE commit、App commit、验证证据和未决事项。
* 对 AES-CCM、服务清单、会话所有权和后台执行方案请求用户确认。
* 不代替两个实现任务直接跨仓修改文件。

### 3.2 BLE 包实现

使用 `gpt-5.6-sol`，推理强度 `high`。

二进制包解析、地址边界、重试状态机和跨平台 BLE 流控错误会直接影响设备可恢复性，因此由 Sol 完成设计和实现。可让 `gpt-5.6-luna` 子任务执行定点代码搜索、测试日志整理和机械性用例补充，但 Sol 必须复核 diff 和测试。

### 3.3 App 实现

主 Codex 使用 `gpt-5.6-terra`，推理强度 `high`，负责拆分任务、处理交互和汇总证据。实现子代理使用项目已有的 `flutterCoder`，即 `gpt-5.6-sol high`。如果审查发现必须大幅调整 `BlueToothServer` 会话所有权，由 `flutterArchitect` 先做只读分析，主 Codex 输出方案，得到确认后再让 `flutterCoder` 修改。

App Codex 负责 GetX Coordinator、Repository、页面、恢复意图、本地化和交互。它不得重新实现 `.rota`、CRC 或 Bootloader 协议。

### 3.4 最终跨仓审查

使用 `gpt-5.6-sol`，推理强度 `xhigh`。

审查两个分支的接口、失败恢复、安全门槛、性能约束和验证证据。审查任务只提出问题和必要修复，不直接把两个仓库揉成一个大提交。

## 4. 子代理配置和所有权

### 4.1 并发规则

Sublinur App 的 `.codex/config.toml` 已启用子代理，并设置 `max_concurrent_threads_per_session = 2`。该字段允许最多 2 个 spawned-agent threads，不计算主线程；项目流程另行收紧为一个主 Codex 同时最多运行一个子代理。

允许并行的是主 Codex 自己的协调工作与一个边界明确的子任务。以下任务必须串行：

* 架构结论确认后再开始实现。
* 生产代码接口稳定后再让测试代理补充用例。
* UI 文本和 key 稳定后再让本地化代理修改 ARB。
* 实现完成后再让只读 Reviewer 检查最终 diff。

两个可写代理不能同时修改相同文件、同一公开类型或同一测试基础设施。子代理发现所有权冲突时立即停止并交回主 Codex。

### 4.2 App 已有子代理

App 仓库直接复用：

* `flutterArchitect`：`gpt-5.6-sol high`，只读分析 `BlueToothServer`、GetX 生命周期和会话所有权。
* `flutterCoder`：`gpt-5.6-sol high`，修改主 Codex 明确分配的 App 文件。
* `flutterTestEngineer`：`gpt-5.6-terra high`，只拥有指定测试文件。
* `localizationSpecialist`：`gpt-5.6-terra medium`，只手工修改三份 ARB，并运行生成流程。
* `flutterReviewer`：`gpt-5.6-sol high`，只读审查最终 App diff。

不要为 OTA 再复制一套 App 通用代理。主 Codex通过任务提示词限制文件所有权即可。

### 4.3 BLE 分支子代理

BLE 仓库在 `codex/ring-ota-ble-core` 分支配置：

* `otaProtocolAnalyst`：`gpt-5.6-sol high`，只读核对文档、字节序、边界和现有调用链。
* `otaTestEngineer`：`gpt-5.6-terra high`，只负责指定单元测试、合成包和失败注入。
* `otaReviewer`：`gpt-5.6-sol xhigh`，只读审查安全、恢复、并发和跨平台行为。

BLE 独立仓库使用自己的 `AGENTS.md`、`.codex/config.toml` 和 `.codex/agents/*.toml`，不依赖父 App 目录中的规则。配置格式沿用 App：`name`、`description`、`model`、`model_reasoning_effort`、`sandbox_mode` 和 `developer_instructions`。生产代码由主 Codex 实现，不配置可写核心实现代理。

BLE 配置同样将 spawned-agent threads 上限设置为 2，但执行规则仍禁止同时运行第二个子代理。配置文件与功能代码放在同一 BLE 分支评审，不先写入 `main`。

## 5. 执行顺序

### 阶段 A：仓库元数据

1. 已确认采用正式 submodule。
2. App 分支 `codex/ble-submodule-metadata` 已提交 `.gitmodules`，commit 为 `7c13ecbc6586b631295ed79022d4b74fe8949672`。
3. 已在 `/private/tmp/sublinur-ble-submodule-metadata` 验证取得 BLE commit `1c54f21e89085f41995ce34cc52c4e720f184ed4` 并完成 `flutter pub get`。
4. 审查无阻断问题，已使用 `--ff-only` 合入 `dev_347`。
5. 已创建 `/Users/silence/projects/flutter/sublinur-worktrees/ring-ota-app`，分支为 `codex/ring-ota-app`；子模块固定在 `1c54f21e89085f41995ce34cc52c4e720f184ed4`，依赖解析通过且没有锁文件差异。

### 阶段 B：BLE 公共能力

0. 审查并提交 README、完整实施计划、协作执行方案、仓库级 `AGENTS.md` 和 `.codex` 子代理配置，不实施 OTA 功能。
1. 单独提交 `universal_ble >=2.2.0 <2.3.0`，只回归普通 BLE。
2. 单独提交 `RingOtaInfo`、`RingDeviceIdentity`、`0x0402` 和 `0x0401`。
3. 单独提交 `.rota v1` 解析器、CRC、地址、长度、产品和版本拒绝规则。
4. 单独提交 `RingOtaProtocolAdapter`、`RingOtaSession` 和单层迭代状态机。
5. 单独提交断连、重试、恢复、进度限流和最终版本确认。
6. 单独提交 Android/iOS 构建集成结果和 Android/iPhone 真机联调证据；没有设备证据时明确标记未验证，不用构建结果替代。

每个功能阶段串行执行：只读协议或调用链分析、主任务实现、测试代理补充测试、主任务复核 diff、只读 Reviewer 审查、提交。每阶段报告公开 API、commit ID、测试、构建、真机边界、文档状态和 App 可依赖内容。

BLE 阶段完成前，App 可以审查页面和网络入口，但不能围绕猜测接口编写兼容层。

### 阶段 C：App 集成

1. App 分支固定到已验证的 BLE commit。
2. 实现 `RingOtaCoordinator`、`RingFirmwareRepository` 和升级意图存储。
3. 调整 `BlueToothServer` 的窄接口和 OTA 独占权。
4. 实现设备详情入口、升级页、恢复页状态和中英阿本地化。
5. 完成异常恢复、性能和真机验收。

### 阶段 D：合并

1. 先审查并合并 BLE 分支。
2. App 分支将 gitlink 固定到最终 BLE commit。
3. 运行 App 全量分析、测试、iOS/Android 构建和真机 OTA 场景。
4. 跨仓审查通过后再合并 App 分支。

固件和服务端若未完成安全协议、签名清单或真机能力位，App 和 BLE 分支只能标记为内部联调，不得启用生产入口。

## 6. 协调任务提示词

```text
你是戒指 BLE OTA 的跨仓协调和架构审查 Codex。使用 gpt-5.6-sol，reasoning high。

项目由两个独立 Git 仓库组成：
1. App：/Users/silence/projects/flutter/sublinur，基线 dev_347。
2. BLE：/Users/silence/projects/flutter/sublinur/packages/blue_tooth_util，基线 main。

先读取两个仓库的 AGENTS.md、BLE README、戒指BLE_OTA_App对接文档.md、戒指BLE_OTA_完整实施计划.md、APP_CODEX_戒指OTA实施交接.md 和戒指BLE_OTA_Codex协作执行方案.md。

你的职责是维护接口和阶段门禁，不跨仓直接实现功能。核对：
- 两个任务是否在各自 codex/ 分支和独立 worktree 中工作；
- BLE 公共 API 是否先完成并有 commit ID；
- App 是否只依赖公开 API，没有复制 CRC、rota 或 Bootloader 协议；
- 固件、服务端、安全和真机前置条件是否有证据；
- 文档、代码、测试和真机状态是否分开记录。

发现 AES-CCM、服务清单、BlueToothServer 会话所有权、后台执行或仓库结构的大型调整时，先输出选项、推荐方案、影响范围和回退方式，等待用户确认。不要创建临时兼容层。每次交接列出仓库、分支、commit、修改文件、测试结果、待确认项和下一任务可依赖的接口。
```

## 7. BLE 主任务提示词

```text
你负责 blue_tooth_util 的戒指 OTA 核心实现。使用 gpt-5.6-sol，reasoning high。

仓库：/Users/silence/projects/flutter/sublinur/packages/blue_tooth_util
基线：main
开发分支：codex/ring-ota-ble-core
必须使用独立 worktree。你不是唯一修改项目的人，不得覆盖用户或其他任务的改动。

开始前读取 `/Users/silence/projects/flutter/sublinur/AGENTS.md` 作为配置来源，并完整读取 README.md、docs/BLE协议_App对接_实现版.md、docs/戒指BLE_OTA_App对接文档.md、docs/戒指BLE_OTA_完整实施计划.md 和 docs/戒指BLE_OTA_Codex协作执行方案.md。先检查真实 Transport、Adapter、Session、Result 和测试入口。

第一个提交只包含 B0 的 README、完整实施计划、协作执行方案、BLE 仓库自己的 AGENTS.md、.codex/config.toml 及 otaProtocolAnalyst、otaTestEngineer、otaReviewer 配置，不包含 OTA 功能。配置的 spawned-agent threads 上限为 2，项目流程进一步限制一次最多调用一个子代理。配置需先由用户或协调任务审查，再进入功能实现。你是主 Codex，对架构、生产代码实现、diff 和交付负责；只读分析、主任务实现、测试和审查按阶段串行。每次分配必须写明文件所有权、禁止触碰的目录、验收标准和返回证据。

按阶段独立提交：
0. README、完整实施计划、协作执行方案、AGENTS.md 和 .codex 子代理配置，不包含 OTA 功能；
1. universal_ble >=2.2.0 <2.3.0 和普通 BLE 回归；
2. RingOtaInfo、RingDeviceIdentity、0x0402、0x0401；
3. .rota v1 解析器、CRC、地址、长度、产品和版本拒绝规则；
4. RingOtaProtocolAdapter、RingOtaSession 和迭代状态机；
5. 断连、重试、恢复、进度限流和最终版本确认；
6. Android/iOS 构建和 Android/iPhone 真机联调证据。

约束：
- 不实现 App 页面、网络下载、GetX Coordinator 或服务端接口；
- 不提交真实 rota、ota_tool.py、密钥或产线资料；
- Service/名称只筛选候选设备，Manufacturer Data 派生 MAC 才确认目标；
- OTA_COMPLETE 后必须重连业务模式并由 0x0402 核验版本；
- 不递归重试，不逐包向 UI 发事件，不为未确认协议写版本分支兼容层；
- 涉及 AES-CCM 格式、原生后台服务或公开 API 大改时停止编码，先提交方案。

完成每个阶段后报告 commit ID、公开 API、测试、构建、真机边界和文档同步状态。不要修改 App 仓库的文件或 gitlink。
```

## 8. BLE 子代理任务模板

### 8.1 协议分析

```text
你是 otaProtocolAnalyst，使用 gpt-5.6-sol high，只读执行。核对 OTA 文档与现有 Transport、Adapter、Session 和测试，输出：需要新增或修改的符号、字节序和长度规则、状态转换、拒绝条件、与普通 BLE 的冲突、需要固件确认的问题。每项附文件和行号。不得修改文件，不替主 Codex决定架构。
```

### 8.2 测试

```text
你是 otaTestEngineer，使用 gpt-5.6-terra high。只拥有主 Codex 指定的测试文件和测试夹具，不修改生产代码。根据公开行为补充 rota 解析、错误包、身份派生、状态转换、重试上限和中断恢复测试。使用合成数据，不提交真实 rota。先运行定向测试，再报告覆盖场景、命令、失败证据和未覆盖的真机边界。
```

### 8.3 只读审查

```text
你是 otaReviewer，使用 gpt-5.6-sol xhigh，只读执行。审查 BLE 分支相对 main 的 diff，重点检查地址/长度溢出、CRC、MAC 字节序、错误重试、并发取消、资源释放、Apple 写流控、Android MTU、OTA_COMPLETE 成功判定和普通 BLE 回归。只报告可触发的真实问题，每项给严重度、文件、行号、触发条件、影响和最小修复方向。不得修改文件。
```

## 9. App 主任务提示词

```text
你负责 Sublinur App 的戒指 OTA 集成。默认使用 gpt-5.6-terra，reasoning high；如果 BlueToothServer 会话所有权需要大范围调整，先切换 gpt-5.6-sol high 输出方案并等待确认。

仓库：/Users/silence/projects/flutter/sublinur
基线：dev_347
开发分支：codex/ring-ota-app
必须使用独立 worktree。开始实现前必须取得 BLE Codex 提供的已验证 commit ID，并让 packages/blue_tooth_util 固定到该 commit。你不是唯一修改项目的人，不得覆盖用户或其他任务的改动。

读取 App AGENTS.md、相关 PROJECT_MEMORY 章节、BLE README、OTA 对接文档、完整实施计划、APP_CODEX_戒指OTA实施交接.md 和 Codex 协作执行方案。检查 BlueToothServer、启动注册、设备详情页、路由、Repository、NetworkService、缓存和 ARB 生成流程。

你是主 Codex，对 App 分支最终结果负责。复用项目现有 flutterArchitect、flutterCoder、flutterTestEngineer、localizationSpecialist 和 flutterReviewer。单会话最多调用一个子代理，按架构分析、实现、测试、本地化、最终审查的顺序执行。每次任务明确文件所有权；禁止两个可写代理并行修改同一文件或公共接口。

实现范围：
- RingOtaCoordinator：单一 OTA、跨页面状态、互斥和恢复；
- RingFirmwareApi/Repository：清单、下载、取消、签名、SHA-256 和原子文件；
- BlueToothServer 窄接口：交出业务会话、暂停业务命令、恢复连接；
- 设备详情入口、独立升级页、单层错误交互和中英阿本地化；
- App 重启、回前台、蓝牙关闭、断电、找不到设备和 OTA 恢复模式。

约束：
- 不在 App 内解析 rota、计算 CRC 或实现 Bootloader 字节协议；
- 不对 RingBleSession 做无条件强制转换；
- 固件检查不阻塞连接和首页；
- UI 最多每 250 ms 或进度增加 1% 更新一次；
- OTA_COMPLETE 不能直接显示成功；
- 不叠加 SnackBar、弹窗和路由，不使用递归状态机或临时协议兼容代码；
- 不手工编辑生成的本地化文件。

完成后报告 BLE commit、App commit、改动入口、分析和测试、Android/iOS 构建、真机场景、文档状态及未完成的固件/服务端依赖。不要修改 BLE 分支源码。
```

## 10. App 子代理分配模板

```text
架构分析任务：只读检查 BlueToothServer、启动注册、RingBleSession 强制转换、页面入口和生命周期。输出最小会话交接接口、受影响文件、竞态和验证方案，不修改代码。

实现任务：你只拥有主 Codex列出的生产文件。实现 RingOtaCoordinator、Repository、页面或 BlueToothServer 中的一个边界，不修改 BLE 子仓库、ARB、生成文件或未分配测试。完成后返回 diff、分析、测试和未决问题。

测试任务：你只拥有主 Codex列出的 test/ 或 patrol_test/ 文件，不修改生产代码。验证可观察行为、恢复和互斥，不复制实现逻辑。

本地化任务：只修改 app_en.arb、app_zh.arb、app_ar.arb 中分配的 OTA key，运行项目规定的生成命令并检查 RTL、长文本和小屏风险。

最终审查任务：只读审查 App 分支相对 dev_347 的 diff，给出带文件和行号的正确性、竞态、性能、安全、本地化和测试问题，不修改文件。
```

## 11. 最终审查提示词

```text
你是戒指 BLE OTA 的最终跨仓审查 Codex。使用 gpt-5.6-sol，reasoning xhigh。只审查，不主动重构或合并。

审查对象：
- blue_tooth_util：main...codex/ring-ota-ble-core
- Sublinur App：dev_347...codex/ring-ota-app

读取协议、完整实施计划、App 交接和协作执行方案。逐项检查：仓库边界、公开接口、身份确认、rota 拒绝规则、MTU、无响应写流控、重试上限、断电恢复、成功判定、版本策略、安全能力、签名、UI 限流、本地化、后台行为和普通 BLE 回归。

按严重程度列出有文件和行号的发现。分别给出 BLE commit、App commit、测试、构建、真机证据和无法验证项。若没有阻断问题，明确说明可以进入哪一个阶段；没有固件、服务端或真机证据时，不得给出生产可用结论。
```
