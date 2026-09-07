# Editor 代码问题清单 — 2026-09-07

审查基线：`codex/code-editor`，`15d6116db`。由三个 subagent 分别审查输入、文件读写/生命周期、预览/设置，主 agent 交叉核对调用链。此清单只记录问题，没有实施修复，也没有创建 Issue/PR。

已提交的上一轮改动通过 530 项测试；这不表示下列未覆盖路径正确。本轮是只读代码审查，未重新执行完整测试或真实 SSH/界面故障注入。

P1：优先处理内容安全与编辑状态丢失。P2：明确功能缺口或生命周期问题。性能待测量项不作为已经复现的卡顿。

建议顺序：E01/E02/E03 → E05/E06 → E07/E08/E09 → E04/E10/E11/E12；E13 先测量。E03/E04 可一起设计，分别验收。

## E01 · P1 · 查找替换可能删除未匹配的字符

- 触发：foo() 中查找 ( 并替换为空，预期 foo)，按调用链会得到 foo。
- 原因与影响：replaceCharacters 经真实 TextViewController 进入 TextFormation.DeleteCloseFilter，额外删除相邻右括号；现有裸 TextView 测试没有覆盖该过滤链。
- 证据：`macos/Sources/Features/Editor/EditorTextSearch.swift:15`。
- 确认程度：调用链确认，未做 UI 复现。
- 后续验收：用真实 controller 验证字面替换、全部替换、括号/引号及一次撤销，确保只改变匹配范围。

## E02 · P1 · SSH 保存中断可能破坏远端原件

- 触发：自动保存上传时断网、写失败，或达到 SFTP 的 15 秒超时。
- 原因与影响：先 get 比对，再直接 put 到原路径，没有远端临时文件和原子替换；失败可能留下截断/部分文件，重试又因基线不同产生冲突。比较与写入之间也有竞态，本地 798 行同样不是原子 CAS。
- 证据：`macos/Sources/Features/Plugins/WorkspaceProvider.swift:1127`。
- 确认程度：直接覆盖路径确认；中断后果按 SFTP 行为推导，未做故障注入。
- 后续验收：注入传输中断和并发修改，验证旧文件完整性、错误恢复、冲突保护及权限保留。

## E03 · P1 · Markdown 切换预览丢失撤销历史和编辑位置

- 触发：编辑 Markdown 后切换 Preview，再切回 Edit。
- 原因与影响：互斥分支销毁 CodeEditorView；光标/搜索存于局部 State，未传文档级 undoManager，依赖新建 CEUndoManager。内容保留，但此前撤销链和编辑上下文不保留。
- 证据：`macos/Sources/Features/Editor/EditorWorkspaceHost.swift:286`。
- 确认程度：状态所有权和销毁链确认，未做 UI 复现。
- 后续验收：往返预览后验证撤销/重做、光标、滚动与搜索状态。

## E04 · P2 · 预览模式缺少文档快捷键路由

- 触发：预览中按保存、关闭或切换文档快捷键。
- 原因与影响：编辑分支销毁时 destroy 注销 EditorCommandRouter；Preview 没有替代注册。按键最终被哪个宿主功能处理仍需实测。
- 证据：`macos/Sources/Features/Editor/CodeEditorView.swift:749`。
- 确认程度：编辑器路由缺失确认。
- 后续验收：在 Edit/Preview 中分别验证保存、关闭当前文件和切标签，不误操作终端。

## E05 · P2 · 慢速保存期间丢弃关闭、退出及 Save All 请求

- 触发：SSH 自动保存期间执行关闭、退出或保存全部。
- 原因与影响：save/canClose 在 isSaving 时直接返回 false；上层没有等待或继续机制。Save All 遇到该文档会中断，后续文档不再执行本次保存。
- 证据：`macos/Sources/Features/Editor/EditorWorkspace.swift:85`。
- 确认程度：代码路径确认。
- 后续验收：模拟阻塞写入，验证请求等待完成、失败反馈和后续文档处理。

## E06 · P2 · 关闭分屏未清理对应文档与在途读取

- 触发：反复创建分屏、打开文件并关闭分屏，保留同一 tab 的其他 pane。
- 原因与影响：干净文档跳过 closeAll；Store 仅有 remove(tabID:)，TerminalController:3149 的分屏关闭没有 surface 级清理。singleton 保留文档，在途打开还能在 pane 消失后完成。
- 证据：`macos/Sources/Features/Editor/EditorWorkspace.swift:194`。
- 确认程度：调用链确认；内存增量未测量，不断言存在幽灵自动保存。
- 后续验收：关闭分屏后验证 workspace/document 释放、读取取消及 tab 内其他 pane 不受影响。

## E07 · P2 · 缩进设置未传入实际输入策略

- 触发：Tab Width 设为 2/8 后输入 Tab、执行缩进或自动缩进。
- 原因与影响：只传 tabWidth，indentOption 留在依赖默认 spaces(count:4)。显示宽度与实际插入策略分离，且没有真实 Tab 选项。
- 证据：`macos/Sources/Features/Editor/CodeEditorView.swift:80`。
- 确认程度：依赖数据流确认。
- 后续验收：核对实际写入字符，覆盖 2/4/8 空格及 Makefile 的真实 Tab。

## E08 · P2 · 多光标整行操作只处理第一个光标

- 触发：Option 拖动建立多光标后复制/删除/移动行或无选区剪切。
- 原因与影响：分支使用 textSelections.first，修改一行后 setSelectedRange 退化为单选区。
- 证据：`macos/Sources/Features/Editor/EditorCommandRouter.swift:240`。
- 确认程度：代码路径确认，未做鼠标交互复现。
- 后续验收：多光标及重叠选区下验证每行只操作一次、选择保留和完整撤销。

## E09 · P2 · 远程选择器不能直接打开列表外的文件路径

- 触发：当前在 /project，输入 /tmp/a.swift 或 src/a.swift。
- 原因与影响：只有当前 entries 中的文件才调用打开回调；其他路径一律 listDirectory，文件被当成目录。
- 证据：`macos/Sources/Features/Editor/EditorFilePicker.swift:113`。
- 确认程度：代码路径确认；不同 SFTP 返回可能表现为错误或文件自身列表。
- 后续验收：输入跨目录绝对/相对文件路径，验证直接打开、目录导航及错误提示。

## E10 · P2 · SSH Markdown 图片错误使用本地文件系统

- 触发：远程 README 引用 images/a.png。
- 原因与影响：远端文档路径转为本地 file URL，MarkdownPreviewView:135 只用 NSImage 本地读图。远端图片缺失，本地同路径存在时还可能显示错误来源。
- 证据：`macos/Sources/Features/Editor/EditorWorkspaceHost.swift:289`。
- 确认程度：代码路径确认。
- 后续验收：验证 local/SSH 相对图片、绝对图片及 HTTP 图片的来源和错误提示。

## E11 · P2 · SSH 大文件限制在下载完成后才检查

- 触发：误打开超过 10 MiB 的日志或数据文件。
- 原因与影响：先 get 到临时文件，之后检查大小；不能提前限制流量、等待和临时磁盘使用。慢链路还可能先触发 15 秒超时。
- 证据：`macos/Sources/Features/Plugins/WorkspaceProvider.swift:1109`。
- 确认程度：执行顺序确认，实际流量受网络和超时限制。
- 后续验收：验证超限文件在传输前拒绝，且正常小文件不受影响。

## E12 · P2 · 符号链接后接 .. 的路径可能打开错误文件

- 触发：打开 /project/link/../config，link 指向 /srv/app/subdir。
- 原因与影响：词法折叠先变为 /project/config，丢失真实路径解析应指向 /srv/app/config 的语义；之后 read/save 都使用折叠后的 id.path。
- 证据：`macos/Sources/Features/Editor/EditorDocument.swift:43`。
- 确认程度：路径变换确认，依赖特定路径输入，未做文件系统复现。
- 后续验收：用 symlink/.. fixture 验证打开内容、文档去重及保存目标。

## E13 · P2待测量 · Markdown 预览同步解析全文并读图

- 触发：打开长 Markdown 或多张大图，父视图更新触发 body 求值。
- 原因与影响：每次 parseBlocks 遍历全文，普通 VStack 构造全部块，loadImage 同步访问文件，无解析/图片缓存或缩略图下采样。
- 证据：`macos/Sources/Features/Editor/MarkdownPreviewView.swift:19`。
- 确认程度：UI 路径确认；尚未测量卡顿、耗时和内存。
- 后续验收：先测长文档、大图和网络挂载路径的首屏耗时、主线程占用与峰值内存，再决定优化范围。

## 次级观察，暂不与上述问题同级排期

- BufferWordCompletionProvider 只扫描开头 100,000 个 UTF-16 单元，尾部局部标识符不在候选来源内（EditorCompletion.swift:128）。
- 所有打开标签保留原生编辑器以保存撤销记录（EditorWorkspaceHost.swift:129）；大量标签的内存需测量，不能简单销毁隐藏视图。
- E01 依赖证据：当前 Xcode checkout 的 TextFormation/DeleteCloseFilter.swift:16、CodeEditSourceEditor/TextViewController+TextFormation.swift 的 shouldApplyMutation，以及 TextViewController+TextViewDelegate.swift:32。
- E03 依赖证据：当前 CodeEditTextView/TextView.swift:303 创建 CEUndoManager，CodeEditSourceEditor/TextViewController.swift:310 析构并销毁 coordinators。
