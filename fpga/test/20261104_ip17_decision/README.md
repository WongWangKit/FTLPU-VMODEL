# IP-17 平台与 MoE 演示决策实验（2026-11-04）

## 问题、边界与结论

在不改变 LPU16 既定配置、native 全系统尚未完成的条件下，选择目标板并定义 MoE 演示，复核已有 Vivado 优化证据。

- 主推 HTG-960/VU19P；候选 V80、HTG-840-2。
- 首期真实模型范围：Granite-3.1-1B-A400M 的一个原宽度完整 block；后续24层、B1、prefill16/decode8、context32，混合 W8A16。
- 已完成分支审计、器件查询、独立小模型脑测与资源/容量外推；未完成整机综合、P&R、真实权重推理或板测。
- 正式结论：[IP17 报告](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/IP17_FPGA平台与MoE演示范围_20261104.md)。
- 所有写入只在 fpga 内，原 RTL 与仓库分支未修改。

## 冻结输入

远程 https://github.com/WongWangKit/FTLPU-VMODEL.git，全 heads：
- main：9e03241f7574a03a2788d1bb64af650e18df8e3a
- develop：a8fb96a377a3d7b8269b8ea86d28019559cd2127

源码归档：
[main.zip](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261104_ip17_decision/results/baseline001/main.zip)、
[develop.zip](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261104_ip17_decision/results/baseline001/develop.zip)。
SHA256 记录在 baseline_audit.json。临时 bare repo 和解包在 fpga/tmp/ip17_20261104；这些不是新的产品代码。

模型 revision：408b6e90baab8cf24f4aa9f8e19703ffa0a53b29。保存了官方 API metadata、config.json、Transformers v4.46.0 modeling_granitemoe.py；没有下载模型权重。
[demo_spec.json](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261104_ip17_decision/cases/demo_spec.json)、
[board_candidates.json](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261104_ip17_decision/cases/board_candidates.json)。

## 实际运行索引

| 运行 | 内容 | 结果 |
|---|---|---|
| baseline001 | 两分支冻结；12条历史源文件/运行组合逐字节比对 | develop 12/12一致，main 不是同一输入；不宣称完整依赖闭包一致 |
| parts001 | 本机 Vivado2023.2 get_parts/get_property | 三种器件命中，PART_AUDIT_COMPLETE；不是综合/授权验证 |
| brain001 | NumPy2.3.5、seed20261104、小型2层MoE | 10/10通过；随机权重，无RTL、无周期证明 |
| projection001 | 首次资源外推 | 保留历史，不作为最终：浮点0.7转换导致VU440 DSP余量少算1 |
| projection002 | 使用整数乘7除10，并保存脚本版本 | 最终资源预算；VU440剩余DSP=1504 |
| sources001 | 尝试将厂商公开网页/PDF保存成本地原文 | 首个HTG页面HTTP Access Denied而停止；不冒充下载成功。研究使用浏览工具成功读取的官方页，URL/日期/要点留存于cases和报告 |
| audit001 | 归档hash、脑测、预算、历史证据hash、报告链接、分支复查 | 以最终audit.json为准 |

历史13组综合/综合网表功能验证仍来自11月2日，链接与限制见主报告，不把本次器件查询说成重跑13组综合。

## 复现

以下 PowerShell 命令使用新运行编号，目录存在即失败，不覆盖历史结果。

```powershell
& 'C:\Users\huazh\anaconda3\python.exe' 'C:\Users\huazh\Desktop\LPU\lpu_src\FTLPU-VMODEL\fpga\test\20261104_ip17_decision\scripts\braincheck.py' --run brain_repro001
& 'D:\python\python.exe' 'C:\Users\huazh\Desktop\LPU\lpu_src\FTLPU-VMODEL\fpga\test\20261104_ip17_decision\scripts\project_resources.py' --run projection_repro001
```

脑测读取冻结的 granite_config.json；资源脚本读取 parts001 日志。无网络、无需真实权重。
- braincheck.py 输出 capacity.json、brain_results.json、tiny_evidence.npz 和脚本快照。
- 判断规则在脚本中：分块矩阵误差、增量/完整causal输出和路由对比、KV长度、量化/边界检查。两种分解使用同一独立模型，不构成RTL对比。
- project_resources.py 输出精确乘法账本与3档未知LUT敏感性；不是整机资源预测分布。

器件库探针重跑示例（先建立新结果与临时工作目录）：

```powershell
$E='C:\Users\huazh\Desktop\LPU\lpu_src\FTLPU-VMODEL\fpga\test\20261104_ip17_decision'
$O=Join-Path $E 'results\parts_repro001'
if (Test-Path -LiteralPath $O) { throw 'Use a new run identifier' }
New-Item -ItemType Directory -Path $O | Out-Null
Push-Location $O
try {
  & 'C:\Users\huazh\Desktop\Vivado2023\Vivado\2023.2\bin\vivado.bat' -mode batch -source (Join-Path $E 'scripts\parts.tcl') -log (Join-Path $O 'vivado.log') -journal (Join-Path $O 'vivado.jou')
} finally { Pop-Location }
```

重新读取远程状态使用独立repo，不在产品工作树fetch。历史baseline.py是首次审计生成器，依赖当时的tmp源码目录，且会写baseline001；**不要用它覆盖冻结结果**。归档和audit001中的生成脚本副本保留了实际输入与方法；新分支评估应新建日期/运行目录。

最终审计可用新编号重跑：
```powershell
& 'D:\python\python.exe' 'C:\Users\huazh\Desktop\LPU\lpu_src\FTLPU-VMODEL\fpga\test\20261104_ip17_decision\scripts\audit.py' --run audit_repro001
```

## 验证范围与剩余事项

- 脑测说明算法分解和容量草案可检查，不说明特定MEM bank端口、SRF日历、MXM逐周期实现已可用。
- W8是8×8 cell对称量化＋BF16反量化，不是INT8整数MAC后端；真实量化误差待测。
- native profile只有MEM作用域，旧top仍4tile/4个32×32 MXM，不允许直接等同LPU16。
- 优化属性不新增流水拍；MXM/VXM的负WNS尚未解决。
- 板级DDR、DMA Load/completion/fence、路由阶段边界、完整native整机资源、post-route与真实板测是下一步验收，不属于本实验已通过内容。
