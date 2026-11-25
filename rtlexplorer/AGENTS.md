# RTL Explorer 协作说明

## 项目定位

LPU RTL Explorer 是 LPU 硬件架构的交互式可视化工具。此副本拟存放在 `WongWangKit/FTLPU-VMODEL` 的 `main` 分支下的 `rtlexplorer/` 目录。项目使用 React、TypeScript、Vite 和 React Flow，提供 Physical Architecture、Functional Block、RTL Hierarchy、Configuration、Bus Detail 与 Inspector 等视图。

此目录只包含 Explorer 应用和发布所需的脱敏 Snapshot；同一分支的仓库根目录仍包含 RTL。不得把 RTL、仿真环境或 EDA 产物复制进此目录，也不要因网页维护修改仓库根目录的 RTL。

## 修改原则

1. 先理解现有组件、数据模型和导航状态，再修改页面。
2. 不重做已经存在的功能；优先复用现有组件、布局引擎、样式和交互。
3. 不重构与任务无关的页面，不删除功能来规避布局问题。
4. 保持搜索、悬停、Inspector、Bus Detail、缩放、平移、Fit、下钻、返回和浏览器 Back/Forward 正常。
5. Physical Architecture 中的人工分组不能冒充真实 RTL module。
6. 推测或规格映射的接口不能标记为 `rtl-confirmed`；使用现有证据状态。
7. 不随意修改 Snapshot 中的真实源码文件名、行号、端口、位宽和连接表达式。
8. 不修改原始 RTL 仓库；扫描工具只能读取配置指定的 RTL 根目录。
9. 不提交凭据、绝对本地路径、完整 Git 状态、波形、编译产物、EDA 日志或 `node_modules`。
10. 修改后执行与风险匹配的测试，并至少完成生产构建。

## 可视化规范

- 模块包含关系使用容器表达，接口关系使用有方向和箭头的语义连线表达。
- 连线可穿过系统级分区，但不得穿过具体功能节点；避免节点、接口框、标签和连线重叠。
- 使用既有模块分类配色与证据状态，保持较大字号和足够间距。
- 画布继续支持缩放、平移和 Fit；同类页面的下钻与返回行为保持一致。
- Configuration 使用阵列和网格表达实际硬件组成，不以模糊倍数文本替代结构。
- 更详细规则见 `docs/visualization-guidelines.md`。

## 主要页面与代码

- 应用入口、视图切换、历史导航：`src/App.tsx`
- Physical Architecture 与 Connectivity：`src/components/PhysicalArchitectureGraph.tsx`
- Functional Block 下钻：`src/components/FunctionalBlockDetail.tsx`
- RTL Hierarchy：`src/components/ArchitectureGraph.tsx`、`src/components/HierarchyTree.tsx`
- Configuration：`src/components/ConfigurationOverview.tsx`
- Bus Detail：`src/components/BusDetailView.tsx`
- Inspector：`src/components/Inspector.tsx`、`src/components/PhysicalInspector.tsx`
- 数据类型：`src/types.ts`
- RTL 解析和模型构建：`server/rtl-parser.mjs`、`server/architecture-model.mjs`、`server/physical-architecture-model.mjs`
- 架构规则与 Metadata：`data/architecture-rules.json`、`data/physical-architecture-rules.json`、`data/interface-semantics.json`、`data/module-metadata.json`
- 公网 Snapshot：`public/data/architecture-snapshot.json`，由 `scripts/export-public-snapshot.mjs` 生成。

Program Load / DMA 是 Physical/Functional 模型中的一组可下钻节点，不应另建平行的临时页面。调整前先搜索 `program-load`、`dma`、`load_system` 和 `distribute_system` 的现有节点及测试。

## 本地与公网数据边界

- 本地模式由 `server/index.mjs` 提供 `/api/*`，支持扫描、导入、Metadata 保存和本地源码片段读取。
- Cloudflare Pages 使用提交到 `public/data/architecture-snapshot.json` 的只读 Snapshot；可视化、下钻、Inspector 和 Bus Detail 保留，本地扫描及源码正文读取不迁移到公网。
- 更新公开数据时，在可信本地环境运行 `pnpm snapshot:public`，检查生成文件没有绝对路径或凭据后再提交。

## 开发和验证命令

```powershell
pnpm install --frozen-lockfile
pnpm build
pnpm start
```

上述方式在 `http://127.0.0.1:4173/` 运行生产构建和本地 API。需要热更新时，另开终端运行 `pnpm dev`，访问 `http://127.0.0.1:5173/`。

```powershell
pnpm test
pnpm snapshot:public
npm run build
```

`npm run build` 是 Cloudflare Pages 构建命令，输出目录为 `dist`。不要在没有说明的情况下跳过失败测试，也不要虚构未运行的验证结果。

## GitHub 协作与发布边界

- 网页变更仅限 `rtlexplorer/` 目录；不得因网页维护修改兄弟目录中的 RTL、仿真或脚本。
- 向学长 `main` 增加此文件夹必然改变 `main`。先在独立分支准备并由维护者审阅；未经明确批准不得直接推送或合并 `main`，禁止 Force Push。
- 网页 Snapshot 来自独立的、较新的 VMODEL 工作区；不能将仓库根目录的旧 RTL 当作此 Snapshot 的源码版本。
- 现有正式 Cloudflare Pages 项目连接的是独立的 `LPU-RTL-Explorer` 仓库。将此目录合入 `main` 不会自动更新正式网站；若日后切换部署源，须单独核准仓库、分支和构建根目录 `rtlexplorer/`。
