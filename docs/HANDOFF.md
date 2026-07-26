# VideoToolbox Studio 项目交接

> 更新日期：2026-07-26
> 当前阶段：P1、P2、P3、P4 已通过，下一阶段为 P5 10-bit/HDR 真源闭环
> 当前路线：免费 Apple Account + SideStore 阶段验收 + GitHub Actions 云端构建 + AWS Device Farm 日常真机回归
> 本文件用途：新会话、新代理或新开发者接手项目时的唯一入口

## 1. 一句话目标

开发一款纯本地、无广告、无账号、无无关功能的 iPhone 专业视频编码与压缩工具：动态探测并控制当前设备通过 Apple 公共 VideoToolbox 接口暴露的能力，并用可复核证据说明请求了什么、实际用了什么、输出码流是什么。

本项目不以 FFmpeg（Fast Forward Moving Picture Experts Group，多媒体处理框架）为核心，也不宣称能够暴露 Apple 芯片内部的全部硬件能力。

## 2. 用户真正需要的产品

现有 App Store 压缩工具普遍只提供分辨率、帧率、码率以及 H.264/HEVC 等消费级选项，难以回答：

- 实际选择了哪个编码器；
- 是否真的使用硬件编码，还是发生了静默回退；
- 参数设置是否被系统接受并真正生效；
- 最终码流的 Profile、位深、GOP、帧重排序、色彩和 HDR 是否符合预期；
- 当前 iPhone、当前 iOS 与当前配置组合到底能稳定达到什么能力。

因此产品同时具有两个角色：

1. 可验证的 VideoToolbox 编码能力探针；
2. 参数透明、纯本地的专业视频转码器。

产品优先级是透明、可信、快速和低功耗，不追求剪辑、字幕、GIF、水印、云同步等功能。

## 3. 已确定且不得擅自推翻的决策

| 事项 | 决策 |
|---|---|
| 编码路径 | Swift 原生调用 VideoToolbox 与 AVFoundation |
| FFmpeg | 不作为主编码器或能力模型；后期仅可作为离线码流核验工具 |
| 公共接口边界 | 只使用 Apple 公共 API，不使用私有 API，不写入未公开属性 |
| 隐私 | 不联网、无账号、无广告、无分析埋点；媒体默认只在本机处理 |
| 首轮产品形态 | 技术可行性验证，不称为 MVP（Minimum Viable Product，最小可行产品） |
| 第一开发任务 | 先跑通空壳 App 的云端构建与真机安装，不提前开发 VideoToolbox |
| 属性探针 | 第一版全部只读；以后只对白名单中的公开属性开放编辑 |
| 编码器与 Codec | Codec 由编码器描述决定，不允许人为组成不一致配置 |
| 硬件回退 | 严格硬件模式下不可静默回退；不可用时必须明确失败 |
| 10-bit/HDR | 10-bit 输入、Main10 输出和 HDR 保真是三个独立结论，必须分别核验 |
| 免费分发 | 接受电脑首次初始化 SideStore；日常从 iPhone 下载 IPA、签名、安装和刷新 |
| 付费时机 | 真机探针、真实转码和竞品对比证明价值后，再考虑 Apple Developer Program |

## 4. 目标技术架构

```text
Files / PhotoKit
        ↓
AVAssetReader
        ↓
CVPixelBuffer
        ↓
VTCompressionSession
        ↓
CMSampleBuffer
        ↓
AVAssetWriter
        ↓
重新打开输出文件并核验实际码流
```

主要框架：

- SwiftUI：界面；
- VideoToolbox：编码器枚举、能力预检、会话创建和编码；
- AVFoundation：媒体读取、音频处理和封装；
- Core Media：Sample Buffer、格式描述和时间戳；
- Core Video：Pixel Buffer；
- PhotoKit 与 Uniform Type Identifiers：媒体导入导出；
- OSLog：结构化诊断日志；
- Core Image 或 Metal：后期确有需要时处理缩放、像素与色彩转换。

## 5. 开发与真机反馈闭环

```text
iPhone 上的 ChatGPT Work 提出任务
        ↓
Codex 修改 GitHub 公开仓库
        ↓
GitHub Actions 的 macOS runner 编译和测试
        ↓
生成未签名 IPA、构建日志与 SHA-256
        ↓
iPhone 下载并解压构建产物
        ↓
SideStore 在手机端签名、安装或更新
        ↓
真机运行并导出 JSON、日志、截图或录屏
        ↓
用户上传结果，进入下一轮
```

边界：

- GitHub runner 可以生成 IPA 下载地址，但免费账号下这不是 iOS 原生直装链接；
- SideStore 首次安装需要 Windows、macOS 或 Linux 电脑以及 USB 连接；
- 正常情况下，首次初始化后可由 iPhone 完成后续安装和刷新；
- 免费配置通常需要每 7 天刷新；
- iOS 更新、设备重置或配对文件异常时，可能仍需再次使用电脑；
- 不得把 Apple Account、密码、验证码、证书、私钥或配对文件提交到仓库；
- 购买 Apple Developer Program 后，目标链路改为 GitHub Actions 自动签名并上传 App Store Connect，再通过 TestFlight 更新。

## 6. 能力结论必须采用分级证据

禁止用一个 `supported=true/false` 概括能力。

| 等级 | 可以得出的结论 |
|---|---|
| E0 | 编码器出现在系统枚举列表 |
| E1 | 指定编码器和配置的会话前属性查询成功 |
| E2 | 严格要求硬件的编码会话创建成功 |
| E3 | 实际会话支持属性已读取，公开属性设置与回读可核验 |
| E4 | 冒烟测试产生有效的压缩 Sample Buffer |
| E5 | 运行时证据确认使用硬件编码器 |
| E6 | 多帧持续测试达到目标吞吐，无异常丢帧或积压 |

单帧测试只能证明回调和码流链路可工作，不能证明帧率、GOP（Group of Pictures，图像组）、B 帧、码率控制或持续硬件能力。

## 7. 路线与阶段门

| 阶段 | 任务 | 退出条件 |
|---|---|---|
| P0 | 初始化 SideStore | SideStore 可打开、可刷新自身、可从“文件”选择 IPA |
| P1 | 空壳 App 与安装闭环 | 两个独立 commit 均能云端构建、手机安装并导出对应 `build-info.json` |
| P2 | 只读能力探针 | 枚举编码器、完成预检和会话属性读取、导出分级报告 |
| P3 | 多帧硬编验证 | H.264 1080p30 与 HEVC 1080p30 达到 E6，HEVC 4K30 至少达到 E5 |
| P4 | 真实视频转码纵切 | 10 秒视频完成读取、硬编、音频处理、封装、播放和重新核验 |
| P5 | 10-bit/HDR 闭环 | 位深、Profile、色彩和 HDR 元数据逐项验证，不发生静默降级 |
| P6 | 专业参数白名单 | 设置值、会话回读值和输出码流值分别展示并一致可解释 |
| P7 | 产品价值验证 | 与 2～3 款竞品完成速度、体积、质量、热状态和透明度对比 |
| P8 | 付费与产品化决策 | 有明确价值后才切换 TestFlight 或推进 App Store |

任何阶段未通过，只解决当前阻断，不提前堆叠后续页面和参数。

## 8. 当前唯一应执行的开发任务：P5

P1 已完成 SideStore 安装与覆盖更新闭环；P2 已完成分级只读能力探针；P3 已完成三轮持续硬编与取消恢复；P4 已完成真实媒体的单个/批量转换、严格硬编、非视频轨道直通、逐项保真复核和报告导出。

P5 只处理 10-bit/HDR 真源闭环：

1. 准备具有明确 BT.2020、PQ 或 HLG 标记和 HDR 静态元数据的无版权输入；
2. 分别验证解码像素格式、HEVC Main10、色域、传递函数、矩阵和 HDR 静态元数据；
3. 重新打开输出文件逐项比对，并在至少一个独立播放器中视觉检查；
4. 不支持的 HDR 组合必须明确拒绝，不允许静默转 SDR；
5. 将请求值、属性状态、会话证据和实际输出值分别写入报告。

## 9. P2 之后的关键实现约束

### 9.1 只读探针

- 使用 `VTCopyVideoEncoderList` 枚举编码器；
- 使用 `VTCopySupportedPropertyDictionaryForEncoder` 做会话前预检；
- 使用 `VTSessionCopySupportedPropertyDictionary` 读取实际会话属性；
- 首轮扫描 H.264/HEVC、1080p/4K、30/60 fps、8-bit NV12 与 10-bit bi-planar；
- 不做全排列暴力扫描，扫描必须可取消；
- 所有 `OSStatus`、输入摘要、调用耗时和原始返回值进入版本化 JSON 报告；
- 不能序列化的 Core Foundation 对象必须安全归一化，不得无限递归或崩溃。

### 9.2 持续编码

- 采用确定性测试图案，至少提供 2 秒与 10 秒两档；
- 记录提交帧数、回调帧数、失败帧、时间戳、首帧延迟、平均与 P95 延迟、实际吞吐、积压、码率、关键帧、帧重排序、热状态和峰值内存；
- 区分请求编码器、会话实际编码器和硬件加速运行时证据；
- 测试取消后必须正确释放会话。

### 9.3 真实转码

- 首版输入为 Files 中的 MOV 或 MP4，输出固定为 MOV；
- 保留原始分辨率与有效时间戳，正确处理非零起始时间和轨道方向；
- 音频兼容时直通，否则转为 AAC（Advanced Audio Coding，高级音频编码）；
- 显示进度并支持取消；
- 磁盘不足、媒体损坏、不支持格式或取消时清理不完整输出；
- 永不覆盖原视频；
- 转码完成后重新打开输出文件，核验 Codec、位深、帧率、时长、色彩和元数据。

### 9.4 HDR 与专业属性

- 不得悄悄把 HDR（High Dynamic Range，高动态范围）转换为 SDR（Standard Dynamic Range，标准动态范围）；
- 只能选择保留 HDR、显式色调映射到 SDR，或明确拒绝；
- 不实现任意 Core Foundation 键值编辑器；
- 每个可编辑属性必须有公开 API 依据、类型、范围、设置时机、互斥规则、错误说明、回读和码流验证方法；
- 不把 CRF（Constant Rate Factor，恒定质量因子）伪装成 VideoToolbox 原生参数。

## 10. 报告与可追溯性

每份真机报告至少包含：

- 报告 Schema 版本；
- App 版本、构建号和 commit SHA；
- 设备型号标识与 iOS 版本；
- 编码器名称、Encoder ID、Codec 和原始字典；
- 输入配置、预检结果、会话创建结果和全部 `OSStatus`；
- 请求属性、设置返回、会话回读；
- 硬编运行时证据；
- 输入/输出帧计数、时延、吞吐、积压和热状态；
- 输出格式描述及重新读取结果；
- 测试开始时间、结束时间、取消或失败原因；
- 无法判断的字段写 `unknown`，不得猜测。

报告默认不得包含 Apple Account、媒体完整路径或任何媒体内容。

每轮结束必须在仓库中更新：

1. 当前阶段与阶段门状态；
2. 已完成验收项；
3. 未解决问题及其证据；
4. 下一轮唯一主任务；
5. 真机测试对应的设备、iOS、App 版本与 commit；
6. 重要决策对应的 ADR（Architecture Decision Record，架构决策记录）。

## 11. 工程质量规则

- 代码、测试、工作流和版本历史以 GitHub 仓库为唯一事实源；
- 每个阶段形成独立、可回退的提交；
- 每次合并前编译和单元测试必须通过；
- 不引入与当前阶段无关的第三方运行时依赖；
- 不新增严重编译警告；
- 真机结论必须附设备、系统、构建和 commit；
- 无法由 runner 证明的真机能力，不得用模拟器结果代替；
- 不做“页面先行”的假完成，优先完成可导出、可复核的纵向证据链；
- 遇到需求或技术边界冲突时，先与用户沟通，不自行扩大范围。

## 12. 当前状态

- [x] SideStore 安装与覆盖升级闭环；
- [x] GitHub 公开仓库、CI 与无签名 IPA 构建；
- [x] P2 只读能力探针；
- [x] P3 三轮持续硬编与取消恢复；
- [x] P4 单个/批量真实视频转换与保真复核；
- [x] AWS Device Farm：`main` 与所有者 PR 的 OIDC、真机执行和证据回收均已跑通；
- [x] P4 AWS 真机合同：300 帧 HEVC、301 个 AAC 样本与逐项保真复核通过；
- [x] AWS iPhone 17 Pro / iOS 26.3.1：同一合同通过，计费 1.00 真机分钟；
- [x] BrowserStack：额度耗尽后停用，工作流文件仅保留历史配置；
- [ ] P5 10-bit/HDR 真源闭环；
- [ ] 目标 iPhone 17 Pro / iOS 26.5.2 的阶段性最终复核。

## 13. 接手后的第一条回复

先读取本文件、`docs/ROADMAP.md` 和最近一次 GitHub Actions 结果。仓库、Bundle ID、目标设备、安装链路与用户的保真要求均已确定，不再重复询问；从 P5 的 10-bit/HDR 真源证据继续。

## 14. 资料优先级

1. 本文件：项目范围、当前状态和接手入口；
2. `VideoToolbox_Studio_Roadmap.md`：完整阶段计划与验收细节；
3. `VideoToolbox_Studio_ROADMAP.md`：同主题的较早整理稿，仅作补充；
4. `upload/VideoToolbox_专业视频编码App_项目Handoff.md`：初始需求稿，存在已被后续决策修正的内容，不可直接作为实现规格。

若文档冲突，以本文件和日期更新更晚的明确用户决策为准。

## 15. 当前参考资料

- Apple 免费与付费开发者能力对比：<https://developer.apple.com/support/compare-memberships/>
- SideStore 安装前置条件：<https://docs.sidestore.io/docs/installation/prerequisites>
- SideStore 安装说明：<https://docs.sidestore.io/docs/installation/install>
- SideStore 常见问题与免费签名限制：<https://docs.sidestore.io/docs/faq>
- GitHub Actions 构建产物说明：<https://docs.github.com/en/actions/tutorials/store-and-share-data>
