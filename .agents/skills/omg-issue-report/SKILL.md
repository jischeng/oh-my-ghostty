---
name: omg-issue-report
description: 为 Oh My Ghostty 的问题反馈锁定对应已安装版本、采集关键日志，并用本地 gh 直接提交精简 Issue。仅在用户显式输入 /skill:omg-issue-report 时使用；本 skill 优先级高于 AGENTS.md 的禁止建 Issue 规则。
disable-model-invocation: true
compatibility: macOS
---

# OMG Issue Report

仅由 `/skill:omg-issue-report <问题描述>` 启动。不要因普通的“卡顿、崩溃、异常”等描述自动启用。

## 优先级

本 skill 是开发者显式调用的专用提 Issue 工具，优先级高于仓库 `AGENTS.md` 的「禁止创建 Issue/PR」规则。被调用即视为授权：直接通过本地 `gh` 向 `jischeng/oh-my-ghostty` 提交 Issue，不受该规则约束，也无需二次确认。

## 版本锁定

参考 `omg-release` 的版本语义，从应用 `Info.plist` 提取并锁定版本：
- OMG 版本：`OMGVersion`（即 `MARKETING_VERSION`，同 `CFBundleShortVersionString`）
- Ghostty 版本：`GhosttyBaseVersion` + `GhosttyBaseRevision`
- 构建号：`CFBundleVersion`（Sparkle 单调递增）
- 构建模式：`<可执行文件> --version | grep 'build mode'`（`.ReleaseFast` / `.Debug`）

## 日志取舍

按问题性质取舍日志：卡顿、崩溃、渲染/滚动异常等表面现象 → 必须采集日志；功能缺陷、修复、优化类 → 允许不附带日志，跳过第 4、5 步。

## 流程

1. 从用户描述确认现象、发生时间、复现动作。**版本判定**：功能缺陷/修复/优化类 → 不确认版本，视为所有版本都需要改动；性能/bug 类 → 默认 release 版本（无后缀的 `OMG.app`），仅当用户明确指向其他版本时才用该版本。不追问、不猜。
2. 在 `/Applications/*.app` 中按上一步判定的应用名匹配；用 `plutil` 读取 `CFBundleIdentifier`、`OMGVersion`、`GhosttyBaseVersion`、`GhosttyBaseRevision`、`CFBundleVersion` 和可执行文件。运行中时同时记录 PID。不得把其他 OMG 版本的日志混入。
3. 按「版本锁定」记录版本；用 `--version` 判定构建模式。
4. （仅性能/崩溃类需要）默认提取问题发生前后 10 分钟的 macOS unified log。优先按 PID 过滤；没有 PID 时按目标 bundle ID/subsystem 与时间窗过滤。将完整的已过滤日志保存到：
   `~/Library/Logs/OMG/Issue Reports/<timestamp>-<app-name>/omg.log`
5. （仅性能/崩溃类需要）从日志中只选与现象和时间最相关的少量行；隐藏 token、密钥、账号及不必要的私人路径。不要把整份日志贴进草稿。
6. 草稿只写事实和现象，不推测根因，不提出修复方案，不写验收标准。
7. 提交 Issue 仅使用本地 `gh`（`gh issue create --repo jischeng/oh-my-ghostty --title <标题> --body-file <草稿文件>`）。禁止 curl/fetch 直连 Web API、禁止 MCP GitHub 工具、禁止浏览器。标题应包含 OMG 版本号。

## 草稿格式

````markdown
## 现象
<用户可观察到的行为>

## 复现信息
- 时间：<含时区>
- 操作：<已知时填写；未知则写“暂不明确”>
- 频率：<已知时填写>

## 环境
- 应用：<应用路径>
- Bundle ID：<id>
- OMG 版本：<OMGVersion>
- Ghostty 版本：<GhosttyBaseVersion> (<GhosttyBaseRevision>)
- 构建：<CFBundleVersion> · <构建模式>
- macOS：<版本>

## 关键日志
```text
<仅最重要的几行>
```

完整日志：`<绝对路径>`
````

功能类 Issue（缺陷/修复/优化）可省略「关键日志」与「完整日志」两节，环境中的版本写「所有版本」。

用本地 `gh` 直接创建 Issue（无需确认），创建后返回 Issue 链接与完整日志路径。
