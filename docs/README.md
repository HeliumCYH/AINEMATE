# AINEMATE Pet · 文档

一只住在菜单栏之外的桌宠：用精灵图动画展示各个 AI 编程 agent 的实时状态，鼠标悬停展开会话卡，需要批准时可以在桌宠上直接点按钮。

- 观察 Qoder CN、Codex（桌面版 / CLI）、OpenCode、DeepSeek Harness 的会话
- 任何程序都能通过 `pet-cli` 或一个 JSON 文件驱动它
- 宠物的图片就是 Codex 的 v2 宠物包，可以直接导入和替换

## 文档目录

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | actor 文件契约、状态机与优先级、卡片与窗口几何、完成提示 |
| [agents.md](agents.md) | 各 agent 怎么被观察到、审批接管通道、`pet-cli` 用法 |
| [pets.md](pets.md) | 导入 / 替换宠物图（Codex v2 格式） |
| [build.md](build.md) | 构建、运行、测试、环境变量、发布边界 |
| [../skills/port-desktop-pet/SKILL.md](../skills/port-desktop-pet/SKILL.md) | 给 AI 的移植技能：任意图/GIF/spritesheet → v2 atlas |

## 快速开始

```bash
cd AINEMATE
./build.sh            # release 构建 → dist/AINEMATE Pet.app
./build.sh run        # 运行
./build.sh test       # 单元测试
```

第一次运行如果桌宠是空白，说明 `~/.aimate/pets` 里还没有宠物包：把任意 Codex v2 宠物放进 `~/.aimate/pets/<id>/`，或参考 [pets.md](pets.md)。

## 数据放在哪

所有状态都在 `~/.aimate` 下，删掉这个目录就等于彻底卸载。

| 路径 | 用途 |
| --- | --- |
| `~/.aimate/pet/actors/*.json` | 每个会话一个 actor 文件，桌宠的唯一输入 |
| `~/.aimate/pet/replies/` | 卡片上按钮的答复 |
| `~/.aimate/pet/seen/` | 手动勾掉的「待检查」 |
| `~/.aimate/pet/settings.json` | 宠物 id、大小、位置、减少动效 |
| `~/.aimate/pet/live.stamp` | 心跳，发送方据此判断桌宠是否在跑 |
| `~/.aimate/pets/<id>/` | 宠物包 |

`AIMATE_HOME` 可以把整棵树搬到别处。

## 迭代约定

新功能的文档直接加进本目录：先更新对应文档，再在 README 的目录表里加一行；跨两个文档都成立的事实（状态、路径、队列）只写一次，另一个链接过去。
