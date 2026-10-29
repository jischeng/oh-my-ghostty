# Workspace review evidence

基线：`01bb5305d928` 加审查开始时已有的四个未提交文件。执行日期：2026-10-29。所有构建/测试串行运行；仅在构建期间并行做静态阅读。

## 既有回归

```sh
macos/build.nu --action test \
  --only-testing GhosttyTests/TerminalWorkspaceTests,GhosttyTests/TerminalWorkspaceIntegrationTests
```

```text
✔ Suite TerminalWorkspaceIntegrationTests passed after 13.227 seconds.
✔ Suite TerminalWorkspaceTests passed after 0.384 seconds.
✔ Test run with 29 tests in 2 suites passed after 13.612 seconds.
** TEST SUCCEEDED **
```

原始日志：`/tmp/omg-workspace-review-VLxrNa/workspace-tests.log`。

## 审查探针

源文件：[TerminalWorkspaceReviewTests.swift](TerminalWorkspaceReviewTests.swift)。执行时临时放在 `macos/Tests/Terminal/`，完成后移到本目录，避免让“断言缺陷存在”的测试成为正常回归要求。

首批命令：

```sh
macos/build.nu --action test --only-testing GhosttyTests/TerminalWorkspaceReviewTests
```

```text
REVIEW_PROBE undo: restoredAvailable=true, includedInCheckpoint=false
REVIEW_PROBE layout: persistedSidebarBefore=false, afterUnrelatedInspectorChange=true, firstWindowSidebar=false, secondWindowSidebar=true
REVIEW_PROBE delete: otherHostVisible=false, fallbackParked=true, fallbackVisible=false
REVIEW_PROBE parkedMove: sourceTabsBefore=2, after=0, remainingTabAvailable=true, sameGroup=true
REVIEW_PROBE emptySnapshot: ownsRestoration=true
✔ Test run with 5 tests in 1 suite passed after 0.726 seconds.
** TEST SUCCEEDED **
```

追加故障边界探针：

```sh
macos/build.nu --action test --only-testing \
'GhosttyTests/TerminalWorkspaceReviewTests/deletingWorkspaceCanFailAfterMovingSomeTabs(),GhosttyTests/TerminalWorkspaceReviewTests/mismatchedCatalogAndSessionGenerationsRestoreUnknownWorkspace()'
```

```text
REVIEW_PROBE partialDelete: result=false, labelStillExists=true, tabsAlreadyMoved=1
REVIEW_PROBE writeSkew: restoredWorkspaceKnown=false, displayFallsBackToDefault=true, unknownGroupPersisted=true
✔ Test run with 2 tests in 1 suite passed after 0.308 seconds.
** TEST SUCCEEDED **
```

空闲 checkpoint 探针先确认文件变化，再补充内层 JSON 语义及 inode 比较复核：

```sh
macos/build.nu --action test --only-testing \
'GhosttyTests/TerminalWorkspaceReviewTests/unchangedCapturesCanRewriteWholeCheckpoint()'
```

```text
REVIEW_PROBE idleCapture: changedBytes=10/10, changedOuterJSON=10/10, changedSemantics=0/10, replacedFiles=10/10, elapsedMs=3.854990005493164
✔ Test run with 1 test in 1 suite passed after 0.159 seconds.
** TEST SUCCEEDED **
```

`changedOuterJSON` 仍比较作为 base64 字符串存储的内部 state；`changedSemantics` 进一步解码每个 tab 的 state 才比较对象。后者为零，因此不能把字节变化归因为有效会话数据变化。inode 每次变化说明实际执行了原子文件替换。

原始日志在同一临时目录：

- `review-probes.log`
- `review-failure-boundaries.log`
- `review-idle-capture.log`（初次确认）
- `review-idle-semantics.log`（语义复核）

## 解释与限制

- Probe assertions intentionally describe broken behavior. Passing probes are evidence of defects, not successful acceptance tests.
- Undo 探针使用真实 UndoState 构造器并验证 checkpoint，未驱动 Undo 菜单或真实重启。
- 跨 generation 探针构造相互不一致的 catalog/session 输入；未对运行中应用做强杀。
- `.disallowed` 注入真实 move 前提失败，未注入 Objective-C exception。
- 空快照只实测 restoration ownership；AppKit suppression 与新终端 fallback 由源代码调用链验证。
- 现有 routine 测试会建立真实 NSWindow fixture，但不替代前台 native fullscreen、拖拽或 Spaces 验证。
- 测试日志中的系统 XPC/WindowManager 诊断没有导致测试失败；本文缺陷依据为明确状态断言和代码路径，不依据这些系统日志。
- 没有读取、导出或强杀用户的真实终端/SSH/Agent 会话，没有安装构建产物。
