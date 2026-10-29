# Workspace 呈现回归根因与修复 — 2026-10-29

基线：`4bcec9e39`，用户报告弹窗不打开、新 workspace 标题短暂显示 Terminal、sidebar 折叠后 workspace 入口仍显示、Quick Input 打开时聚焦 pane 闪烁。工作树开始时干净。本轮直接修复，不改持久化格式、不重建既有 Surface/PTY。

## 根因与修改

| 问题 | 根因与证据 | 修复边界 |
| --- | --- | --- |
| Workspace 弹窗不打开 | `WorkspacePopoverAnchor` 只保存 Controller 引用；SwiftUI 可把 representable 的输入判为未变，不再次调用 updateNSView。原有测试手动 update(anchor:) 绕过真实问题。真实 NSHostingView 中切换 published 状态后，旧代码 `isShown=false`。 | Controller 的 `workspaceSwitcherIsPresented` didSet 直接发送原生呈现命令；SwiftUI 只登记锚点。按钮隐藏时快捷键使用稳定的 window.contentView 锚点。关闭回调及 afterDismiss 保持单次执行。 |
| 首次新 workspace 短暂 Terminal | 创建分支直接使用空 SurfaceConfiguration，Swift 层没有初始 cwd/title，row 在 OSC 到达之前只能使用 Terminal。已有 workspace 往返的稳定标题测试没有复现回退；首次创建同步检查明确得到 cwd=nil、title=Terminal。 | 首次工作区 shell 和移动最后 tab 的 replacement 复用既有 new-tab 配置解析，沿用 cwd 继承、字体及 SSH/runtime 本地目录规则，首帧可用已知目录。禁用 cwd 继承时仍交 Ghostty 选默认目录，不硬编码路径、不冻结后续真实标题。 |
| Sidebar 折叠后 workspace 不折叠 | TerminalShellLayoutContainer 通过 `!leftVisible` 主动在内容区生成第二个入口，这是原先的产品规则，并非动画 bug。 | 按用户新要求，仅 horizontal tabs 使用 compact header；vertical sidebar 隐藏时入口一起消失，快捷键仍可唤出。 |
| Quick Input 打开时 pane 闪烁 | `toggleQuickInput()` 无条件在 focused pane 上盖旧帧 NSImageView，150ms 后移除，即使没有任何 Agent draft 请求；dock 已改变终端尺寸，截图仍覆盖旧几何。此外 Quick Input 的 shared presentation 更新无条件重发 sidebar/Inspector 的所有 @Published 属性；提前手动 resignFirstResponder 早于 native composer 接管，视觉选中还依赖 SwiftUI 临时 focus。 | 普通展开不创建截图；仅实际本地/远端外部编辑器握手建立短时截图，pane resize 立即失效。布局消费先比较 sidebar/Inspector 投影，Quick Input 不再发布无关几何。相同 workspace/presentation 不重复绑定。first responder 由 native composer 准备好后一次移交，split 高亮消费 Controller 的稳定 pane 选择。 |

没有添加额外固定等待、强制重绘或替代颜色层。保留原 fullscreen 目标先入组、旧组后移出和最终帧准备机制。

## 回归证据

新增 `TerminalWorkspacePresentationTests` 使用真实 NSWindow/NSHostingView：

- hosted workspace button 状态变化打开原生 popover；重绘/改名不重建弹窗内容。
- 可选桌面测试以真实 mouseDown/mouseUp 点击按钮，验证弹窗保持打开且只创建一次内容。
- 无按钮锚点时的键盘呈现与关闭。
- Quick Input 展开、pin、height 更新不发布 sidebar/Inspector geometry。
- vertical sidebar 折叠后无 workspace 替代 header。
- 普通 Quick Input 展开不向 Surface parent 添加截图覆盖层，也不提前取消 pane focus。
- 同一个 shared presentation 重绑定不发布变化。
- 首次 workspace 在 shell title 事件前具备目录显示。
- 已有 workspace 往返不发布 Terminal fallback。

`QuickInputDraftBridgeTests` 追加 pane resize 后截图立即移除，保留 deadline 清理测试。

`VerticalTabFullscreenTests` 追加正常与 sidebar 折叠状态下打开/关闭 workspace popover，以及 split 中 Quick Input 打开后的 native composer focus、关闭后的原 pane focus、无旧帧覆盖层和全屏保持。此套件需要解锁前台桌面，不能由 routine fixtures 替代。

运行记录（原始日志 `/tmp/omg-workspace-presentation-hVg4sa/`）：

- `baseline.log`：新增正确行为断言中，真实弹窗和 Quick Input 无关几何发布均失败；已有 workspace 稳定标题通过。
- `presentation-fixes.log`：弹窗、隐藏锚点、布局隔离和 sidebar 折叠通过；首次 workspace cwd/title 断言仍失败。
- `launch-metadata.log`：上述 6 项全部通过。
- `focused-regression.log`：70 tests / 7 suites 全部通过，覆盖 workspace、Quick Input、draft bridge。
- `routine-a.log`：第一批报告 559 tests / 65 suites，成功；其中 1 个 Benchmark 测试按仓库声明跳过，实际 558 tests 成功。
- `routine-b.log`：第二批 591 tests / 65 suites，589 成功、2 项时序断言失败：SSH Git provider 等待超时，以及 remote Pi scroll dispatch 约 278ms 超出动态阈值。workspace、Quick Input 相关套件全部通过。
- `regression-recheck.log`：隔离重跑 SSHGitExecutorTests 和滚动测试，12 tests 全部通过；滚动本地约 14ms、remote 16ms、remote Pi 12ms。两次广泛运行失败仍保留，未放宽断言或修改无关 SSH/Git 代码。常规范围共覆盖 129 个可执行 suite，Benchmark 另行跳过。
- `popover-click.log`：解锁前台桌面实际点击 workspace 按钮打开弹窗，1 test 通过；包含 transient popover 的完整 mouseDown/mouseUp 时序。
- `desktop.log`：解锁前台桌面上 QuickInputFooterMouseTests 通过；VerticalTabFullscreenTests 两个参数化测试（horizontal/vertical 共 4 场景）全部通过，包括本轮追加的 workspace popover、collapsed sidebar、Quick Input native focus 和无截图覆盖层断言。VerticalTabMouseTests 两项未通过：CGPreflightPostEventAccess=false；取消拖拽手势没有进入 CoreDrag。
- `drag-recheck.log` / `drag-diagnostic.log`：后者隔离复核仍失败，具体为 destination row -1（释放到 header、预期取消的手势）未使 drag pasteboard changeCount 变化；同次正常重排及后续点击断言没有失败。保留该独立桌面验证问题，不宣称拖拽全部通过。
- SwiftLint strict：13 个改动 Swift 文件零违规；文档契约通过；测试选择器 41 个 Python 测试通过。

## 验证边界

开始及调查期间 `CGSessionCopyCurrentDictionary` 返回 `CGSSessionScreenIsLocked=1`，前台为 loginwindow；后续桌面解锁，已实际完成 fullscreen/popover/Quick Input 焦点与 frame 断言。没有逐帧录屏或让用户确认主观闪烁；Quick Input 旧截图及焦点中间状态通过直接代码路径和结构断言消除。原生鼠标事件投递权限及取消拖拽手势验证仍未完成，不把 routine NSWindow 断言称为这些桌面行为已通过。

首次 workspace 的测试覆盖默认开启目录继承的路径。禁用继承时保持原配置语义；不能承诺在没有启动目录且 shell 尚未发任何标题的情况下凭空预知最终标题。没有对现有 workspace 的动态标题增加缓存或延迟隐藏。

本轮未安装、提交或发布。后续鼠标权限和取消拖拽验证可使用：

```sh
macos/build.nu --action test \
  --only-testing GhosttyTests/VerticalTabFullscreenTests,GhosttyTests/VerticalTabMouseTests,GhosttyTests/QuickInputFooterMouseTests \
  --include-desktop-tests
```
