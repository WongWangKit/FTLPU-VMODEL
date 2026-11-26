# SXM 逐个向量累积的 ISA 与兼容 ISA 现状

核对对象：2026-11-25 本地 VMODEL 工作树（HEAD `2ec0824` 加工作区修改）。本文记录已接线的 RTL 和测试用例中的编码，供写程序、看波形和维护旧镜像时使用。

## 1. 从哪个入口看 SXM？

**整机只有一个启用计算的 SXM 入口。它支持两种操作：矩阵逐行收满后转置、重排；独立向量收一行就重排。** 两者由同一程序中的上下文模式位选择，共享三角形排列的存储槽和输出控制。向量模式在功能上是一条独立路线；在当前 RTL 中，它仍走 CAP、P、RUN，没有从 SRF 输入直接绕到输出的专用 Permute 指令。

| 使用场景 | 实际调用关系 | 调用方给什么 |
|---|---|---|
| 当前整机 | `lpu_top → lpu_fu_subsystem_cluster → lpu_sxm_subsystem → sxm_triangle_full_core`；其中 `u_core` 是 `sxm_triangle_row_frontend`，`u_storage` 是 `sxm_triangle_core` | 两张定时事件表：CTRL 和 EXEC。两种操作均可在同一构建中安排。关闭 `ENABLE_SXM_VXM_EXECUTION` 后该位置只传递 stream。 |
| 三角核单测 / MEM 联调 | `sxm_triangle_core` 可单独接 job 接口；`sxm_triangle_full_core` 也暴露 ROW、旧 raw 和 batch 三个入口。`lpu_sxm_triangle_mem_integration` 经 `sxm_triangle_writetap_core` 接完整核 | batch 用独立信号 `mode_i`（0 矩阵、1 向量）、`dtype_i`（0 BF16、1 FP32）、数量和映射；完整核对三个入口做互斥仲裁。整机将 batch、compat 的 valid 接 0。 |
| 旧 VMODEL / SRF 回归 | `lpu_sxm_srf_command_integration → lpu_sxm_command_adapter → lpu_sxm_srf_integration → sxm_slice` | 旧 T4 的 416 位指令，两条有效信号分别指示 Transpose、Permute。适配器翻成旧核的 96 位命令。 |
| 其他历史入口 | `lpu_mem_srf_sxm_turnaround_integration` 用构建参数 `P_ROW_MODE` 选 `sxm_compatible_core` 或旧 `sxm_slice`；仓库另保留直接接 416 位端口的 `lpu_sxm_slice`（带 `lpu_` 前缀） | 这些模块有各自的连线和回归用途。`P_ROW_MODE` 只属于该联调外壳，与整机运行时的矩阵/向量选择无关。 |

要找整机程序的位定义，先看[事件分发](../rtl/core/lpu_fu_subsystem_cluster.sv)、[SXM 子系统接线](../rtl/sxm/lpu_sxm_subsystem.sv)和[ROW 前端](../rtl/sxm_native/sxm_triangle_row_frontend.sv)。[完整核](../rtl/sxm_native/sxm_triangle_full_core.sv)说明谁占用存储；[批处理核](../rtl/sxm_native/sxm_triangle_core.sv)的 job 端口说明适用于模块级调用。

## 2. 整机程序怎么编码？

### 2.1 外层：给哪个半球、在哪一拍执行？

SXM 的 Program Load 描述符用 `encoding_mode=1`（native）、`format=1`（128 位）。全局 queue ID 为 0 时选东半球、1 时选西半球；半球内 queue ID 为 0。**target kind 选事件表，payload 才决定具体动作**：

| target kind | 代码中的旧名称 | 现在发出的事件 |
|---|---|---|
| 5 | `PROGRAM_TARGET_SXM_TRANSPOSE` | CTRL：写上下文、写目的 tile 配置、预留存储槽 |
| 6 | `PROGRAM_TARGET_SXM_PERMUTE` | EXEC：采一行 CAP、选数据 P、启动输出 RUN；CAP 也发给 **6** |

每条事件占 **32 B**。先写一个 128 位 payload，再写一个 128 位时间字：`[31:0]` 为相对程序启动的发射拍，`[63:32]` 为 aux，`[127:64]` 写 0。两张表分别从字地址 0 连续写，每表最多 64 条；描述符的字数为字节数除以 16。每表内部的发射拍严格递增。两张表可以同拍发射，操作仍须满足下文的存储与上下文条件。事件按预定拍执行，错误会报 fault，由软件安排好时间。

来源：[描述符检查和半球路由](../rtl/program_load/lpu_program_control_system.sv)、[程序常量](../rtl/program_load/lpu_program_load_pkg.sv)、[事件表的写入和发射](../rtl/program_load/lpu_native_issue_calendar.sv)。

### 2.2 CTRL（target 5）：先定义怎么读、怎么排、怎么写

aux 的 `[1:0]=op`、`[2]=ctx`（上下文 0/1）、`[5:3]=index`；高位写 0。op 取值如下：

| op | index 的含义 | 128 位 payload，低位在前 |
|---|---|---|
| 1：配置上下文 | 忽略，建议写 0 | `[95:0]` 为 16 个输入 stream 选择码，每项 6 位；`[111:96]` epoch；**`[113:112]` 0 矩阵、1 独立向量**；`[114]` 0 两个 byte plane、1 四个 byte plane；`[115]` layout；`[116]` mirror；`[117]` 将镜像输出复制到附加 RHS 端口，仅在 mirror=1 时合法；`[127:118]=0`。epoch、layout 在这版 ROW 前端随配置保存，读值和路由逻辑不按它们分支。 |
| 2：配置目的 tile | 目的 tile 编号 | `[95:0]` 为 16 个输出 stream 选择码；`[96+3*l +: 3]` 给出输出 lane `l` 要读取的位置；`[122:120]` 为该目的 tile 关联的 group；`[127:123]=0`。 |
| 3：预留槽 | group 编号 | `[7:0]` 为 source tile 掩码，单独设置一位即可为一条向量预留；0 表示全部 T 个 source。`[127:8]=0`，超出 T 的源位写 0。 |

native 的 6 位选择码是 `{方向, stream[4:0]}`，方向 1=East、0=West。每个配置里的 16 项都要互异，即使当前向量只用其中两项。写 op 1 会清除该 ctx 原有的 tile 配置有效位；依次配置全部目的 tile、使 group 各不相同，然后才能预留。预留成功后由该上下文持有存储槽。

### 2.3 EXEC（target 6）：一条事件里有三组使能

aux 写 0，payload 的 `[127:81]` 写 0。表中位号属于 **payload**。

| 动作 | 位域 | 作用 |
|---|---|---|
| CAP | `[0]` 使能；`[1]` ctx；`[4:2]` source tile；`[7:5]` group；`[11:8]` 输入行 | 在已预留的槽中写一行、每行 8 个元素。16 位数据需两个有效 byte plane，32 位需四个。矩阵行号 0…7；独立向量只用行 0。 |
| P | `[12]` 使能；`[13]` ctx；`[16:14]` dest；`[19:17]` source；`[23:20]` 输出行码；`[24]` paired；`[25]` branch；`[31:26]` sequence | 按目的 tile 的 group 找到 source 槽，再按目的 lane map 读数据。行输出进入该目的 tile 的待发数据寄存器；整块输出走当拍写端口。 |
| RUN | `[35:32]` 目的 tile 启动掩码（T4；T2 仅低两位）；`[36]` ctx；`[52:37]` delay；`[68:53]` interval；`[74:69]` count；`[80:75]` 起始 sequence | 为选中的目的 tile 安排一段行输出。首个输出拍为启动拍 + delay + 1；interval 至少 2 拍，count 至少 1，起始 sequence + count ≤64。到期检查 ctx、sequence 和数据就绪状态。 |

P 的行码直接影响源槽何时能复用：

- **0…7**：选择这一个输出行；普通单行读到 7 释放源槽。**9…15**：选择行 0…6 并在此次 P 后释放。向量模式选行 0 即释放，通常用行码 0。
- **8**：矩阵整块输出，8 行一起写并释放，省去 RUN。16 位数据占 16 个 stream；FP32 占 32 个，要求 32 端口、同方向连续编号 0…31。目的 tile 必须空闲，mirror 和 paired 均关闭。**此处 8 是 P 的输出行码；主线 CAP 不接受输入行码 8。**
- **镜像输出**：普通输出用 branch=0、paired=0。mirror 打开时可给两个分支分别准备数据，也可在矩阵模式用 paired 从偶数行 0/2/4/6 一次取相邻两行；配对取满 8 行后释放。两个分支的 ctx、sequence 必须匹配，FP32 镜像分低、高两拍发。它们是同一目的 tile 的输出分支。

### 2.4 用一组数区分矩阵与向量

设输入行是 `X[r][0..7]`，目的 lane `l` 在配置里选位置 `g[l]`。两条路线共用 CAP 和 P，区别在 **P 要等哪些数据，以及 g 究竟选择什么**：

| ctx 模式 | P 就绪条件 | 输出 lane 的值（q 为输出行） |
|---|---|---|
| 0：矩阵 | 同一槽的 8 个不同行号都已写入，`written_q == 8'hff`；即使只请求输出一行也要满足 | `Y[q][l] = X[g[l]][q]`。例如输入 `X[r][c]=10*r+c`，lane map 为恒等，取 q=2 得到 `[2,12,22,32,42,52,62,72]`。 |
| 1：独立向量 | 同一槽的行 0 已写入，`written_q[0] == 1` | `Y[0][l] = X[0][g[l]]`。例如 `[0,1,2,3,4,5,6,7]` 加逆序 map，输出 `[7,6,5,4,3,2,1,0]`。同一 tile 内多个 lane 可选同一元素。 |

采样后的最早读拍是下一拍。同拍 CAP 和 P 可以访问不同槽；同一个槽没有把刚写数据直接送 P 的通路。单行 P 与真正写 SRF 也是两个动作。例如[向量边界用例](../sim/tb/sxm_triangle/sxm_boundary_vector_tb.sv)先配置 ctx 0、目的 tile 2，再为 group 2 的 source 1 预留。按其动作换成顶层事件，普通 16 位模式可这样排：

| 相对拍 | 软件动作 | 这拍的数据 |
|---|---|---|
| t | target 6，CAP payload = `0x45` | source 1 从 East S0、S1 采行 0 的低、高字节。 |
| t+1 | target 6，P payload = `0x29000` | dest 2 从 source 1 取向量，按逆序 map 选 lane；sequence=0。 |
| t+2 | 留一拍 | 已选数据进入 dest 2 的待发寄存器。 |
| t+3 | target 6，RUN：掩码 0100、delay=0、interval=2、count=1、sequence=0 | 启动 dest 2。 |
| t+4 | 无新命令 | West S4、S5 得到逆序后的两个 byte plane。 |

这是该用例的排法；表中留的一拍不用于接收其余 7 行。[整机程序用例](../sim/program_load/native_chain_tb.sv)中的 `event_at(5,...)` 和 `event_at(6,...)` 给出了同类操作的实际镜像写法。

## 3. 兼容 ISA：分清两条路径

### 3.1 integration：旧 416 位整块指令 → 96 位 phase 命令

以 [命令适配器](../rtl/integration/lpu_sxm_command_adapter.sv) 接到 [旧 SRF 外壳](../rtl/integration/lpu_sxm_srf_command_integration.sv) 为准。旧 416 位字的 `[1:0]` 是 opcode（2=T、3=P），`[10:6]`、`[15:11]` 分别为 src、dst 选择码数；16 项 src 从 bit 16 开始，16 项 dst 从 bit 112 开始，每项 6 位。P 另读 `[210:208]`（目的 tile 0…3，4=全部）及 `[240+5*i +: 5]`（32 个目的 lane 对应的源 lane）。这里列的是适配器实际读取的字段。

两份列表都须有 16 项，各自同方向、连续，base≤16。旧选择码方向 0=East、1=West，翻译时将方向位取反。P 只接受四种 phase：对目的 tile d、目的 lane l，源位置须为 `8*((phase+4-d)%4)+l`。例如 phase=1 时 d0…d3 分别取 s1、s0、s3、s2，各 tile 内 lane 原位。任意 lane 逆序无法经此适配器表示。

| 翻译出的 96 位命令字段 | 含义 |
|---|---|
| `[1:0]` | 0=T，1=P；与外层 416 位 opcode 数值不同 |
| `[2]`、`[7:3]`；`[8]`、`[13:9]` | native 的 src 方向、base；dst 方向、base |
| `[17:14]`、`[21:18]` | 输入行码、输出行码；适配器 T 填输入 8，P 填输出 8，均表示整块 |
| `[24:22]`、`[32:25]`、`[95:33]` | P 的目的 tile、phase、保留零 |

使用者传旧镜像时，这条路径保留“一拍整块 T → 整块 P”。无法表示的选择码或 phase 触发 `command_fault_o`，对应命令不发出。96 位是送给 [sxm_slice](../rtl/sxm_native/sxm_slice.sv) 的内部命令，位域见 [sxm_command_decode](../rtl/sxm_native/sxm_command_decode.sv)。

### 3.2 triangle 内的 raw 兼容前端：保留旧路由，T 只接逐行

[sxm_compat_decode](../rtl/sxm_native/sxm_compat_decode.sv) 和 [sxm_compat_engine](../rtl/sxm_native/sxm_compat_engine.sv) 在 `rtl/sxm_native`。它们直接解 raw 字、不经上面的 96 位 phase 命令。T、P 各有自己的 valid、raw 和 **字外**的 2 位 family：

| family | 解码方式 | 当前边界 |
|---|---|---|
| 0 | 固定 T4 VMODEL；目的 tile 取 `[210:208]`，输入、输出行码强制为 8 | P 可解整块；T 因强制整块而被当前逐行捕获规则拒绝。原样成对回放旧整块 T/P 请走 §3.1。 |
| 1 | 随 T 改变宽度的 CModel raw；输入和输出行码字段均在 0…8 | T 只收输入行 0…7，src 数=2；P 的 src 数=16，可选单行或整块。 |
| 2 | 本地 API 测试传输，复用 family 1 的位位置 | P 另可用 9…15“取行并释放”。当前 T 同样只收 0…7；历史注释里的 broadcast T 在该 decoder 中被拒绝。 |
| 3 | 保留 | 拒绝。 |

family 1/2 的低 208 位与 §3.1 的 opcode、计数、列表位置相同。其余字段按下式定位，`+:w` 表示从起始位向高位取 w 位：

    LB = max(5, clog2(8*T))        // 全局 lane 编号位数
    TB = max(3, clog2(T)+1)        // 含 ALL=T
    R  = 240 + 8*T*LB
    [208+4*i +: 4]  八项值，decoder 检查每项 ≤8
    [240+i*LB +: LB] 目的 lane i 的源 lane 编号，须 <8*T
    [R +: 4] 输出行码；[R+4 +: 4] 输入行码；[R+8 +: TB] 目的 tile

字宽向上补齐到 32 位，高位补 0：T=2/4/8 分别为 **352/416/640 位**。尤其在 T4，family 0 与 1 都占 416 位，但 family 1 的目的 tile 在 bit 408 开始；仅凭字宽判不出语义。

每类 raw 的 dst 数都须为 16。参与的 src、dst 列表各自同方向、各自无重复，允许不连续。一次 P 中，一个目的 tile 的八个 lane 必须来自同一个源 tile，各目的 tile 选不同源；tile 内可按 map 选 lane。引擎只对已经收满八行、且 T 保存的目的选择码与 P 的源列表一致的块执行输出。T 在 tile k 的有效拍为根入口拍 + k；P 在有效拍读旧数据。ALL 可跳过波前尚未到齐的 tile。它没有整机 ROW 前端的 RUN 命令。

**使用结论：** 写现有整机程序看 §2；验证旧 416 位整块镜像看 §3.1；比较旧 raw 行码、逐 tile 时序看 §3.2。整机子系统将 raw 入口关闭，给 target 5/6 发送旧 416 位字不会自动切换前端。本次按本地 RTL、位域检查和测试源码核对，未重新运行仿真，也未将上述编码认定为冻结的软件 ISA。
