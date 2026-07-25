# VideoToolbox Studio

纯本地、无广告、无账号、参数透明的 iPhone 专业视频编码与能力验证工具。

当前只实施 **M0/P1 安装闭环**：验证 GitHub Actions 云端构建、SideStore 安装、覆盖更新和 `build-info.json` 回传。尚未实现 VideoToolbox 编码或能力探针。

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

当前的完整范围、阶段门和证据要求见 [项目 Handoff](docs/HANDOFF.md) 与 [开发路线图](docs/ROADMAP.md)。M0/P1 未通过前，不进入 VideoToolbox 功能开发。
