# SXM 两功能、三组合裁剪回归（2026-11-11）

## 当前产品范围

- MATRIX_TP：ROW→ROW、ROW→BLOCK8。
- VECTOR_PERMUTE：ROW→ROW，单片段可就绪，不补齐矩阵。
- 退出：typed mode 2/3、ROW CFG mode 2/3、CAP row≥8、raw T input_row 8/9（包括 VMODEL family0 的整块 T）。明确拒绝，不拆成新指令序列。
- 保留原编码、端口宽度、context、map、P/pair/RUN、FP32相位、源池和 WriteTap/drain。typed 输入端口上部为兼容填充，仅低256 bit/源有效。
- 裁剪生效于 `sim/filelist_sxm_triangle_full.f` / `sim/filelist_sxm_triangle_mem.f` 当前产品层级。历史 `sxm_slice` / `sxm_row_core` 和旧 ICU 顶层不自动迁移；不把历史全功能测试标为新产品PASS。

## 修改范围

1. `sxm_triangle_core.sv`：拒绝广播/整块模式，删除广播输出和整块捕获分支。
2. `sxm_triangle_row_frontend.sv`：拒绝广播配置/整块CAP，删除整块输入字节选择与广播value分支；不改行输出流水和计数。
3. `sxm_compat_decode.sv` / `sxm_compat_engine.sv`：保留ROW T/P及输出编码，拒绝整块/广播T，删整块输入写入选择。
4. MXM/VXM/MEM/SRF、WriteTap writer/completion均未修改。未改CModel，未运行综合/布局布线/STA。

源池仍为3/10/36×256 B；LPU32 P/pair payload仍为320 B。收益是被删除功能的组合选择/译码，不宣称减少对应寄存器量或已经量化LUT收益。

## RTL回归入口

Linux/WSL + 本机现有 Verilator（`/usr/local/bin/verilator`）：

```sh
python3 scripts/run_sxm_prune.py /absolute/path/to/new-run --tiles 2 4 8
```

必须使用新的输出目录，不覆盖旧证据。支持 `--part typed` 或 `--part row`。当前RTL与已发布main祖先 `468ad6b13e28141cc9b26160876209567bc67ad5` 同时实例化；五个参考模块与原回归使用的本地快照 `9bd20a29` 内容完全一致。需要本地Git中存在该main祖先提交；浅克隆需先获取它。每次冻结RTL/测试、记录hash，构建文件在运行目录 `tmp/`。

测试检查：
- typed：原日历、私有配置、两格式、双矩阵/32批次与8-bit timer回绕，ready/busy/accept及有效数据/tag逐拍对照。
- ROW/raw：原consume/output-valid/有效数据golden不变；修改前后控制、busy、fault、有效selector及数据在每个时钟沿后对照。
- 旧 `wide04` / `full07` 的适用子集、`c814_04` 的792拍连续双矩阵原样复制在cases中；不将更早814拍固定池日历称为本次基线。
- 新增拒绝用例：提供合法selector，仅改变被裁剪的mode/row字段；拒绝无输出/消费，非法CAP不得写payload。
- 用例及来源见 `cases.json`。历史广播/整块正例未覆写，未计入新版本通过数量。

## 本地实验与运行保护

完整本地记录：`learn/sxm_prune_20261111/results/reg01`。
真实MEM/SRF小回归：`learn/sxm_writetap_implementation_20261109/results/prune_mem01`，原 `guard.py prune_mem01 2 4 8 smoke`，每档BF16/FP32连续双矩阵、一般map、真实WriteTap采样及普通Read读回。

Windows父进程复用已有 `host_runtime`，持有任务级系统休眠抑制；允许息屏，不修改全局电源设置。不以息屏为进程终止条件。原始日志/快照留本地，精选summary另列。

## 验证边界

这是RTL仿真及有限用例的逐拍差分，不是形式化全输入等价证明。未重跑所有长序列，未重新实例化最新MXM/VXM跑整条FU链；本轮以原SXM输入/输出边界日历差分和真实MEM/SRF回归验证修改。历史L5结果不移记为本次结果。


## 本轮结果（2026-11-11）

| 范围 | LPU16 | LPU32 | LPU64 | 合计 |
|---|---:|---:|---:|---:|
| typed核心、ROW/raw、原golden与拒绝测试 | 50/50 | 51/51 | 50/50 | 151/151 |
| 真实MEM/SRF：两格式连续双矩阵、一般map、WriteTap及Read读回 | 2/2 | 2/2 | 2/2 | 6/6 |

合计 **157/157通过**。其中109项在同一TB内实例化修改前后RTL进行时钟沿后逐拍对照（包括原负例的错误/无副作用轨迹）；其他项检查拒绝或真实MEM/SRF。LPU32原c814_04的792拍、2048个FP32值、私有map、镜像配对及两相位golden原样通过。typed三档覆盖N=2/32和计数器回绕；向量覆盖3T+1尾片及单源片段。没有将被删除模式的历史PASS移入当前统计。

精选结果：[总览](results/20261111/summary.json)、[核心/ROW逐项](results/20261111/core_row_summary.json)、[MEM逐项](results/20261111/mem_summary.json)。完整日志和原始manifest保留在上述本地实验目录。本次未发现保留用例的周期或数据差异；没有进行形式化全输入等价证明。

## 追加综合结果

2026-11-11按用户授权，只完成LPU16/32新完整核综合及综合后内部STA；不重跑旧核，不做布局布线，不跑LPU64。LUT分别下降9.65%/9.24%，FF下降1.44%/0.09%；100MHz下内部setup/hold估算均满足约束。LPU32 setup裕量比旧设计少0.775ns，不能把面积下降表述为所有时序均改善。

详见[资源和STA比较](results/20261111_ppa/comparison.md)、[数据与源码hash](results/20261111_ppa/summary.json)。前述“未综合”描述的是上一轮RTL功能回归的范围；此次追加结果仍不属于布线后L5签核。
