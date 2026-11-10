# 将当前SXM改动发布到远程develop

## 已检查的分支关系

2026-11-10整理时：本地工作区在`FPGA`，HEAD=`ff42e8c`；本地`develop`仍为`a8fb96a`，远程`develop`已经到`a39c5d0`。已fetch更新远程跟踪引用，但**未切分支、未暂存、未提交、未推送**。

`FPGA`比旧develop多一个FPGA资料提交，远程develop另有MXM/VXM更新。因此推荐：

1. 从当前工作区建本地快照分支，提交本轮列明的文件；本机其它忽略文件完全不动。
2. 用独立worktree基于最新origin/develop，只cherry-pick本轮快照提交；不把FPGA资料提交一并合入。
3. 核对差异，普通快进推送`HEAD:develop`。远程又前进则重新核对合并，绝不强推。

这样原工作区和本地DCP仍保留，也不会把新develop的MXM覆盖成旧版本。不要直接从当前FPGA执行`git push origin HEAD:develop`。

## 1. 检查并保存本地快照

在PowerShell执行。分支名已存在则命令停止，换新名字，不用`switch -C`。
以下使用PATH中的Python 3；若本机没有`python`，将`PY`函数中的命令替换为实际Python解释器。

```powershell
& {
  $ErrorActionPreference = 'Stop'
  Set-Location 'C:\Users\<你的用户名>\Desktop\LPU\lpu_src\FTLPU-VMODEL'
  function G { & git @args; if ($LASTEXITCODE -ne 0) { throw "git failed: $args" } }
  function PY { & python @args; if ($LASTEXITCODE -ne 0) { throw "python failed: $args" } }
  G diff --cached --quiet
  PY scripts/check_sxm_publication.py
  G switch -c sxm-writetap-snapshot-20261110
  $paths = Get-Content -LiteralPath config/sxm_publication_paths.txt -Encoding utf8
  G add -- $paths
  PY scripts/check_sxm_publication.py --staged
  G diff --cached --check
  G diff --cached --stat
  G diff --cached --name-only
}
```

确认暂存范围只有预期的SXM/既有集成修改、配置、spec和结果包，然后执行：

```powershell
git commit -m "sxm: add striped WriteTap integration and preserve partial L5 evidence"
# 必须确认commit成功后再继续第二步。
```

不使用`git add -A`或`git add -f`。`.gitignore`不会取消已跟踪文件；检查脚本同时检查候选/暂存文件名和实际内容，避免靠忽略规则漏检。当前预检不扫描无改动历史，不代表全仓库历史无敏感信息。

## 2. 在最新develop上准备发布提交

在原VMODEL工作区中执行；以下目录不存在时才创建。worktree在旁边新建，不覆盖原工作区。

```powershell
& {
  $ErrorActionPreference = 'Stop'
  function G { & git @args; if ($LASTEXITCODE -ne 0) { throw "git failed: $args" } }
  $snapshot = (G rev-parse sxm-writetap-snapshot-20261110).Trim()
  G fetch --no-tags origin develop
  $publish = Join-Path (Split-Path (Get-Location).Path -Parent) 'FTLPU-VMODEL-publish-20261110'
  if (Test-Path -LiteralPath $publish) { throw '发布目录已存在，请检查后使用新的目录名' }
  G worktree add -b sxm-develop-20261110 $publish origin/develop
  G -C $publish cherry-pick $snapshot
  G -C $publish status --short --branch
  G -C $publish diff --stat origin/develop...HEAD
}
```

如果cherry-pick冲突，停在发布worktree处理。尤其检查`.gitignore`和集成接口；不要整树选择ours/theirs，不覆盖远程MXM/VXM。解决后对具体文件`git add`，再`git cherry-pick --continue`。不确定时保留现场，原快照和原工作区不受影响。

**功能边界**：已有L4基线是main `f4dd088f`；develop `a39c5d0`包含后续MXM变化，应用成功不代表新组合已通过L4。这里是保存阶段成果的提交，L5仍暂停；若团队要求develop每次更新必须通过新基线回归，先推发布分支并走PR，不直接更新develop。

## 3. 最终预检与普通推送

进入刚创建的发布worktree后：

```powershell
& {
  $ErrorActionPreference = 'Stop'
  function G { & git @args; if ($LASTEXITCODE -ne 0) { throw "git failed: $args" } }
  & python scripts/check_sxm_publication.py --base origin/develop
  if ($LASTEXITCODE -ne 0) { throw '发布预检失败' }
  G status --short --branch
  G log --oneline origin/develop..HEAD
  G diff --check origin/develop...HEAD
  G push --dry-run origin HEAD:develop
  G push origin HEAD:develop
}
```

若远程拒绝non-fast-forward，说明别人又更新了develop：停止，fetch后检查差异并合并/重建发布分支，再验证。**不使用`--force`或`--force-with-lease`。** 若develop受保护，改为`git push -u origin sxm-develop-20261110`，通过PR合入，不绕过保护。

## 本地结果保全

- Git发布只包含脱敏报告及哈希，不删除原始实验目录。
- 原DCP/综合网表依旧保存在工作区`learn/sxm_writetap_implementation_20261109/results`，不受worktree切换影响。
- 当前T4综合网表超过100 MiB；不建议把它或DCP强行加入普通Git历史。若需要异机继续实现，按publication_manifest核验哈希后另行传输这些本地产物。
- 不执行`git clean -fdx`，它会删除忽略的结果。不要用`reset --hard`保存当前工作。
