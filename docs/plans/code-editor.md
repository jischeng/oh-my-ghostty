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
