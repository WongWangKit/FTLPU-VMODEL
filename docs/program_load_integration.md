# Program Load 整合契约（共享 AXI、指令 DMA 与各 FU 本地取指）

## 基线与范围

- 装载框架原基线为 `56c7adf`。2026-11-25 在本地共享 AXI 上接入 [VMODEL-DEV/main 快照 73462d8](https://github.com/wzqwzqwzq123-123/FTLPU-VMODEL-DEV/tree/73462d8da629f476f5c65f2d46149324b5a64bb7)：逻辑指令 DMA、队列 iMEM/Fetch 和五队列 MXM ICU。
- 本地基线：`2ec0824c2b5a014b8a0b6c1d08a05d4e03175e4b` 加用户已确认保留的工作区修改。
- 补齐 `lpu_mem_subsystem`、`lpu_mxm_subsystem`、`lpu_qctl_fabric`，以及
  iMEM、Fetch、Macro Decoder/Scheduler、Timed Queue、QCTL Pool/Controller 等依赖。
- 保留本地 MEM/MXM/SRF/FU 实现；未用远程仓库整体覆盖本地 rtl。
- 未修改 CModel，未提交或推送 Git。

## 当前唯一的顶层装载入口

```text
Host 写 Program Descriptor RAM / 发出 LOAD_START
  -> Loader: LOAD_IMEM / WAIT_DMA / COMMIT_QUEUE / END
  -> DMA command {address, byte_length, id}
  -> Program Read 字节范围格式器 -> 共享 Master（程序 ID0）-> 系统互联或 DDR 控制器
  <- 内部 DMA response {data, keep, last, id, error}
  -> RX FIFO -> 字节重组 -> 96/128-bit Program Word FIFO
  -> 东/西 endpoint -> WRITE / 写入确认 -> PRIME
  -> MEM / 旧 MXM 镜像：本地 iMEM -> Fetch -> Macro Decode -> Timed Queue
  -> 新 MXM：队列 iMEM -> Fetch -> 宏解码/调度或原生事件 -> 已有对应 FIFO -> 执行
  -> SXM / VXM：各队列 iMEM -> Fetch -> 按事件指定绝对周期发射 -> 对应 FU
```

本地共享 AXI 负责总线传输；远程逻辑指令 DMA 跟踪装载命令和响应。
图中没有全局程序 SRAM，也没有把程序先写数据 MEM 再经 SR 搬入 ICU。
当前顶层对外仅有一个五通道 AXI4 Master；程序请求/响应留在模块内部。接真实板卡时须连接
同一时钟域的 AXI 互联或 DDR 控制器；此仓不自带 DDR 控制器、PHY 或跨时钟桥。

删除了旧 `lpu_top` 的 `schedule_*`、`host_mem_*`、`run_i`、138-slot dispatch
观测接口，以及新旧路径选择参数。没有增加兼容顶层或旧指令翻译器。
历史注入 TB 源文件保留作参考，但从活动 `sim/filelist.f` 移除。

## 映射与指令口径

| 目标 | Descriptor global queue | Endpoint local queue | 镜像字宽 |
|---|---|---|---|
| MEM East | 0–103 | slice × 2 + bank | 96 bit |
| MEM West | 104–207 | global − 104 | 96 bit |
| 旧 MXM（回归构建）Load / Dequant / Compute | 每种 target 各 0–3（32 档） | East 0/1；West global − 2 | 128 bit |
| 原生 MXM 五队列 | 每种 target 各 0–3（32 档） | 同上 | 模式 0：128-bit 压缩宏字流；模式 1：每事件两个 128-bit 字 |
| SXM CTRL / EXEC | 0=East，1=West | 各半球 0 | 模式 1，每事件两个 128-bit 字 |
| VXM | 0=中央 VXM | East 0 | 同上 |

QCTL 的 220 个逻辑 queue 为 MEM 0–207、MXM Load 208–211、
Dequant 212–215、Compute 216–219；它与 descriptor 的 `{target, global_queue}`
不是同一个编号空间。QCTL 内容经独立的 96-bit 装载口写入，不经过指令 DMA。

### MEM

发射端直接使用当前本地 native32：`preserve[31] / delay3[30] /
row[29:15] / reserved[14:9]=0 / dir[8] / stream[7:3] / opcode[2:0]`。
支持 READ=0、WRITE=1；preserve 只允许用于 WRITE。
旧的 47/64-bit command adapter 不在此新装载执行链中。

Packed-v1 的 affine row operand 仍为 13 bit，因此本程序编码可寻址 0–8191，
最终还受实际 MEM 深度限制；不能因为 native row 字段是 15 bit 就宣称镜像支持 32K 行。
Compact template 不带 delay3；长延迟必须使用包含 bit30 的 extended native template。
非法 reserved、READ+preserve 和旧 opcode 3/4 在 Decoder/Scheduler 报错，未静默改写。
MEM_READ_SYNC/MEM_WRITE_SYNC 的上层语义尚未自动下沉为 QCTL 控制记录。

`ACTIVE_MEM_COLUMNS` 每半球为 4 的倍数，范围 4–52；每列两个 bank。
缩减配置只实例化实际 bank 的 iMEM/前端，未实例化的 global ID 保留并在装载时拒绝。
这个参数控制列数，**不代表 LPU16/32/64 的 tile 行数参数化已完成**。

### 原生命令镜像

`encoding_mode=1`，`format=PROGRAM_FORMAT_128`。每个目标队列每段一个完整镜像，基址为 0。
每事件 32 B：低地址的 128 bit 是指令，下一字是 `{64'b0, aux[31:0], cycle[31:0]}`。
每队列容纳 64 个事件。同队列的周期严格递增；不同队列可同拍发射。每条命令的高位和未使用的 aux 位填零。
这些队列使用 START 之后的段内时钟；原有 220 路 QCTL 的局部停顿只控制原有队列。

| target | 执行端 | payload（低位起） |
|---:|---|---|
| 7–11 | `lpu_mxm_core` 的 weight / param / dequant / compute / backend | 分别为 2 / 1 / 1 / 7 / 13 bit（默认配置），直接使用各队列原生指令 |
| 5 | SXM CTRL | 128-bit 控制字；aux[1:0] 是 op，[2] 是 ctx，[5:3] 是 index |
| 6 | SXM EXEC | [0] CAP、[1] ctx、[4:2] tile、[7:5] group、[11:8] row；[12] P、[13] ctx、[16:14] dest、[19:17] source、[23:20] row、[24] paired、[25] branch、[31:26] sequence；[35:32] RUN mask、[36] ctx、[52:37] delay、[68:53] interval、[74:69] count、[80:75] sequence |
| 4 | VXM local/global | [7:0] local 队列有效位、[63:8] 八条 7-bit local 指令；[64] global 有效位、[79:65] 15-bit global 指令 |

PRIME 启动队列本地取指。发射拍到达时，空的 MXM FIFO 可在同一边沿接受并执行这条指令；有积压时仍先取原队首。调度器发现错拍、同队列同拍冲突或到期无法接受会报错。权重和 BF16 激活来自向东的 SRF，激活的低、高字节分别使用 base、base+1（base 0–30）。各列的结果写入向西的 S00 起始 stream，BF16 用两条，FP32 用四条。软件排开同一物理 stream 的写入。

每个半球的 SXM 使用 `sxm_triangle_full_core` 的 CTRL/CAP/P/RUN 入口。当前 row frontend 接受单行 CAP：向量在第 0 行捕获后可重排；矩阵在八行有效后允许 P，可整块提交。逐行路径的输出继续经 SRF 送 VXM。整矩阵另有下述 WriteTap 写 MEM 路径。旧 raw compatibility 引脚保留在核心层。中央 VXM 保留既有指令波前、方向选择与 ALU；调度器决定 global/local 命令何时到达。

**五队列压缩镜像（encoding_mode=0）。** 对外 target 1、2、3、7、8 分别是 Load、Dequant、Compute、ParamLoad、Backend，与远程加载包一致。模式 1 的 target 7–11 保持原有含义。每段为一个物理队列选一种格式，COMMIT_QUEUE 沿用 LOAD_IMEM 的模式。模式 0 按 128-bit 字原样写入 iMEM；模式 1 在收到第二个字时组合成一条带周期的事件写入同一 iMEM。

`lpu_five_macro_decoder_core` 来自远程 `rtl/mxm/icu/lpu_mxm_macro_decoder_core.sv`（最后修改 `4b2df33`）。本地仅更改模块名，以便与旧三队列解码器共存。每条 MXM 队列的实例通过 `QUEUE_KIND` 选择本队列的指令格式。SXM 与 VXM 复用队列存储和取指，分别解释自己的控制字。远程该版本的 SXM 装载口未应答，VXM local/global 发射无效。本地定时事件是集成接口；远程编译器的 VXM resident-config 镜像需单独适配。

**SXM 批处理写 MEM。** 下表是本地 SXM CTRL 事件扩展，原 CTRL/CAP/P/RUN 字段保持原值。保留位填零。

| aux | payload | 动作 |
|---|---|---|
| 0x40 | [2:0] source tile、[5:3] 映射的 tile 编号、[29:6] 八个 3-bit lane 选择 | 每个源 tile 配置一次。跨 tile 映射取排列，批次执行期间保持。 |
| 0x41 | [14:0] MEM 起始行、[30:15] 矩阵数、[31] FP32（0 为 16-bit）、[36:32] 第一个输入 stream、[37] 输入方向（1：来自 MEM 的 East；0：来自 MXM 的 West） | 启动一批矩阵。每行占连续 2 或 4 个 byte-plane stream，MEM 地址范围为 base 至 base+矩阵数×T−1。 |

若在周期 J 启动，源 tile t 在 J+1+t 接受第一行，随后每拍一行，每个 tile 共接受 矩阵数×8×T 行。每个 stream segment 提供 8 个元素的同一字节。缺少应到的 byte plane 会触发 SXM 故障。逐行路径与批处理共享已有转置存储。WriteTap 从输出 block 生成向西的 SRF 数据和带 preserve 的 MEM 写命令。16-bit 写距 SXM 最近的两个 MEM group，32-bit 写四个。批次执行期间，软件须把最近的四个监控组（缩减配置取实际存在的组）的其他 MEM/DMA 指令排在批次以外。完成时检查采样数量、目标地址和 MEM 排空。

**VXM 查表装载。** VXM 事件 aux=0 沿用上表的 local/global 格式。aux=1 配置查表函数：[1:0] 函数、[17:2] 输入最小值、[33:18] 段宽。aux=2 写系数：[1:0] 函数、[7:2] 表地址、[23:8]/[39:24] 为 k/b、[89:40] 为 log 专用系数。每个 tile 现有的 LUT SRAM 同拍接收；查表装载与 local/global 共用一个有序事件入口。

历史三队列镜像使用单独构建 `LEGACY_MXM=1`。早期 AccumulatorRead 镜像选 `LEGACY_VECTOR_ARRAY=0`：读操作本身就产生输出；后来的 streaming vector 路径按 bit 44 选择输出。两个回归构建均复用同一顶层。

整机验证入口：`sim/program_load/run_fu_chain.ps1 -Mode native -Build <新的编译目录> -Results <新的结果目录>`。`-Mode macro` 比较五队列压缩镜像与原生事件的发射拍、SRF 数据和结果；`-Mode tap` 检查 SRAM 落点及异常输入；`-Mode geometry` 检查 T=2 边界；`-Mode legacy` 执行三个历史用例。运行器保存源文件散列、编译日志和仿真记录。

## 启动、停顿和完成边界

1. 写描述符；LOAD_IMEM 指定合法目标、格式、长度、iMEM 地址及完整镜像信息。
2. LOAD_START 后发 DMA 请求；响应按请求顺序返回，KEEP 必须从低字节连续有效。
   RX FIFO 和后续弹性级按 ready/valid 保存未消费数据。
3. WAIT_DMA、写入确认和 COMMIT_QUEUE/PRIME 保证 iMEM 写入与预取顺序。
4. START 请求可先到并被记住，但必须等所有已配置前端就绪、装载完成和
   `program_dependencies_ready_i` 有效。上层负责权重等依赖的真实性。
5. MEM/旧 MXM 的 PRIME 先发入逻辑周期0和1的操作。短镜像在 Decoder/Context 入口排清后就绪。
   槽位不足时，有序前缀已占满 Active Context，且首条被阻塞的 Context 至少在
   周期4，才提前 START；执行期间按 FIFO credit 从已提交 iMEM 持续 fetch、decode、
   补 Context/Timed Queue。流式模式要求各 Context 起点单调不降且满足编译器的前瞻
   与容量合同。发现乱序、首个未准入项过近或运行期迟到时报错，不补拍重排。
   新 MXM 压缩队列在全部宏解码并进入活动槽后就绪；槽满且后续已解码宏开始排队时也可启动。随后边执行边补充。编译排程需给解码和槽位复用留足时间；运行期遇到过期命令即报错。原生事件队列预取到首条再启动。
6. 运行时 Timed Queue 仅在目标 queue cycle 发射；到期而 FU 不可接受会报错，
   不会自动延后静态时序。QCTL 可在 WAIT_EVENT、SYNC、NOTIFY、MEM_PACKET 边界
   冻结相应 queue 的局部调度时钟，其它 queue 可继续。
7. `program_load_complete_o` 是装载流水完成；`program_done_o` 要求已启动，并等待
   指令队列、可选 QCTL、MEM 与 SRF 传输、MXM 阵列与后端、SXM 活动任务、VXM 控制及执行流水排空。段结束后停止逻辑时钟推进；
   这不等于数据 DMA、外部消费者或未接入 FU 已完成。

`program_reset_i` 是可提前提交的重装请求：与 `program_reload_ready_o` 握手后撤除
valid，再等 `program_reload_ack_o`。ACK 才清除本段描述符有效位、iMEM 元数据、指令
队列及 QCTL 状态；保留 MEM SRAM 和 legacy MXM 的权重/累加数据。ACK 脉冲过去后，
Host 写下一段描述符并按本段逻辑时间重编址后重新 LOAD/START；相同 DDR 地址也会重读。
不运行旧描述符，不允许边运行边写活动槽。编译器须声明共同切点、排完本段跨 FU 依赖，
外部 stream 源不能在切点后继续发旧段数据。已启动的故障段不自动重装。

程序 client 每次取对齐的32 B，内部裁切 KEEP；物理 beat 为16/32 B，AXI ID0只承载程序。只用于可读整个对齐包的普通 DDR 区间，不用于 MMIO。数据 AR/R 使用 ID1–7 并与程序读轮转；AW/W/B 独立。合法错误按已发义务排空；结构错隔离整个物理口，不能用客户端软重装恢复。系统硬复位须与互联/控制器协同。

## 数据描述符与完成

- 一次接收一个描述符：在 `dma_desc_valid_i && dma_desc_ready_o` 时采样方向、半球、物理 bank（2×slice+bank）、lane、起始 row、DDR 字节地址、向量数、DDR 字节 stride 和 tag。目标行逐向量加1；DDR 按 stride 前进。完整对齐向量，无局部写掩码，单向量允许 stride=0。非法范围返回带 tag 的错误且不发总线事务。
- LOAD：R 返回有预留的位置，跨 ID 重排后经 RX→SR 波前→native MEM。STORE：RegisteredR1→SR→TX 收齐完整向量才发布 AW/W，独立等待 B。结束时 `dma_result_valid_o`、错误位和 tag 保持至接受；先取走错误结果再重装，已生效的写不回滚。结构故障看 `dma_isolated_o`，不伪报完成。
- 一个活动数据描述符分时占用 MEM/SR；可以同时装程序，不能边运行 FU 边争用同一窗口。每半球目标可选8个 lane，但没有16组同时在途的队列。此增量不生成编译的 SYNC/QCTL 事件或全局页就绪。真实 DDR 控制器、PHY 与 CDC 由平台集成。

## 保留的限制与后续缺口

- 整机原生回归覆盖四个 tile、单个活动 MXM、一条 BF16 VXM 链；其他配置与指令组合应分别验证。
- 原生事件按绝对周期排程。需要跨 FU 动态等待的程序须另行定义同步机制。

## 容量参数化增量（2026-11-19）

- `lpu_top.PROGRAM_DMA_RX_FIFO_DEPTH` 与 `PROGRAM_DMA_OUTSTANDING_DEPTH`
  传到 Program Load 实例；16/32 档的 RX 默认112/192，逻辑命令槽仍为16。前者单位为有序 program-response
  条目，256-bit 配置下一条承载32 B；后者是逻辑 DMA 命令槽数，不是 AXI ID/事务数。
- 各目标按自身容量检查；共享重组器地址上界取 MEM、旧 MXM、原生队列三者所需最大字数。
  例如 MEM128/MXM2048 时，合法 MXM word2047 不再被二次误拒，2048 仍在描述符入口拒绝。
- `program_dma_sizing_tb.sv` 验证 P64/P80＋窗口4、600拍消费者停收、
  FIFO回绕、在途ID释放及逐响应顺序。输入响应握手有反压；本测试不证明 AXI 读发出前的容量预约。
  `program_control_sizing_tb.sv` 验证到 endpoint 的字和 commit，使用端点应答夹具而非 FU 执行。
- 上述是 Loader 组件用例；当前共享主端的顶层双向数据回归另见主 spec 第19.16节，产品 iMEM 默认值未修改。
  模型参数和冻结边界见主 spec 第19.15–19.16节。
- 数据 DMA/native MEM 已接2/4 tile；外围 FU 几何未全部按16档转换，未验证完整三档整机。
- 控制层仍是同一 target/queue 每轮一个完整镜像描述符；底层重组器支持跨请求拼字，
  不意味着顶层允许任意拆分/热更新同一队列镜像。
- 流式启动不把 iMEM 变成可在线写的双页。超过物理 iMEM 的程序仍需在共同切点单槽
  重装；未接硬件自动换页表或预取下一段 DDR 镜像。非任意日历都能流式启动。
- QCTL 的 token 与 MEM_PACKET retirement 仍由上层提供；本次没有把它们自动连接成
  DMA completion 或 MEM_READ_SYNC/MEM_WRITE_SYNC 指令语义。
- 历史 CModel/VCS 顶层 golden 流程仍使用旧注入接口，需要重做 ProgramImage stimulus。
- iMEM 默认容量沿用研究版，不是已经完成面积评估的 SRAM 规格；16-bit
  expected_word_count 也限制单镜像最多 65535 个字。容量与编译器打包约束还需收敛。
- 本轮不包含综合、时序收敛、CDC 或 FPGA 实板验证；存在源版本/本地既有 lint warnings，
  不宣称 warning-free。

## 验证入口

```bash
# Linux / WSL；输出目录必须全新，禁止覆盖历史结果。
python3 sim/program_load/run.py --stage transport \
  --out /absolute/results/run/transport --build-root /absolute/tmp/run/transport
# stage 还可选 axi_read、epoch、prime_window、mem_native、frontends、qctl、mem_subsystem、system。
# system 使用 lpu_top 的真实 MEM/MXM 执行，SXM/VXM 选用无 issue 的被动路由；
# AXI 从端以仿真 DDR 响应，不含 DDR 控制器/PHY。
# 可用 --verilator /absolute/path --jobs 2 指定工具。
./scripts/smoke.sh           # 程序读、生命周期、传输和队列部件
./scripts/smoke.sh --system  # 再编译运行完整顶层
```

Windows 使用 `scripts/smoke.ps1 -Distribution Ubuntu-22.04 -Verilator <Linux路径>`；
`-FullSystem` 增加完整顶层。运行器保存源码 SHA256、命令、构建日志、运行日志与结果 JSON。
旧 Verilator 5.008 的 `--binary --hierarchical` 会错误传递 `--exe`；运行器采用显式
`--cc --exe --main --build`。本机 5.008 安装还需要正确的 VERILATOR_ROOT；工具安装修复
不写入 RTL，也不掩盖构建失败。

默认 `scripts/lint.*` 检查这四组装载/前端测试；其它 FU/native 测试继续使用各自的
专用脚本与 filelist，不再将所有历史 TB 同时塞入活动 `sim/filelist.f`。

本次实验、保留文件哈希与实际结果索引：
`../../../learn/c2c_dma_integrate_20261114/README.md`。
源码清单通过 `python3 sim/program_load/update_filelist.py` 生成，排除 `rtl/**/test/**`
中同名历史源码快照，避免误编译。
