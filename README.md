# Codex Task Notifier

Codex 生命周期通知插件。每个主任务回合结束时，插件监听 `Stop` 事件，将最终结果以 JSON POST 到一个 Webhook URL。邮件等下游通知由服务器统一分发。

## 配置

只需要配置一个链接：

```bash
python3 scripts/configure.py 'https://notify.example.com/notifications/v1/hooks/codex/your-token'
```

链接保存在 `~/.codex/codex-task-notifier.url`，文件权限自动设置为 `600`。也可以通过环境变量 `CODEX_NOTIFY_WEBHOOK_URL` 临时覆盖。URL 中包含用户专属 Token，请勿公开分享。

该插件只负责本地 Hook 触发和 Webhook 投递，不保存 SMTP 配置，也不直接发送邮件。通知服务负责保存任务结果、邮箱验证和邮件订阅。

## Webhook 请求

```json
{
  "schema_version": "1",
  "event": "codex.task.completed",
  "occurred_at": "2026-07-29T21:00:00+08:00",
  "task": {
    "session_id": "session-id",
    "turn_id": "turn-id",
    "model": "model-name",
    "project": "project-name",
    "cwd": "/workspace/project",
    "result": "Codex 的最终回复"
  }
}
```

请求头包含：

- `Content-Type: application/json; charset=utf-8`
- `X-Codex-Event: codex.task.completed`
- `User-Agent: codex-task-notifier/0.1.0`

服务器返回任意 `2xx` 状态即视为成功。插件默认最多尝试两次，每次超时 7 秒；通知失败不会改变 Codex 任务结果。

## 隐私

插件只发送事件元数据、工作目录和 `last_assistant_message`，不读取或发送完整会话转录。若 URL 包含 token，请勿提交 `~/.codex/codex-task-notifier.url`。

## 验证

```bash
python3 -m unittest discover -s tests -v
python3 ../../.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .
```
