# 裁剪前后完整SXM核：综合与估算STA

| 设计 | 旧LUT | 新LUT | LUT变化 | 旧FF | 新FF | FF变化 | 旧WNS / WHS(ns) | 新WNS / WHS(ns) |
|---|---:|---:|---:|---:|---:|---:|---|---|
| LPU16 | 78688 | 71096 | -7592 (-9.65%) | 9416 | 9280 | -136 (-1.44%) | +5.298 / +0.071 | +5.918 / +0.071 |
| LPU32 | 217787 | 197654 | -20133 (-9.24%) | 26509 | 26486 | -23 (-0.09%) | +5.464 / +0.071 | +4.689 / +0.071 |

仅综合后估算，没有布局布线。不能据此给出最终物理时序签核或真实最高频率。复用原LPU16/32综合基线，未重跑旧核；本轮未运行LPU64。

完整核包含保留的ROW/raw/typed入口；不包含MEM/SRF或WriteTap外壳。不能把完整核面积当成只启用矩阵的集成面积。

## I/O预算（单列，输入/输出各1ns，无系统布局）

- LPU16: io.status=Not evaluated this round; core report excludes IO paths
- LPU32: io.status=Not evaluated this round; core report excludes IO paths
