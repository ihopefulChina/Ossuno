# ossuno-mcp — 让 AI 直接操作你的阿里云 OSS

`ossuno-mcp` 是 Ossuno 项目提供、可独立使用的 MCP（Model Context Protocol）服务器。配置到 Codex、Claude Desktop、Claude Code、Cursor 等支持 MCP 的 AI 客户端后，AI 就能用自然语言完成常见的 OSS 操作：

- 「看看我有哪些 Bucket」
- 「把这个截图上传到 ossuno-assets 的 2026/08 文件夹」
- 「给最新的发布包生成一个 24 小时有效的下载链接」

服务器通过 stdio 与 AI 客户端通信（由客户端按需拉起，无需保持运行），OSS 凭证保存在 macOS 钥匙串中，与 Ossuno App 的账号相互独立。

## 工具

| 工具 | 说明 |
| --- | --- |
| `list_buckets` | 列出账号下所有 Bucket（名称、地域、创建时间） |
| `list_objects` | 浏览 Bucket 内的对象和子文件夹；返回截断标记与 `next_continuation_token`，下一页用 `continuation_token` 原样续查 |
| `upload_file` | 上传允许目录内的普通文件；默认拒绝覆盖，只有用户明确确认后才传 `overwrite=true` |
| `download_file` | 下载到允许目录；拒绝符号链接逃逸，本地已有同名文件时不覆盖 |
| `presign_url` | 为私有 Bucket 的对象生成带签名的临时下载链接（默认 1 小时） |

## 提示词

除了工具，服务器还内置 2 个提示词（Agent 说明），可在客户端的 Prompts 面板一键使用：

| 提示词 | 说明 |
| --- | --- |
| `ossuno-oss-expert` | 把 Agent 定位为阿里云 OSS 操作专家，附安全使用规则（先浏览再操作、删除需确认、私有桶自动给临时链接等） |
| `oss-batch-upload` | 批量上传工作流：确认目录 → 展示清单 → 逐个上传保留目录结构 → 汇总报告 |

服务器握手时还会下发 `instructions`（Agent 使用说明），Claude Desktop 等客户端会直接展示并用于约束 AI 行为。

## 安装

[`ossuno-mcp`](https://www.npmjs.com/package/ossuno-mcp) 已发布到 npm。需要 macOS 与 Node.js 18 或更高版本；`npx` 会按 Mac 架构下载 arm64 或 x64 预编译二进制。

### 第一步：配置凭证

```bash
npx ossuno-mcp auth
```

按提示填写地域、AccessKey ID / Secret（STS Token 可选）。凭证保存在当前用户的钥匙串，不会写入磁盘明文文件。支持多账号档案：

| 命令 | 作用 |
| --- | --- |
| `npx ossuno-mcp auth` | 交互式添加/更新配置档案 |
| `npx ossuno-mcp auth --list` | 列出所有配置档案（`●` 标记活动档案） |
| `npx ossuno-mcp auth --use <名称>` | 切换活动配置档案 |
| `npx ossuno-mcp auth --remove <名称>` | 删除配置档案 |
| `npx ossuno-mcp auth --test` | 验证当前凭证（调用 ListBuckets） |

前置条件：macOS 与 Node ≥ 18（`node -v` 检查；没有的话 `brew install node`）。

### 第二步：一键接入 AI 客户端

```bash
npx ossuno-mcp install
```

自动检测本机已安装的客户端（Claude Desktop、Claude Code、Cursor、Trae、Windsurf、Codex）并写入配置，重启客户端即可使用。支持：

```bash
npx ossuno-mcp install --client codex   # 只注册指定客户端（可重复传）
npx ossuno-mcp install --all            # 注册全部支持的客户端
npx ossuno-mcp install --dry-run        # 只预览将要写入的内容
npx ossuno-mcp uninstall                # 移除注册
```

通过 npx 运行时，写入客户端的是 `npx -y ossuno-mcp` 命令形式，不依赖缓存里的临时路径，重装、升级都不会失效。JSON 配置采用合并写入并保留 `.bak` 备份，不影响其他 MCP 服务器。

### 替代方案

- **全局安装**：`npm install -g ossuno-mcp` 后直接用 `ossuno-mcp auth` / `ossuno-mcp install`，客户端配置里写的是 PATH 上的 `ossuno-mcp`。
- **从源码构建**（开发者 / 无 Node 环境）：克隆仓库后 `cd Tools/ossuno-mcp && swift build -c release`，用 `.build/release/ossuno-mcp` 绝对路径运行。在 Terminal.app 中执行（IDE 内置终端可能有沙箱限制）。

## 手动配置（可选）

不想用一键安装时，可手动编辑各客户端配置。所有客户端使用相同的服务条目（npx 形式最省心）：

```json
{
  "mcpServers": {
    "ossuno": {
      "command": "npx",
      "args": ["-y", "ossuno-mcp"]
    }
  }
}
```

| 客户端 | 配置位置 | 说明 |
| --- | --- | --- |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers` 键，重启 App |
| Claude Code | `claude mcp add --scope user ossuno -- /absolute/path/to/ossuno-mcp` | 命令行注册 |
| Cursor | `~/.cursor/mcp.json` | `mcpServers` 键 |
| Trae | 设置 → MCP，或 `~/Library/Application Support/Trae/User/settings/mcp.json` | `mcpServers` 键 |
| Windsurf | `~/.windsurf/mcp.json` | `mcpServers` 键 |
| Codex | `~/.codex/config.toml` | TOML 格式：`[mcp_servers.ossuno]` + `command = "…"` |
| VS Code (Copilot) | 工作区 `.vscode/mcp.json` | 注意顶层键是 `servers` |
| Cline | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` | `mcpServers` 键 |
| Qoder | `~/.qoder/mcp.json` | `mcpServers` 键 |

## 默认 Bucket（可选）

日常主要用某一个 Bucket 时，可通过环境变量 `OSSUNO_MCP_DEFAULT_BUCKET` 设置默认值。设置后：

- 所有工具的 `bucket` 参数变为可选，AI 不传时自动使用默认 Bucket；
- 默认桶名会直接写进工具描述和服务器说明，任何 AI 客户端一连上就能看到，无需额外解释。

配置方式：在客户端的 MCP 服务条目里加 `env` 字段（各客户端通用）：

```json
{
  "mcpServers": {
    "ossuno": {
      "command": "npx",
      "args": ["-y", "ossuno-mcp"],
      "env": {
        "OSSUNO_MCP_DEFAULT_BUCKET": "prod"
      }
    }
  }
}
```

Codex 的 TOML 格式写法：

```toml
[mcp_servers.ossuno]
command = "npx"
args = ["-y", "ossuno-mcp"]

[mcp_servers.ossuno.env]
OSSUNO_MCP_DEFAULT_BUCKET = "prod"
```

Claude Code 命令行注册时用：

```bash
claude mcp add --scope user ossuno --env OSSUNO_MCP_DEFAULT_BUCKET=prod -- npx -y ossuno-mcp
```

修改后重启客户端生效。AI 仍可显式传 `bucket` 操作其他桶，两者不冲突。

## 本地文件访问范围

`upload_file` 和 `download_file` 不接受任意磁盘路径。默认只允许当前用户的桌面、文稿、下载目录和系统临时目录；路径必须是绝对路径，上传源必须是普通文件，且不能通过符号链接跳出允许范围。

需要访问项目目录时，在 MCP 服务的 `env` 中设置 `OSSUNO_MCP_ALLOWED_ROOTS`。可用冒号分隔多个绝对路径，或传 JSON 字符串数组：

```json
{
  "mcpServers": {
    "ossuno": {
      "command": "npx",
      "args": ["-y", "ossuno-mcp"],
      "env": {
        "OSSUNO_MCP_ALLOWED_ROOTS": "/Users/me/projects:/Users/me/Downloads"
      }
    }
  }
}
```

不要把 `/` 配成允许目录。修改环境变量后需要重启 AI 客户端。

## 安全说明

- AccessKey Secret 与 STS Token 只保存在 macOS 钥匙串，AI 客户端接触不到凭证本身。
- 建议使用权限最小化的 RAM 子账号，只授予需要的 Bucket 和动作。
- `ossuno-mcp` 的凭证与 Ossuno App 的账号完全独立，删除一边不影响另一边。
- 上传默认先调用 GetBucketVersioning，再检查远端对象并发送禁止覆盖请求头。版本状态查询失败，或 Bucket 处于 Enabled / Suspended 状态时会安全拒绝；只有用户明确确认替换后才允许传 `overwrite=true`。
- 本地文件工具只能访问允许目录，并拒绝符号链接逃逸。
- AI 只能执行上面 5 个工具覆盖的操作；创建 Bucket、改权限策略等控制台操作不在范围内。
- 大文件（GB 级）建议仍用 Ossuno App，分片上传与断点续传更完整。

默认安全上传至少需要 `oss:PutObject`、`oss:GetBucketVersioning`，以及用于 HEAD 存在性检查的 `oss:GetObject`。缺少任一读取权限都会 fail-closed；不要让 Agent 自动改用 `overwrite=true` 绕过检查。Ossuno App 的对象复制与版本恢复还会使用 `oss:GetObjectAcl`、`oss:GetObjectVersion` 等动作，但它与 `ossuno-mcp` 使用相互独立的账号和 RAM 策略。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| AI 提示「找不到配置档案」 | 先运行 `ossuno-mcp auth` 完成配置 |
| AI 提示连接失败 | 检查客户端配置里的二进制路径是否为绝对路径、文件是否有执行权限 |
| 上传报签名错误 | 运行 `ossuno-mcp auth --test` 验证凭证与地域是否匹配 |
| 想换账号 | `ossuno-mcp auth --use <名称>` 切换活动档案后重启 AI 客户端 |
| 重新编译后 AI 调用时弹钥匙串授权窗 | 二进制重新构建后签名发生变化，属正常现象，点一次「始终允许」即可 |
| 下载报「本地已存在同名文件」 | 这是不覆盖保护。让 AI 换一个保存路径，或先手动删除该文件 |
| 提示「拒绝访问允许目录之外的路径」 | 把目标放到桌面/文稿/下载目录，或配置 `OSSUNO_MCP_ALLOWED_ROOTS` 后重启客户端 |
| 上传提示无法确认版本状态或远端是否存在 | 当前 RAM 权限缺少 `oss:GetBucketVersioning` 或用于 HEAD 的 `oss:GetObject`；默认会安全拒绝。补齐最小读取权限，或仅在用户明确确认覆盖后使用 `overwrite=true` |

更多问题请到 [GitHub Issues](https://github.com/ihopefulChina/Ossuno/issues) 反馈。

## 维护者：发布 npm 包

npm 包是 Swift 服务器的薄启动器（位于 `Tools/ossuno-mcp/npm/`），平台二进制通过 optionalDependencies 按架构自动安装。发布流程：

```bash
cd Tools/ossuno-mcp
./npm/publish.sh <version>    # 例如 1.0.0
```

脚本会：构建 arm64 与 x86_64 双架构 release 二进制 → 同步三个包的版本号 → 依次发布 `ossuno-mcp-darwin-arm64`、`ossuno-mcp-darwin-x64`、`ossuno-mcp`。前置条件：`npm login` 已完成、Xcode 命令行工具可用。发布完成时，把 `npm/` 下 package.json 的版本变更提交进仓库。
