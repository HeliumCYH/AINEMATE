# 桌宠导入（Codex v2 格式）

宠物包用的就是 Codex 的 custom-pet 契约，不需要转换。

## 放在哪

按顺序扫描，同名 id 先找到先用：

1. `${CODEX_HOME:-~/.codex}/pets/<name>/` — Codex 自己 hatched 的宠物直接能用
2. `~/.aimate/pets/<name>/`

右键宠物 → 「打开宠物文件夹」会直接打开第 2 个目录；拷进去后右键 →「重新扫描宠物」或直接再右键一次，列表就会更新，不用重启 app。

## 包长什么样

```text
pets/<name>/
├── pet.json
└── spritesheet.webp
```

```json
{
  "id": "pet-name",
  "displayName": "Pet Name",
  "description": "One short sentence.",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.webp"
}
```

另外两种偷懒形态也认：目录里只放一张图（取文件名排序第一张）、或直接把 `xxx.webp` 丢进 pets 目录。

## 图规格（硬门槛）

- 尺寸 **1536×2288**，8 列 × 11 行，单元格 192×208
- PNG 或 WebP，背景透明，不用的格子全透明
- 行 0–8 是状态动画，行 9–10 是 16 个顺时针视线方向

| 行 | 内容 | 用到的帧 |
| --- | --- | --- |
| 0 | idle | 6 |
| 1 | 朝左跑 | 8 |
| 2 | 朝右跑 | 8 |
| 3 | 挥手 | 4 |
| 4 | 跳跃 | 5 |
| 5 | 失败 | 8 |
| 6 | 等待你 | 6 |
| 7 | 工作中 | 6 |
| 8 | 待检查 | 6 |
| 9 | 视线 0°–157.5° | 8 |
| 10 | 视线 180°–337.5° | 8 |

0° 是正上方（12 点），不是正面；正面是「没有方向」的死区，回落到 idle。每帧时长写在代码里（`AtlasLayout.swift`），包里不需要配。

我们只信像素尺寸，不看 `spriteVersionNumber`：旧版 8×9（1536×1872）的图会被拒。

## 导入失败的表现

宠物会保持原来那只，右上角出现一个红点，鼠标悬停能看到具体原因（比如「实测 1536x1872，应为 1536x2288」）。

## 让 AI 帮你移植

项目里有 `port-desktop-pet` skill（`skills/port-desktop-pet/`）：给它一张图、一个 GIF 或别的 app 的 spritesheet，它会拆帧、拼成 v2 atlas、装进 `~/.aimate/pets`，并用脚本校验尺寸与透明背景。把它交给 Qoder 之类的 agent，说「把这个宠物移植进来」，它就会照着 `SKILL.md` 做。
