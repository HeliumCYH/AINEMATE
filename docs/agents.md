# Agent 接入

两类通道：**拉取**（读 agent 自己留下的日志，零安装）和**推送**（发送方写 actor 文件）。审批需要反向通道，所以必须推送。

## Qoder CN（拉取 + hook）

读 `~/.qoder-cn/logs/sessions/<project>/<session>/segments/<run-id>-p<pid>.jsonl`，只用最近 15 分钟内写过的最新一段。`AIMATE_QODER_LOGS` 可覆盖根目录。

认得的、会刷新状态的事件：

| 事件 | 含义 |
| --- | --- |
| `input.prompt.submitted` | 标题；子 agent / meta 会话忽略 |
| `turn.started`、`model.request.started`、`tool.shell.started` | 工作中 |
| `tool.requested` | 工作中，detail = 正在调用 X |
| `tool.execution.finished`（denied） | detail = X 被拒绝 |
| `permission.requested` / `permission.resolved` | 等待你 / 继续 |
| `fork.agent.started`（compact） | 正在压缩上下文 |
| `turn.finished` | `end_turn`→待检查（带用时）、`max_turns`→等待你、`error`→出错了、其它→空闲 |

其余事件（phase、hook、token）只读不认，不延长寿命。run id 末尾的 `-p<pid>` 是 worker 进程号：进程没了这条行就消失，Qoder 重启换段时 pid 跟着换。

Qoder 每轮结束会另起一个隐藏的 Recap 会话，状态同样是 `review`，优先级会盖住还在跑的主会话；适配器按首条 prompt 前缀（「你正在为 Qoder 任务监控编写简短的会话 Recap」）把它整条过滤掉。Qoder 换文案时过滤失效，行为退回「多一条待检查」。

**审批**：在 Qoder 的 PermissionRequest hook 里调 `pet-cli hook qoder-permission`，它读 stdin、在桌宠卡片上等按钮、把决定打印成 Qoder 期望的 JSON。超时或桌宠没在跑就放行到 Qoder 自己的确认框，不会卡住 agent。

## Codex（拉取）

读 `${CODEX_HOME:-~/.codex}/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`，桌面版和 CLI 写的是同一棵树。`task_started` / `user_message` 进工作中，`task_complete` 进待检查，token 计数之类的记录不续命。没有任何 hook 需要安装。

## OpenCode（拉取 + bridge）

读 `~/.local/share/opencode/opencode.db`（只读打开）。2.2 之后的库用 `session_message` / `session_part`：

- 最新消息是 assistant 且写着 `time.completed`：先保持「正在回复」15 秒（工具可能在回复之后才跑），之后转「待检查 · 已完成，用时 X」
- 出现 `idle` 行：这一轮真正结束，同样是「待检查」
- 工具调用内联在消息里，状态未终结 → 工作中
- abort → 空闲；error → 出错了

**审批**：`pet-cli bridge opencode` 常驻，把 OpenCode 的待批准请求转发到桌宠卡片，再把点击结果通过 OpenCode 的本地服务 API 写回。它依赖 OpenCode 正在跑且有 `~/.local/share/opencode` 下的服务信息。

已知问题：强杀桌宠时 bridge 会变成孤儿常驻进程，下一次启动会因为端口/服务被占而退避 60 秒；换新 build 前先 `pkill -f "pet-cli bridge opencode"`。

## DeepSeek Harness（推送，未验证）

`integrations/dsh-aimate/` 是 dsh 的进程内插件，把 turn / tool / error 投影成 actor 转发，并有 presence claim 让同一个会话不被文件通道重复渲染。仓库里还有一个兜底读取器。**这套还没在真实 dsh 上跑通**，接入前先当作实验代码。

## pet-cli

任何一个能执行命令的地方都能驱动桌宠：

```bash
pet-cli push running --title "重构桌宠" --detail "swift build"
pet-cli push waiting --id build --ttl 300 --options 允许,拒绝 --title "放行 rm 吗？"
pet-cli ask --source opencode --id ses_123 --options 允许,拒绝 --wait 300
pet-cli reply --id ses_123 --timeout 120     # 阻塞直到用户点了按钮
pet-cli list                                  # 打印当前活着的 actor
pet-cli clear --id build
```

`push` 写完即退，不会挂住调用方；`ask` / `reply` 会阻塞，适合放在 hook 里。桌宠没在跑时 `ask` 会立刻返回失败码，让调用方回落到自己的交互，而不是让用户等一个看不见的超时。
