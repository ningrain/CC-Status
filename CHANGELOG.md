# 更新日志

本文件记录 CC Status 的用户可见变化。版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- 暂无。

### 变更

- 暂无。

### 修复

- 修复 Release 工作流在 Windows PowerShell 中读取中文更新说明时出现乱码的问题。

## [1.1.0] - 2026-08-08

### 新增

- CC Switch 改写 Claude 配置后自动补回缺失的状态 Hooks，无需重启 CC Status。
- 右上角增加提示音开关，并持久化开启或关闭状态。

### 变更

- CC Switch 用量查询缓存由 60 秒缩短为 30 秒。
- 优化 Codex 与 Claude 用量悬停文案，移除重复标签和 Claude 周限制占位。

### 修复

- 暂无。

## [1.0.0] - 2026-08-07

### 新增

- 支持 Codex 与 Claude Code 的工作中、需要批准、已完成和无任务状态。
- 展示 Codex 与 Claude 的本地用量、缓存比例及可用的周限额数据。
- 支持浅色/深色主题、窗口位置、置顶设置和系统托盘操作。
- 提供 EXE 安装包、开机启动、开始菜单入口及卸载流程。

### 变更

- CC Switch 管理的 Claude 自定义接入使用只读数据库查询并缓存结果。
- README 增加四种状态的实际界面预览。

### 修复

- 修复 Claude 中断或拒绝权限后状态未及时恢复的问题。
- 修复组件重复启动时窗口被二次显示而异常退出的问题。
- 修复瞬时文件访问失败可能导致组件退出的问题。
- 修复运行中卸载后进程或托盘图标残留的问题。

[Unreleased]: https://github.com/ningrain/CC-Status/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ningrain/CC-Status/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ningrain/CC-Status/releases/tag/v1.0.0
