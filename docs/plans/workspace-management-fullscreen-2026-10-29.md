# 工作区管理交互与全屏创建修复 — 2026-10-29

基线 `4752da37f`。用户提供工作区弹窗截图，要求优化新建/编辑/删除/移动，并报告全屏创建无响应、退出全屏后恢复。

## 已确认根因

1. **非原生全屏被当成“不支持工作区”。** `NonNativeFullscreen.supportsTabs=false` 是 AppKit 的窗口能力限制；workspace adapter 的 `canApply()` 直接用它拒绝整个命令。旧 UI 先 `store.create`，再 `switchWorkspace`，失败没有处理，因此表现为新增 label，但没有终端、没有反馈。
2. **测试只覆盖了一种全屏。** 新增从真实 popover 点击 New、在 native text field 输入、点击 Save 的桌面基线：native fullscreen 通过；nonNative 稳定失败，`transition=[]`、`error=none`、created label 没有 Controller。基线日志 `fullscreen-modes-baseline.log`。
3. **非原生全屏进入的异步回调没有取消。** 快速 enter→exit 后，旧 callback 仍把普通窗口 frame 改成屏幕尺寸；新测试 `immediateExitCancelsDeferredBorderlessEntryGeometry` 修复前失败。工作区交接会更频繁触发这类时序。
4. **管理目标不清。** 旧弹窗高亮行与当前 workspace 不同，编辑/删除却只能作用当前项；移动隐藏在二级 Menu。失败关闭后只 beep 或直接没有反馈。
5. **测试隔离依赖加载时机。** shared store/session 用 `NSClassFromString("XCTestCase")` 判断，AppDelegate 早期初始化时测试 bundle 可能尚未加载。用户 Dev catalog 确实存在多个 Fullscreen test / Window inheritance 名称（只统计元数据，没有导出终端状态）；未擅自删除。新测试计划显式设置启动环境，避免再依赖类加载时机。

## 实现

- `TerminalWorkspacePickerModel` 持有明确 page、编辑/删除 ID、表单、错误和执行状态，独立于 transient popover 的销毁。
- `TerminalWorkspacePicker`：顶部 New；每行 … 管理该项；当前状态与高亮选择分别展示；tab count 限定当前窗口；Move Tab 为可搜索目标页；Delete 为内联确认，显示实际 fallback 名称、所有窗口 tab count；创建名称、图标、颜色即时预览，同名给出提示；Esc/Back 返回，Return 提交。
- 原生 popover 关闭后恢复明确 owning window 的焦点再运行命令。pending action 在关闭重入中不被空 close 覆盖；错误重新打开原表单并显示原因。
- `createWorkspace` 生成新 workspace 放入 draft，同一次 native transaction 完成创建与选择；成功才 commit catalog，失败回滚，不遗留空 label。
- Native adapter 不再一概拒绝非原生 fullscreen。在 screen-update transaction 内 exit 旧 borderless mode、组装目标 native tabs、再将目标选中 tab 进入相同 mode；失败恢复旧目标。全程保留 Controller/Surface/PTY。
- 非原生全屏选中窗口会脱离 NSWindowTabGroup，sidebar/数字快捷键/goto-tab 因此消费 committed logical group；退出 full screen 重新组装 native group。frame/fullscreen 采样只读逻辑组 selected tab，避免后台 singleton 覆盖。
- `Window.fullscreenMode` 为可选向后兼容字段；恢复时使用记录模式，旧 bool-only 数据按 native 恢复。
- native fullscreen transition 以实际 NSWindow identity 为键，记录开始时 host；结束/关闭清理；只处理所属 coordinator 的窗口。
- `NonNativeFullscreen.transitionGeneration` 使已经退出/被下一操作替代的 entry callback 失效。
- `OMG_TESTING=1` 写入 xctestplan，workspace singleton 在 AppDelegate 初始化前即知道不读写用户目录；显式 session fixtures 使用临时路径。既有用户 catalog 不变。

## 验证

- 初始 workspace 回归：56 tests / 5 suites 通过。
- 新管理模型、页面、非原生多 tab 测试：8 tests 通过。
- 多 tab 非原生全屏：创建、5 次无等待工作区往返、组内 tab 选择、退出重组、Surface identity / 图校验通过。
- 旧 entry callback 测试修复前失败、修复后通过。
- 最终 workspace 回归：58 tests / 5 suites，29.302 秒通过。
- native adapter owner 隔离补强后，管理与集成 targeted 回归 30 tests / 2 suites 全部通过，22.761 秒，记录于 `adapter-final.log`。
- 广泛常规第一批 576 tests / 66 suites 条目成功（包括仓库显式禁用 benchmark 条目）。第二批 582 tests / 65 suites 有 2 项时序失败：cold link callback 未及时完成、title timer 序列不全；隔离重跑 7 tests 全过，原结果保留。
- SwiftLint strict 对 14 个改动 Swift 文件零违规，docs contract、selector Python 41 tests 通过（新增 desktop suite 已登记）。
- 新 UI 的 switcher/create/move/delete 在真实 NSHostingView 渲染并检查 bounded size，带背景截图位于 `/tmp/omg-workspace-management-{switcher,create,move,delete}.png`。

原始测试日志：`/tmp/omg-workspace-management-4vqzF4/`。

## 待完成的桌面边界

修复前真实 popover 基线在解锁桌面复现了 nonNative 失败；修复后的第一轮 desktop 运行遇到系统锁屏，active/key 前置条件失败，未进入新操作断言。后续宿主 nonNative tests 可以验证状态与原生调用，但不能代替可见 fullscreen Space 中完整 UI 的最终验收。

需解锁前台桌面运行：

```sh
macos/build.nu --action test \
  --only-testing GhosttyTests/TerminalWorkspaceManagementDesktopTests,GhosttyTests/VerticalTabFullscreenTests \
  --include-desktop-tests
```

不声称最终桌面验收已完成。未安装、提交或发布；未清理用户真实工作区。
