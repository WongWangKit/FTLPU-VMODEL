# LPU RTL Explorer

LPU RTL Explorer 是 LPU 硬件架构的交互式可视化应用，用于查看功能拓扑、RTL 层次、接口语义、规模组成和架构证据。此副本拟放在 `WongWangKit/FTLPU-VMODEL` 的 `main` 分支下的 `rtlexplorer/` 目录；部署来源仍需单独配置。

## 技术栈与主要视图

项目使用 React 18、TypeScript、Vite 5、React Flow 和 Node.js。本地 Node 服务负责扫描与 API；Cloudflare Pages 发布只读静态 Snapshot。

- **Physical Architecture**：West / Central / East 功能拓扑、FU Frontend 和语义接口。
- **Functional Block**：MEM、MXM、SXM、VXM、Program Load / DMA 等多层下钻。
- **RTL Hierarchy**：当前 Snapshot 的实例层次与连接证据。
- **Configuration**：统一大画布和分区画布中的规模、阵列与组成。
- **Bus Detail / Inspector**：接口方向、信号、位宽、端点、参数和证据状态。

所有主要画布保留缩放、平移、Fit、搜索、下钻、返回和浏览器 Back/Forward。

## 可视化布局约束

- 数据流与控制流采用正交连线，禁止使用斜线箭头。
- 节点、接口标签、箭头头部、分组标题和说明文字不得互相覆盖。
- 大型系统分区可以被连线穿过，但连线不得横穿实际功能模块矩形。

## 本地启动

首次克隆后，将 `config.example.json` 复制为本地 `config.json`，并填写 RTL 根目录与 Verible 路径。`config.json` 只用于本机，不会提交到 Git。

```powershell
pnpm install --frozen-lockfile
pnpm build
pnpm start
```

访问 `http://127.0.0.1:4173/`。该模式由 Node.js 提供本地 Snapshot、重新扫描、导入导出、Metadata 保存和源码片段读取。

需要前端热更新时，保持 `pnpm start` 运行，并在另一终端执行 `pnpm dev`，访问 `http://127.0.0.1:5173/`。

## 构建与测试

```powershell
pnpm test
pnpm build
```

Cloudflare Pages 配置：

```text
Build command: npm run build
Build output directory: dist
Production branch: main
```

生产构建会复制 `public/` 到 `dist/`，其中 `_redirects` 保证刷新和前端路由回退正常。

## 架构数据模型

本地扫描结果写入 `data/architecture-snapshot.json`，包含模块定义、层次、语义连接、Physical Architecture 和 Configuration 模型。原始本地 Snapshot 不提交到 Git。

公网版本使用脱敏、只读的 `public/data/architecture-snapshot.json`。更新当前 Snapshot 后运行：

```powershell
pnpm snapshot:public
```

生成脚本会合并 Configuration 数据，移除本地绝对路径和详细 Git 工作区状态。公网模式保留 Snapshot 中已有的接口、位宽、连接表达式、参数、Metadata 和必要代码片段，但不提供本地 RTL 正文读取，也不能在线重新扫描或持久化编辑。

## 目录结构

```text
src/                         React 页面、画布、Inspector 与样式
server/                      本地扫描、模型构建和 API
data/                        架构规则与本地生成数据
public/data/                 公网只读 Snapshot
scripts/                     扫描辅助和公开 Snapshot 生成脚本
tests/                       Node 自动化测试
docs/                        可视化与协作规范
```

主要入口和页面映射见 [AGENTS.md](AGENTS.md)，详细布局规则见 [docs/visualization-guidelines.md](docs/visualization-guidelines.md)。

## 此目录的维护方式

此目录拟合入 `WongWangKit/FTLPU-VMODEL` 的 `main`。这必然新增一个 `main` 文件夹，因此要先由维护者审阅并批准；不得未经批准直接推送或合并 `main`。网页后续修改应限制在 `rtlexplorer/`，不能顺带改动根目录 RTL。

公开 Snapshot 由独立的较新 VMODEL 工作区生成，与此分支根目录的旧 RTL 并非同一源码版本；请以 Snapshot 内的扫描时间、源码哈希及证据状态为准。

## Codex 使用方式

协作者应先阅读此目录的 [AGENTS.md](AGENTS.md)，核对网页 Snapshot 的来源，维护现有组件和数据模型。项目不在网页内嵌 Codex，也不使用 Codex SDK。

## Cloudflare Pages

现有 Cloudflare Pages 项目 `lpu-rtl-explorer` 仍连接独立的 `wzqwzqwzq123-123/LPU-RTL-Explorer` 仓库，生产分支为该仓库的 `main`。将此目录合入 VMODEL 的 `main` 不会自动更新现有正式网址。

如果日后获准改由 VMODEL 承载网站，Cloudflare 必须单独配置为读取 `WongWangKit/FTLPU-VMODEL` 的 `main` 分支，构建根目录设为 `rtlexplorer/`，构建命令 `npm run build`，输出目录 `dist`；配置后需要实际检查部署结果。

公网版本是可视化 Snapshot，不要求 Cloudflare 访问本机 D 盘或原始 RTL 仓库。

## 安全与范围

不要向网页目录复制 RTL、`node_modules`、波形、EDA 日志、构建缓存、凭据、Token、SSH 私钥或个人配置。Explorer 的构建和部署不得修改仓库根目录的 RTL。
