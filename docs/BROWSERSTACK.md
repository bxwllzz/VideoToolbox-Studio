# BrowserStack 云真机回归

BrowserStack 只承担日常功能回归和硬件能力筛查，不能替代目标设备 iPhone 17 Pro / iOS 26.5.2 的最终性能、热状态与 HDR 验收。

## 凭据

仓库仅使用以下 GitHub Actions Secrets：

- `BROWSERSTACK_USERNAME`
- `BROWSERSTACK_ACCESS_KEY`

工作流只能把它们注入 `curl` 的认证参数，代码和构建产物不会记录明文。不得把凭据放入 Variables、源码、日志或测试报告。

## 自动化流程

1. GitHub runner 使用 Xcode 26.6 为真机生成未签名 App；
2. `build-for-testing` 生成 `VideoToolboxStudioCloudTests-Runner.app`；
3. 工作流分别打包 IPA 与 Runner ZIP；
4. BrowserStack 自动重签并安装两者；
5. 从账号可用列表中选择 iOS 26 或更高版本的真实 iPhone；
6. XCUITest 启动 App，依次运行只读能力探针、三轮多帧持续硬编和取消后会话重建验证；
7. 两个紧凑 JSON 通过测试日志回收；
8. GitHub Artifact 保存构建响应、设备与会话元数据、仪器日志、能力摘要和持续硬编摘要。

## 触发规则

- 日常按需从 Actions 页面手动触发 `BrowserStack 真机回归`；
- `agent/browserstack-*` 分支向 `main` 提交 PR 时自动执行一次，用于验证云测试链路本身；
- 其他 PR 不自动消耗 BrowserStack 真机分钟。

## 结果口径

云真机测试通过只能证明本次 BrowserStack 设备、系统和构建组合通过。结果必须与 Artifact 中的 `selected-device.json`、`build-final.json`、`capability-summary.json` 和 `sustained-encoding-summary.json` 一起解释，不能外推为所有 iPhone 均支持。设备池可能在不同运行中分配 iOS 26.0 或 26.2；目标 iPhone 17 Pro / iOS 26.5.2 仍承担阶段性最终验收。
