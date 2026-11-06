# FPGA 分支发布说明

日期：2026-11-06。只整理发布规则，尚未执行暂存、提交、创建分支或推送。

## 分类与阅读入口

| 类别 | 位置 | 阅读入口 |
|---|---|---|
| 调查结论 | docs/ | [IP-17 平台与演示范围](docs/IP17_FPGA平台与MoE演示范围_20261104.md) |
| 优化综合结论 | docs/ | [MEM/SRF/VXM/MXM 对照](docs/FPGA资源映射对照与MXM综合_20261102.md) |
| 初轮综合与仿真 | test/20261102_initial_synth/ | [实验说明](test/20261102_initial_synth/README.md) |
| 映射优化与验证 | test/20261102_mapping_compare/ | [实验说明](test/20261102_mapping_compare/README.md)、[13组最终审计](test/20261102_mapping_compare/results/analysis003/audit.json)、[资源CSV](test/20261102_mapping_compare/results/analysis003/measured_resources.csv) |
| 板卡与MoE脑测 | test/20261104_ip17_decision/ | [实验说明](test/20261104_ip17_decision/README.md)、[资源外推](test/20261104_ip17_decision/results/projection002/resource_projection.json)、[脑测结果](test/20261104_ip17_decision/results/brain001/brain_results.json) |

沿用“日期_课题 / results / 运行编号”分类，不迁移被历史报告和hash引用的文件。失败、恢复、未采纳运行同样留存，最终结论以各报告明确选定的运行编号为准。

## 上传与排除

- 上传：调查文档、实验README、RTL探针/测试平台、Python/Tcl/PowerShell脚本、XDC、配置、JSON/CSV汇总、原始rpt/log/txt证据。
- results默认忽略，仅放行上述明确的证据格式。三份冻结源码zip和tiny_evidence.npz逐个放行，不泛化允许所有压缩包。
- 排除：fpga/tmp整个临时工作区（含独立bare Git仓库）、DCP、netlist.v、波形、缓存、可执行文件以及其他未列入白名单的生成产物。
- 不上传本机其它RTL联调修改，不包含仓库外doc/PPT中的演示文稿。
- fpga/.gitattributes对本目录关闭文本换行转换，保留原始字节，避免core.autocrlf=true改变历史SHA256。
- 没有删除任何本地结果。未来新增白名单之外的证据需要审核后修改规则，不使用git add -f整目录。

## 可复现范围

历史结果是当时的真实记录，不因为上传GitHub就升级成“完整LPU16已综合”或“上板成功”。

历史artifact_manifest包含部分本地保留的综合网表/DCP，因此仅克隆此分支不能直接通过要求全部本地产物存在的旧audit脚本。公开包保留报告、日志、输入归档和生成脚本，网表/DCP需要在相应Vivado环境重建。

部分旧脚本/报告使用本机绝对路径，旧正文链接在GitHub不能直接跳转。本页提供相对链接入口，未改写历史报告、输入或审计hash。重跑时按实验README配置路径和工具；冻结zip保存了必要版本输入，但不承诺未经移植即可在任意机器一键重跑。

保留的日志可能出现本机用户名、路径和工具/主机信息。发布预检不等同全面凭据扫描，推送前应检查暂存差异。

## 预检（不修改index或远程）

在FTLPU-VMODEL仓库根目录执行：
```powershell
python fpga/scripts/check_publication.py
git add --dry-run -- .gitignore fpga
```

预检清单和统计保存在被忽略的fpga/tmp/publish_20261106中。未运行Vivado、不修改任何综合结果。

## 创建并发布 FPGA 分支

以下命令由用户执行。本次检查时本地在develop，HEAD为a8fb96a，暂存区为空，远程未发现FPGA分支。普通新分支继承该提交及其历史，新增提交仅包含FPGA资料和忽略设置，并非仅有fpga文件夹的孤立仓库。

```powershell
& {
$ErrorActionPreference = 'Stop'
Set-Location 'C:\Users\huazh\Desktop\LPU\lpu_src\FTLPU-VMODEL'
function G {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw "git failed: $args" }
}
G diff --cached --quiet
G switch -c FPGA
G add -- .gitignore fpga
G diff --cached --stat
G diff --cached --name-only
G commit -m "fpga: publish studies, test sources and synthesis evidence"
G push --set-upstream origin FPGA
}
```

第一条diff检查已有暂存区，若非空则中止，不会把其它已暂存改动带入提交。切分支保留尚未提交的SXM/联调工作，定向git add不会提交它们。不要改用git add .或git add -A。

最后一条push创建远程refs/heads/FPGA并设置跟踪关系，不需要另在GitHub网页建分支。若分支已存在、推送冲突或权限失败，停止检查，不使用force或switch -C覆盖。无需为这批小型证据引入Git LFS。
