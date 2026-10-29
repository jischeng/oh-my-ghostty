# Workspace 核心重构实施记录 — 2026-10-29

基于 [workspace 审查](workspace-review-2026-10-29.md) 实施。用户要求整体重构，并重点保护曾多轮修复的全屏内容展示与切换。

## 实现边界

- `TerminalWorkspaceState` 是 committed ownership/order graph：logical window、workspace group、tab order/selection 和共享布局。隐藏成员不再由已经拆散的 NSWindowTabGroup 推导。
- `TerminalWorkspaceCoordinator` 接收 switch/move/delete/native group/close/undo，维护实例级 Controller registry。命令持有旧图和 draft，全体预检后执行 native plan，成功一次提交，失败补偿。
- `TerminalWorkspaceNativeAdapter` 集中 attach/show/park/publish。目标先加入现有全屏 stack，再移出旧成员；最终 membership/selection 一起发布，sidebar host、framebuffer 与 focus 最后收敛。fullscreen transition 期间排队最后一次切换，延迟 presentation 使用 generation。
- `TerminalWorkspaceSessionState` 是纯 Codable DTO，解析旧文件不创建 Surface。恢复校验完成后才通过原有 terminal archive instantiate。
- `TerminalWorkspaceSessionStore` + `TerminalWorkspaceSnapshotWriter` 以 `workspaces/state.json` v2 envelope 提交 catalog 和 session payload，后台串行编码、合并写入、0600 临时文件原子 rename；上一份完整有效 generation 保留为 `.previous`。旧 catalog/sessions 保留为迁移输入。
- Close Tab 只排除正在关闭的 Controller 对象；Undo 的同 ID 新对象可以重新 checkpoint。Close Window 继续保留 suspended records。
- workspace 布局更新同步到同 workspace 的各窗口；order/selection/scroll 仍属于窗口。Picker/Controller 接入采用所属 coordinator/store，保留审查前已有的 popover owner 改动。

保留完整 Ghostty App、Surface/PTY/runtime 生命周期、原生 fullscreen 和 sidebar host。没有改动插件 API、wire、权限或 Zig core；没有安装、提交或发布。

## 回归

新增 `TerminalWorkspaceRefactorTests`：

- 200 次跨窗口状态序列的不变量检查。
- Close→Undo→Checkpoint。
- 跨窗口删除保留可见窗口与 Surface 身份。
- 删除整体预检、show 失败后 native 顺序/选择/graph 回滚。
- 同 workspace 布局同步。
- 空闲重复 capture 不写文件。
- 旧版未知归属迁移、空 v1 不接管恢复。
- v2 明确清空仍保留窗口与偏好。
- 最新文件损坏回退备份；内部 payload 损坏不能覆盖有效备份。

已有 integration 测试保持行为断言，fixture 改为显式注入 runtime，避免在 shared store 注册后直接改 workspace 字段。checkpoint 不再替测试承担 native ownership reconcile。

## 全屏专项

`VerticalTabFullscreenTests` 在解锁前台测试进程上通过，覆盖 horizontal/vertical 两种布局：

- 新建、关闭原生全屏 tab。
- workspace 首次创建及切回。
- 目标多 tab + split，独立 sidebar preference。
- 6 次无等待快速往返，随后验证最终 focus/sidebar/Surface identity。
- IOSurface 尺寸与最终 layer 尺寸匹配。
- 移动最后一个 source tab，在现有 fullscreen stack 内创建 replacement。
- 删除 workspace 后仍为全屏，选择和窗口归属有效。

通过日志：`/tmp/omg-workspace-refactor-GJDOEc/fullscreen-foreground.log`；2 个参数化测试、4 个场景，约 24.2 秒。

后续最终复跑时桌面已锁定：`CGSSessionScreenIsLocked=1`、前台 `loginwindow`。`VerticalTabFullscreenTests` 与 `VerticalTabMouseTests` 在 active/key 前置条件失败，未执行行为断言。这些失败不能当作行为通过，也不能当作已复现产品回归。**最终 native mouse/drag 覆盖仍需在解锁前台桌面完成。** 后续 native 部分只增加窗口 frame/fullscreen 元数据捕获及 transition 完成时 presentation 收敛，完整全屏交接算法未撤换；最终记录仍应保留复核缺口。

```sh
macos/build.nu --action test \
  --only-testing GhosttyTests/VerticalTabFullscreenTests,GhosttyTests/VerticalTabMouseTests \
  --include-desktop-tests
```

## 广泛验证与限制

- Workspace 最终专项：**41 tests / 3 suites 全部通过**，14.690 秒，日志 `final-checkpoint.log`。包含追加的 v2/backup 边界。
- 常规 Swift 全量范围共 129 suite 条目，其中 BenchmarkTests 被仓库显式禁用。采用串行分批验证：57 个 suite 完成后在 InspectorTreeLayoutTests 的异步列表测试停滞；保留 2 秒 sample 并中止该轮，隔离重跑该 suite 的 4 tests 全过；其余 71 个 suite 条目运行成功（601 tests 报告包含禁用 benchmark 条目，实际 600 个成功 test 声明）。总计覆盖 128 个可执行常规 suite。
- 原始全量日志不是一次完整成功；分批完成结果分别为 `routine-all.log`、`inspector-stall-check.log`、`routine-remaining-71.log`。Inspector 单次挂起原因未定位；未为此修改无关 Git/Files 代码。
- 新增边界之后只重跑受影响 workspace 套件；没有因为注释/格式重复整套无关测试。
- SwiftLint strict 对 17 个改动 Swift 文件通过。
- 文档契约检查通过。
- Test selector Python 契约：41 tests 通过。
- 未进行真实网络 SSH 故障、kill 在每个写入点、磁盘断电、多显示器/Stage Manager 人工测试，不将模拟故障等同这些场景。

临时原始日志目录：`/tmp/omg-workspace-refactor-GJDOEc/`。本文件记录结果与缺口；临时日志不承诺长期保留。
