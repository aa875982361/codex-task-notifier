# Codex Task Notifier

Codex 生命周期通知插件。每个主任务回合结束时，插件监听 `Stop` 事件，将最终结果以 JSON POST 到一个 Webhook URL。邮件等下游通知由服务器统一分发。

## 配置

只需要配置一个变量。推荐将变量放入插件运行环境中：

```bash
export CODEX_NOTIFY_WEBHOOK_URL='https://notify.example.com/notifications/v1/hooks/codex/your-token'
```

也可以使用配置脚本，将链接保存为本机私有配置。macOS/Linux：

```bash
sh scripts/configure.sh 'https://notify.example.com/notifications/v1/hooks/codex/your-token'
```

Windows PowerShell（无需安装 Python）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure.ps1 'https://notify.example.com/notifications/v1/hooks/codex/your-token'
```

Windows 上的 Stop Hook 使用系统自带的 Windows PowerShell 和 .NET；macOS/Linux 使用
POSIX `sh` 和 `curl`。所有平台的运行时和配置流程都不依赖 Python、Node 或 `jq`。
Codex 通过 `commandWindows` 自动选择 Windows 命令。macOS 系统自带 `curl`；精简版
Linux 若未包含 `curl`，需要由系统包管理器安装。

链接保存在 `~/.codex/codex-task-notifier.url`；macOS/Linux 配置脚本会将权限设为
`600`，Windows 文件位于当前用户的个人配置目录。环境变量
`CODEX_NOTIFY_WEBHOOK_URL` 优先级更高。事件类型由插件默认发送为
`codex.task.completed`，无需额外声明。配置值包含用户专属 Token，请勿公开分享。

该插件只负责本地 Hook 触发和 Webhook 投递，不保存 SMTP 配置，也不直接发送邮件。通知服务负责保存任务结果、邮箱验证和邮件订阅。

## Webhook 请求

新版插件在所有系统上都原样转发 Codex 提供的 Stop Hook JSON，以避免在缺少 JSON
运行时的客户端上使用不安全的文本解析。通知服务负责将它标准化为任务记录。旧版插件发送的
`codex.task.completed` 标准化结构仍由通知服务兼容。

```json
{
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "session_id": "session-id",
  "turn_id": "turn-id",
  "model": "model-name",
  "cwd": "/workspace/project",
  "last_assistant_message": "Codex 的最终回复"
}
```

请求头包含：

- `Content-Type: application/json; charset=utf-8`
- `X-Codex-Event: codex.task.completed`
- `X-Codex-Payload: hook-input`
- `User-Agent: codex-task-notifier/0.1.0`

服务器返回任意 `2xx` 状态即视为成功。插件默认最多尝试两次，每次超时 7 秒；通知失败不会改变 Codex 任务结果。

## 隐私

插件只发送 Codex 提供给 Stop Hook 的事件对象，其中包含事件元数据、工作目录和
`last_assistant_message`，不读取或发送完整会话转录。若 URL 包含 token，请勿提交
`~/.codex/codex-task-notifier.url`。

## 验证

```bash
python3 -m unittest discover -s tests -v  # 仅开发测试需要 Python
python3 ../../.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .
```

Windows PowerShell 可直接检查 Hook 脚本语法；完整自动化测试在开发环境使用 Python 3：

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\scripts\webhook_notify.ps1), [ref]$null, [ref]$errors) | Out-Null
if ($errors.Count) { $errors | Format-List; exit 1 }
```
