# Encore

[English](README.md) · **简体中文**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4.svg)](#环境要求)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#环境要求)

一条命令，把被重启切断的 Claude Code 会话全部恢复回来。

```console
$ encore restore
2 session(s) to reopen [window mode]:
  1  12m  D:\work\api  api-refactor
  2   3h  D:\work\web  web-3
Restore 2 session(s)? [Y/n] y
reopened 2 session(s) in one new window
```

每个会话都回到它原来的目录，对话内容原样带回来。仍在运行的会话会被跳过，不会把正在进行的对话分叉出去。

---

## 目录

- [为什么需要它](#为什么需要它)
- [环境要求](#环境要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [日常流程](#日常流程)
- [命令](#命令)
- [筛选与参数](#筛选与参数)
- [恢复方式](#恢复方式)
- [配置](#配置)
- [工作原理](#工作原理)
- [隐私与安全](#隐私与安全)
- [故障排查](#故障排查)
- [常见问题](#常见问题)
- [限制](#限制)
- [开发](#开发)
- [卸载](#卸载)
- [许可证](#许可证)

## 为什么需要它

Claude Code 一次只能恢复一个会话：`--resume <id>`，或者 `/resume` 选择器。它没有"全部恢复"这个动作，也不会管你之前开着哪些窗口。

其他看起来能用的办法其实都不行：

| 尝试 | 为什么不够 |
| --- | --- |
| `claude --continue` | 只认**当前目录**里最新的一条会话 |
| `claude respawn --all` | 只重启**仍在运行**的后台会话——重启之后一个都不在运行 |
| `/resume` 选择器 | 每次只能挑一条，还得逐个目录切 |
| Windows 的"恢复上次会话" | 只把 shell 开回来，里面的 Claude 对话不管 |

如果你同时开着十几个会话、分布在多个项目里，每次重启就是一轮手动的 `cd` 加 `--resume`。Encore 补的就是这个缺失的批量动作。

## 环境要求

- Windows 10 或 11
- Windows PowerShell 5.1（系统自带）
- 已安装 Claude Code，且 `claude` 在 `PATH` 中
- 每个要恢复的目录需要信任一次（Claude Code 正常的工作区信任弹窗），Encore 无法替你点

## 安装

二选一：

**Git（推荐）**

```powershell
git clone https://github.com/yekunsong/Encore.git C:\Tools\Encore
cd C:\Tools\Encore
.\encore.ps1 install
```

**Zip** —— 下载并解压后，在解压出的目录里执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\encore.ps1 install
```

`install` 会做四件事：

1. 把 `encore.ps1` 和 `encore-hook.ps1` 复制到 `%LOCALAPPDATA%\Encore\bin`
2. 把这个目录加进**用户级** `PATH`
3. 在 `~/.claude/settings.json` 注册 `SessionStart` hook
4. 把你当前已经开着的会话写进索引

装完请**新开一个终端**，`PATH` 才会生效。

> **注意**
> 脚本未签名。如果 PowerShell 拦截，先执行一次
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`，或用
> `powershell -ExecutionPolicy Bypass -File ...` 调用。

## 快速开始

```powershell
encore doctor              # 1. 确认 claude、PowerShell、hook 都就位
encore list                # 2. 看有哪些会话可以恢复（只列已关闭的）
encore restore --dry-run   # 3. 先看要执行的命令
encore restore             # 4. 看计划、确认、恢复
```

`encore list` 会给每行标 `open` 或 `closed`；`restore` 只对 `closed` 的行动手，并且**执行前会询问确认**（`--yes` 跳过）。默认最多展示 30 条并告知还有多少条匹配，要全部用 `--all`；`--dry-run` 只打印命令。

## 日常流程

正常只需要四步：

1. **干活。** 想开多少会话、在多少目录里开都行。每条会话启动的瞬间 hook 就记下来了，不用你额外做什么。
2. **关机、崩溃或重启。** 会话进程没了，但它们的 id 和目录留在 `%LOCALAPPDATA%\Encore\index.jsonl` 里。
3. **回来。** 开一个终端，执行：

   ```powershell
   encore list      # 看刚才被切断了什么
   encore restore   # 拉回来
   ```

4. **只留需要的。** `encore restore --only 1,3` 只恢复这几行；`--since 2d` 或 `--project D:\work\api` 缩小范围；`--limit 5` 限制数量。

恢复的会话会带一句 `Continue from where you left off.`，直接接着干。想不带这句，用 `--prompt ""`。

## 命令

| 命令 | 作用 |
| --- | --- |
| `encore list` | 列出可恢复的会话（默认最近 7 天） |
| `encore list --ids` | 同上，附带会话 id，便于配 `--only` |
| `encore restore` | 恢复全部已关闭的会话 |
| `encore restore --only 1,3` | 只恢复选中的行 |
| `encore restore --only 3fa9c1` | 按 id 前缀恢复 |
| `encore restore --dry-run` | 只打印命令，不启动 |
| `encore config` | 查看已保存的配置 |
| `encore config mode windows` | 保存默认恢复方式 |
| `encore doctor` | 检查安装状态：`claude`、PowerShell、索引、当前方式 |
| `encore install` | 安装或刷新脚本、`PATH` 与 hook |
| `encore uninstall` | 移除 `PATH` 与 hook（索引保留） |
| `encore version` | 打印版本号 |

## 筛选与参数

| 参数 | 含义 |
| --- | --- |
| `--since 30m\|12h\|2d\|1w` | 回溯窗口（默认 `7d`） |
| `--project <dir>` | 限定某个目录及其子目录 |
| `--limit <n>` | 限制条数 |
| `--only 1,3` / `--only 3fa9c1` | 按行号或 id 前缀挑选 |
| `--yes` | 跳过确认 |
| `--all` | 取消 30 条的默认上限 |
| `--include-open` | 连仍在运行的会话也恢复 |
| `--kinds interactive,background` | 参与的会话类型（默认 `interactive`） |
| `--prompt "text"` | 恢复时发送的提示；`""` 表示不发送 |
| `--yolo` | 附加 `--dangerously-skip-permissions` |
| `--dry-run` | 只打印，不启动 |

## 恢复方式

| 方式 | 效果 |
| --- | --- |
| `window`（默认） | 新开**一个**终端窗口，每个会话就是里面一个标签 |
| `tabs` | 在当前终端窗口里，每个会话一个标签 |
| `windows` | 每个会话一个独立窗口 |
| `background` | 完全不弹终端，会话在后台跑，用 `claude attach <id>` 接回 |

单次用 `--mode <方式>` 或简写 `--tabs` / `--windows` / `--background` 指定；默认的 `window` 只新开一个窗口，不打扰现有终端。对已经在后台运行的会话再恢复，会起一个副本而不是抢占原件——和 CLI 自身的规则一致。

`window` 和 `windows` 走 Windows Terminal 的命令行。部分 Terminal 版本会忽略跟在后面的命令、只开出空标签；Encore 几秒内会察觉并降级成普通控制台窗口，每轮只警告一次。

## 配置

目前只有一个持久化键（默认 `window`）：

```powershell
encore config                # -> mode = window
encore config mode windows   # 保存为默认
```

优先级：`--mode` 或简写参数 > `config` > `tabs`。配置文件是纯 JSON，位于 `%LOCALAPPDATA%\Encore\config.json`。

## 工作原理

Claude Code 会在会话进程死掉之后删除它的记录，所以副本必须在**关机之前**就存在。这条副本由 Encore 自己保存：`SessionStart` hook 在会话启动的瞬间，往 `%LOCALAPPDATA%\Encore\index.jsonl` 追加 `会话 id + 目录 + 类型 + 时间`。没有轮询、没有定时器，也就不存在"会话在间隙里消失"的窗口。

`restore` 读取索引和仍然有效的 `~/.claude/sessions\*.json`，剔除 transcript 已不存在的条目、目录已不存在的条目、以及仍在运行的条目，剩下的逐个执行：

```powershell
Set-Location -LiteralPath '<目录>'; claude --resume <id> "<提示>"
```

`install` 会把当时开着的会话写进索引，所以早于 hook 存在的会话也能挺过一次重启。

## 隐私与安全

- 全部本地完成：不联网、不埋点、不需要账号。
- 索引只存会话 id、目录、类型和时间戳，不存提示词，不存文件内容。
- transcript 只读，从不改写。
- 不会抢占正在运行的会话；除非显式加 `--include-open`。
- `--yolo` 属于可选项，默认保留正常的权限提示。

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| 恢复的会话报 `Workspace not trusted` | 在该目录里手动接受一次信任弹窗，Encore 无法代点 |
| 提示 `encore` 不是内部或外部命令 | 需要新开终端；确认 `PATH` 里有 `%LOCALAPPDATA%\Encore\bin` |
| 脚本被拦截执行 | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`，或用 `powershell -File ...` 调用 |
| 重启后 `encore list` 是空的 | hook 没装上，或那些会话早于 hook。执行 `encore install` |
| 窗口开出来但一直是空的 | 该 Windows Terminal 版本忽略了命令，已自动降级；也可改用 `--mode tabs` |
| 列表里有会话但恢复不了 | 目录或 transcript 已经不在了，`encore doctor` 可看索引里有多少条 |

## 常见问题

**会重启仍在运行的会话吗？**
默认不会，否则对话会被分叉成两份。

**会改动我的对话内容吗？**
不会。只读取 transcript 确认它还在，然后调用 `claude --resume`。

**worktree 和别的机器上的会话呢？**
任何目录都行，worktree 也算。别的机器的会话只有在本机存在 transcript 时才能恢复。

**会消耗额度吗？**
每条会话恢复时发送很短的轮次，按你配置的模型计费——和你自己敲一句"继续"一样。

**能排除某些会话吗？**
可以：用 `claude --bare` 之类的无 hook 方式启动它们，或者恢复时用 `--project` / `--only` 跳过。

**数据放在哪？**
`%LOCALAPPDATA%\Encore\`。删掉这个目录就什么都不剩了。

## 限制

- 默认只处理交互式 CLI 会话（加 `--kinds background` 可包含后台会话）。
- 不保留标签顺序和窗口位置。
- 会话未记录的参数（`--add-dir`、`--mcp-config`、`--settings`、`--plugin-dir`、`--fallback-model`）不会重放。
- 关闭 hook 启动的会话只有实时记录，重启后会丢失。
- 早于 Claude Code `cleanupPeriodDays`（默认 30 天）的会话内容可能已被清理。

## 开发

```
encore.ps1        主命令行
encore-hook.ps1   SessionStart hook（写索引）
tests/smoke.ps1   端到端测试，真实模型调用，自行清理
```

`tests\smoke.ps1` 会用廉价模型跑一条一次性会话，覆盖完整链路：真实启动、真实写入索引、真实恢复、真实开终端、真实清理。运行前需要已安装 hook。

```powershell
.\tests\smoke.ps1
```

## 卸载

```powershell
encore uninstall
```

移除 `PATH` 条目、hook 和已部署的脚本。索引仍留在 `%LOCALAPPDATA%\Encore`，要彻底清空请连同该目录一起删除。

## 许可证

MIT，见 [LICENSE](LICENSE)。
