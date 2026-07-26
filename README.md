# VideoToolbox Studio

纯本地、无广告、无账号、参数透明的 iPhone 专业视频编码与能力验证工具。

**M0 安装闭环已通过**：同一 Bundle ID 的两个版本已在 iPhone 17 Pro / iOS 26.5.2 上通过 SideStore 安装和覆盖更新，安装标识保持不变。

**M1 只读能力探针已通过**：H.264 1080p、HEVC 1080p 和 HEVC 4K 均取得 E1、E2、E3、E5 证据。BrowserStack 已在 iPhone 17 Pro / iOS 26.2 实际跑通 XCUITest、结果断言与证据回收。

**M2 持续硬编验证已通过**：BrowserStack iPhone 17 Pro 连续三轮运行 H.264 1080p30、HEVC 1080p30 和 HEVC 4K30 的 2 秒合成帧编码，全部 60/60 帧并达到 E6；取消后也能安全收尾并重新创建达标会话。

**M3 真实转码纵切已实现**：主界面直接显示照片库视频，支持单选或多选，并在缩略图中显示文件大小、码率、分辨率与编码类型；选中后以严格硬件 VideoToolbox 会话转码并输出 MOV。除重新编码后必然变化的视频码流和文件大小外，分辨率、时间轴、方向、色彩/HDR 描述、音频与其他非视频轨道、容器元数据和文件创建时间均执行强制复核，不能保留时明确失败。

## 视频转换

- 单个任务与顺序批量队列，显示进度并可取消；不覆盖原视频，失败或取消会清理残缺输出；
- 照片库按日期显示视频，采用原生多选交互；PhotoKit 返回的 `AVAsset` 会直接进入转码器，不额外复制原视频，iCloud 素材仅由系统按需下载；
- 内部能力探针和压力测试仅在自动化测试启动参数下显示；
- 编码设置页不提供 App 自造模板或计算模式，只显示可直接映射到公开 VideoToolbox 接口的字段；
- 以当前素材分辨率创建严格硬件会话并读取 `VTSessionCopySupportedPropertyDictionary`：公开且可写的原生字段生成对应编辑器，本机只读或不支持的字段置灰；
- `AverageBitRate`、`ConstantBitRate`、`VariableBitRate`、`Quality` 与 `ConstantQualityFactor` 只显示当前选中的一个；VBV 字段只随 CBR/VBR 出现，`MultiPassStorage` 与 `RealTime`／速度优先互相隐藏；
- 每项点按说明均显示完整 `kVTCompressionPropertyKey_*` 名称；请求值、解析值和实际 `VTSessionSetProperty` 结果分别进入报告；
- 可对首个视频中段执行最多 5 秒的真实硬件试编码，给出预计体积、合理范围及是否可能增大；
- HDR/10-bit 自动选择 HEVC Main10；不能保真时拒绝转换，不静默降级为 SDR；
- 保真核验通过后默认写入照片库；确认新视频已保存后，才允许通过系统确认删除原视频；
- 每个任务在手机端渲染人类可读报告；版本化 JSON 作为高级导出项，继续记录请求参数、VideoToolbox `OSStatus`、硬编证据、输入/输出属性和逐项保真检查。

## 当前目标

| 项目 | 固定值 |
|---|---|
| 目标设备 | iPhone 17 Pro |
| 目标系统 | iOS 26.5.2 |
| App 名称 | VideoToolbox Studio |
| Bundle ID | `io.github.bxwllzz.VideoToolboxStudio` |
| 最低系统 | iOS 26.0 |
| 云端环境 | macOS 26 + Xcode 26.6 + iOS 26.5 SDK |
| 工程生成 | XcodeGen 2.46.0 |

## 仓库结构

```text
VideoToolboxStudio/       SwiftUI App
VideoToolboxStudioTests/  单元测试
.github/workflows/        编译、测试和无签名 IPA 打包
scripts/                  可复现构建脚本
docs/                     路线图、Handoff、安装说明和 ADR
project.yml               XcodeGen 工程定义
```

## 云端构建

- `持续集成`：生成 Xcode 工程，在 iPhone 17 Pro / iOS 26.5 模拟器上编译和运行单元测试；
- `构建无签名 IPA`：为真机编译无签名 App，输出 IPA、构建信息、日志和 SHA-256 校验值。
- `AWS Device Farm 真机回归`：所有者从同仓库分支发起的 PR 通过 OIDC 运行单个“写入系统照片库 → PhotoKit 读取 → 真实转码”用例，`main` 运行完整真机套件；
- `BrowserStack 真机回归`：已停用；工作流文件仅保留历史配置，不再触发。

AWS 公有设备不登录个人 iCloud，因此真实 iCloud Photos 下载由用户自己的 iPhone 安装验收；云端回归不把网络模拟结果冒充 iCloud 证据。

完整手机端安装步骤见 [SideStore 安装说明](docs/SIDESTORE_INSTALL.md)。
默认云真机通道的身份边界、触发规则与结果口径见 [AWS Device Farm 真机回归](docs/AWS_DEVICE_FARM.md)；备用通道见 [BrowserStack 云真机回归](docs/BROWSERSTACK.md)。

## Apple Account 边界

免费阶段，Apple Account 只由用户在自己的 SideStore 中登录并完成签名。Codex 和 GitHub Actions 都不需要 Apple Account，仓库也不接受密码、验证码、证书、私钥或配对文件。

未来验证产品价值并购买 Apple Developer Program 后，云端分发改用 App Store Connect API（应用商店连接接口）密钥，不使用 Apple Account 密码。

## 开发顺序

当前的完整范围、阶段门和证据要求见 [项目 Handoff](docs/HANDOFF.md) 与 [开发路线图](docs/ROADMAP.md)。下一阶段是 M4 10-bit/HDR 真源闭环。
