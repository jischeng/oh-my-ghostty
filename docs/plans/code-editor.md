# Code Editor Plan

本文记录 OMG 内置代码编辑器（Monaco + `@pierre/highlights` + 纯 Swift 智能引擎与主机工作台）的架构设计与验收检查项。
它是实现交接记录，不是完成声明；未经过真实应用、VM GUI 或真实 SSH 环境交互验证的细节仍需按测试清单持续核对。

## 当前架构（Monaco + Pierre + LSP/Symbol + FileWatcher + Ask-Agent）

- **单实例共享 `WKWebView` 工作台（`MonacoWorkbenchView.swift`）**：
  - 彻底移除第三方 `CodeEditSourceEditor` / `CodeEditTextView` / `SwiftTreeSitter` SPM 依赖；由 OMG 原生轻量 `EditorTheme` 承载语法配色，对外保持属性名与 `EditorCatalogThemes` / Ghostty 终端主题适配 100% 源码兼容。
  - 每个 `EditorWorkspace` 仅持有 **一个** `MonacoWorkbenchController`（单个池化 `MonacoEditorWebView`），同一工作区内打开的所有文件标签共享单个 `WKWebView`，通过 `openOrUpdateModel` + `activateModel` + `closeModel` 毫秒级切换 `ITextModel` 并自动保存/恢复各标签的光标、选区、折叠、滚动位置与独立 Undo/Redo 栈。
  - 终端工作区空闲后支持 1.5s 轻量预热（测试环境自动跳过后台预热）；通过自定义 `WKURLSchemeHandler`（`omg-editor://bundle/index.html`）+ `.nonPersistent()` 数据存储提供完全离线资源加载（CSP `connect-src 'none'`，路径穿越严格校验在 bundle 根目录内）。
  - `MonacoEditorWebView` 保持全链路透明（`isOpaque = false`、`drawsBackground = false`、`underPageBackgroundColor = .clear`、内部 `NSScrollView`/`NSClipView` 背景清零，Monaco 主题 `#00000000`），无缝透出底层 `EditorBackdrop` 毛玻璃与终端背景。

- **离线语法高亮与 Pierre Git Diff 前端包（`dist/code-editor/` → `macos/Resources/CodeEditor/`）**：
  - 基于裁剪版 `monaco-editor`（内置多光标、括号配对着色、Sticky Scroll、折叠、原生 Find/Replace/Go-to-Line）结合 `@pierre/highlights` Tree-sitter WASM `LiveTokenizer`（`packed24` 同步状态机适配 Monaco `TokensProvider`，内置超长行 `20,000` 与超大文件 `300,000` 行安全降级阈值）。
  - **单 WebView Pierre Git Diff（`@pierre/diffs` + `@pierre/highlights`，`GitEditorDiffView.swift`）**：
    - 移除旧版 SwiftUI `GitDiffReviewView` 表格、双 WebView `GitDiffLinkedEditor` 分栏以及不透明 `GitDiffTextView` 兜底；统一由单个 `MonacoWorkbenchController` 承载 ThinkRail 风格 Pierre Diff 视图。
    - 原生紧凑顶部工具栏保持完整（文件切换 `<`/`>`、变更导航 `↑`/`↓` 及跨文件二次确认提示、`Review | Full Source` 折叠上下文与全量源码切换、自动换行、`Side by Side | Inline` 双栏同步与行内视图、在编辑器中打开、刷新），在单一池化透明 `WKWebView` 内无闪烁原地切换所有模式；当完整源码快照受限时以 `patchOnly: true` 方式在毛玻璃背景上直接渲染统一补丁。
    - Git Diff 内选中变更行并触发 Ask Agent（`⌘⇧L` / `⌘⇧I` 或内联提问栏）直接解析工作树文件路径与行号区间，经 `EditorWorkspaceHost.sendAskAgentToQuickInput` 注入所属终端的 `QuickInput` 草稿框；关闭 Diff 标签时调用 `tearDown()` 彻底回收 `WKWebView` 与快捷键注册。
  - 支持 `idea` 与 `vscode` 双快捷键配置档案，并拦截编辑器内按键以防终端菜单项（如 `⌘D` 分屏）误抢焦点。

- **纯 Swift 代码智能、Git 行级变更槽与文件监听（`macos/Sources/Features/Editor/Intelligence/` + `EditorWorkspaceIntelligenceBridge.swift`）**：
  - `EditorIntelligenceCoordinator` 统一调度本地按需启动的 stdio JSON-RPC 2.0 语言服务器（`EditorLSPManager`：支持 `sourcekit-lsp`、`zls`、`rust-analyzer`、`gopls`、`typescript-language-server`/`vtsls`、`basedpyright`/`pyright`/`pylsp`、`clangd`，空闲自动回收并带优雅退出与 SIGTERM/SIGKILL 兜底）以及零进程纯 Swift 工作区符号索引（`EditorSymbolIndex`）和 `EditorCompletionEngine`。
  - 打通 Monaco `HoverProvider`、`DefinitionProvider`（`⌘+Click` / `F12` 跨文件跳转直接通过 `EditorWorkspace.open(path:filesystem:location:)` 在标签页打开目标文件并定位）、`ReferenceProvider`、`DocumentSymbolProvider`（`⇧⌘O` 文件符号大纲与 Sticky Scroll）、`CompletionItemProvider` 以及 `publishDiagnostics` 波浪线标注。
  - **严格的本地 / SSH 隔离边界**：`EditorDocumentID.Endpoint == .ssh` 的远程文档绝不触发本地宿主机目录遍历、绝不启动本地 LSP 子进程、绝不调用本地 `git` 命令。
  - `EditorGitGutterService` 异步解析零上下文统一 diff（`git diff -U0 HEAD`），向 Monaco 注入行级 `added` / `modified` / `deleted` 侧边栏色条。
  - `EditorFileWatcher` 同时监听父目录与目标文件描述符（`O_EVTONLY`），安全捕获 Claude Code / Codex / `vim` / `git` 的原子 `rename()` 替换并哈希去重，自保存前预登记摘要防误报：
    - 当未修改文档（`!isDirty`）在磁盘被外部更新时，`EditorDocument.applyExternalDiskUpdate` 原地无损同步（`preserveView: true` 最小差分编辑，不销毁视图、不重置光标与滚动条）。
    - 当已修改文档（`isDirty`）发生外部磁盘变更时，置位 `hasExternalDiskConflict = true` 并在编辑器顶部展示冲突横幅（`File changed on disk`：`Reload from Disk` / `Keep My Edits`）。SSH 文档在窗口重新获得焦点时通过 `WorkspaceFilesystem` 异步校验远端摘要。

- **ThinkRail 风格 “Ask Agent” 与工作区全局模糊快开（`⌘P` / `⌘O`）**：
  - 选中代码通过右键菜单、`⌘⇧L` / `⌘⇧I` 或内联提问浮层发送 `{ type: "askAgent", path, startLine, endLine, selectedText, comment }`，`EditorQuickInputBridge` 生成 `@<relative-path>#L<start>-L<end>` + 注释 + 代码围栏并自动展开聚焦所属终端分屏的 `QuickInput` 草稿框。
  - `EditorFilePicker` 支持 `⌘P`（`Quick Open in Editor…`）与 `⌘O`：空查询保持目录浏览；输入关键字时异步递归扫描工作区文件（自动跳过 `.git`、`node_modules`、`zig-*`、`build*`、`DerivedData`、`target` 等产物目录）并按文件名/路径边界模糊打分排序，支持上下方向键与回车直达打开。

- **Markdown 实时预览与编辑双模保留**：
  - `.md` / `.markdown` 默认以离线安全的 `MarkdownPreviewView` 打开，保留顶部 `Edit | Preview` 切换、待办复选框单字符写回、宽表自适应与行号导航自动切回 Monaco 编辑模式。

## 构建、选择器与验证命令

- 前端包重编与单测：`npm run build --prefix dist/code-editor && npm test --prefix dist/code-editor`
- 测试计划选择器验证：`dist/macos/dev-tool.sh python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'`（`dist/code-editor/**` 与 `macos/Resources/CodeEditor/**` 均映射至 `editor` 模块）
- Swift 静态规范与文档契约：
  - `dist/macos/dev-tool.sh swiftlint lint --strict --config macos/.swiftlint.yml macos`
  - `dist/macos/dev-tool.sh python3 dist/check_omg_docs.py`
- macOS 构建与测试（遵循串行执行与 VM 隔离原则）：
  - `macos/build.nu --action test --test-modules editor,git,inspector`

## 持续验收清单

- **单 WebView 池化与内存**：在同一工作区连续打开/切换/关闭 10+ 个文件标签及 Git Diff，确认仅存在 1 个 `MonacoEditorWebView` 实例，关闭工作区后 `WKWebView` 与 LSP 子进程完全释放。
- **外部 Agent 协同改码**：使用外部进程原子改写已打开文件，验证干净状态下光标不跳动、未保存状态下冲突横幅按钮（`Reload from Disk` 与 `Keep My Edits` 后继续保存）行为准确。
- **中文 IME 与快捷键**：在 Monaco 编辑区验证中文拼音组合态候选词、撤销重做、`⌘F` / `⌥⌘F` / `⌘L` / `⇧⌘O` / `⌘P` / `⇧Escape` 以及终端分屏焦点切换。
- **SSH 隔离与远端往返**：在 SSH 会话中验证打开、编辑、保存、重新加载以及窗口切回时的远端变更检测，确认无任何本地文件系统或本地 LSP/Git 泄露。
