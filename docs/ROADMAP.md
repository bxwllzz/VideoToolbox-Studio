# VideoToolbox Studio 开发路线图

> 文档状态：v1.3
> 更新日期：2026-07-26
> 当前阶段：M3 已通过，下一阶段为 M4
> 目标设备：iPhone 17 Pro / iOS 26.5.2
> 项目定位：通过 Apple 公共 API 动态探测真实可用的视频编码能力，并提供纯本地、无广告、参数透明的专业转码工具

当前执行信息：

- 目标设备：iPhone 17 Pro；
- 目标系统：iOS 26.5.2；
- App 显示名称：`VideoToolbox Studio`；
- Bundle ID：`io.github.bxwllzz.VideoToolboxStudio`；
- M0 状态：已通过。真机安装标识 `CE79063C` 在覆盖更新后保持不变，启动次数从 2 增至 4；
- M1 状态：目标 iPhone 已证明 H.264 1080p、HEVC 1080p、HEVC 4K 的严格硬件会话可创建，且运行时硬件标记为真；
- 云真机状态：BrowserStack 已完成 M1、M2 历史回归后停用；AWS Device Farm 的 `main` 与所有者 PR OIDC、真机执行和证据回收均已跑通；iPhone 17 Pro / iOS 26.3.1 已通过 M3 的 300 帧 HEVC、301 个 AAC 样本和保真复核；
- M2 状态：BrowserStack iPhone 17 Pro 连续三轮完成 60/60 帧编码，三种配置均取得 E2、E4、E5、E6；取消后可重新创建会话；
- M3 状态：已实现单个/批量转换、模板与专业参数、严格硬编、非视频轨道压缩样本直通、失败清理以及重新读取后的逐项保真复核；
- 当前唯一主任务：使用明确标记的 10-bit/HDR 真源完成 M4 端到端正确性验证。

---

## 1. 已确定的项目决策

| 项目 | 决策 |
|---|---|
| 核心编码路径 | 原生 VideoToolbox + AVFoundation，不以 FFmpeg（Fast Forward Moving Picture Experts Group，多媒体处理框架）为核心 |
| 能力边界 | 只描述当前设备通过 Apple 公共 API 暴露的能力，不宣称覆盖芯片全部硬件能力 |
| 开发终端 | 用户主要通过 iPhone 上的 ChatGPT Work 发起、审查和推进开发 |
| 云端构建 | GitHub Actions（GitHub 自动化工作流）的 macOS runner 负责编译、测试和生成未签名 IPA（iOS App Store Package，iOS 应用安装包） |
| 云真机回归 | AWS Device Farm 通过 OIDC 自动执行日常回归；BrowserStack 已停用；目标 iPhone 负责阶段性最终验收 |
| 免费安装 | 接受使用电脑一次性初始化 SideStore；此后由 iPhone 下载 IPA 并用 SideStore 签名、安装和续签 |
| 付费时机 | 在真机探针、真实转码和竞品对比证明产品价值后，再购买 Apple Developer Program（苹果开发者计划） |
| 隐私 | 不联网、无账号、无广告、无分析埋点，视频与诊断数据默认只在本机处理 |
| 属性写入 | 未识别、未公开或语义不确定的属性一律只读；可写属性必须进入人工维护的公开白名单 |
| 结果口径 | 区分“枚举到、预检通过、会话创建、属性生效、产生码流、确认硬编、持续性能达标”，不使用单一 `supported` 布尔值 |

---

## 2. 持久化与单一事实源

### 2.1 什么需要持久化

| 内容 | 持久位置 | 说明 |
|---|---|---|
| 源代码、测试、工作流 | GitHub 公开仓库 | 项目建立后唯一代码事实源 |
| 路线图、架构决策、验收标准 | 仓库 `docs/` 目录 | 当前先保存本文件；建仓后复制为 `docs/ROADMAP.md` |
| 真机能力报告 | 仓库外保存，必要时只提交脱敏样本 | 原始报告可能含设备和媒体元数据 |
| 构建产物 | GitHub Actions Artifact 或 Release | Artifact 有保留期限，不能作为长期归档 |
| 会话聊天记录 | 仅作协作上下文 | 不作为项目状态或工程交付物的唯一来源 |

### 2.2 每轮开发结束必须更新

1. 当前里程碑状态；
2. 已完成验收项；
3. 未解决问题与对应证据；
4. 下一轮唯一主任务；
5. 真机测试所用 App 版本、commit、iOS 版本和设备型号；
6. 关键技术决策写入 `docs/adr/`，其中 ADR 为 Architecture Decision Record（架构决策记录）。

---

## 3. 目标工作闭环

```text
iPhone 上向 ChatGPT Work 提需求
        ↓
Codex 修改 GitHub 公开仓库
        ↓
GitHub Actions macOS runner 编译和测试
        ↓
生成未签名 IPA、日志和校验值
        ↓
iPhone 登录 GitHub 下载并解压 IPA
        ↓
SideStore 重签、安装或更新
        ↓
真机测试并导出 JSON、日志、截图或录屏
        ↓
上传结果，进入下一轮迭代
```

### 3.1 这条链路的真实限制

- SideStore 首次安装需要 Windows、macOS、Linux 或 Chromebook 电脑以及 USB 连接。
- 正常情况下，首次安装后可在 iPhone 上完成 App 安装、更新和周期性刷新。
- 安装、更新或刷新时需要 Wi-Fi 和 SideStore 要求的 LocalDevVPN。
- 免费 Apple Account（苹果账号）的 provisioning profile（配置描述文件）有效期为 7 天，需要在到期前刷新。
- 免费账号通常最多同时安装 3 个自签 App，SideStore 本身占用其中 1 个；一周最多注册 10 个 App ID。
- iOS 升级、设备重置或配对文件偶发失效后，可能需要再次连接电脑替换 pairing file，因此“一次性初始化”不是永久保证。
- GitHub Actions 的 Artifact 通常以 ZIP（ZIP Archive，压缩归档）提供。首版采用“下载 ZIP → 在文件 App 解压 → 将 IPA 导入 SideStore”，不把它包装成一键直装。
- 若后续需要 SideStore 点击链接安装，必须提供可匿名访问的 IPA 或 AltSource 地址；公开源代码不等于默认公开每个构建产物。

---

## 4. 总体里程碑

| 里程碑 | 要回答的问题 | 退出条件 |
|---|---|---|
| M0 安装闭环 | 没有本地 Mac，能否持续把云端构建装进 iPhone？ | 空壳 App 从提交到真机启动，全链路成功两次 |
| M1 只读能力探针 | 当前 iPhone 公共 API 实际暴露什么？ | 可导出分级证据的能力报告 |
| M2 持续硬编验证 | 能编码一帧是否也能稳定工作？ | H.264/HEVC 多帧持续测试通过 |
| M3 真实转码纵切 | 能否正确处理一个真实视频？ | 10 秒真实视频完成读、编、封装、播放 |
| M4 10-bit/HDR 正确性 | 输入 10-bit/HDR 后输出是否仍正确？ | 重新读取输出并验证位深、色彩和元数据 |
| M5 专业参数控制 | 参数是否真实可控、可解释？ | 白名单参数设置、回读和码流验证一致 |
| M6 产品价值验证 | 是否明显优于现有压缩 App？ | 完成速度、功耗、体积、质量、透明度对比 |
| M7 付费分发升级 | 是否值得购买开发者账号？ | Go 决策后切换 TestFlight |
| M8 产品化 | 是否达到长期自用或上架质量？ | 稳定性、可访问性、隐私和商店材料齐备 |

---

## 5. 分阶段执行计划

### M0：建立安装与反馈闭环

#### 范围

1. 创建 GitHub 仓库并接入 Codex；
2. 建立最小 SwiftUI 工程；
3. 使用 XcodeGen 管理工程；
4. 创建单一 CI（Continuous Integration，持续集成）工作流，完成编译、单元测试和未签名 IPA 打包；
5. App 仅显示版本、commit、设备型号、iOS 版本；
6. 支持导出一个最小 JSON 构建报告；
7. 完成 SideStore 首次初始化和真机安装；
8. 再提交一个可见的小改动，验证更新链路不是偶然成功。

#### 验收

- [x] 两次独立 commit 均能在 runner 上成功构建；
- [x] 两个 IPA 均可在同一台 iPhone 上通过 SideStore 安装或覆盖更新；
- [x] Bundle ID（Bundle Identifier，应用包标识符）保持不变，更新后 App 数据不丢失；
- [x] App 显示的 commit 与 GitHub 构建一致；
- [x] 用户可从 iPhone 导出并上传 JSON；
- [x] GitHub 中不保存 Apple Account、密码、证书或配对文件。

#### 停止条件

若 M0 无法稳定重复，不进入 VideoToolbox 功能开发，先修复分发闭环。

---

### M1：只读 VideoToolbox 能力探针

#### 范围

1. 使用 `VTCopyVideoEncoderList` 枚举编码器；
2. 让 Codec（Codec，编解码格式）由所选编码器决定，禁止产生不一致组合；
3. 使用 `VTCopySupportedPropertyDictionaryForEncoder` 按编码器、分辨率和规格进行会话前预检；
4. 创建严格要求硬件的 `VTCompressionSession`；
5. 使用 `VTSessionCopySupportedPropertyDictionary` 读取实际会话属性；
6. 第一版属性浏览器全部只读；
7. 所有调用记录 `OSStatus`、耗时、输入摘要和原始返回值；
8. 生成版本化的 `CapabilityReport` JSON。

#### 证据等级

| 等级 | 含义 |
|---|---|
| E0 | 编码器被系统枚举到 |
| E1 | 指定配置的会话前属性查询成功 |
| E2 | 严格硬件会话创建成功 |
| E3 | 实际会话支持属性已读取 |
| E4 | 冒烟测试产生有效压缩 Sample Buffer |
| E5 | 运行时证据确认使用硬件编码器 |
| E6 | 多帧持续测试达到目标吞吐且无异常积压 |

#### 验收

- [x] 能导出全部编码器及原始字典；
- [x] 能区分预检属性与实际会话属性；
- [x] 硬件不可用时明确失败，不静默回退；
- [x] 不把“属性字典中出现”解释成“设置后一定生效”；
- [x] 报告中没有粗粒度 `supported=true` 作为最终结论；
- [x] 未识别属性不会触发写操作。

---

### M2：固定组合的多帧硬件编码验证

#### 首轮组合

1. H.264 1920×1080、30 fps；
2. HEVC 1920×1080、30 fps；
3. HEVC 3840×2160、30 fps；
4. 仅在预检通过后增加 4K60、4K120 和 10-bit。

其中 fps 为 Frames Per Second（每秒帧数）。

#### 测试设计

- 单帧测试只用于验证回调和码流生成；
- 生成 2～10 秒带帧号和时间戳的合成视频帧；
- 记录准备时间、首帧时延、总吞吐、平均与分位耗时、回调积压、失败帧和实际输出帧数；
- 记录关键帧、帧重排序、GOP（Group of Pictures，图像组）和实际格式描述；
- 记录 `UsingHardwareAcceleratedVideoEncoder` 等运行时硬编证据；
- 记录系统 thermal state（热状态），但首轮不把它等同于精确温度或功耗。

#### 验收

- [x] H.264 1080p30 达到 E6；
- [x] HEVC 1080p30 达到 E6；
- [x] HEVC 4K30 达到 E6；
- [x] 报告可追踪请求、提交、回调、输出、失败与丢弃帧；
- [x] App 提供取消测试并在取消后完成当前 session 的安全收尾；
- [x] 连续执行三次不会崩溃或出现失控迹象。

---

### M3：10 秒真实视频转码纵切

#### 固定首版合同

- 输入：Files 中的本地文件；
- 视频：保留原分辨率和帧率，先只允许选择 H.264 或 HEVC；
- 输出：MOV；
- 时间：保留有效时间戳，正确处理非零起始时间；
- 方向：保留或规范化轨道方向，禁止输出旋转错误；
- 音频：格式兼容时直通，否则转 AAC（Advanced Audio Coding，高级音频编码）；
- 错误：磁盘不足、取消、损坏媒体和不支持格式时清理不完整输出；
- 诊断：输出报告同时记录请求值、设置回读值和重新打开文件后的实际值。

#### 验收

- [x] 真实视频可完整转码，并支持单个与批量队列；
- [x] 输出时长、音画轨道、方向、分辨率与容器元数据通过自动复核；
- [x] 取消或失败后清理不完整输出；
- [x] 输出文件可重新读取并生成实际码流报告；
- [x] 失败不会覆盖原视频；
- [x] 无法保留的轨道或属性会明确失败，不静默丢弃。

---

### M4：10-bit 与 HDR 端到端正确性

HDR 为 High Dynamic Range（高动态范围）。

#### 原则

10-bit 输入像素缓冲区、HEVC Main10 输出和 HDR 保真是三个不同结论，必须分别验证。

#### 验证项

- 输入位深与像素格式；
- 编码 Profile 和输出位深；
- Color Primaries（色彩原色）；
- Transfer Function（传递函数）；
- YCbCr Matrix（亮度与色度矩阵）；
- Full Range / Video Range；
- HDR 静态或动态元数据；
- 输出文件重新读取后的实际格式；
- 系统相册和至少一个独立播放器中的视觉检查。

#### 验收

- [ ] SDR（Standard Dynamic Range，标准动态范围）路径无明显回归；
- [ ] 支持的 HDR 输入可选择“保留 HDR”；
- [ ] 无法保真时明确阻止或要求用户选择转 SDR，不静默丢失 HDR；
- [ ] 报告可以区分“请求、会话回读、实际输出”。

---

### M5：专业参数与产品交互

#### 实现顺序

1. 平均码率；
2. Data Rate Limits（数据率限制）；
3. Profile / Level；
4. 关键帧间隔与关键帧时长；
5. 帧重排序；
6. Real Time（实时模式）；
7. Quality（质量参数）；
8. 编码速度或功耗相关的公开属性；
9. 多遍编码，仅在 API、容器和实测链路明确后加入。

#### 约束

- 不做任意 Core Foundation 值编辑器；
- 每个控件必须绑定明确的公开属性、数据类型、允许范围、设置时机和互斥规则；
- 设置成功后必须回读；转码结束后必须重新读取输出；
- 不把 CRF（Constant Rate Factor，恒定质量因子）伪装成 VideoToolbox 原生参数；
- 简洁模式是专业参数的受控预设，不是另一套编码逻辑。

#### 验收

- [ ] 不支持的选项不显示或明确禁用；
- [ ] 设置值、回读值、实际输出值分开展示；
- [ ] 每个参数都有中文说明和失败原因；
- [ ] 同一配置可保存为本地预设；
- [ ] 参数组合测试覆盖主要互斥关系。

---

### M6：竞品对比与 Go/No-Go 决策

#### 对比维度

| 维度 | 测量方式 |
|---|---|
| 压缩速度 | 相同输入、相同目标分辨率和近似码率下的总耗时 |
| 文件体积 | 输出文件字节数与目标偏差 |
| 画质 | VMAF（Video Multi-Method Assessment Fusion，视频多方法评估融合）或 SSIM（Structural Similarity Index Measure，结构相似性指标），必要时在云端离线计算 |
| 功耗代理 | 系统能耗日志、热状态、耗电变化和持续性能；不宣称为芯片级精确功耗 |
| 专业透明度 | 是否显示编码器、硬编证据、实际生效参数、色彩与 HDR 信息 |
| 稳定性 | 多次转码、取消、后台切换、低磁盘空间和异常输入 |
| 使用成本 | 操作步骤、广告、订阅、数据上传和无关功能 |

#### Go 条件

满足以下任一主价值，并且稳定性可接受：

1. 在速度、功耗和输出质量的综合指标上明显优于现有 App；
2. 专业参数、硬编证据和 HDR 正确性具有现有 App 缺失的独特价值；
3. 即使压缩率不占优，也能成为可信的 iPhone VideoToolbox 能力诊断工具。

#### No-Go 或转向条件

- 公共 API 可控能力不足以形成差异；
- 关键专业参数设置成功但无法稳定生效；
- HDR/10-bit 链路无法可靠验证；
- SideStore 调试成本高到显著阻碍迭代；
- 产品价值只剩普通压缩器，无法优于成熟 App。

---

### M7：购买开发者账号后的升级

在 M6 通过后：

1. 购买 Apple Developer Program；
2. 将证书与 provisioning profile 安全配置到 GitHub Secrets；
3. runner 完成签名并上传 App Store Connect；
4. 使用 TestFlight 内部测试替代 SideStore；
5. 保留 SideStore 路径一段时间作为应急验证手段；
6. 增加多设备测试、崩溃诊断和性能基线；
7. 决定仅自用、公开 TestFlight 还是 App Store 上架。

---

## 6. 测试分层

| 层级 | 运行位置 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| 纯 Swift 单元测试 | GitHub runner | JSON、属性解析、状态机、错误映射 | 真机硬编能力 |
| 编译与模拟器启动 | GitHub runner | API 可编译、基础 UI 可启动 | iPhone 媒体引擎表现 |
| 真机冒烟测试 | iPhone | 会话和码流链路可工作 | 持续吞吐和稳定性 |
| 真机持续测试 | iPhone | E6、积压、失败帧、热状态影响 | 实验室级精确功耗 |
| 输出文件复核 | iPhone/离线工具 | 位深、Profile、帧率、色彩和元数据 | 仅凭会话设置无法替代此层 |
| 竞品基准 | 同一台 iPhone | 产品实际相对价值 | 跨机型普遍结论 |

---

## 7. 报告与可追溯性

每份报告至少包含：

- 报告 Schema 版本；
- App 版本、构建号和 commit SHA（Secure Hash Algorithm，安全散列算法）；
- 设备型号标识和 iOS 版本；
- 编码器名称、Encoder ID 和原始字典；
- 输入配置、预检结果和会话创建结果；
- 所有 `OSStatus` 与中文错误说明；
- 请求属性、设置返回、回读属性；
- 硬编运行时证据；
- 输入/输出帧计数、时延、吞吐和积压；
- 输出格式描述与重新读取结果；
- 热状态；
- 测试开始、结束和取消原因；
- 对无法判断的字段使用 `unknown`，不猜测。

报告中不得默认包含 Apple Account、文件完整路径或用户媒体内容。

---

## 8. 当前任务队列

### 已完成

1. M0 SideStore 安装与覆盖更新；
2. M1 只读能力探针；
3. M2 三轮持续硬编和取消恢复；
4. M3 单个/批量真实视频转换、模板、专业参数和保真报告。

### 现在执行

1. M4 10-bit/HDR 真源闭环；
2. 在 AWS iPhone 17 Pro 上持续回归真实转码合同；
3. 在目标 iPhone 17 Pro / iOS 26.5.2 上复核 HDR、性能和热状态。

---

## 9. 下一次开发会话的启动指令

```text
阅读 docs/ROADMAP.md、docs/HANDOFF.md 和最近一次 GitHub Actions 结果。

M0～M3 已通过，当前只执行 M4 10-bit/HDR 真源闭环。

交付：
1. 具有明确 BT.2020、PQ/HLG 与 HDR 静态元数据的无版权真源；
2. 输入解码像素格式和位深证据；
3. HEVC Main10 严格硬编与属性状态；
4. 输出重新读取后的位深、色域、传递函数、矩阵与 HDR 元数据；
5. 不支持时明确拒绝，不静默转 SDR；
6. 云真机证据和目标 iPhone 阶段性复核。

约束：
- 不使用 FFmpeg；
- 不引入第三方运行时依赖；
- 不联网；
- 不配置或收集 Apple Account、证书和配对文件；
- 所有界面、代码注释、README、日志说明使用中文；
- 不使用 try!、强制解包或吞掉错误；
- 每个阶段提交独立 commit；
- CI 通过后再交付 IPA。

不提前进入竞品对比；先把 HDR 保真证据闭环。
```

---

## 10. 参考资料

- [Apple：会员能力与免费账号限制](https://developer.apple.com/support/compare-memberships/)
- [GitHub：下载工作流 Artifact](https://docs.github.com/actions/managing-workflow-runs/downloading-workflow-artifacts)
- [GitHub：GitHub-hosted runner](https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners)
- [SideStore：安装前提](https://docs.sidestore.io/docs/installation/prerequisites)
- [SideStore：安装流程](https://docs.sidestore.io/docs/installation/install)
- [SideStore：常见问题与免费账号限制](https://docs.sidestore.io/docs/faq)
- [SideStore：配对文件失效与替换](https://docs.sidestore.io/docs/advanced/pairing-file)
- [SideStore：URL Scheme](https://docs.sidestore.io/docs/advanced/url-schema)
