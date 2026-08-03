# CC Status

Windows 桌面悬浮小组件，用颜色和提示音显示 Codex 与 Claude Code CLI 的当前状态。

![CC Status 效果预览](docs/preview.png)

- 蓝色：工作中
- 橙色：需要批准
- 绿色：已完成
- 灰色：等待任务

CC Status 通过 Codex 生命周期数据和 Claude Code Hooks 显示状态。它只保存任务来源、会话 ID、状态、时间和工作目录，不读取或保存提示词、命令内容或聊天文本。

## 安装

推荐直接运行 `release\CC-Status-Setup-2.1.0.exe`。安装后，桌面会创建“CC Status”快捷方式，开始菜单提供控制中心、打开、退出和卸载入口。

也可以使用 ZIP 版：

1. 双击 `Install.cmd`。
2. 安装程序会合并并配置 Codex 用户级 Hooks；检测到 Claude Code CLI 时，同时配置 `%USERPROFILE%\.claude\settings.json`。
3. 重启 Codex 或 Claude Code 可确保新 Hook 配置生效。Claude Code 中可输入 `/hooks` 查看配置。

默认安装目录是 `%LOCALAPPDATA%\CC Status`。安装不需要管理员权限，也不会修改系统 PowerShell 执行策略。

如果 Claude Code CLI 未安装，安装程序会跳过 Claude 配置并给出提示；如果现有 `settings.json` 不是有效 JSON，则不会覆盖该文件，CC Status 和 Codex 集成仍会完成安装。

## 使用

- 拖动卡片可调整位置。
- 右键托盘图标，在“主题”菜单中切换黑色或白色主题；选择会自动保存。
- 双击卡片或点击操作按钮会按任务来源切换窗口：桌面任务打开 Codex，CLI 任务打开对应终端。
- 双击托盘里的图标可重新显示隐藏的小组件；关闭小组件窗口只会隐藏到托盘。
- 只有托盘菜单或控制中心的“退出”才会结束进程。
- “已完成”显示 90 秒，随后恢复为灰色等待状态。
- 多任务状态优先级为：需要批准 > 工作中 > 已完成。

## 卸载

使用开始菜单里的“卸载 CC Status”，或双击安装包中的 `Uninstall.cmd`。卸载程序只删除本组件添加的 Hook、启动入口和安装目录，并在修改 Codex/Claude 配置前创建备份；安装或卸载时会自动清理 30 天以前的 `hooks.json` / `settings.json` 备份。

## 开发验证

在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StatusBridge.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-RolloutMonitor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ApprovalMonitor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Installer.ps1
```

安装包构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1
```

构建脚本会清理旧版本安装包、编译控制程序、生成 `release\CC-Status-Setup-2.1.0.exe`，并可静默安装验证文件、版本、Hooks、桌面快捷方式和进程。可用 `-SkipValidation` 跳过安装验证。

状态来源采用 Codex 的 `UserPromptSubmit`、`PermissionRequest`、`PostToolUse`、`Stop` Hooks，以及 Claude Code 的 `UserPromptSubmit`、`PermissionRequest`、`PostToolUse`、`PostToolUseFailure`、`PostToolBatch`、`PermissionDenied`、`Notification`、`Stop`、`StopFailure`、`SessionEnd` Hooks。Claude 手动拒绝权限时，组件会监听对应 transcript 中的工具结果，避免状态卡在“需要批准”。
