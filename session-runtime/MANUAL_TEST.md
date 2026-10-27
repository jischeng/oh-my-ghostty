# 原生会话人工验证（macOS，本地传输）

本轮测试仅验证原生 daemon/GUI 链路。SSH 尚未实现，不能据此验收远程保活。
使用仓库刚构建的 Debug App；它和 OMG Dev 共用开发设置。先退出已有的
Debug / OMG Dev 实例，正式 `/Applications/OMG.app` 可以保持运行。
不要在测试中恢复多窗口工作区；每个实验窗口都会连接同一个 session。

## 1. 启动 daemon

在系统 Terminal 等独立终端中执行，并保持该终端打开：

```sh
cd /Users/chengjisheng/code/test/oh-my-ghostty
mkdir -p /tmp/omg-session-manual
chmod 700 /tmp/omg-session-manual
cargo build --manifest-path session-runtime/Cargo.toml
session-runtime/target/debug/omg-sessiond serve /tmp/omg-session-manual/session.sock -- /bin/zsh -l
```

它在前台运行、没有输出是正常的。若报 socket 已存在，先确认旧测试 daemon
已经退出，再删除该测试 socket；不要删除仍在运行的 daemon 的 socket。
不要从正在测试的 OMG 窗口启动 daemon，否则关闭父终端会干扰测试。

## 2. 启动实验窗口

另开一个系统 Terminal 窗口执行：

```sh
cd /Users/chengjisheng/code/test/oh-my-ghostty
OMG_EXPERIMENTAL_SESSION_SOCKET=/tmp/omg-session-manual/session.sock \
  macos/build/Debug/OMG.app/Contents/MacOS/omg \
  --window-save-state=never --quit-after-last-window-closed=true
```

只保留一个实验窗口。若已有开发实例，先退出，再执行上面的命令，避免环境变量
只进入新进程而没有进入实际显示窗口的旧实例。不要将变量写进 shell 全局配置。

## 3. 先测普通进程

在实验窗口中执行：

```sh
printf 'shell PID=%s\n' $$
python3 -u -c 'import os,time; print("worker PID=",os.getpid()); exec("while True:\n print(time.strftime(\"%H:%M:%S\"), flush=True)\n time.sleep(1)")'
```

记录 PID 和时间。退出实验 App（Cmd-Q），等待 10–20 秒，再执行第 2 步。
预期：看到更新后的输出，并且 Ctrl-C 能停止原来的计时进程；随后 `echo $$`
仍是原 shell PID。若要从外部核实 worker，可执行 `ps -p <worker PID> -o pid,etime,command`。

检查：中文、emoji、输入法、复制/选择/滚动、连续缩放窗口、重连后继续输入。
失败时记录操作顺序、黑屏/错位截图以及启动 App 的终端日志。

## 4. 再测真实 Agent TUI

在同一个实验 shell 中直接执行 `codex` 或 `pi`（按本机安装情况选择），无需包装。
给它一个无破坏性的任务，例如阅读一个临时测试目录并生成说明。
在任务运行期间退出实验 App，等待，再按第 2 步打开。
预期：显示当前 TUI、原进程还在、能继续输入，且不会重复启动 Agent。

再测试全屏程序：例如 `vim` 打开临时文件，切换模式、缩放、退出 App、重新连接，
检查内容、光标和方向键。不要用重要工作目录作为首轮测试对象。

## 5. 多窗口仅测试只读观察

第二个窗口会成为 observer，不能输入或 resize 远端会话。首个 writer 关闭后，
已有 observer 暂不自动取得控制权；关闭并重新打开它才能重新申请。
当前没有 UI 控制权指示，所以首轮建议只用一个窗口。

## 6. 正常结束

先退出 Agent，然后在实验 shell 中执行 `exit`。daemon 应退出并删除 socket。
关闭实验 App。若只关闭 GUI，daemon/Agent 会继续运行，这是预期行为。
强制杀 daemon、重启主机不保活；不要将其作为 SSH 断线的等价测试。

## 当前限制

- 无 SSH、多会话列表、自动重连、GUI CloseSession、控制权转交 UI。
- socket 写入暂时是有超时的阻塞操作，故障时可能有短暂卡顿；失败后断开，需手动重连。
- 部分终端能力、剪贴板与通知策略尚未完成；发现 Agent TUI 问题应记录。
- 二进制快照仅支持同一 checkout 的 daemon 与 App，不支持在线升级互通。
- 已通过自动化 PTY/快照测试和构建；真实窗口/TUI 正确性正是此次人工验收内容。
