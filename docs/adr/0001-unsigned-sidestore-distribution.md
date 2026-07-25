# ADR 0001：免费阶段采用无签名 IPA 与 SideStore

- 状态：已接受
- 日期：2026-07-25

## 背景

用户没有 Mac，当前目标是先在 iPhone 17 Pro、iOS 26.5.2 上证明原生 iOS 工程能够持续构建、安装和更新，再投入 VideoToolbox 功能。

## 决策

1. 私有 GitHub 仓库作为代码唯一事实源；
2. GitHub Actions 使用 `macos-26`、Xcode 26.6 和 iOS 26.5 SDK；
3. XcodeGen 固定为 2.46.0；
4. 云端只生成无签名 IPA，由 SideStore 在 iPhone 上使用免费 Apple Account 重签；
5. Bundle ID 固定为 `io.github.bxwllzz.VideoToolboxStudio`；
6. Apple Account、密码、验证码、证书、私钥和配对文件都不进入仓库或云端构建；
7. M0/P1 通过前不实现 VideoToolbox 探针。

## 结果

- 首次 SideStore 初始化仍需要电脑；
- 日常更新可在 iPhone 上完成；
- 免费签名存在 7 天刷新和 App 数量限制；
- GitHub 私有 Artifact 需要登录下载并手工导入 SideStore；
- 购买 Apple Developer Program 后再新增 App Store Connect API 密钥和 TestFlight 流程，不复用 Apple Account 密码。
