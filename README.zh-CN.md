<p align="center">
  <img src="images/omg/omg-app-icon-1024.png" alt="Oh My Ghostty 应用图标" width="112">
</p>

<h1 align="center">Oh My Ghostty · OMG</h1>

<p align="center">
  基于 Ghostty，为 AI Agent 工作流扩展的 macOS 终端。
  <br>
  在一个原生窗口中处理 Agent、输入草稿、文件与 Git 上下文。
</p>

<p align="center">
  <a href="https://github.com/jischeng/oh-my-ghostty/releases/latest">下载</a>
  · <a href="README.md">English</a>
  · <a href="docs/REPORTING.md">报告问题</a>
  · <a href="docs/CONTRIBUTING.md">参与贡献</a>
</p>

<p align="center">
  <a href="https://github.com/jischeng/oh-my-ghostty/releases/latest"><img src="https://img.shields.io/github/v/release/jischeng/oh-my-ghostty?label=release" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13 或更高版本">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT 许可证"></a>
</p>

> OMG 是独立开发、仍在持续演进的 **Ghostty fork，尚未到 1.0**，不是 Ghostty 官方版本。
> 它有独立的应用身份，可以与 `Ghostty.app` 共存。公开版本提供 Apple Silicon 和 Intel 下载。

![OMG 垂直标签页与文件 Inspector](docs/images/right-inspector-files.png)

## 为什么做 OMG？

使用 Agent CLI 时，经常要在终端输出、长提示词、文件和仓库上下文之间切换。
OMG 保留 Ghostty 作为终端宿主，在外层增加原生工作流能力，而不是重写一个终端引擎，
也不是提供模型服务。

| 你想做什么 | OMG 提供什么 |
| --- | --- |
| 更方便地编写多行提示词 | **快速输入**：可调整高度的输入框，明确的发送与排队操作 |
| 复用提示词、连续输入 | **发送历史**：搜索、键盘选择、追加/覆盖，以及全局 Pin 固定 |
| 整理多个会话 | **垂直标签页**：分组、排序、可选的 Agent 活动状态；也保留原生横向标签页 |
| 查看当前工作区 | **文件 Inspector 与编辑器**：包括实时 Markdown 预览 |
| 在会话旁边检查仓库 | **Git Inspector**：查看状态、diff 和历史 |
| 处理远程工作区 | **SSH 文件浏览与端口转发**：使用 OpenSSH 配置及系统工具 |

Codex、Claude Code、Pi 等 Agent CLI 需要自行安装。可选的 Agent 集成用于提供活动/会话
上下文，各 Agent 的能力不完全相同。OMG 不提供模型订阅，也不取代你的 Agent CLI。

## 下载与安装

需要 **macOS 13 或更高版本**。在
[最新 GitHub Release](https://github.com/jischeng/oh-my-ghostty/releases/latest)
中选择 DMG：

| Mac 类型 | 下载文件 |
| --- | --- |
| Apple Silicon | `OMG-<version>-macos-arm64.dmg` |
| Intel | `OMG-<version>-macos-x86_64.dmg` |
| 两种架构通用 | `OMG-<version>-macos-universal.dmg` |

1. 打开 DMG，将 **OMG.app** 拖入 Applications。
2. 启动 OMG；它不会替换官方 Ghostty。
3. 如果 macOS 首次启动时拦截，请先检查警告；**确认信任下载来源后**，在
   **系统设置 → 隐私与安全性**中允许打开。

**签名说明：**公开版本使用固定的**自签名身份**，**没有 Apple notarization**，
也不是 Developer ID 签名应用。不要为了运行 OMG 全局关闭 Gatekeeper。
Release 附带 `SHA256SUMS.txt`；详情见[发版规范](docs/RELEASING.md)。

卸载时移除 `OMG.app` 即可；这不会自动删除设置、会话数据或历史。
如需删除发送历史，可先在设置中清空；存储位置和其他配置见
[配置说明](docs/settings/configuration.md)。

## 第一次体验 Agent 工作流

1. 在终端中启动常用 shell 或已安装的 Agent CLI。
2. 按 **⌘⇧E** 打开快速输入，编写提示词。**⌘↩** 发送，**⌥⌘↩** 排队。
   自动出队依赖消息所属 Agent 会话的归一化完成信号，不是通用 shell 命令调度器。
3. 按 **⌘⇧H** 或点击时钟图标打开发送历史：**↑/↓** 选择，直接输入文字搜索，
   **Enter** 回填。选择历史不会自动发送。
4. 点击 **Pin**，发送/排队后继续保持输入框展开。主动 Esc 仍可关闭；
   展开/关闭和 Pin 在 OMG 的标签页与窗口间共享。
5. 在 **设置 → 编辑器 → 快速输入**调整历史范围、追加/覆盖、过期时间和退出保留。
   Agent hook 的安装是可选且明确触发的，入口在 **设置 → Agent 集成**。

| 快捷键 | 操作 |
| --- | --- |
| ⌘⇧E | 展开/收起快速输入，可自定义 |
| ⌘↩ | 发送草稿；编辑排队消息时保存修改 |
| ⌥⌘↩ | 草稿排队；编辑排队消息时移到队尾 |
| ⌘⇧H | 打开/关闭历史，重开保留选择与搜索状态 |
| ↑ / ↓ | 浏览历史；输入框内首次到边界后需两次独立按键确认切换 |
| Esc | 关闭输入框；历史弹窗中先退出搜索，再关闭弹窗 |

只浏览历史时，会保留最新未发送草稿及光标；修改回填内容后，它成为新草稿，
原发送记录不变。输入法、焦点、排队与持久化的完整行为见
[快速输入配置与操作说明](docs/settings/configuration.md)。

## 隐私与当前边界

- **发送历史默认以本机明文保存**，可能包含私人提示词、代码或凭据。
  默认当前 Tab 可见、7 天过期、退出后保留；可以调整设置或清空历史。
- 存储有上限，但已关闭 Pane 的记录仍可能保留到过期。
  关闭退出保留会删除磁盘副本，不会立即清空当前进程内的历史。
- Agent CLI、模型服务和远程服务器有各自的数据与网络行为。
  历史保存在本机，不意味着整个工作流都离线。
- **OMG 新增应用能力目前面向 macOS**；仓库继承了跨平台 Ghostty 源码，
  不代表已经提供相同功能的 OMG Linux/Windows 版本。
- 内建 typed provider 是宿主功能；**尚未提供公开的第三方可执行插件加载器/SDK**。
  已实现与计划中的边界见[插件开发说明](docs/PLUGIN_DEVELOPMENT.md)。
- 这是持续开发的 0.x 项目，不承诺零 Bug 或稳定的公开扩展 API。
  请结合[发版说明](https://github.com/jischeng/oh-my-ghostty/releases)与
  [已报告问题](https://github.com/jischeng/oh-my-ghostty/issues)了解现状。

## 反馈与贡献

欢迎中文或英文反馈。OMG 有**独立的社区入口**，参与这里不需要先通过 Ghostty 的上游担保流程。

- [报告规范](docs/REPORTING.md)：复现信息、版本识别、证据脱敏，以及可选的 Agent 辅助报告。
- [创建 OMG Issue](https://github.com/jischeng/oh-my-ghostty/issues/new/choose)：问题或工作流建议；
  不要把仅在 OMG 中出现的问题直接交给 Ghostty 上游。
- [贡献规范](docs/CONTRIBUTING.md)：小范围补丁、构建测试、文档同步、AI 辅助披露与 PR 要求。
- 安全问题按[报告规范](docs/REPORTING.md)中的保密流程处理，不要在普通公开 Issue 中放入利用细节。

## 从源码构建

需要 Xcode、Zig 0.16.0、Nushell 与 SwiftLint。**干净 checkout 先构建 GhosttyKit**，
具体步骤见[贡献规范](docs/CONTRIBUTING.md)。然后执行：

```bash
macos/build.nu --configuration Debug --action build
macos/build.nu --action test --test-modules quick-input
```

Debug 产物为 `macos/build/Debug/OMG.app`，内部 Xcode scheme/Swift module 仍名为 `Ghostty`。
本地安装使用 **OMG Dev**，它拥有独立身份与可变数据存储；不要用测试版覆盖用户的正式 OMG。
当前 Swift 测试 target 需要 macOS 15.5+；测试选择与可选的前台桌面验证见
[测试规范](docs/TESTING.md)。

## 架构与上游

OMG 保留完整的 Ghostty macOS 宿主，优先把新增功能放在 fork-owned 文件中，
将上游改动限制为小型适配点。OMG 发版版本与 Ghostty base 版本/修订独立记录。
详细约束见[架构说明](docs/oh-my-ghostty-architecture.md)和[发版规范](docs/RELEASING.md)。

Ghostty 由 Mitchell Hashimoto 与贡献者创建。感谢
[Ghostty 上游](https://github.com/ghostty-org/ghostty)；本 fork 保留原版权、许可和归属，
不隶属于官方项目，也没有暗示官方背书。继承的终端配置可参考
[Ghostty 文档](https://ghostty.org/docs)。

## 许可证

[MIT](LICENSE)。分发副本或软件的重要部分时，需保留 Ghostty 版权声明与许可条款。
