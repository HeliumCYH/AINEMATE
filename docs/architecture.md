# 架构

一只桌宠只认一件事：`~/.aimate/pet/actors/*.json`。谁写文件谁就能驱动它，app 不关心发送方是谁，也不需要发送方活着。

## actor 文件契约

一个文件 = 一个会话。文件名由 id 清洗得到（`:`、`/` 等换成 `-`），所以同一个会话永远覆盖自己那份。

```json
{
  "id": "qoder:89e60c0e",
  "source": "qoder",
  "state": "running",
  "title": "重构桌宠的视线逻辑",
  "detail": "正在调用 Bash",
  "thread": "89e60c0e",
  "options": ["允许", "拒绝"],
  "ttl": 900,
  "updatedAt": "2026-10-29T12:43:18Z",
  "startedAt": "2026-10-29T11:03:00Z",
  "pid": 31385
}
```

- `state`：`idle` / `running` / `waiting` / `review` / `failed`
- `title` 是卡片标题（通常是用户 prompt），`detail` 是第二行（工具名、错误、用时）
- `options` 非空时，卡片显示按钮，点击结果写到 `~/.aimate/pet/replies/`
- `ttl` 是几秒后过期，缺省 45；`updatedAt` 是最后一次状态变化的时间
- `startedAt` 只影响卡片里的行序（按开始顺序，不按活跃度）
- `pid` 非空时，进程不存在就整条丢弃——发送方崩了不会留下僵尸行

### 过期与已读

一个 actor 在 `now - updatedAt > ttl` 时被忽略，文件留在磁盘上不删。用户点掉「待检查」的 ✓ 会写 `~/.aimate/pet/seen/`，规则是 `ack.at >= actor.updatedAt`：同一会话下一轮有了更新，勾会失效，行会自己回来。

## 状态机

```
idle ──▶ running ──┬─▶ review ──▶ (过期 / ✓) ──▶ 让位
                   ├─▶ waiting ──▶ (回答 / 过期)
                   ├─▶ failed
                   └─▶ idle
```

**优先级**：`等待你 > 出错了 > 待检查 > 工作中 > 空闲`。宠物只画优先级最高的那个状态（`dominant`），同优先级按 `updatedAt` 新者优先。

| 状态 | 标签 | ttl | 说明 |
| --- | --- | --- | --- |
| `waiting` | 等待你 | 900s | 需要批准或回答，卡片带按钮 |
| `failed` | 出错了 | 180s | 运行出错 |
| `review` | 待检查 | 20s | 这一轮结束、等你看一眼；✓ 可立即清掉 |
| `running` | 工作中 | 180s，发送方 pid 存活时用 900s | 正在跑 |
| `idle` | 空闲 | 0 | 不显示 |

拉取型适配器（Qoder / Codex / OpenCode）只让「认得的、会改变状态的事件」刷新 `updatedAt`；噪声事件（phase、hook、token 计数）不延长寿命。`running` 且 worker pid 存活时用更长窗口，避免一条跑了七分钟的命令让桌宠中途掉回空闲。

## 完成提示

一个会话从 `running` / `waiting` 进入 `review` 时，桌宠跳一下，卡片槽位出现一条玻璃胶囊「完成 N 项 · Qoder」，持续 3 秒；这 3 秒里循环跳跃、不落空闲，结束后直接显示当时的 `dominant` 状态。不是这几个状态转来的 `review` 不提示（例如第一次看到就已经是 review 的会话）。多会话在窗口内接连完成时计数累加。

## 卡片

悬停展开，一行一个会话，按 `startedAt` 排序。同一时间只展开一行，展开的是「玻璃气泡滑到那一行」，行本身不动。顶部最多 5 行，多出来的显示「另有 N 个会话」。

- 红色胶囊 + 红点 + 红字：`review` 行
- 行尾 ✓：把它当作已读，立刻从卡片消失
- 行尾箭头：展开 / 收起
- 有 `options` 时行内出现按钮，回答后显示「已选择 X」

## 窗口与视线

窗口是固定信封（232 × 306.6pt）：宠物图 115pt 宽（高 124.6pt）贴在信封的一端，卡片占另一端固定的槽位，所以卡片开合不会推动宠物或卡片行。卡片宽度恒为 232pt。

视线以 20Hz 采样鼠标位置：

- 指针在宠物身上或在展开的卡片里时，视线让位，继续播当前状态动画
- 指针在宠物周围（约 2.25 倍宽度以内）时，冻结在对应的 16 向朝向帧
- 更远、或正在播完成提示时，回到状态动画

## 代码地图

| 文件 | 职责 |
| --- | --- |
| `Sources/AimateCore/Actor.swift` | actor 数据与快照排序 |
| `Sources/AimateCore/ActorStore.swift` | 文件读写、过期/存活/已读过滤 |
| `Sources/AimateCore/Discovery/` | 各 agent 的适配器（见 [agents.md](agents.md)） |
| `Sources/AimateCore/AtlasLayout.swift` | atlas 网格、行表、视线角度量化 |
| `Sources/AimateCore/Completion.swift` | 完成检测与提示文案 |
| `Sources/AimatePet/PetViewModel.swift` | 1Hz 轮询、状态 → 动画、提示计时 |
| `Sources/AimatePet/TaskCardView.swift` | 会话卡 |
| `Sources/AimatePet/PetWindowController.swift` | 浮动面板、菜单、拖拽、视线采样 |
