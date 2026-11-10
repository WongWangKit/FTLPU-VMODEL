# SXM WriteTap：2026-11-10 暂停时的发布包

这是已有结果的脱敏归档，没有因整理 Git 而重跑 RTL、综合或 STA。

## 当前结论

- SXM-01～04按模块级范围完成；多bank条带＋原生WriteTap，额外完整块payload队列为0。
- LPU32最新MXM→SXM→MEM→正常Read→VXM，两格式各32矩阵全链通过。
- L5暂停：9项综合完成5项，布线DCP为0；当前T2后综冒烟10/10。
- **测试基线是VMODEL main `f4dd088f`；发布时远程develop已到`a39c5d0`，其中含后续MXM改动。合入develop之后的集成回归尚未执行。** 不把旧结果改写成新提交通过。

| 综合对象 | T2 LUT/FF | T4 LUT/FF | T8 LUT/FF |
|---|---:|---:|---:|
| 完整核心 | 78688 / 9416 | 217787 / 26509 | 未完成 |
| 完整WriteTap外壳 | 3635 / 185 | 7159 / 318 | 14510 / 623 |
| 合体 | 未执行 | 未执行 | 未执行 |

五份已完成综合均0 DSP/BRAM/LUTRAM/latch/blackbox。综合估计不是布线后签核。

## 阅读入口

- [当前设计spec](../../spec_new_c7ae225/sxm设计与参数化方案.md)
- [验收清单](../../spec_new_c7ae225/SXM三角主设计回归测试清单.md)
- [归档索引及双SHA256](results/20261110_pause/publication_manifest.json)
- [功能与物理状态汇总](results/20261110_pause/evidence03/summary.json)
- [资源CSV](results/20261110_pause/evidence03/resources.csv)
- [T4核心综合资源](results/20261110_pause/physical/l5_queue05_core_t4_synth/synthesized/synth_utilization.rpt)
- [T8暂停时日志](results/20261110_pause/physical/l5_queue05_core_t8_synth/synthesized/vivado.log)
- [当前T2后综冒烟](results/20261110_pause/functional/gate_probe04/summary.json)
- [推送方法](PUBLISHING.md)

## 保留与排除

**上传**：当前RTL/TB/filelist、当前spec、精选JSON/CSV/rpt/log、约束与历史脚本逻辑。

**本机保留，不上传**：DCP、百MB级综合网表、完整构建输出、波形、缓存、厂商工具、运行时进程/主机采样和本机配置。原始位置仍为工作区`learn/sxm_writetap_implementation_20261109`；没有删除或移动它们。10个DCP/网表文件的大小和原始SHA256列在publication_manifest的local_only_artifacts中。克隆仓库不能恢复这些二进制，异机继续实现时另行安全传输，不使用`git add -f`塞进普通Git历史。

发布副本对用户名路径/主机名做了脱敏；原始文件不改。索引同时记录source_sha256和published_sha256，历史manifest里的hash仍指原始字节。`<VMODEL>`、`<LPU_WORKSPACE>`、`<USER_HOME>`和`<HOST>`是脱敏标记。

`reference_scripts/20261110_pause`仅保留本轮脚本逻辑及约束，含外部learn用例、旧baseline和本机工具配置依赖；脱敏路径是占位符，**不能声称克隆后这些历史脚本即可一键重跑**。产品入口使用仓库内显式filelist，不把`rtl/sxm_native/test`中的历史重复模块递归加入编译。

spec内指向工作区`learn`、历史archive或exploration的链接仍是本地证据路径；远程读者请从本页的发布索引查阅已归档结果。保留本地原文，不批量重写历史证据引用。

## 本地预检

在VMODEL仓库根目录：

```powershell
python scripts/check_sxm_publication.py
# git add之后，检查真正将提交的index字节：
python scripts/check_sxm_publication.py --staged
```

预检不暂存、不提交、不切分支、不推送；检查生成物/常见凭据/个人路径/大小、忽略规则及归档hash。不是全历史的穷尽秘密审计，人工仍应检查暂存diff。
