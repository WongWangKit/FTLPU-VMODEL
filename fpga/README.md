# LPU FPGA 原型与演示

GitHub 阅读与发布入口：[分类索引、上传范围和分支命令](PUBLISHING.md)。历史结果保持原字节，临时工作区和可重建大产物不纳入 Git。

本目录隔离 FPGA 专用研究、实验副本、测试结果与平台集成工作；当前未改动产品 RTL 或正式 LPU16 配置。

## 2026-11-04 IP-17 平台与 MoE 演示决策

- [当前平台、MoE 演示范围、资源外推与回退方案](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/IP17_FPGA平台与MoE演示范围_20261104.md)
- [远程基线、脑测与选型复核实验](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261104_ip17_decision/README.md)

## 2026-11-02 初步评估（历史证据）

- [最新：等功能资源映射对照与 MXM 综合](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/FPGA资源映射对照与MXM综合_20261102.md)
- [最新实验入口与失败/恢复记录](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/README.md)

- [综合、仿真与选型结论](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/LPU16初步综合与上板评估_20261102.md)
- [开发板资源、片外存储和主机接口](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/开发板资源与主机接口_20261102.md)
- [演示模型、算子、输入规模和配置提案](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/docs/LPU16演示配置与实施门槛_20261102.md)
- [实验运行入口、代码基线和结果索引](C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_initial_synth/README.md)

目录用途：`docs/` 保存结论，`test/<日期_课题>/` 保存脚本、测试用例与不可丢失的结果，`tmp/` 保存可重建快照及编译产物。重跑使用新运行编号，不能覆盖被报告引用的结果。当前只有局部综合及部分综合网表功能仿真，没有整机装载、布局布线或真实板测结论。
