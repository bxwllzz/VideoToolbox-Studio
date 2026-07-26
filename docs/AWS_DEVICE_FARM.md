# AWS Device Farm 真机回归

AWS Device Farm 是本项目的默认日常真机执行通道。它负责自动重签、安装、运行 XCUITest（Xcode User Interface Testing，Xcode 用户界面测试）并回收证据；目标设备 iPhone 17 Pro / iOS 26.5.2 仍负责阶段性最终性能、热状态与 HDR 验收。

## 身份与权限边界

GitHub Actions 使用 OIDC（OpenID Connect，开放式身份连接）换取短期 AWS 凭据，不保存 AWS Access Key。

固定资源：

- 区域：`us-west-2`；
- Device Farm 项目：`arn:aws:devicefarm:us-west-2:247332612374:project:36ab8700-d09f-42fa-ad15-65df8d06958b`；
- IAM（Identity and Access Management，身份与访问管理）角色：`arn:aws:iam::247332612374:role/bxwllzz@github`。

项目 ARN 和角色 ARN 是资源标识，不是凭据。仓库不得保存 OIDC 令牌、临时访问密钥、长期访问密钥或 AWS 控制台密码。

## 自动化流程

1. GitHub runner 使用 Xcode 26.6 执行 `build-for-testing`；
2. 将未签名 App 打包为 `IOS_APP` 类型的 IPA；
3. 将 `VideoToolboxStudioCloudTests-Runner.app` 打包为 `XCTEST_UI_TEST_PACKAGE` 类型的 ZIP；
4. Device Farm 处理并自动重签两个上传对象；
5. 从公共设备目录选择 iOS 26 或更高版本的 iPhone，优先 iPhone 17 Pro；
6. 以 `XCTEST_UI` 类型执行测试；PR 只跑真实转码用例，`main` 和手动触发运行完整套件；
7. 回收 Run、Job、文件、日志和截图，删除 Artifact 元数据中的临时下载 URL；
8. 从 XCTest 日志提取 `capability-summary.json`、`sustained-encoding-summary.json` 与 `transcode-summary.json`；
9. 只有 Run 结果为 `PASSED` 且本轮要求的摘要都成功回收，工作流才判定通过。
10. 无论终态如何，都向当前 commit 写入 `AWS Device Farm 真机回归` 提交状态及对应 Run 链接。

## 触发规则

- 仓库所有者 `bxwllzz` 从同仓库分支发起的 PR（Pull Request，拉取请求）：通过 OIDC 获取临时凭据，只执行 `testCloudTranscodePreservesMediaContract`。该用例先将内置样片写入系统照片库，再通过主界面 PhotoKit 链路读取 `AVAsset` 并转码；IAM 信任策略必须允许所有者仓库的 `:pull_request` 主体，并用不可变 `actor_id` 限制触发者；
- 其他作者或 fork 发起的 PR：整个 AWS Job 跳过，不申请 OIDC 令牌，也不访问 AWS；
- 推送到 `main`：通过 OIDC 获取临时凭据，并自动执行完整 Device Farm 真机回归；
- Actions 页面手动触发：在所选分支执行完整回归。

BrowserStack 免费额度耗尽后停止使用；工作流文件仅保留历史配置，不自动或手动触发。

## 结果口径

AWS 结果只证明 Artifact 中记录的设备、系统、构建和 commit 组合通过，不能外推为所有 iPhone 均支持。至少联合解释以下文件：

- `selected-device.json`：请求选择的设备；
- `run-summary.json`：运行、实际 Job 设备和计数；
- `metadata/run-final.json`：Device Farm 原始终态；
- `capability-summary.json`：严格硬件会话摘要；
- `sustained-encoding-summary.json`：三轮持续硬编摘要；
- `transcode-summary.json`：真实媒体转码、非视频样本直通与保真复核摘要；
- `artifacts/`：Device Farm 日志、文件与截图。

Device Farm 报告中的临时下载 URL 不进入 GitHub Artifact。

AWS 公有 iPhone 不登录个人 iCloud。上述用例验证系统照片库、PhotoKit 授权/读取与直接 `AVAsset` 转码，不构成真实 iCloud Photos 下载证据；真实 iCloud 素材仍须在用户自己的 iPhone 上验收。

## 当前接入状态

Xcode 26.6 真机 App 与 XCUITest Runner 构建、打包已经通过；`main` 和同仓库所有者 PR 均已通过 OIDC 获取临时凭据、验证项目权限并进入 Device Farm。PR #6 已分别在 iPhone 14 Pro Max / iOS 26.5 与 iPhone 17 Pro / iOS 26.3.1 完成 300 帧 HEVC 转码、301 个 AAC 样本直通和保真复核，成功轮各计费 0.99 与 1.00 真机分钟。工作流会额外保存只包含 `aud`、`sub`、仓库、分支、工作流和作业名的 `oidc-claims.json`，不保存 JWT 或任何临时凭据。PR 接入以 `:pull_request` 信任主体、同仓库来源和所有者身份三项条件共同约束。
