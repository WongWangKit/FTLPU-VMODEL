# LPU FPGA 等功能映射对照实验

本实验比较默认映射、专用 RAM/DSP 映射和等价逻辑重写，保持被测接口的功能、精度及对外周期不变。不采用固定 BF16、减少 lanes、删减错误检测或增加流水级来换面积。所有改造均为本目录实验副本，产品 RTL 只读。

## 配置与运行

- 工具：本机 Vivado/XSim 2023.2；器件 xcvu9p-flga2104-2L-e。
- 综合：OOC、默认 synthesis directive、flatten rebuilt、单线程；常规组综合前读入 10 ns 时钟/虚拟时钟及 1 ns I/O 预算。异步复位 false path；不包含布局布线。MXM 单列最终面积对照均使用 no_timing_driven；默认单列的约束修复例外见历史记录。它与上一轮综合后才加约束的结果不能直接作严格 A/B。
- 每次运行独立保存实际工作树源码快照和 SHA256；git HEAD/status 在对应结果目录。历史源码快照位于 fpga/tmp/mapping_<run>/src，清理前必须归档。
- 原版 MXM 固定四 tiles、每 dot bank 有 32 个输出列、每列顺序累加 8 个乘积。完整 compute 对照设置 FTLPU_DISABLE_BLOCK8 和 ACCUMULATOR_BLOCK_COUNT=1，仅为旧 Vector 计算后端，**不是 native LPU16 或完整 MXM slice**。

~~~powershell
Set-Location 'C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare'
python ./scripts/prepare.py
python ./scripts/make_mxm_tests.py
python ./scripts/make_mxm_optimized.py
python ./scripts/make_mxm_compact.py
python ./scripts/run.py --run new_vxm --cases alu_default alu_dsp alu_wide_dsp --timeout 900 --simulate
python ./scripts/run.py --run new_memory --cases mem_bram mem_uram srf_default srf_onehot --timeout 900 --simulate
python ./scripts/run.py --run new_mxm_leaf --cases mxm_mul_default mxm_mul_dsp mxm_mul_narrow_dsp --timeout 1200 --simulate
python ./scripts/run.py --run new_mxm_columns --cases mxm_column_default mxm_column_narrow_dsp mxm_column_compact_dsp --no-timing-driven --timeout 1200 --simulate
$env:FPGA_MIN_FREE_GB='3'
# 本机 Anaconda Python 已含 psutil；不要同时启动多组完整 compute 综合。
& 'C:/Users/huazh/anaconda3/python.exe' ./scripts/run.py --run new_mxm_full --cases mxm_compute_compact_dsp --no-timing-driven --timeout 1200 --simulate
python ./scripts/check_math.py --run new_math
python ./scripts/summarize.py --run new_analysis
~~~

python 可换成本机 D:/python/python.exe。通过 VIVADO_BIN 指定其他工具安装。每个运行编号必须全新；超时只终止该次工具调用自己的进程树。完整 compute 的仿真命令需要前一步实际生成完整综合网表。

## 对照组

| Case | 改动 |
|---|---|
| alu_default | 上轮移除不可达 special 分支的 basic wrapper，保留三格式基础运算 |
| alu_dsp | 只对原九个 8×8 子乘法器指定 use_dsp=yes |
| alu_wide_dsp | 在合法左对齐 significand 输入合同下，用一个带格式掩码的 24×24 DSP 乘法表达替代九个子乘法与 CSA 拼接；保留 active_blocks 输出和浮点后处理 |
| mem_bram / mem_uram | 同一 RAM/控制分离后端，唯一差异为 ram_style=block / ultra |
| srf_default / srf_onehot | 计数/优先选择写法与 unique-source one-hot 选择写法对照；保留逐 lane 状态、冲突无赢家、无效数据清零及 consume 语义 |
| mxm_mul_default / mxm_mul_dsp | 同一个旧 FP16/BF16 解码与 FP32 乘法函数；后者仅给 product 变量加 DSP 属性 |
| mxm_mul_narrow_dsp | 解码后的有效尾数低 13 bit 恒零，24×24 乘法精确改写为 11×11 再左移 26 bit；原结果规格化/舍入代码不变 |
| mxm_column_* | 一个真实 8 项点积列；保留原顺序 FP32 加法，未改成树形加法 |
| mxm_column_compact_dsp | 在 narrow DSP 后端基础上，将浮点减法的 26 次条件左移改为前导零计数＋指数限幅＋一次桶形移位；保留相同移位次数、加法顺序和舍入 |
| mxm_compute_* | 旧 Vector compute，保留四 tile 选择、跨 tile 累加、输入 consume、结果与 fault 控制；不包含权重装载、反量化模块或外部 accumulator SRAM |

narrow 表示消除已知零位，不是缩小数值精度。FP16/BF16 解码结果满足尾数 m24=m11<<13，因此 m24*n24=(m11*n11)<<26，乘积精确相同。旧 MXM 的异常数规则原样保留，不借机改成新的 IEEE 实现。

## 测试与验收规则

- VXM：每个版本 RTL/综合网表同一套 1221 个精确 bit-pattern 向量及非法格式/opcode 检查。新增 1200 个确定性随机乘法期望值由主机浮点打包产生，不复用 DUT 算术函数。
- MEM：4619 个端口级 scoreboard 检查，包括 1024 行冷零、全地址随机读写、WriteTap、非法输入、执行复位后数据保留。
- SRF：2305 个 scoreboard 步骤，每步检查全部 256 个 cells；包含地址遍历、2048 组多源/consume、冲突、空状态、复位。
- MXM 标量：8194 个结果检查；单列：512 个结果检查；完整 dot bank 测试入口预备 4096 个结果检查。随机全 16-bit 输入与冻结的原函数逐 bit 比较，另含独立已知数值。
- 完整 compute：12 组四 tile 波，覆盖 FP16/BF16、两个 weight buffer、正/负/分列权重；检查 384 个结果和 overlap/backpressure 两个错误案例。
- 规格化结构改写另有 73,553 个完整 FP32 加法函数差分检查，覆盖全部指数、消去距离和 50,000 组随机输入；不是形式证明。
- write_verilog -mode funcsim、XSim、unisims_ver/glbl；综合网表测试**无 SDF**，不证明 100 MHz 可实现。MXM 差分证明的是与旧行为的用例一致性，不是整个旧浮点模型的 IEEE 合规性。
- 资源以 utilization.rpt 的物理资源列为准。早期 primitives.txt 的 DSP* 会包含 DSP 内部展开单元，不能当 DSP48E2 数量；当前脚本使用精确 DSP48E2 名称。

## 结果索引与历史失败

| 目录 | 内容 |
|---|---|
| vxm001 / memory001 | 综合、utilization、DCP 和网表已导出；随后 primitive 报告 Tcl 引号错误。保留原失败状态，不把整段运行写成 PASS |
| vxm_recover001 | 只读打开 vxm001 的 DCP，补导原语/时序/DRC，再运行同源码与网表测试 |
| memory_recover001 | 对 memory001 做同样恢复；状态以实际 summary 为准 |
| mxm001 | 原乘法函数默认/强制 DSP，以及单列点积对照 |
| mxm_narrow001 | 等价有效位收窄 DSP 后端的标量与单列对照 |
| mxm_full001 | 旧 Vector compute 默认/优化后端有界综合 |
| mxm_full_rtl001 | 完整 compute 的定向 RTL 检查 |
| srf_sim002 | 扩大随机用例后，将 TB watchdog 从 10 µs 改为 100 µs；同一网表重跑，原 watchdog 失败保留 |
| mxm_area001 | 采用相同 no_timing_driven 策略重跑默认/尾数收窄单列；仍报告 10 ns 下估算时序 |
| mxm_compact001 | 与 mxm_area001 同策略，加入等价规格化优化的单列 |
| mxm_full_compact001 | 规格化与 DSP 后端组合的旧 Vector compute，采用 no_timing_driven |
| math_equiv001 | 规格化优化的函数级定向与随机差分 |
| mxm_column_rtl003 / mxm_area003 | 修复单列实验 wrapper 的组合求值写法，改成显式连续连线；RTL/综合网表均通过 512 项；默认列最终资源基线 |
| mxm_area003_sta001 | 只读打开 area003 的 DCP，补齐失效的 I/O 延迟并重导 STA；网表不变，面积模式不依赖 timing-driven 优化 |
| mxm_full_compact_rtl001 | 完整优化 compute 的 RTL 386 项定向检查通过；未声称有整块综合网表 |
| analysis003 | 最终资源 CSV/JSON、13 组证据审核、源码快照 ZIP 与交付文件哈希；analysis002 为无效 inf WNS 的解析器修复记录 |

summary.json 记录真实退出码与阶段完成情况；simulation.json 记录 RTL/gate 的独立状态。初期报告脚本错误不改变已保存的网表，但恢复仍须成功打开 DCP、检查黑盒/latch/DRC 后才采纳。

旧 MXM 的 10 ns timing-driven 尝试在单列优化或后续 STA 阶段达到 900 秒限额；完整原版 compute 曾在并行运行时触发主机低内存中止，记录在 HOST_MEMORY_ABORT.json。之后 MXM 面积对照统一使用 --no-timing-driven，不把不同策略的面积变化归因于 RTL 优化。后续可使用 Anaconda Python 并设置 FPGA_MIN_FREE_GB=3 启用主机内存保护，触发后仅终止本次工具进程树并停止该批后续启动。

综合后 DSP 的 DPIP/DPOP 警告表示缺少内部流水寄存器。实验保持原有对外周期，没有通过加拍消除警告；这些警告、负 WNS 和无布局布线状态必须随结果保留，不能合称为“时序通过”。

额外失败与修复记录：

- mxm_area001 默认列的旧实验 wrapper 出现 RTL/综合网表不一致，原始失败留存，不作为最终功能基线。mxm_area002 有 Vivado 环境错误；mxm_column_rtl002 的中间写法仍未通过。最终连续连线版本由 mxm_column_rtl003 与 mxm_area003 双层回归确认。
- mxm_area003 尝试在受管 XDC 内用 for 循环分块设置 I/O delay，Vivado 报 Designutils 20-1307，原 WNS=inf 无效。当前生成器已恢复合法的简单 XDC；retime.py 在普通 Tcl 中补齐约束，结果另存 mxm_area003_sta001。不能把 inf 当作时序通过。
- 完整 compute 的端口数量超过 10,000，旧简单 XDC 曾报 Constraints 18-929；整块综合尚未完成，未采纳其时序。未来正式全块流程需要使用合法 Tcl 约束文件或按已知端口分组的 XDC，并检查约束覆盖。
- mxm_full_compact001 在 Cross Boundary and Area Optimization 阶段达到 1200 秒上限，无最终 utilization/DCP；不是已经证明 FPGA 容量不足。其完整 RTL 测试由 mxm_full_compact_rtl001 单独完成。

最终结论见 [资源映射与 MXM 报告](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/FPGA资源映射对照与MXM综合_20261102.md)。analysis003/frozen_sources.zip 归档所有带 source_manifest.json 的实际源码快照；解压到 fpga/tmp 可恢复 mapping_<run>/src 路径；math_equiv001 的原快照另直接保存在其 results/src 下。audit.py 对本次选定的固定结果编号做审核，不是任意新运行的自动验收器。
