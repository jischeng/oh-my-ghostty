# Oh My Ghostty 插件与原生扩展架构

- 状态：已采纳，进入实施
- 日期：2026-08-21
- 范围：macOS 首批功能；共享 Zig 核心仅在没有可靠上层接入点时修改

## 1. 最终裁决

首批 Sidebar、Agent 状态提醒和 Pi 集成全部使用 SwiftUI/AppKit 原生渲染。首批不链接、不初始化 WKWebView，也不引入前端框架。

WebView 不是首批架构依赖。它只可能在第三方生态开放后作为按插件启用、按插件懒加载、默认关闭的可选 UI 后端返回。

以下核心方向维持不变：

- 插件逻辑运行在 Ghostty UI 进程之外。
- macOS 宿主与插件通过 Unix domain socket 通信。
- Ghostty API 按能力授权，写能力默认拒绝。
- 改动集中在 fork 自有目录和稳定接入点，降低跟随 upstream 的冲突。
- Sidebar、状态插件和 Pi 按独立功能交付，共享同一协议与进程监管底座。

## 2. 仓库事实

当前仓库已具备以下可复用链路：

- 每个 `Ghostty.SurfaceView` 都有 UUID，可作为运行期和恢复后的 surface 标识。
- OSC 标题最终更新 `SurfaceView.title`，聚焦 surface 的标题再进入 `NSWindow.title`。
- OSC 9;4 已在 Zig 核心解析，并作为 `progressReport` 到达 macOS `SurfaceView`。
- `Ghostty.Surface.foregroundPID` 已通过公开 C API 读取 PTY 前台进程组 PID。
- `SplitTree<Ghostty.SurfaceView>` 已表达单个 tab 内的 pane/split 树。
- `Ghostty.Surface.sendText` 已能向 PTY 输入端发送文本，但它是控制能力，不是终端显示注入能力。

这些事实降低了原生实现成本，但不等于已有完整插件事件总线。

## 3. 术语与标识

协议中的 `session` 明确定义为一个 terminal surface/pane，对应 `SurfaceView.id`。它不是 AppKit tab，也不是 window。

- Session ID：`SurfaceView.id`，UUID。
- Tab：一个 `BaseTerminalController` 管理的窗口/标签，内部可以包含多个 session。
- 聚焦 session：决定当前 tab 标题和大部分快捷操作的 surface。
- Vertical tab item：一个 `TerminalController`/`NSWindow` tab，与 `NSWindowTabGroup.windows` 1:1；split/session 不额外生成 tab 行。

首版不承诺 ID 跨设备或跨一次被删除后重新创建的 session 保持不变。

## 4. 进程模型与传输

### 4.1 进程拓扑

宿主为每个已启用插件启动一个受监管子进程。首版不把多个插件装入同一个共享进程，避免一个插件崩溃拖垮其他插件。

首版只允许随应用签名和发布的官方插件。第三方可执行代码必须等到系统沙箱、签名校验、安装与升级策略完成后开放。

独立进程只提供故障隔离，不自动提供安全沙箱。Ghostty 能力授权可以阻止未授权 IPC 调用，但无法单独阻止一个普通子进程读取用户文件或访问网络。

### 4.2 Socket

- 每次 Ghostty 启动创建私有运行目录，目录权限为 `0700`。
- 每个插件使用独立 socket，socket 权限为 `0600`。
- 路径和一次性随机 nonce 只通过子进程环境传递。
- 宿主校验连接方 UID、预期 PID 和握手 nonce；未知连接立即关闭。
- wire format 是 4 字节网络字节序长度加 UTF-8 JSON payload。
- 单帧上限 1 MiB。队列必须有界；慢消费者不能阻塞 UI 或 terminal I/O。
- 握手协商协议版本和能力。版本不兼容时拒绝启动，不做猜测性降级。

### 4.3 生命周期

宿主负责启动、握手超时、心跳、退出检测、有限次数退避重启和禁用。插件断开时，宿主立即撤销该连接的状态 lease、订阅和待处理控制请求。

## 5. API 边界

### 5.1 Terminal Event API

稳定首版事件：

- session opened/closed
- title changed
- OSC 9;4 progress changed
- foreground process changed
- focus changed

前台 PID 当前是读取接口，不是推送源。首版由宿主低频采样，仅在值变化时发事件；应用不活跃或 session 不可见时降低采样频率。

原始 terminal output 不属于稳定首版。它需要修改高吞吐路径，并必须先解决背压、敏感输入、密码模式、日志留存和每插件授权。未来若实现，能力名为实验性的 `rawTerminalOutput`，默认拒绝，丢弃策略优先于阻塞 terminal。

状态识别优先级：

1. Agent/CLI 显式结构化事件或适配器。
2. OSC 9;4 进度事件。
3. 前台进程和生命周期信号。
4. 明确授权后的实验性输出识别。

通用输出启发式不能承诺准确识别“等待用户”。

### 5.2 Declarative Native UI API

稳定首批能力：

- `setSessionStatus`
- `clearSessionStatus`
- Sidebar 只读数据模型
- QuickInput 的展示请求和提交结果

`setSessionStatus` 以 plugin/session/revision 为所有权键。revision 必须单调递增。状态在插件断开、session 关闭、显式清除或 TTL 到期时撤销，防止崩溃后留下陈旧 UI。

首版只授予一个官方状态插件可见状态写 lease。未来多来源状态进入 Sidebar 前再定义仲裁规则，不把“最后写入者获胜”固化为稳定行为。

标题渲染只组合宿主拥有的数据：agent、原始/用户覆盖标题、状态。它不访问私有 `NSTabButton`。有 split 时，垂直 tab 行只显示该 tab 聚焦 session 的标题与状态。

### 5.3 Terminal Control API

该 API 是实验能力，首版只授予官方 Pi 集成。所有 PTY 写请求必须：

- 绑定目标 session 和插件身份。
- 展示完整或可检查的待写内容。
- 每次由用户确认，不能以“本次会话允许”绕过。
- 确认时再次校验 session 仍存在且仍是预期目标。
- 写入审计日志，记录时间、插件、session、摘要、长度和结果；默认不持久化密钥或完整敏感文本。
- 在 secure input/password input 状态拒绝自动发起。

`sendText` 是 PTY 输入，不是终端显示输出。首版不增加绕过 PTY、直接喂 terminal parser 的“伪输出”API。

## 6. 首发功能

### 6.1 Agent 状态提醒

官方状态插件将 Codex、Claude Code 和 Pi 的原生 hook/extension 事件归一为 `idle`、`working`、`needsAttention`、`done`、`error`。事件使用 `omg-agent-<tool>-<process-group-id>` 的 bounded OSC 3008 presentation context，由 agent 所在 TTY 接收，因此 Local 和 SSH Pane 使用同一 Surface correlation；hook 可附带经过白名单校验的 `omg_conversation`，用于精确恢复。部分 agent 版本会延迟或不发送 `SessionStart`，因此 macOS Host 每秒只读取一次 Ghostty 已有的 foreground process-group PID；仅当 PID 改变时，才在 utility queue 执行一次 `ps`，识别本地 `codex`/`claude`/`pi` 并合成 `idle`。唯一实例 ID 阻止旧 session 的 `end` 清理新 session；Local 启动有 4 秒 foreground handoff grace，之后以 process-group 存活性清理异常退出。SSH 不做本地 process-name fallback，而在下一个 authenticated remote Fish prompt 到达时清理异常残留；远端不依赖 OMG executable。

Vertical Tabs 保留唯一 Tab icon slot，并按整个 Tab 的所有 split 聚合状态：`needsAttention > error > working > done > idle`，同优先级优先 focused Surface。Agent 启动时 OpenAI/Claude/Pi template glyph 替换 terminal/cloud；idle 不显示 ring，working 使用旋转的四分之一圆 progress indicator；等待审批、完成和失败继续使用右侧 status slot。用户选中已完成 Tab 时，`done` acknowledge 为 `idle`，提醒立即消失但 agent identity 保留。Agent context 结束后恢复 canonical terminal/cloud icon。Horizontal Tabs 保持 Ghostty 原生 presentation，不注入自定义状态 UI。Hook 只能改变展示状态，不获得 Terminal Control、文件系统或网络能力。

Settings 显式安装/移除用户级 hooks，使用 versioned owner marker 合并 Codex/Claude 配置并保留同 entry 的其他命令，Pi 使用可审计 TypeScript extension。SSH 上可导出 Python 3 installer，由用户审阅、传输并在 agent 实际运行的远端账户显式执行；本地 App 不登录或静默修改远端 dotfiles。

每个内建 Agent 由 bundle manifest 声明 command、icon、process markers、hook dialect/events/identity fields 和 resume/store 机制。Host 只实现固定机制，manifest 不能携带任意代码。Terminal restoration v9 在每个 Surface 上保存 typed `AgentResumeDescriptor`；默认开启的 `sessions.restoreOnLaunch` 让 AppKit 恢复原有 window/tab/split tree，并对退出 OMG 时仍运行的 Agent 使用 exact conversation ID。Local 只生成 allowlisted resume argv；SSH 只重放 original OpenSSH argv、cwd 和 typed agent/session options。Agent 已 `/quit` 回 shell 时 descriptor 被清除，下次只恢复 shell。

### 6.2 Tab Layout

Vertical Tabs 不是独立 Sidebar 产品，而是 Ghostty tab bar 的另一种 orientation。`macos-tab-layout` 支持：

- `horizontal`：使用 Ghostty 原有 window nib、titlebar style 和 native horizontal tab UI。
- `vertical`（默认）：同一 `NSWindowTabGroup.windows` tab model 由左侧 vertical tab bar 呈现，native horizontal accessory 在加入窗口层级之前被拒绝。

两种 layout 共享 `TerminalController`/`NSWindowTabGroup` 的新建、关闭、选择、恢复、顺序、标题和快捷键路径。Vertical presentation 消费统一的 title/shortcut/icon/selected/hovered metadata；插件未来只能提供可选 icon/metadata override，不能控制 tab bar view。split 继续由 terminal 内容区管理，不生成额外 tab 行。

Layout 配置只对新窗口生效。运行时更换 orientation 需要替换 NSWindow class/titlebar hierarchy，当前不安全，因此不会重建已有 PTY、surface 或 scrollback。

### 6.3 Pi

Pi 不依赖 Sidebar 或状态插件，但依赖 IPC、QuickInput 和 Terminal Control。

首版采用 Pi CLI 适配：QuickInput 收集内容，用户确认后写入目标 PTY，由 CLI 自己产生正常 PTY 输出。这样不需要终端伪输出通道，也不让 Ghostty 持有 Pi API key。

后续若改为插件直接调用模型 API，必须先选择并实现以下一种凭据方案：

- 独立、受信任且签名的 HTTP/credential broker 持有 Keychain 密钥，插件只调用受限模型 API；或
- 插件本身被定义为受信任组件并可读取专属 Keychain item，同时明确放弃“插件不可见密钥”的约束。

任意插件直接发模型请求却永远看不到所用 bearer key 在进程安全模型上不可实现。

### 6.4 SSH Pane 与 OMG CLI

每个 split 都拥有独立 PTY 和独立 SSH child，不能共享另一个 Pane 的 OpenSSH 进程。SSH Pane 的“复用”定义为复用原始 launch descriptor，而不是复制 resolved IP 或向终端模拟键盘输入。

`omg +ssh` 在最终 OpenSSH child 存活期间保存 owner-only、短生命周期的 exact argv descriptor。源 Pane 执行 split 时，`TerminalController` 以当前 connection ID 读取 descriptor，并通过 `SurfaceConfiguration.command` 启动新的 `omg +ssh`；ready remote cwd 作为独立、shell-quoted wrapper option 传入，使新 Fish session 从相同目录开始。因此 `ssh cloud` 继续由 OpenSSH 读取 alias、ProxyJump 和 IdentityFile；`ssh -J jump user@host` 则原样重放参数。child 结束后 descriptor 删除，超过 24 小时的残留 descriptor 拒绝使用。

OMG 不另造第二个 CLI binary。现有 app executable `omg` 是统一 CLI 入口，Ghostty upstream actions 继续使用 `+ssh` 等兼容形式。后续面向用户的 `omg pane split`、`omg config get/set` 应建立在经过认证的 app IPC 上；在此之前，SSH split replay 是宿主内部 launch handoff，不是可由插件调用的 Terminal Control API。

## 7. 权限模型

首版能力：

- `terminalEvents`
- `sessionStatus`
- `sidebarModel`
- `inspectorPane`
- `quickInput`
- `terminalControl`
- `rawTerminalOutput`（实验，默认拒绝）

能力由 manifest 声明、宿主静态 allowlist 和握手结果三者取交集。插件不能在运行期自行扩大权限。高风险能力升级需要重新确认并重启插件。

首版官方插件仍按最小权限授权。官方身份不是授予全部能力的理由。

## 8. 上游同步策略

- 新代码优先放在 `macos/Sources/Features/Plugins` 和对应测试目录。
- 与 `AppDelegate`、`BaseTerminalController`、`SurfaceView` 的改动保持为小型适配点。
- 首发不修改 renderer，不访问私有 tab view，不引入 WKWebView。
- 只有实现事件所必需时才修改 Zig/C 边界，并为新增 C API 增加 Zig 测试。
- 每次同步 upstream 后优先运行协议单测、macOS 构建和插件进程崩溃/重连测试。

## 9. 实施阶段与退出条件

### 阶段 0：协议与宿主底座

交付：版本化 wire contract、帧编解码、manifest/能力校验、每插件进程监管、私有 socket、握手和有界队列。

退出条件：拆包/粘包/超限/畸形消息测试通过；错误插件无法阻塞 UI；断开后资源和 lease 被清理。

### 阶段 1：状态提醒端到端

交付：session 事件桥、状态 lease/store、原生标题组合、官方状态插件。

退出条件：session 创建/关闭、插件崩溃、OSC 进度、PID 变化和 tab/split 聚焦切换均无陈旧状态；无外部插件时无额外子进程，内建 Agent Status 只保留 bounded foreground-PID 采样，PID 不变不得执行 `ps`。

### 阶段 2：Tab Layout

交付：默认启用以 AppKit tab group 为数据源的 vertical presentation，并保留 Ghostty 原生 horizontal tabs 作为显式可选 layout。

退出条件：两种 orientation 的新建、关闭、选择、重排、恢复和数字快捷键与 `NSWindowTabGroup` 一致；Vertical tab bar 的显隐/宽度不重建 surface、改变 tab 顺序或在切换 tab 时改变 terminal rows/columns。

### 阶段 3：QuickInput 与 Pi CLI

交付：原生 QuickInput、逐次确认、审计、官方 Pi CLI 插件/适配器。

退出条件：取消、目标消失、secure input、插件崩溃和大输入均采取拒绝优先策略；未经确认没有 PTY 字节写入。

### 阶段 4：凭据 broker（按需）

仅在需要插件直连模型服务时开始。完成前不把 API key 交给普通插件进程。

### 阶段 5：第三方与可选 WebView

先完成系统沙箱、签名、安装/升级/撤销和权限 UI。声明式 API 连续两个版本仍不能覆盖主要第三方 UI，或头部插件因表达力受限无法迁移时，才评估 WebView 后端。

## 10. 当前不做

- 私有 `NSTabButton` 图标或旋转动画。
- 原始输出稳定 API。
- 任意第三方可执行插件。
- 直接向 terminal parser 注入插件响应。
- 富文本 agent blocks。
- WebView 容器和前端运行时。

本文是首批实现的架构基线。改变安全边界、session 语义、终端写确认规则或首批渲染技术时，需要更新本文并记录原因。

## 11. 实施状态

截至 2026-08-21 已完成：

- v1 wire contract、长度帧编解码和单帧上限。
- 官方插件 manifest/nonce/版本/能力授权规则。
- session 状态消息路由、ACK、所有权、revision、TTL、断线和 session 删除清理。
- 状态到原生 tab/window 标题的组合链路。
- `macos-tab-layout = horizontal|vertical` orientation 配置，默认 vertical；Horizontal 继续使用 Ghostty 原实现。
- 两种 presentation 与 `NSWindowTabGroup.windows` 共享 tab model、lifecycle、title 和 `⌘1…⌘9` shortcut 解析。
- Vertical window 在 `addTitlebarAccessoryViewController` 入口拒绝 native tab accessory，使横向 strip 从不进入窗口层级；不使用异步或延迟隐藏。
- Vertical tab bar 直接使用聚焦 terminal 的实际背景色，hover/active 仅由共享前景语义低透明度叠层派生，自动适配配置主题和 OSC 动态背景。
- `GhosttyTabPresentation`、`GhosttyTabStyle` 和 `GhosttyTabIconProviding`；默认 icon provider 可被插件 metadata provider 覆盖。
- `NSWindowTabGroup` 关联的 window layout state：显隐、176-480pt 宽度和 last-width 持久化；新 window 从 last width 初始化，同组 tab 不拥有独立宽度。
- 1pt divider + 8pt native `NSView` mouse tracking/cursor rect；selected tab 使用约 60Hz 合并后的 live width，隐藏 tabs 保持 committed width，mouseUp 一次同步最终 width 到整个 tab group 且只在此时写 UserDefaults。
- `SurfaceScrollView` 只在 framebuffer size 实际改变时调用 `ghostty_surface_set_size`，避免 duplicate layout pass 重复触发 renderer resize；连续 resize 不 remove/add view，也不重建 Surface。
- titlebar accessory 根据 close/minimize/zoom button 的实际 window-space centerY 布局 Sidebar Toggle 与 New Tab controls，不依赖固定 y offset，适配 fullscreen 和 display scale 变化。
- Vertical organization menu 支持 No Grouping、By Project、By Date、Created Time 与 Recently Used；grouping/order 存在 `NSWindowTabGroup` 共享 layout state，last-used mode 通过 UserDefaults 持久化，collapsed group 只属于当前 window state。
- By Project 从 cwd 向上查找 `.git` repository root 并按 cwd 缓存结果，非 Git cwd 回退到目录名；group presentation 使用可扩展的 title/icon/id 模型，不执行 `git` 子进程。
- `NSWindowTabGroup.windows` 是唯一 canonical tab order。Ghostty `move_tab`、Vertical drag、Horizontal native UI、`goto_tab` 和 shortcut labels 都消费同一顺序；Created/Recently Used 会先重排 canonical windows，开始手动 drag 时 ordering 切换为 Manual。
- Vertical drag 使用稳定 tab session UUID payload 和 host-owned DropDelegate；同一 derived group 内允许 reorder，跨 project/date group 拒绝，drop 不移动 Surface/PTY ownership。
- 每个 `TerminalController` 拥有可恢复的 `tabSessionID`，新 PTY 注入 `OH_MY_GHOSTTY_SESSION`；cwd/title 只用于 project presentation，不用于 status correlation。
- 尺寸 HUD 根因是旧 tab presentation 在切换时改变 content frame（per-tab width 与 native accessory 进入/退出布局），进而改变 terminal rows/columns；修复后快速切换前后所有 surface dimensions 保持不变，不隐藏 HUD 本身。
- 将 OSC 9;4 progress 生命周期映射为 running/waiting/completed/failed wire 状态，再归一为 host-owned idle/working/done/needsAttention/error activity model。
- `~/.config/oh-my-ghostty/settings.json`、typed settings model、machine-readable schema 与原生 Settings Window；fork preference 不再散落在 UserDefaults，Ghostty config 仅作为未显式设置项的 fallback。
- Host-owned tab icon/metadata/activity presentation contracts；plugin 只能贡献已验证的数据，不能访问 SwiftUI/AppKit/PTY/renderer 对象。
- Core-owned `InspectorRegistry` / `RightInspectorHost`；Horizontal/Vertical 共用 `NSWindowTabGroup` layout state，`InspectorPresentationStore` 持久化 UI state，titlebar pane switch 按宽度稳定收纳到 `…` menu 并预留 Git/SSH 扩展；Plugin Inspector 仅贡献经过 owner validation 的 typed snapshot/action，`builtin.files` 按稳定 tab ID 跟随 live cwd，node-scoped 异步合并 subtree，保留 scroll/selection/expanded identity，并提供递归 tree 与 type-aware icons。
- 修复 AppKit appearance KVO 自激：effective appearance observer 不再反写 app/window appearance，Debug idle CPU 从 83–93% 恢复至约 0.5–1.0%。
- Ghostty baseline + OMG Appearance overlay resolution；theme/font/size/opacity/blur/cursor 通过 Ghostty live config update 应用，Reset 只移除 OMG override，不改写用户 Ghostty config。
- Vertical Tabs 和 Right Inspector 使用 renderer-derived background color/opacity；移除 terminal content 上方的 opaque SwiftUI fill，保持 glyph/cursor/icon opaque 并恢复 upstream transparency/blur semantics。
- Plugin capability audit 明确：codec/authorization/status store 是已测试组件，但 discovery、socket、peer credential、进程监管和真实 Agent adapter 尚未完成。

下一实施块：

- 私有运行目录、Unix socket server、peer UID/PID 校验和每插件进程监管。
- `ghostty +oh-my-config` / status CLI，共用 settings descriptor registry 与 `OH_MY_GHOSTTY_SESSION`。
- Terminal Event bridge 与有界发送队列。
- 将官方 Agent reducer 放入受监管子进程，并增加 agent 身份识别适配器。
- 多窗口 tab group 的恢复、拖出/合并与重排专项验证。

在上述下一实施块完成前，Agent reducer 已可测试但尚未作为独立插件进程自动运行。

Vertical Tabs 验证截图：

- `docs/images/horizontal-tabs-native.png`：显式 Horizontal 使用 Ghostty 原生 tab UI。
- `docs/images/vertical-tabs-hover-active.png`：Vertical 8 tabs，⌘8 active、⌘3 hover。
- `docs/images/vertical-tabs-hidden-toggle.png`：Sidebar 隐藏后 titlebar toggle 仍可见。
- `docs/images/vertical-tabs-light-theme.png`：Ghostty 浅色背景下 Sidebar 与 terminal 融合。
- `docs/images/vertical-tabs-groups.png`：By Project 的 compact group header、collapse state 与 canonical-index shortcuts。
- `docs/images/vertical-tabs-reordered.png`：Manual reorder 后 A,D,B,C 的 position-based shortcuts，active C identity 保持。
- `docs/images/vertical-tabs-groups-status.png`：Mock agent 的 plugin icon 与 host-owned working indicator。
- `docs/images/settings-tabs.png`：原生 Settings Window 的七个 category 与 typed Tabs controls。
- `docs/images/settings-appearance.png`：Dark Appearance 下的 Ghostty inherited values、OMG optional override、effective source 与 Reset to Ghostty。
- `docs/images/settings-appearance-light.png`：相同原生 Settings hierarchy 的 explicit Light Appearance 验证。
- `docs/images/appearance-transparency-vertical.png`：Vertical Sidebar 与 terminal content 在相同 58% Ghostty background alpha 下保持一致。
- `docs/images/appearance-transparency-horizontal.png`：相同 opacity/blur config 下的 Ghostty 原生 Horizontal 对照。
- `docs/images/right-inspector-files.png`：Core-owned Right Inspector Host 挂载 owner-scoped `builtin.files` typed content。
