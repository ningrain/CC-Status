# 分支与发布流程

历史问题和防复发规则见 [发布复盘](RELEASE-RETROSPECTIVE.md)。

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

发布准备提交不得直接创建在本地 `main` 上。即使本地拥有推送权限，也必须通过短期分支和 Pull Request，以免本地提交与 squash 合并后的远端历史分叉。

### 合并前硬性检查

- 工作区只包含本次发布内容，没有运行时数据或 PowerShell 模块缓存。
- 提交作者是项目维护者配置的 Git 身份。
- PR 的必需检查全部通过；失败检查必须先修复，禁止先打标签再补救。
- PR 已合并且远端短期分支已删除。
- 不把多个具有前后依赖的 `git`/`gh` 写操作放在同一条 PowerShell 命令中。PowerShell 的 `$ErrorActionPreference` 不会自动把原生命令的非零退出码转换成终止错误；每一步都必须检查 `$LASTEXITCODE`。

## 创建 Release

PR 合并后，从最新远端 `main` 创建带说明的标签：

```powershell
git fetch origin main --tags
if ($LASTEXITCODE -ne 0) { throw 'git fetch failed' }

git switch main
if ($LASTEXITCODE -ne 0) { throw 'git switch main failed' }

git pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'main is not a clean fast-forward from origin/main' }

$head = git rev-parse HEAD
$originMain = git rev-parse origin/main
if ($head -ne $originMain) { throw 'HEAD does not match origin/main' }
if (git status --porcelain) { throw 'Working tree is not clean' }

$version = (Get-Content .\VERSION -Raw).Trim()
if (git tag --list "v$version") { throw "Local tag v$version already exists" }
if (git ls-remote --tags origin "refs/tags/v$version") { throw "Remote tag v$version already exists" }

git tag -a "v$version" -m "CC Status $version"
if ($LASTEXITCODE -ne 0) { throw 'git tag failed' }

git push origin "v$version"
if ($LASTEXITCODE -ne 0) { throw 'tag push failed' }
```

禁止在同一命令中先推送 `main` 再推送标签。标签只能指向已经存在于 `origin/main`、且对应 PR 必需检查已经通过的提交。

标签推送会触发 Release 工作流。工作流会验证标签与 `VERSION`，运行全部测试，构建安装包，生成 SHA-256，并创建包含附件的 Draft Release。

检查 Draft Release 的说明、安装包和校验和后再手动发布。仓库启用不可变 Release 后，正式发布的标签和附件将被锁定。

正式发布前再次确认：

- Release 标题和标签均为目标版本。
- Release 不是 prerelease，说明中没有“重新发布”等临时措辞。
- 安装包与 `.sha256` 文件同时存在，下载后计算的 SHA-256 与文件内容一致。
- Release 工作流的测试、安装包构建和验证步骤全部成功。

## 紧急修复

通常从最新 `main` 创建 `fix/<name>`，修复后发布新的 PATCH 版本。如果 `main` 已包含不适合进入旧版本的新功能，则从旧标签创建维护分支，发布修复后再把修复合并回 `main`。
