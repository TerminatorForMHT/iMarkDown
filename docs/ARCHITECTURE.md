# iMarkDown 架构设计

> 一个 macOS 26 原生 Markdown 编辑器：外壳使用 SwiftUI + 官方 Liquid Glass 接口，编辑内核使用 WKWebView 承载成熟的 Web 技术栈。
> 文档版本：v0.1 · 2026-11-20

---

## 1. 目标与约束

| 维度 | 目标 |
| --- | --- |
| 产品形态 | 桌面 Markdown 编辑器，参考 FluentMarkDown 的功能集：实时预览、主题、最近文件、自动保存、导出 |
| 视觉 | 全面适配 macOS 26 Liquid Glass，只使用 Apple 官方接口，不模拟毛玻璃 |
| 内核 | Markdown 编辑与渲染跑在 Web 层，复用成熟开源库，便于快速迭代 |
| 工程 | 不依赖 Xcode GUI 工程与 Node 构建链，`swift build` + 脚本即可产出 `.app` |
| 可演进 | Web 内核可替换（CodeMirror 5 → 6 / Milkdown），原生侧不感知 |

当前开发机只有 Command Line Tools（Swift 6.3 / macOS 26 SDK），没有 Xcode GUI，也没有 Node，因此工程选型以此为前提。

---

## 2. 关键决策

### ADR-1 外壳与内核分离：SwiftUI + WKWebView

- **决策**：窗口、侧边栏、工具栏、设置、菜单、文件 IO 全部原生；正文编辑区是一个 WKWebView。
- **理由**：原生外壳才能拿到系统级的玻璃材质、菜单栏、窗口行为与无障碍；Web 内核负责高频迭代的排版与编辑体验。
- **代价**：需要一条稳定的桥接协议，并明确“文本真源”归属。

### ADR-2 文本真源在 Web，原生只持有镜像

- **决策**：`CodeMirror` 的文档是唯一真源；`DocumentSession.text` 只是供原生 UI 展示与自动保存使用的镜像（140ms 去抖回传）。
- **理由**：如果双向同步文本，任何一次原生回推都可能重置光标/选区。原生只通过显式命令（打开文件、新建、格式化插入）改写 Web 文本。
- **结果**：保存前通过 `getText()` 主动拉取最新值，避免镜像滞后导致丢字。

### ADR-3 Web 依赖：CodeMirror 5 + marked + DOMPurify + highlight.js

- **决策**：全部使用可离线 vendored 的单文件 UMD 产物，放在 `Resources/Web/vendor/`。
- **理由**：无 Node，无法运行 esbuild/Vite；上述库成熟、体积小（合计约 540KB），并覆盖 GFM 表格、任务列表、代码高亮与 XSS 清洗。
- **可替换性**：Web 层向上只暴露 `window.MD.*` 接口，后续迁移到 CodeMirror 6 或 Milkdown 时，原生桥接协议不变。

### ADR-4 构建：SwiftPM + 手工 .app 组装

- **决策**：不使用 `.xcodeproj`。`scripts/build-app.sh` 负责编译、拷贝资源 bundle、写入 `Info.plist`、ad-hoc 签名。
- **理由**：CLI 环境无法可靠生成/维护 Xcode 工程；SwiftPM 足以构建 SwiftUI + WebKit 可执行文件。
- **代价**：缺少 Xcode 的 Preview、Instruments 与自动签名；后续可平滑迁移到 Xcode 工程。

---

## 3. 分层架构

```
┌──────────────────────────────────────────────────────────────┐
│ Presentation（SwiftUI / AppKit）                              │
│  RootView · SidebarView · EditorWorkspaceView · SettingsView  │
│  AppCommands（菜单与快捷键）                                   │
│  Liquid Glass：系统工具栏/侧栏 + .glassEffect + NSGlassEffectView │
├──────────────────────────────────────────────────────────────┤
│ Application State                                            │
│  AppState（@MainActor ObservableObject）                      │
│  会话 · 保存状态 · 模式 · 导出 · 错误提示 · 设置联动            │
├──────────────────────────────────────────────────────────────┤
│ Domain / Infrastructure（MarkdownKit）                        │
│  DocumentSession · DocumentStats · FileService                │
│  AppSettings · RecentFilesStore                               │
│  HTMLComposer · PDFExportService（App 层）                     │
├──────────────────────────────────────────────────────────────┤
│ Bridge                                                       │
│  EditorController（原生 → Web 命令，未就绪自动排队）             │
│  EditorBridge（Web → 原生事件白名单，WKScriptMessageHandler）   │
├──────────────────────────────────────────────────────────────┤
│ Web Editor（WKWebView，本地文件，非持久化存储）                  │
│  CodeMirror 5（GFM 源码） · marked（渲染） · DOMPurify（清洗）   │
│  highlight.js · GitHub Markdown CSS · 自定义主题令牌            │
└──────────────────────────────────────────────────────────────┘
```

### 模块职责

| 模块 | 路径 | 职责 |
| --- | --- | --- |
| App 入口 | `Sources/iMarkDown/App/iMarkDownApp.swift` | Window / Settings Scene、AppDelegate |
| 应用状态 | `Sources/iMarkDown/App/AppState.swift` | 状态机、文件操作、自动保存、导出编排 |
| 菜单命令 | `Sources/iMarkDown/App/AppCommands.swift` | 新建/打开/保存/导出/格式/视图快捷键 |
| 原生桥 | `Sources/iMarkDown/Editor/EditorController.swift`、`EditorBridge.swift` | 双向通信，命令排队与事件解码 |
| 编辑器宿主 | `Sources/iMarkDown/Editor/MarkdownWebView.swift` | WKWebView 创建、资源加载 |
| 视图 | `Sources/iMarkDown/Views/*` | 侧栏、工作区、HUD、设置 |
| 设计系统 | `Sources/iMarkDown/Design/DesignSystem.swift` | 圆角/材质/背景 MeshGradient |
| 核心模型 | `Sources/MarkdownKit/*` | 会话、统计、设置、最近文件、工作区文件树、文件编码兼容 |
| Web 编辑器 | `Sources/iMarkDown/Resources/Web/` | HTML/CSS/JS 与离线 vendor |

---

## 4. 关键流程

### 4.1 打开文件

```
用户选择文件 → AppState.open
  → FileService.read（UTF-8 / UTF-16 / Latin1 兼容）
  → 更新 DocumentSession（text = savedText）
  → RecentFilesStore.record
  → WorkspaceStore.reveal（展开文件所在目录，文件树中高亮当前文档）
  → EditorController.setDocument(text, baseDirectory)   // Web 静默 setValue，不触发 change
  → Web 返回 stats → 原生刷新字数与阅读时长
```

`baseDirectory` 用于把 Markdown 中的相对图片路径解析为 `file://` 绝对路径；WKWebView 以根目录为读取范围加载本地资源。

文件树由 `WorkspaceStore` 驱动：打开文件夹后异步扫描根目录，只保留目录与 Markdown/文本文件，跳过隐藏项及 `.git`、`.build`、`node_modules` 等目录；子目录在展开时按需扫描，避免一次性遍历大型工程。根目录路径持久化到 UserDefaults，下次启动自动恢复。

### 4.2 编辑与自动保存

```
CodeMirror change → 140ms 去抖 → postMessage('change', {text, stats})
  → AppState 更新镜像、脏状态、HUD
  → 若已命名且开启自动保存：1.2s 去抖后原子写入磁盘
  → 保存成功：savedText = text，状态变为“已保存 HH:mm”
```

未命名文档不自动落盘，避免在用户不知情的位置生成文件；新建/打开前若存在未保存修改，会弹出原生确认框。

### 4.3 导出

- **HTML**：Web 返回预览区 `innerHTML` → 原生把 `github-markdown.css`、highlight 主题、`preview.css`、`export.css` 全部内联进模板 → 写出单文件 HTML，不依赖应用资源。
- **PDF**：同一份 HTML 交给离屏 WKWebView → `NSPrintOperation`（`jobDisposition = .save`，A4、页边距、自动分页）→ 落盘 PDF。

---

## 5. 桥接协议

Web → 原生（`window.webkit.messageHandlers.editor.postMessage`）：

| type | 载荷 | 说明 |
| --- | --- | --- |
| `ready` | — | Web 初始化完成，原生开始冲刷排队命令 |
| `change` | `text`, `stats` | 用户编辑（140ms 去抖），原生更新镜像与脏状态 |
| `stats` | `characters`, `words`, `lines`, `readingMinutes` | 仅统计信息更新（打开/切换文档后），字段直接铺在消息根部 |
| `link` | `href` | 点击链接，原生负责打开浏览器或跳转 Markdown 文档 |
| `save` | — | Web 内 ⌘S 转发到原生保存 |
| `log` | `text` | 调试输出 |

原生 → Web（`EditorController` 内的 `evaluateJavaScript`）：

| 方法 | 说明 |
| --- | --- |
| `MD.setDocument(text, baseDirectory)` | 静默替换全文、清空历史与滚动、重渲染 |
| `MD.setMode('source' \| 'split' \| 'preview')` | 切换布局 |
| `MD.applyConfig({appearance, previewTheme, editorFontSize, previewFontSize, baseDirectory})` | 主题与排版快照 |
| `MD.wrap(before, after)` / `MD.insert(text)` | 格式化命令、插入内容 |
| `MD.getText()` / `MD.getArticleHTML()` | 保存与导出前同步拉取 |
| `MD.focus()` | 聚焦编辑器 |

**时序保障**：Web 未 `ready` 前，所有原生命令进入队列；`ready` 后按序执行，避免“配置早于页面加载”导致的丢失。

**安全边界**：`EditorBridge` 只解析白名单消息类型；Markdown 渲染结果经过 DOMPurify；Web 内点击链接一律 `preventDefault` 交给原生校验协议（http/https/mailto/file），避免 WebView 内任意导航。

---

## 6. Liquid Glass 适配策略

只使用官方接口，按“组件由谁承载”选择材质路径：

| 场景 | 接口 | 落地 |
| --- | --- | --- |
| 窗口标题栏、工具栏、菜单 | 系统自动材质 | 使用标准 `Window` / `.toolbar`，不叠加自绘材质 |
| 侧边栏 | 系统自动材质 | `NavigationSplitView` + `.listStyle(.sidebar)` |
| 侧栏底部操作按钮 | `GlassEffectContainer` + `.buttonStyle(.glass / .glassProminent)` | 按钮各自成玻璃，容器负责合并与性能 |
| 编辑器浮动状态条 | `NSGlassEffectView`（`NSViewRepresentable`） | 需要精确控制圆角、tint 与 AppKit 层级 |
| 未来自绘面板 / 批量玻璃 | `NSGlassEffectContainerView` | 容器合并、`spacing` 调邻近融合 |

**降级**：低于 macOS 26 时，`GlassSurface` 回退到 `NSVisualEffectView(.hudWindow)`；玻璃按钮回退到 `borderedProminent` / `bordered`。

**无障碍**：系统开启“降低透明度/提高对比度”时由系统材质自动响应；HUD 设置了合并后的无障碍标签，且不拦截鼠标事件。

**背景策略**：工作区使用低饱和 `MeshGradient` 作为可被折射的内容；内容卡片保持高不透明度以保证长时间阅读舒适度，玻璃只出现在浮动层。

---

## 7. 目录结构

```
iMarkDown/
├── Package.swift                     # SwiftPM：MarkdownKit + iMarkDown
├── Support/Info.plist                # bundle 元信息、Markdown 文档类型
├── scripts/
│   ├── fetch-vendor.sh               # 拉取并固化为本地 UMD/CSS
│   ├── build-app.sh                  # 编译 + 组装 .app + ad-hoc 签名
│   └── run.sh                        # 构建并启动
├── docs/
│   ├── ARCHITECTURE.md               # 本文
│   └── UI-SPEC.md                    # UI / 视觉规范
├── design/
│   └── ui-preview.html               # 高保真可交互 UI 设计稿
├── Sources/
│   ├── MarkdownKit/                  # 无 UI 依赖的核心层
│   │   ├── DocumentSession.swift
│   │   ├── DocumentStats.swift
│   │   ├── FileService.swift
│   │   ├── AppSettings.swift
│   │   └── RecentFilesStore.swift
│   └── iMarkDown/
│       ├── App/                      # 入口、状态、命令
│       ├── Editor/                   # WKWebView 与桥
│       ├── Views/                    # SwiftUI 界面
│       ├── Design/                   # 设计令牌与玻璃桥
│       ├── Services/                 # HTML/PDF 导出、版本信息
│       ├── Models/
│       └── Resources/Web/            # 编辑器前端
│           ├── index.html
│           ├── css/{editor,preview,export}.css
│           ├── js/app.js
│           └── vendor/               # CodeMirror/marked/DOMPurify/hljs/主题
└── dist/iMarkDown.app                # 构建产物（gitignore）
```

---

## 8. 构建与运行

```bash
# 首次会先下载 Web 依赖（约 540KB）
./scripts/build-app.sh release

# 开发迭代
./scripts/run.sh debug
```

不依赖 Xcode 工程；`swift build` 与打包脚本均可在只有 Command Line Tools 的环境完成。

---

## 9. 已验证项（v0.1）

- `swift build` 通过，`.app` 成功启动，窗口 1240×820 正常创建。
- 离屏 WKWebView 冒烟测试通过：CodeMirror 实例、GFM 标题/表格/任务列表、highlight.js 代码高亮、分栏布局、主题切换、字数统计回传均正常。
- 最近文件持久化、自动保存、HTML/PDF 导出链路已接通（导出 UI 待人工点验）。

---

## 10. 当前限制与路线图

| 优先级 | 事项 | 说明 |
| --- | --- | --- |
| P0 | 单窗口文档模型 | 当前为单窗口；多窗口需要将 `AppState` 下沉为 per-window 对象 |
| P0 | 关闭窗口前的未保存确认 | 当前仅在新建/打开时确认 |
| P1 | 本地图片写入 | 支持剪贴板粘贴图片并落盘到 `assets/` |
| P1 | 沙盒化 | 用自定义 `WKURLSchemeHandler` 替代 `allowingReadAccessTo: /`，并按文档目录授权 |
| P1 | 大纲 / 快速跳转 | 基于 marked 标题生成目录，⌘K 面板 |
| P1 | Word (.docx) 导出 | 现有 HTML 可转为 OOXML，或引入轻量转换器 |
| P2 | 内核升级 | CodeMirror 6 / Milkdown，保持 `window.MD` 协议不变 |
| P2 | 全文搜索 | 原生索引 + Web 高亮 |
| P2 | 崩溃恢复 | 未命名草稿定时快照到 Application Support |

---

## 11. 设计取舍备忘

- **不做 Web 侧窗口 chrome**：所有按钮、菜单、焦点环都保持原生，避免“Electron 感”。
- **不手绘毛玻璃**：Web 侧仅使用半透明表面与渐变，不尝试用 `backdrop-filter` 模仿系统材质。
- **滚动同步按比例**：实现简单、对长文足够稳定；后续可换为按标题锚点对齐。
- **预览样式可导出**：预览 CSS 与导出 CSS 同源，保证“所见即所得”的导出结果。
