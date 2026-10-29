# dsh-session-move-tool

**DeepSeek Harness 桌面版的会话管理工具。** 一个窗口里列出、搜索、体检、迁移会话。

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-5391FE)
![License](https://img.shields.io/badge/license-MIT-green)

## 这是什么

DeepSeek Harness（下称 DSH）把会话按工作区分组，侧边栏一次只能看一个工作区。会话攒多之后有三个具体麻烦：

- **找不到**：忘了标题、忘了在哪，只能逐个工作区点开翻。
- **说不清**：会话文件明明还在磁盘上，侧边栏就是不显示，看不出哪里坏了。
- **搬不动**：想把一条会话从 A 工作区挪到 B，界面里没有这个入口。

这个工具补上这三件事。纯 PowerShell，拷过去就能跑，不用安装、不用编译、不联网。

设计上把「读」和「写」彻底分开：主脚本 `move-session.ps1` **零写入**，只读数据、只打印诊断；任何会改数据的动作都在 `experiment-move-session.ps1` 里，并且每次写入前自动备份，一条命令回滚。

## 功能

| 功能 | 用法 | 说明 |
|---|---|---|
| 跨工作区列出 | `move-session.ps1` | 全部会话按工作区分组，带表头；中文标题按显示宽度对齐 |
| 搜索 | `-Search <关键词>` | 同时匹配标题、首条消息、工作区名、路径、会话 ID |
| 单条详情 | `-Title <片段>` / `-SessionId <id>` | 标题模糊匹配，多条命中列候选让你选编号 |
| 完整性体检 | `-Repair` | 五道关逐条扫，指出是哪条会话的哪一层不对 |
| 工作区清单 | `-List` | 全部工作区及其文件夹路径 |
| 迁移会话 | `experiment-move-session.ps1` | 自动对齐全部必需数据，先干跑后执行 |
| 一键回滚 | `-Restore` | 回到最近一次迁移之前，或指定某一次 |
| 菜单交互 | `dsh-session.cmd` | 双击进菜单，也能把文件夹拖进窗口 |

## 安装

要求 **Windows** + **PowerShell 5.1 或 7.x**（系统自带的 5.1 就够用）。

`node.exe`（Node 22+）是可选的，只影响「header 校验」和「DSH 枚举核对」两项，其余功能不依赖它。

```powershell
git clone https://github.com/majic-origin/dsh-session-move-tool.git
cd dsh-session-move-tool
.\dsh-session.cmd
```

不装 git 也行：页面右上角 **Code → Download ZIP**，解压后双击 `dsh-session.cmd`。

**所有文件必须放在同一个目录**，拆到不同目录会互相找不到。

首次运行如果提示找不到 `node.exe`，跳过即可——只有体检的 E 关和 `-Verify` 需要它。

## 如何使用

### 双击：菜单

双击 `dsh-session.cmd`：

```
    [1] 全部会话                [5] 全量体检（五道关）
    [2] 最近 20 条              [6] 迁移 / 修 header / 还原
    [3] 只看未分组              [7] 工作区清单（含文件夹路径）
    [4] 看会话 ID（可搜）       [0] 退出
```

提示符那里可以直接粘路径、把文件夹拖进窗口、或者敲关键词。一行输入按这个顺序判定：

| 输入 | 当作 | 结果 |
|---|---|---|
| 带 `storages\workspace.json` 的目录（DSH 数据根） | 数据根 | 切换数据根，菜单顶部那行立刻变 |
| 盘符开头 / UNC / 磁盘上真实存在的目录 | 工作区目录 | 列出该工作区会话 |
| 其它任何东西（`登录`、`gif`…） | 关键词 | 按标题 / 首条消息搜索 |

做完一个动作会回到菜单，不用反复启动。

### 命令行

```powershell
.\move-session.ps1                          # 全部会话，按工作区分组
.\move-session.ps1 -Top 20                  # 最近 20 条，平铺带表头
.\move-session.ps1 -Search 登录              # 跨字段搜索
.\move-session.ps1 -Id -Top 20              # 带完整会话 ID，方便复制
.\move-session.ps1 -Path "C:\Work\proj"     # 只看这个目录对应的工作区
.\move-session.ps1 -Ungrouped               # 只看未分组
.\move-session.ps1 -Title "ffmpeg"          # 单条详情
.\move-session.ps1 -Repair                  # 五道关体检
.\move-session.ps1 -List                    # 工作区清单
.\move-session.ps1 -help                    # 参数速查
```

列表长这样（只有 `-Id` 才带最后一列）：

```
    创建时间    会话名称                                所属工作区                  大小    标记        会话 ID                                     
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    2026-10-29  用ffmpeg导出视频为GIF                   my-project                  2.2MB               session-1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
    2026-10-28  修复登录跳转                            my-project                  0.1MB   钉          session-2b3c4d5e-6f7a-8b9c-0d1e-2f3a4b5c6d7e
    2026-10-28  （无标题）                              样例项目工程exe             0MB                 session-3c4d5e6f-7a8b-9c0d-1e2f-3a4b5c6d7e8f
  索引 120 条 / 正文 118 个 / 未分组 6 条
```

各列含义：

| 列 | 含义 |
|---|---|
| 创建时间 | 会话创建日期，只到日 |
| 会话名称 | 侧边栏显示的名字；空的话是（无标题） |
| 所属工作区 | 登记在哪个工作区；没登记就是「未分组」 |
| 大小 | 正文文件的实际字节数 |
| 标记 | `钉`=置顶 `档`=归档 `无正文`=正文文件没了 `DSH不显示`=见案例 2 |
| 会话 ID | 正文目录名，也就是 `-SessionId` 要填的值 |

## 使用案例

### 案例 1：只记得聊过什么，不记得标题

```powershell
.\move-session.ps1 -Search 登录
```

`-Search` 同时搜标题、首条消息、工作区名、路径和会话 ID，所以记得半句话、记得路径片段、甚至只记得一段 ID 都能命中。

看到目标后看详情：

```powershell
.\move-session.ps1 -Title 登录
```

标题撞车（好几条都叫「修复登录」）时会列出候选带序号，输编号就行。

### 案例 2：会话在磁盘上，侧边栏就是不显示

跑体检：

```powershell
.\move-session.ps1 -Repair
```

```
五道关：
A 登记       0 条不符（登记的工作区与 header cwd 冲突）
B 索引       0 条不符（索引 cwd ≠ header cwd）
C 位置       0 条不符（文件不在 header 指定目录）
D header     0 条异常（zstd 解不开）
E 枚举       0 条不符（DSH 的 listArtifacts 里没有它，必不显示）
注：C 类为 0 是「能启动」的关键，E 类为 0 是「会显示」的关键。
```

哪一关不为 0，就是那一层出了问题，报告会点名具体的会话 ID 和它期望的值。全 0 还看不见，那就是显示层的问题，跟磁盘数据无关。

顺带会报「正文与索引差 N 条」——索引里有、正文已删的归档会话。不影响使用，但值得知道。

### 案例 3：把会话迁到另一个工作区

```powershell
# 先干跑，只打印计划，一个字节都不写
.\experiment-move-session.ps1 -Title "修复登录" -TargetPath "C:\Work\other-project"

# 确认无误再加 -Apply
.\experiment-move-session.ps1 -Title "修复登录" -TargetPath "C:\Work\other-project" -Apply
```

**执行前必须完全退出 DSH**（托盘图标 → 退出）。DSH 运行时缓存着会话状态，边跑边改会互相覆盖。

不想敲路径就走菜单：`[6] → [3]`，输中文标题片段，目标工作区从编号列表里挑。

迁移完启动 DSH，跑一次 `-Repair` 确认五道关全 0、侧边栏能看到新位置。目标目录不必预先存在，会自动建成新工作区。

### 案例 4：迁移搞砸了

```powershell
.\experiment-move-session.ps1 -Restore                               # 回到最近一次操作之前
.\experiment-move-session.ps1 -Restore -Stamp 20261030-101500-123    # 指定某一次
```

每次写入前自动备份到 `%USERPROFILE%\.dsh\storages\_experiment\<时间戳>\`，目录名就是 `-Stamp` 要填的值。`[6] → [1]` 可以看全部备份列表。

备份不自动清理，确认稳妥后手动删。还原同样要求 DSH 退出。

### 案例 5：标题重复的会话，想分清哪条是哪条

```powershell
.\move-session.ps1 -Search 测试 -Id
```

带上 `-Id` 后每条都有完整 ID，横向对比创建时间、大小和工作区，判断哪条是废弃的。未分组的通常是历史遗留，用 `-Ungrouped` 单独过一遍再决定怎么处理。

本工具**不提供删除**——删会话请直接用 DSH 界面。脚本只做迁移和诊断，不碰删除，也不碰归档开关。

## 为什么搬一条会话要这么麻烦

DSH 判断「这条会话属于哪个工作区」，靠五处数据同时对齐：

1. 工作区登记表里有没有它的 ID
2. 索引文件里记的 `cwd`
3. 正文文件在不在 `sessions\<目录编码>\<会话ID>\` 这个位置
4. 正文第一帧头里写的 `cwd` 和 `id`
5. DSH 自己的枚举结果里有没有它

只改其中一处，结果分别是：落到「未分组」、工作区列表整个变空、或者会话静默消失。

**这些错误都不报错**，只会「不显示」。所以本工具把整套改动做成一个原子操作，写完用 DSH 自己的枚举做验收，而不是拿脚本复刻的逻辑去判断。

## 安全边界

- `move-session.ps1` **零写入**，只读、只诊断。想改数据必须显式调用 `experiment-move-session.ps1`。
- 所有写入先备份，落在 `_experiment\<时间戳>\`，`-Restore` 一条命令回滚。
- 迁移 / 还原要求 DSH 完全退出；查询、搜索、体检在 DSH 运行时执行是安全的。
- 能绕过预览直写的开关（给只读脚本传 `-Apply` / `-MoveFiles` / `-Yes`）**已删除**，传了会打印原因并 `exit 2`。
- 不联网、不写注册表、不留后台进程。

## 兼容性

实测 **DeepSeek Harness 0.2.0-rc.2**。

DSH 改版后存储格式可能变。换版本后先跑 `-Repair`，五道关全 0 再动手。

数据根默认 `%USERPROFILE%\.dsh`，可以用 `-DataRoot` 指向副本，对着备份库做演练。

## 文件清单

| 文件 | 性质 | 作用 |
|---|---|---|
| `dsh-session.cmd` | 启动器（纯 ASCII） | 双击入口，找 PowerShell 后调 `.ps1` |
| `dsh-session.ps1` | 交互外壳 | 菜单、输入分派、停窗判定 |
| `move-session.ps1` | **只读** | 列表 / 搜索 / 详情 / 五道关体检 |
| `experiment-move-session.ps1` | **写入** | 迁移 / 修 header / 还原 |
| `list-sessions.ps1` | 转发壳 | 兼容旧命令写法，逻辑已并入 `move-session.ps1` |

最少 3 个能用（`.cmd` + `dsh-session.ps1` + `move-session.ps1`），4 个能写。
`experiment-move-session.ps1` 缺失时，只读功能全部照常，写操作会明确提示缺哪个文件。

## License

[MIT](LICENSE)
