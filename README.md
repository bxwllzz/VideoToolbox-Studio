# VideoToolbox Studio

纯本地、无广告、无账号、参数透明的 iPhone 专业视频编码与能力验证工具。

**M0 安装闭环已通过**：同一 Bundle ID 的两个版本已在 iPhone 17 Pro / iOS 26.5.2 上通过 SideStore 安装和覆盖更新，安装标识保持不变。

当前实施 **M1 只读能力探针**：枚举 VideoToolbox 编码器，针对 H.264 1080p、HEVC 1080p 和 HEVC 4K 查询预检属性、创建严格硬件会话、读取会话属性和运行时硬件标记，并导出 `capability-report.json`。本阶段不读取用户媒体，也不写入编码属性。

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

完整手机端安装步骤见 [SideStore 安装说明](docs/SIDESTORE_INSTALL.md)。

## Apple Account 边界

免费阶段，Apple Account 只由用户在自己的 SideStore 中登录并完成签名。Codex 和 GitHub Actions 都不需要 Apple Account，仓库也不接受密码、验证码、证书、私钥或配对文件。

未来验证产品价值并购买 Apple Developer Program 后，云端分发改用 App Store Connect API（应用商店连接接口）密钥，不使用 Apple Account 密码。

## 开发顺序

当前的完整范围、阶段门和证据要求见 [项目 Handoff](docs/HANDOFF.md) 与 [开发路线图](docs/ROADMAP.md)。取得首份真机能力报告后，再根据设备实测结果进入多帧编码和真实视频纵切。
