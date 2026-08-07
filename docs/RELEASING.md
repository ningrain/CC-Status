# 分支与发布流程

## 分支模型

`main` 始终保持可测试、可构建和可发布。开发工作使用短期分支：

- `feat/<name>`：向后兼容的新功能。
- `fix/<name>`：缺陷修复。
- `docs/<name>`：文档与示例。
- `refactor/<name>`：不改变用户行为的重构。

短期分支通过 Pull Request 合并，默认使用 squash merge，合并后删除。只有同时维护旧版本线时才创建 `release/<major>.<minor>`。

## 版本规则

仓库根目录的 `VERSION` 是唯一版本源，格式必须为 `MAJOR.MINOR.PATCH`：

- PATCH：兼容性缺陷修复，例如 `1.0.0 → 1.0.1`。
- MINOR：向后兼容的新功能，例如 `1.0.1 → 1.1.0`。
- MAJOR：不兼容的配置、数据或行为变化，例如 `1.1.0 → 2.0.0`。

已经发布的精确版本标签和附件不得移动、替换或复用。发现问题时发布新的 PATCH 版本。

## 准备发布

1. 从最新 `main` 创建发布准备分支。
2. 更新 `VERSION`。
3. 把 `[Unreleased]` 内容整理到新的版本章节，并填写发布日期。
4. 更新底部的 Changelog 比较链接。
5. 运行全部测试：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-All.ps1
   ```

6. 构建并完整验证安装包：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1
   ```

7. 通过 Pull Request 合并到 `main`，等待 `CI / test` 通过。

## 创建 Release

从最新 `main` 创建带说明的标签：

```powershell
git switch main
git pull --ff-only
$version = (Get-Content .\VERSION -Raw).Trim()
git tag -a "v$version" -m "CC Status $version"
git push origin "v$version"
```

标签推送会触发 Release 工作流。工作流会验证标签与 `VERSION`，运行全部测试，构建安装包，生成 SHA-256，并创建包含附件的 Draft Release。

检查 Draft Release 的说明、安装包和校验和后再手动发布。仓库启用不可变 Release 后，正式发布的标签和附件将被锁定。

## 紧急修复

通常从最新 `main` 创建 `fix/<name>`，修复后发布新的 PATCH 版本。如果 `main` 已包含不适合进入旧版本的新功能，则从旧标签创建维护分支，发布修复后再把修复合并回 `main`。
