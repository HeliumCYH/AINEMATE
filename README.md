# AINEMATE Pet

一只原生 SwiftUI 桌宠：用精灵图展示 Qoder CN、Codex、OpenCode 等 AI 编程 agent 的实时状态，鼠标悬停展开会话卡，需要批准时可以直接在桌宠上点按钮。

```bash
cd AINEMATE
./build.sh          # release 构建 → dist/AINEMATE Pet.app
./build.sh run      # 运行
./build.sh test     # 单元测试
```

宠物图就是 Codex 的 v2 宠物包（1536×2288 atlas），放进 `~/.aimate/pets/<id>/` 后右键 →「重新扫描宠物」即可。

## 文档

全部在 [docs/](docs/README.md)：

| 文档 | 内容 |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | actor 文件契约、状态机与优先级、卡片与窗口几何 |
| [docs/agents.md](docs/agents.md) | 各 agent 怎么被观察到、审批接管通道、`pet-cli` 用法 |
| [docs/pets.md](docs/pets.md) | 导入 / 替换宠物图（Codex v2 格式） |
| [docs/build.md](docs/build.md) | 构建、运行、测试、环境变量、发布边界 |
| [skills/port-desktop-pet/SKILL.md](skills/port-desktop-pet/SKILL.md) | 给 AI 的移植技能：任意图/GIF/spritesheet → v2 atlas |

新增文档放进 `docs/`，并在 [docs/README.md](docs/README.md) 的目录表里加一行。

## 发布边界

只发布 `AINEMATE/` 这一个目录。同级的 `00_target/`、`01_recon/` 是逆向证据，`02_assets/dev_only_pets/` 里是 OpenAI/Codex 的官方图集，都不能进仓库或安装包。
