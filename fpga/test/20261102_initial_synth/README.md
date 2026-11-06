# LPU16 初步 FPGA 综合与综合网表仿真实验

## 范围与基线

问题：旧 VMODEL 是否能直接上板；新 LPU16 的 MEM、SRF、VXM 基础资源是否支持合理选板；FPGA RAM 后端能否保持已有叶模块行为。

- 2026-11-02，VMODEL HEAD `7366a2b9eeaf65f1866ba603158b405c112bc2e9`，使用当时实际 dirty 工作树，未覆盖用户改动。
- Vivado/XSim 2023.2；主要目标 `xcvu9p-flga2104-2L-e`。
- 原 `rtl/` 仅只读。实验改造均在本目录 `rtl/`；每次 run 的实际源码在 `fpga/tmp/<run>/src/`，逐文件 hash 留在 `results/<run>/source_manifest.json`。
- 原 native MEM leaf 的 RAM 不能推导 BRAM，实验后端分离 RAM 和异步复位。basic ALU wrapper 仅在 `SPECIAL_KIND=NONE` 的等价条件下结构移除 special；固定 BF16 另有独立配置和测试。
- 结果解读及候选：[评估报告](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/LPU16初步综合与上板评估_20261102.md)。

## 可复现入口

以下从 VMODEL `fpga/` 目录执行。`python` 可替换为本机 `D:/python/python.exe`。未设置 `VIVADO_BIN` 时脚本默认使用本机 Desktop/Vivado2023 下的 2023.2；其他安装通过环境变量传入 bin 目录。

```powershell
Set-Location 'C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga'
$env:VIVADO_BIN = 'C:/Users/huazh/Desktop/Vivado2023/Vivado/2023.2/bin'
python ./test/20261102_initial_synth/scripts/run.py --run rerun001 --cases mem_leaf_bram mem_slice_bram srf_leaf alu_basic_pruned alu_basic_bf16 --timeout 900
python ./test/20261102_initial_synth/scripts/sim.py --synth-run rerun001 --run resim001 --cases mem_leaf_bram srf_leaf alu_basic_pruned alu_basic_bf16
python ./test/20261102_initial_synth/scripts/sim.py --synth-run rerun001 --run resim_original --cases mem_leaf alu_basic --modes rtl
python ./test/20261102_initial_synth/scripts/summarize.py
python ./test/20261102_initial_synth/scripts/audit.py
```

`--run` 必须是新的单一目录名；已有源码快照或仿真结果不会被自动覆盖。`--part` 可指定另一器件，但不同器件需独立 run。`--timeout` 限制的是**单项 Vivado 完整调用**，包括综合、报告和导出；timeout 不一定代表综合内核失败，需结合日志分阶段判断。

当前 `synth.tcl` 为后续重跑改用单线程，并先导出 DCP/funcsim 再生成报告；历史 run 使用其快照版本，线程数/导出顺序以对应日志为准。100 MHz 只是综合后的报告约束，不是 synthesis timing-driven target 或实现签核。`summarize.py` 的已选证据组合固定为 run007/run010/run012；新 run 会进入原始测量表，但用于结论的组合应明确审核后更新。

本机沙箱环境曾出现 Tcl 路径归一化与 `.Xil` 清理异常；可在普通获授权的终端运行上述命令。文件路径用 `/` 传递给 Tcl，避免反斜杠转义。无需改全局 Git safe.directory，脚本使用单次命令配置。

## 文件与检查规则

| 目录/文件 | 用途 |
|---|---|
| `scripts/run.py` | 冻结源码、记录 git baseline/hash，逐项有界调用 Vivado，保存退出状态 |
| `scripts/synth.tcl` | 按 case 选择真实顶层/参数，OOC synth、资源/时序/DRC、黑盒/latch、DCP/funcsim |
| `scripts/sim.py` | 同一 TB 分别编译 RTL/网表；XSim + unisims_ver/glbl；检查退出码、PASS sentinel 和 Fatal/ERROR |
| `scripts/summarize.py` | 提取已生成报告，另算线性外推和模型容量；不把外推混入实测 |
| `scripts/audit.py` | 核对已选证据、黑盒/latch/DRC、仿真状态、本地文档链接、Python 语法和源码 hash；不重跑 Vivado |
| `scripts/parts_selected.tcl` | 精确器件资源和本机可用 part 探测 |
| `scripts/recover_utilization.tcl` | 从已有 DCP 只读补导资源报告 |
| `rtl/mem_leaf_bram.sv` | FPGA RAM 实验后端，未替换产品 RTL |
| `rtl/basic_alu_probe.sv` | 基本 ALU 的实验结构 wrapper，支持动态三格式或固定 BF16 |
| `tb/*_tb.sv` | 独立端口级 scoreboard/固定 bit-pattern 期望值；无层级 force/预载 |

所有 post-synthesis 测试是 **functional simulation，无 SDF**。TB 等待初始 200 ns 避开 glbl GSR。未执行行为之外的时序仿真、实现或上板。

## 结果索引

| 运行 | 内容和状态 |
|---|---|
| run001 / parts_selected | Vivado 版本、VU9P/ZU9EG/KU115/U250/VU19P 器件库探测 |
| run002–run006 | 环境和脚本探索；路径归一化、沙箱临时目录、早期报告命令问题及人工终止；不算成功实验 |
| run007 | MEM BRAM leaf、2-tile MEM slice、SRF leaf 完整综合；旧 MEM/旧 dot 各 600 秒超时，旧 top 被保留字语法阻塞 |
| run008 | 全 filelist ALU 被 tile `config` 语法阻塞，以及工具文件读取异常；不作资源结论 |
| run009 | 最小 ALU 依赖；basic 已生成 2393 LUT/109 FF 报告，后续 timing 阶段超时；special/原 MEM 运行存在工具文件读取异常 |
| run010 | 三格式 basic wrapper 完整综合；其中 `alu_basic_bf16` 接线有误并已标 INVALID，不能用于 BF16 外推 |
| run011 | 单线程原 native MEM 生成 DCP、导出阶段超时；旧 top 保留字错误；旧 dot 环境错误 |
| recover001 | 从 run011 MEM DCP 补导 utilization；不补称该 run 已完成全部步骤 |
| run012 | 正确固定 BF16 wrapper 完整综合；用于 BF16 预算 |
| sim001 | MEM 原版/BRAM 后端/SRF RTL PASS；初次 ALU 缺默认 timescale，失败后由 sim003 修正 |
| sim002 | MEM BRAM 综合网表，4619 checks PASS |
| sim003 | 原版 ALU RTL，21 算术向量及格式/opcode 拒绝检查 PASS |
| sim004 | SRF 综合网表，385 checks PASS |
| sim005 | 三格式 basic wrapper RTL/综合网表，同用例 PASS |
| sim006 | 固定 BF16 wrapper RTL/综合网表各 36 个向量及拒绝检查 PASS，遍历全部未使用格式引脚值 |
| analysis001 | 测量 CSV/JSON、线性外推 JSON、参考 LPU16 profile、最终脚本 hash |

关键结果链接均在 `results/`。`fpga/tmp/` 含可重建快照、编译工程和临时 XSim 数据；本轮未清理。清理前保留报告引用的源码/hash、DCP、完整综合网表、TB 及日志。**run011 MEM 的 timeout 导出网表不能因文件存在就当完整有效网表。**

## 验证层级

已完成：代码审计、局部实际综合、部分局部 RTL/综合网表同用例检查、板卡官方资料核对、可复算资源外推。

最终证据核对见 [audit.json](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_initial_synth/results/analysis001/audit.json)：5 个选定综合案例均为 0 blackbox、0 latch、该阶段 DRC 0 violation；10 项 RTL/网表测试通过，另保留 1 项已由后续运行修正的初始失败。106 个原始输入文件与 run012 快照 hash 一致。这里的 DRC 不包含布局布线后的实现签核。

未完成：native 整机 LPU16、原旧顶层综合网表、完整 MXM/special 资源签核、整机 CModel 差分、P&R、CDC、SDF、MIG/PCIe、真实上板、模型准确率或端到端性能测试。
