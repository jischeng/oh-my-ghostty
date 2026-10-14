---
name: omg-issue-report
description: 为 Oh My Ghostty 锁定实际受影响版本、采集有界日志并用本地 gh 提交精简 Issue。仅在用户显式输入 /skill:omg-issue-report 时执行；公共规范见 docs/REPORTING.md。
disable-model-invocation: true
compatibility: macOS
---

# OMG Issue Report

本 skill 是公共报告规范的执行辅助。先阅读仓库中的
[Reporting problems](../../../docs/REPORTING.md)；贡献规则见
[Contributing to OMG](../../../docs/CONTRIBUTING.md)。不要另建与文档冲突的规则。

## 启动与授权

仅由 `/skill:omg-issue-report <问题描述>` 启动。普通故障描述、排查、讨论或
“写一份草稿”不触发本 skill，也不构成发布授权。

按维护者既有约定，显式调用即授权通过本地 `gh` 直接向
`jischeng/oh-my-ghostty` 提交一次精简 Issue，无需二次确认。这一窄授权记录在
`AGENTS.md` 和公共报告文档中；skill 本身不能提升自己的指令优先级，也不能
绕过适用的更高优先级规则。它不授权发 PR、合并、推送、向上游提交、上传完整日志，
或擅自关闭/重启/替换现有 OMG/OMG Dev。

## 版本锁定与证据

- 默认排查 release `OMG.app`；用户明确指定 OMG Dev 或其他构建时只用该构建。
  无法确认目标或版本时标明未知，不把不同版本/PID 的日志合并。
- 从实际应用 `Info.plist` 提取 `CFBundleIdentifier`、`OMGVersion` /
  `CFBundleShortVersionString`、`CFBundleVersion`、`GhosttyBaseVersion`、
  `GhosttyBaseRevision` 和可执行文件名；运行中时记录该实例 PID。
- 如可用，以对应 `Contents/MacOS/omg --version` 输出确认 build mode；不要启动 GUI
  来猜测版本，不以 checkout 当前版本代替已安装版本。
- 新功能/工作流建议可以不采集版本和日志，适用范围写“不限定版本”。现有功能 bug
  仍尽量锁定版本；没有证据不要写“所有版本都存在问题”。
- 对卡顿、崩溃、渲染/滚动等事件，在权限允许时采集有界 macOS unified log：
  优先按目标 PID，否则按 bundle/subsystem；已知时间默认前后各 10 分钟，未知时先看
  最近 10 分钟并明确说明。权限拒绝或证据缺失必须报告，不绕过权限或静默提权。
- 完整的已过滤日志仅保存到
  `~/Library/Logs/OMG/Issue Reports/<timestamp>-<app-name>/omg.log`，目录 `0700`、
  文件 `0600`。Issue 仅包含最相关的少量脱敏行；完整日志路径只私下返回给用户。
- 隐藏 token、密钥、账号、主机地址、私人仓库及不必要的个人路径；截图也要检查。
  不上传整个日志、环境、配置或 Quick Input 历史，不默认读取 Agent 私人会话。

## 流程

1. 从描述提取现象、发生时间/时区、操作与频率；未知就写未知，不编造复现。
2. 搜索已有 OMG Issue（含已关闭），避免重复；已有同一问题时先告知用户并保留草稿，
   不把“创建一次 Issue”的授权扩展成擅自评论或另发上游报告。
3. 按上面的版本/证据流程锁定目标，保存必要的本地证据。
4. 编写短草稿：只陈述事实与观察，不将假设写成根因，不替维护者制定修复方案或验收标准。
   用户的功能建议可记录其期望效果，并明确它是请求而非已验证故障。末尾注明由 OMG Issue
   Report helper 在用户显式请求下辅助整理，不虚称未发生的人类审阅。
5. 脱敏并核对仓库/版本/事实。显式调用已授权提交，不追加无必要的确认步骤。
6. 仅用本地 CLI 提交：

   ```bash
   gh issue create --repo jischeng/oh-my-ghostty --title '<标题>' --body-file '<草稿文件>'
   ```

   不用 curl/fetch 直连 Web API、MCP GitHub 或浏览器来替代本 helper 的提交方式。
   标题使用 `[OMG <已核实版本或 version unknown>] <现象>`；功能建议可写
   `[Feature] <期望工作流>`。
7. 返回 Issue URL，以及本地草稿/完整日志位置（若有）。提交失败则保留草稿并报告失败，
   不换工具、仓库或身份重试发布。

## 草稿格式

````markdown
## 现象
期望：<用户期望>
实际：<可观察行为>

## 复现信息
- 时间/时区：<已知时填写>
- 操作：<已知时填写；否则“暂不明确”>
- 频率：<已知时填写>

## 环境
- 应用：<OMG.app / OMG Dev.app / source build>
- Bundle ID：<id 或未知>
- OMG 版本/构建号：<已核实值或未知>
- Ghostty 版本/修订：<已核实值或未知>
- 构建模式：<已核实值或未知>
- macOS / 架构：<已核实值或未知>

## 关键证据
```text
<仅相关且脱敏的少量行；无日志时明确未取得>
```
````

功能建议可以用“工作流 / 当前困难 / 期望效果”，省略不适用的环境/日志项。
公共 Issue 不填写私人完整日志绝对路径；本地路径单独返回给调用者。
