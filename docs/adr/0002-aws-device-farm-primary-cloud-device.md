# ADR 0002：AWS Device Farm 作为默认云真机通道

- 状态：已采用并通过真机验证
- 日期：2026-07-26

## 背景

BrowserStack 已完成 M1、M2 的历史真机验证，但免费额度已经耗尽；项目将自动化执行和结果回收迁移到用户已配置的 AWS Device Farm 项目。

## 决策

1. AWS Device Farm 成为默认日常真机通道；
2. GitHub Actions 通过 OIDC 和限定 IAM 角色获取临时凭据，不创建长期 Access Key；
3. 所有者从同仓库分支发起的 PR 只运行真实转码合同，其他 PR 整个 AWS Job 跳过；
4. `main` 推送与手动触发运行完整套件；
5. 动态选机要求 iOS 26 或更高版本的公共 iPhone，并优先 iPhone 17 Pro；
6. BrowserStack 停止使用，工作流文件仅保留历史配置；
7. 供应商切换不得改变目标设备 iPhone 17 Pro / iOS 26.5.2 的最终验收职责。

## 原因

- OIDC 消除了长期 AWS 密钥管理；
- Device Farm 原生支持 `IOS_APP`、`XCTEST_UI_TEST_PACKAGE` 与运行产物回收；
- PR 单用例将真机计费控制在约一分钟，同时在合并前验证真实媒体合同；
- IAM 同时校验仓库所有者、不可变触发者 ID 与 OIDC 主体，其他人和 fork PR 无法获取角色。

## 后果

- 每次真机结论必须与 Artifact 中的设备、系统、commit、摘要和计费分钟一并解释；
- 若 AWS 设备目录没有 iOS 26 或更高版本的 iPhone，工作流明确失败并保存设备清单，不静默降级到旧系统；
- Device Farm 的平台级基础设施错误需要重跑确认，不能直接归因于 App。

## 当前证据

- Xcode 26.6 已成功构建并打包 `IOS_APP` 与 `XCTEST_UI_TEST_PACKAGE`；
- IAM 信任策略修正后，`main` 与受限 PR 均已成功执行 `AssumeRoleWithWebIdentity`；
- PR #6 在 iPhone 14 Pro Max / iOS 26.5 完成 300 帧 HEVC 转码、301 个 AAC 样本直通与保真复核，计费 0.99 真机分钟；
- 修正设备型号规范化后，PR #6 又在 iPhone 17 Pro / iOS 26.3.1 通过同一合同，计费 1.00 真机分钟；
- 工作流只导出经过白名单筛选的 OIDC 声明用于匹配信任条件，不输出或保存令牌；
- BrowserStack 不再自动执行；AWS Device Farm 是唯一日常真机通道。
