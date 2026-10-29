# 构建与运行

## 命令

```bash
./build.sh              # release 构建 → dist/AINEMATE Pet.app
./build.sh dev          # debug 构建 + 挂上 02_assets 里的开发用宠物，然后运行
./build.sh run          # 运行已构建的 app
./build.sh test         # 单元测试（swift test）
./build.sh install-pets # 把开发用 atlas 装进 ~/.aimate/pets
```

app 用 ad-hoc 签名（本机没有开发者证书）。改完代码后要先 `./build.sh` 再重启，否则跑的还是旧二进制——桌宠「改了没生效」十有八九是这样，`ps -o lstart -p <pid>` 对一下构建时间即可。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `AIMATE_HOME` | 把 `~/.aimate` 整棵树搬走（测试、沙盒都靠它） |
| `AIMATE_DEV_PETS_DIR` | 额外的宠物目录，插在搜索顺序最前面，仅开发用 |
| `AIMATE_QODER_LOGS` | 覆盖 Qoder 会话日志根目录 |
| `CODEX_HOME` | 覆盖 Codex 的 `~/.codex`（宠物包和 rollout 都跟着走） |
| `AIMATE_SNAPSHOT` | 不开窗口，把会话卡渲染成 PNG 后退出 |
| `AIMATE_SNAPSHOT_LIVE` | 快照读真实 actor 文件，而不是内置样例 |
| `AIMATE_SNAPSHOT_PIN` | 快照时把玻璃气泡固定在指定会话 id 上 |
| `AIMATE_SNAPSHOT_PET` | 把宠物本体（含完成胶囊）渲染成 PNG 后退出 |
| `AIMATE_SNAPSHOT_PET_WAIT` | 快照前先跑若干秒，用来让完成提示的计时器走完 |
| `AIMATE_SNAPSHOT_PET_CARD` / `AIMATE_SNAPSHOT_PET_BELOW` | 快照时展开卡片 / 把卡片放到宠物下方 |

快照是这台机器上唯一可靠的 UI 校验方式：显示器休眠后系统截图会冻结，但 app 自己渲染的 PNG 不受影响。

## 开发用 atlas 的边界

`02_assets/dev_only_pets/` 里是 OpenAI 的精灵图，**只做开发夹具**：

- 运行时只通过 `AIMATE_DEV_PETS_DIR` 引用，不会被打进 app 包
- `install-pets` 把它们复制到用户自己的 `~/.aimate/pets`，属于用户数据，不在任何构建产物里
- 发布前自查：`ls "dist/AINEMATE Pet.app/Contents/Resources"` 应该是空的

仓库里 `00_target/`、`01_recon/`、`02_assets/` 都是逆向证据和别人的素材，**不要上传公开仓库**。可公开的是 `AINEMATE/`（代码、文档、技能）。

## 测试

```bash
./build.sh test
```

覆盖：actor 契约与过期/已读过滤、四个适配器的事件映射、完成提示、卡片行序、视线几何、atlas 布局。改状态机或 ttl 后，先看 `Tests/AimateCoreTests` 里的边界用例有没有卡在「正好等于 ttl」上。
