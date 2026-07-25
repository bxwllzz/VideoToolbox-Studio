# SideStore 安装与回传

## 1. 下载构建产物

1. 在 iPhone 上打开本仓库的 **Actions** 页面；
2. 进入最新成功的“构建无签名 IPA”记录；
3. 下载名称以 `VideoToolboxStudio-` 开头的 Artifact；
4. 在“文件”App 中点按 ZIP，将其解压；
5. 解压目录应包含 `.ipa`、`build-info.json`、`SHA256SUMS.txt`、构建日志和本说明。

## 2. 用 SideStore 安装

1. 确认 SideStore 已完成首次电脑初始化，能够刷新自身；
2. 打开 SideStore 所需的 `LocalDevVPN`；
3. 在 SideStore 的 **My Apps** 页面点按加号；
4. 从“文件”中选择本次下载的 `.ipa`；
5. 等待签名和安装完成，再打开 `VideoToolbox Studio`。

免费 Apple Account 的签名通常需要每 7 天刷新。Apple Account 只在用户自己的 SideStore 中登录，不得发给 Codex，也不得写入 GitHub Secrets、仓库文件或构建日志。

## 3. 验收与回传

打开 App 后核对：

- 设备标识与系统版本正确；
- Commit 与当前 GitHub 构建一致；
- “导出 build-info.json”能够调出系统分享页；
- 导出的 JSON 中没有 Apple Account、媒体路径或媒体内容。

第二个独立 commit 构建完成后覆盖安装，再核对：

- 安装标识与第一版一致；
- 启动次数继续增加；
- Commit 已更新。

请将两次导出的 `build-info.json` 上传到项目会话，作为 M0/P1 验收证据。
