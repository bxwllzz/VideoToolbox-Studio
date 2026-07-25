# ADR 0002：AWS Device Farm 作为默认云真机通道

- 状态：待首次完整运行验证
- 日期：2026-07-26

## 背景

BrowserStack 已完成 M1、M2 的日常真机验证，但项目需要把自动化执行和结果回收迁移到用户已经配置好的 AWS Device Farm 项目，同时继续 M3 真实视频转码纵切。

## 决策

1. AWS Device Farm 成为默认日常真机通道；
2. GitHub Actions 通过 OIDC 和限定 IAM 角色获取临时凭据，不创建长期 Access Key；
3. PR 只验证 App 与 XCUITest Runner 能否为真机构建和打包；
4. `main` 推送与手动触发负责上传、动态选机、执行和证据回收；
5. 动态选机要求 iOS 26 或更高版本的公共 iPhone，并优先 iPhone 17 Pro；
6. BrowserStack 保留为仅手动触发的备用通道，待 AWS 首次完整运行通过后不再承担默认回归；
7. 供应商切换不得改变目标设备 iPhone 17 Pro / iOS 26.5.2 的最终验收职责。

## 原因

- OIDC 消除了长期 AWS 密钥管理；
- Device Farm 原生支持 `IOS_APP`、`XCTEST_UI_TEST_PACKAGE` 与运行产物回收；
- 保留 BrowserStack 手动通道可降低单一供应商临时故障带来的阻断；
- 将 PR 打包验证与 `main` 真机执行分开，可兼容仅信任 `main` 的 IAM 信任策略。

## 后果

- 首次 PR 合并后，必须以 `main` 的真实 Device Farm Run 结果完成本 ADR 的状态更新；
- 若 AWS 设备目录没有 iOS 26 或更高版本的 iPhone，工作流明确失败并保存设备清单，不静默降级到旧系统；
- Device Farm 的平台级基础设施错误需要重跑确认，不能直接归因于 App。
