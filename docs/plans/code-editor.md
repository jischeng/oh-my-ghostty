# Code Editor Plan

本文记录本轮 OMG 内置代码编辑器工作的分工、方向和接续检查项。
它是实现交接记录，不是完成声明；未经过构建、真实应用或 SSH 环境验证的内容不得按已完成能力对外描述。

## 当前方向

- 编辑器组件采用 `CodeEditSourceEditor`，先做轻量代码查看和基础编辑，不从零实现文本编辑器。
- 文件读写走统一 `WorkspaceFilesystem` 边界，保持 local 和 SSH 文件路径共用同一套打开、读取、保存入口。
- Files Inspector 仍保持 data-only action 模型；Files UI 只发 typed action，不直接持有编辑器控制器。
- 文件打开入口从 Files 行的双击和上下文菜单进入 `.openFile(path:)`，由 `BuiltInFilesInspectorProvider` 校验当前树内非目录节点后调用 host 注入的 `OpenFileHandler`。
- 编辑器嵌入目标是终端旁的 Editor 区域，支持文件标签、切换、保存、关闭和 dirty 状态展示。
- Files provider、终端布局及 Editor host 已接线；菜单的 `Open File in Editor…`（⌘O）也进入同一打开流程。

## 本轮分工

- 组件方向：使用 `CodeEditSourceEditor` 承载文本编辑体验。
- 文件模型：保留 `EditorDocument` 作为文档状态和编码/换行处理边界。
- 文件系统：复用 `WorkspaceFilesystem`，后续 local/SSH 都应通过同一读取和保存抽象进入编辑器。
- Files 入口：新增 Files action，避免单击打开文件；双击和 `Open in Editor` 才请求打开。
- host 集成：由 root 负责把 provider 的 `OpenFileHandler` 接到实际 Editor controller，并把 Editor 放入终端布局。

## 已写入的入口约束

- `InspectorPaneActionKind.openFile(path:)` 表示打开文件请求。
- `BuiltInFilesInspectorProvider.OpenFileHandler` 签名为 `@MainActor (String, InspectorPaneContext) -> Void`。
- `BuiltInFilesInspectorProvider` initializer 需要显式注入 `openFile`，避免未接线时静默 no-op。
- Provider 只接受当前 published file tree 内的文件节点；目录和不存在的 path 会被忽略。
- `RightInspectorHost` 的 SwiftUI Files row 已有双击和上下文菜单入口；当前未发现独立的原生 `NSOutlineView` Files 树入口。

## 后续共用打开路径

- Files 面板、未来文件搜索、Git Diff 详情里的文件打开都应调用同一 Editor 打开服务。
- Git detail 当前不扩展为编辑器功能；后续只在需要“打开这个文件”时复用统一路径。
- 后续普通文件与 Diff 本身共用 Editor 文档打开流程和展示区域；Git 提供差异数据，Editor 承载只读 Diff。不只复用从 Diff 跳到文件的动作。

## 当前不扩展范围

- 不扩展 Git detail 的交互范围。
- 不实现 Vim 模态编辑。
- 不接 LSP、诊断、补全服务。
- 不设计完整 IDE 工作区。
- 不新增插件 API 或第三方编辑器协议。

## 使用与验收

- 在 Files 双击文件，或选择 `File → Open File in Editor…`。SSH Pane 的打开对话框接受远端绝对路径。
- 编辑区域按终端 Tab 保存文件标签；⌘S 保存、⌘F 查找、⌘W 关闭当前文件，隐藏区域保留文档。
- 首版支持 UTF-8（含 BOM）及原换行风格；读取上限 10 MiB。SSH 使用已有 SFTP 连接能力，不提供新的交互认证界面。
- 工作目录：`../oh-my-ghostty-editor`，分支：`codex/code-editor`，基于 `codex/git-readonly`。
- 构建：`macos/build.nu`；测试：`macos/build.nu --action test`。独立 worktree 复用原 checkout 的 GhosttyKit 与 zig-out/share 构建产物。

## 第二轮功能完善

- 查找支持匹配计数与大小写选项；替换当前项或全部匹配走编辑器原生修改接口，保留撤销。
- 支持按 `行:列` 跳转。快捷键：⌘F 查找、⌥⌘F 替换、⌘L 跳转、⌘G / ⇧⌘G 查找下一项或上一项。
- Control-Tab / Control-Shift-Tab 切换文件，⇧⌘S 保存全部文件；标签菜单列出完整路径，支持重新加载与关闭全部文件。
- 重新加载使用原文件系统，因此本地和 SSH 共用逻辑；未保存文件先确认，读取失败或读取期间继续编辑都保留现有内容。
- 外部重新加载后重建对应编辑器视图，更新文本及编码基线；普通文件切换继续保留每个编辑器的撤销记录。
- 本轮按用户要求只推进功能、编译和自动化测试，人工界面验收暂缓。

## Worker 接续检查清单

- 构建：确认 `BuiltInFilesInspectorProvider` 所有初始化点都已注入真实或测试 handler。
- Files 入口：在真实 app 中验证文件双击打开，目录双击仍只展开/收起。
- 中文 IME：在 Editor 中输入中文、候选词选择、组合态取消、光标移动和撤销。
- 大文件：实际打开较大源码/日志文件，观察首屏时间、滚动、编辑延迟和内存增长。
- 快捷键：验证保存、关闭、切换标签、复制粘贴、撤销重做和终端焦点切换。
- Dirty 状态：修改后显示 dirty，保存后清除 dirty，关闭 dirty 文件时有明确处理。
- 文件切换：多个标签切换不丢编辑内容，重复打开同一文件复用已有标签。
- SSH roundtrip：如环境可用，验证远端文件打开、编辑、保存、重新读取后内容一致。
- 错误路径：验证二进制文件、不可读文件、保存失败和 SSH 断线时的用户可见状态。
- 文档同步：若入口、provider 行为或读写 contract 继续变化，同步更新 `docs/PLUGIN_DEVELOPMENT.md`。

## 2026-09-07 保存可靠性与行操作修复

- 自动保存失败显示文档内错误提示并提供 Retry Save；保留未保存内容，成功保存或重新加载后清除错误。
- 慢速本地/SSH 写入期间继续编辑，当前写入成功后重新安排自动保存，避免剩余修改停留在 dirty 状态。
- 关闭和重新加载确认期间暂停自动保存；取消后恢复，已移除的文档停止自动保存。
- 修复文件末尾空行被误判为上一行，避免在空行执行删除或复制时修改上一行。
- 回归覆盖保存冲突、慢写入、自动保存暂停/恢复、末尾空行操作及撤销。真实 SSH 网络、中文 IME 和界面交互仍需验收。

## 2026-09-07 输入热路径代码优化

- 查找栏缓存匹配范围，只在文本、查询条件或查找模式变化时更新；移动光标和遍历匹配不再重复扫描全文。修改查询从首项定位，关闭后仍可使用 Find Next。
- 补全统一取消入口：输入空白、移动光标、多选区、IME 组合态、Escape、停用编辑器及提交补全都会使旧请求失效。返回及提交时校验当前光标/前缀；按键优先核对实际焦点及修饰键。
- 关键词使用明确语言标识和别名，未知语言不再回退到 Swift；buffer 词表只聚合匹配词，按最近出现距离评分；同分候选按 label 稳定排序，过滤后无匹配立即清空。
- 每个编辑器保留自己的高亮 provider 实例；Markdown 辅助高亮复用正则和 NSString 切片；等长修改仅使受影响行失效，长度变化时使后续范围失效，以兼容组件未平移有效范围缓存的行为。跨行语法仍由 Tree-sitter 管理。
- 自动化覆盖原生编辑器补全请求失效、焦点、修饰键、IME 标记文本、提交及撤销；这些不是人工输入法和视觉验收的替代。

### 本轮检查后仍待推进

- Markdown 文件（`.md` / `.markdown`，不区分大小写）默认预览，每个文档保留独立的 Edit/Preview 选择。预览使用离线 Milkdown Crepe 直接编辑渲染内容，支持 `# ` 标题输入规则、GFM 表格、任务列表与嵌套列表；修改回写同一文档，沿用自动保存和冲突检测。公式、Mermaid 与图片保留预览；GitHub alerts、admonitions、HTML/SVG 等特殊块保留原始源码，并可双击就地编辑源码。普通块编辑后可能规范化 Markdown 排版，打开文件本身不会标记修改。
- `MarkdownPreviewView` 使用透明 WKWebView 继承终端背景，渲染更新合并处理；本地和 SSH 图片通过同一个 `WorkspaceFilesystem` 异步读取，资源桥只返回图片类型。重载文档重建预览并重新请求图片。脚本、字体和样式随应用打包，远程 URL 图片仍需要网络；HTML 经 DOMPurify 过滤，Mermaid 使用 strict 模式，外部链接仅在用户点击后交给系统浏览器。
- 预览拥有自身选区与复制快捷键；隐藏终端不抢占 WebView 快捷键。编辑消息携带基准文本，拒绝覆盖已经变化的文档；保存前取得最新编辑内容。编辑器依赖锁定和构建方式见 `dist/markdown-editor/README.md`。
- buffer 补全仍只扫描文件开头 100,000 个 UTF-16 单元，大文件尾部的局部标识符可能缺失；后续应采用光标周边窗口或增量索引。
- `EditorWorkspace.save/canClose` 在已有保存进行时直接返回 false，慢速 SSH 下缺少等待完成后继续用户操作的机制。
- 每个打开的文档都保留原生编辑器以保存撤销历史；大量标签的内存及恢复策略需要实际测量，不能直接通过销毁隐藏编辑器优化。
