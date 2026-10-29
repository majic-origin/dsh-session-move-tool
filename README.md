# DSH 会话管理脚本

> **本文档版本：2026-10-29 11:06，与同目录脚本同批写入。**
>
> 怀疑自己看到的是旧内容？`Ctrl+F` 搜这三个锚点，三个都在就是最新版：
> `不知道工作区文件夹在哪`、`切换数据根`、`[7] 工作区清单`。
> 缺任何一个 = 你面对的是编辑器里的旧缓冲区，不是磁盘上的文件。
>
> 编辑器弹「文件已被外部修改，是否保存」时，选 **否** 是安全的 —— 选否只丢掉它自己
> 手里的缓冲区，磁盘一个字节都不动；选 **是** 才是拿旧内容覆盖新版。

## 这是什么

DeepSeek Harness 桌面版的**会话管理工具**：列出、搜索、体检、迁移会话，一个窗口搞定。
纯 PowerShell，零安装，主脚本零写入。

解决三个具体问题：

1. GUI 里会话按工作区分组，**看不到全局** —— 几十条会话散在多个工作区里，想找一条只能靠翻。
2. 会话归哪个工作区，由**五层数据共同决定**（登记表 / 索引 / 正文位置 / header / DSH 枚举）。
   手改其中一层，轻则会话落到「未分组」，重则整个工作区服务瘫痪、或会话直接静默消失。
3. 迁移会话在 GUI 里**没有入口**。

配套：这份 README 记了 DSH 会话存储的完整结构、五层不同步时的确切故障现象，以及回滚办法。

> 实测版本 **DeepSeek Harness 0.2.0-rc.2**。DSH 改版后存储格式可能变，
> 动手前先跑一次 `.\move-session.ps1 -Repair` 看五道关是否全 0。

## 安装

要求 Windows + PowerShell 5.1 或 7.x。`node.exe`（Node 22+）可选，只影响 header 校验和
「DSH 枚举核对」这两项，其余功能不依赖它。

```powershell
git clone https://github.com/majic-origin/dsh-session-move-tool.git
cd dsh-session-move-tool
.\dsh-session.cmd
```

不想装 git 就下 ZIP 解压，双击 `dsh-session.cmd`。**所有文件必须放在同一个目录**，
拆到不同目录会互相找不到。文件清单见下一节。

`node.exe` 不在 PATH 里时用 `-Node "C:\path\to\node.exe"` 指定，或者设环境变量 `DSH_APP_DIR`
指向 DSH 安装目录。

## 三分钟上手

```powershell
.\dsh-session.cmd                    # 双击等价的菜单入口
.\move-session.ps1                   # 全部会话，按工作区分组
.\move-session.ps1 -Search 登录       # 搜标题 / 首条消息 / 工作区 / 路径 / 会话 ID
.\move-session.ps1 -Id -Top 20       # 最近 20 条，带完整会话 ID
.\move-session.ps1 -Repair           # 五道关体检，迁移后必跑
.\move-session.ps1 -help             # 参数速查 + 列表列名解释
```

迁移走菜单 `[6]`，向导让你输**中文标题片段**定位会话，不用抄 36 位 ID；
目标工作区从编号列表里挑，也不用敲长路径。先干跑，看清了再输入 `yes` 执行。

## 安全边界

- **`move-session.ps1` 零写入。** 只读、只诊断。任何会改数据的动作都在
  `experiment-move-session.ps1` 里，物理隔离。
- **所有写入先备份**，落在 `%USERPROFILE%\.dsh\storages\_experiment\<时间戳>\`，
  一条命令 `-Restore` 可还原。
- **迁移和还原要求 DSH 完全退出**（托盘图标 → 退出）。查询、搜索、体检在 DSH 运行时执行是安全的。
- `-Apply` / `-MoveFiles` / `-Yes` 这些能绕过预览直接写的开关**已删除**，传了就打印原因并 `exit 2`。
## 要哪几个文件

**最少 3 个能双击用，4 个能写。** 全部放在同一个文件夹里，
拆开放别的目录会找不到彼此。

| 文件 | 什么时候要 | 性质 | 作用 | 依赖谁 |
|---|---|---|---|---|
| `dsh-session.cmd` | 想双击 / 拖拽 | 启动器（纯 ASCII） | 找 PowerShell，调 `dsh-session.ps1` | `dsh-session.ps1` |
| `dsh-session.ps1` | 想双击 / 拖拽 | 交互外壳，**不写** | 菜单、启动方式判定、停窗 | `move-session.ps1`（硬）<br>`experiment…`（软） |
| `move-session.ps1` | **必需** | **只读** | 列会话 / 搜索 / 详情 / 五道关体检 | **无**，零依赖 |
| `experiment-move-session.ps1` | 要迁移 / 还原 | **写入** | 迁移会话、header 帧修补、一键还原 | `move-session.ps1`（软，仅收尾交叉验证） |
| `list-sessions.ps1` | 老命令还在用 | 转发壳 | 旧写法兼容，逻辑已并进 `move-session.ps1` | `move-session.ps1` |

按用途挑：

| 你的场景 | 需要的文件 | 数量 |
|---|---|---|
| 双击看会话、搜索、体检 | `dsh-session.cmd` + `dsh-session.ps1` + `move-session.ps1` | **3** |
| 还要迁移 / 修 header / 还原 | 上面三个 + `experiment-move-session.ps1` | **4** |
| 只从命令行调，不要菜单 | `move-session.ps1` 一个就够 | **1** |
| 手头记着 `list-sessions.ps1 -Search x` | 加 `list-sessions.ps1` | 可选 |

**缺少时怎么降级**（沙箱实测过）：

- 缺 `move-session.ps1` → 外壳直接拒绝，`exit 2`。没有它什么都看不到，只能拒。
- 缺 `experiment-move-session.ps1` → 外壳**照常工作**，列表/搜索/体检全正常，只是菜单 `[6]` 和
  `-FixHeader` / `-Restore` / `-Apply` 会提示「写操作引擎不在」并 `exit 2`；`-Backups` 仍可用
  （它自己实现，不依赖引擎）。
- 缺 `dsh-session.cmd` → 只能命令行 `pwsh -File dsh-session.ps1`，失去双击和拖拽。
- 缺 `list-sessions.ps1` → 只有旧命令失效，功能都在 `move-session.ps1` 里。

**外部依赖只有一个：`node.exe`（Node 22+）。** 不是这套文件的一部分，只在需要解 zstd 的地方用到
（体检的 D 关、E 关、`-Verify`、`-FixHeader`）。找不到时脚本会明确标注「本项已跳过、结论不完整」，
不会假装通过。纯列会话不需要它。

写入全部隔离在 `experiment-move-session.ps1`，它自带备份与 `-Restore`。其余三个一个字都不写。

> **判断修正记录（重要）**
>
> 10-28：当时的 `move-session.ps1` 带 `-Apply`，声称能迁移会话，实际造成一次全量故障
> （工作区列表全空、无法新建）。当时的结论是「DSH 不支持迁移，此事不可行」。
>
> 10-29：**那个结论也是错的。** 迁移实测成功。真相是漏了两个约束 ——
> header 帧末尾必须带 `\n`（少一个字节就静默消失），以及必须用 DSH 自己的 `listArtifacts`
> 做验收（文件能解压不等于它会显示）。详见第五节。
>
> 教训：两次都栽在「用自己复刻的逻辑代替对方的实现来验收」。

实测环境：DeepSeek Harness 0.2.0-rc.2，数据根 `C:\Users\you\.dsh`。
当时样本库规模：75 个正文文件 / 80 条索引 / 8 个工作区 / 80 条会话。

---

## 一、先搞清 DSH 把会话存在哪

三个位置，各管一件事。

| 用途 | 路径 | 内容 |
|---|---|---|
| 正文 | `.dsh\sessions\<cwd编码>\<会话ID>\session.v4.jsonl.zstd` | 全部对话事件，zstd 压缩的 jsonl |
| 索引 | `.dsh\storages\session_projcache\sessions\<会话ID>.json` | 明文 JSON：标题、cwd、创建时间、token 统计 |
| 分组 | `.dsh\storages\workspace.json` | 哪个会话归哪个工作区、置顶、归档 |

会话 ID 是文件名，中文标题写在索引文件内部的 `record.rows.title.val`，不存在单独的映射表。

工作区目录编码规则（`sessions\` 下的文件夹名由 cwd 算出）：

1. 去掉冒号。
2. 反斜杠和斜杠换成连字符 `-`。
3. 非 ASCII 字符换成 `~XXXX`，XXXX 是该字符的 UTF-16 码位，大写十六进制。
4. 整体前后各加 `--`。

| cwd | 目录名 |
|---|---|
| `C:\Work\my-project` | `--C-Work-my-project--` |
| `C:\Work\中文目录` | `--C-Work-~4E2D~6587~76EE~5F55--` |
| `C:\Work\资料v2备份` | `--C-Work-~8D44~6599v2~5907~4EFD--` |

**最容易忽略的一点**：`session.v4.jsonl.zstd` 解压后第一行是个 JSON header，里面写死了自己的身份：

```json
{"type":"session","version":4,"id":"session-1a2b3c4d-...","cwd":"C:\\Users\\you\\WorkBuddy",...}
```

这个 `cwd` 决定文件必须待在哪个目录，也决定它归哪个工作区。
它**可以改**（重压第一帧就行，事件流一个字节都不用动），但改完必须同时对齐另外四层，
否则要么工作区服务全瘫、要么会话静默消失 —— 第五节。

---

## 二、一个窗口搞定：`dsh-session.cmd`

以前查会话要另开一个 PowerShell 窗口。现在不用了：双击 `dsh-session.cmd`，一个窗口里
列表、搜索、详情、体检、迁移、还原全都能做。

### 三种启动方式

| 启动方式 | 行为 |
|---|---|
| **双击** `dsh-session.cmd` | 进菜单 |
| **拖文件夹到** `dsh-session.cmd` 图标上 | 不走菜单，直接列出该目录对应工作区的会话 |
| **命令行** | `dsh-session.cmd -Repair`、`-Search gif`、`-Top 20 -Id` |

菜单里也可以直接在提示符处**把文件夹拖进窗口**，或粘贴路径后回车 —— 拖进来和双击拖图标等价。

一行输入能认三种东西，按这个顺序判：

| 你输的 | 它当作 | 结果 |
|---|---|---|
| 带 `storages\workspace.json` 的目录（即 `.dsh` 数据根） | 数据根 | 切换数据根，菜单顶部那行立刻变 |
| 盘符开头 / UNC / 磁盘上真实存在的目录 | 工作区目录 | 列出该工作区的会话 |
| 其它任何东西（`移动测试`、`gif`…） | 关键词 | 按标题 / 首条消息搜索 |

拖的是 `.dsh` 数据根时，整库换成那个数据根，用来查备份库。

**不知道工作区文件夹在哪？** 它就是你在 DSH 里新建工作区时指定的那个项目目录，直接在磁盘上。
进菜单 `[7]`，那一列路径就是；或者随便粘一个不存在的路径，脚本会把全部工作区及其路径摊开给你看。
`C:\Users\you\.dsh` 本身**不是**工作区 —— 它是数据根，粘进去会切换数据根并明确告诉你这一点。

记不住参数就 `dsh-session.cmd -help`，一份分组速查：怎么启动、查询参数、写操作参数、`-NoPause` 之类。

### 优先级（严格按这个顺序）

1. **拿到路径就直接用** —— 裸路径（拖拽 / 粘贴）或 `-Path`，不再问任何问题
2. **有明确动作参数就执行** —— `-Repair` / `-List` / `-Search` / `-SessionId` / `-Title` / `-Top` 等，执行完退出
3. **什么都没有才进菜单** —— 但只在交互环境下；管道 / 批处理里改为列全部会话后退出，不会卡在等输入

### 窗口停下来的判定

只有一项判据，写在 `dsh-session.ps1` 里：

```powershell
function Test-Interactive {
    if ($NoPause) { return $false }
    if ([Console]::IsInputRedirected)  { return $false }   # 被别的脚本喂输入
    if ([Console]::IsOutputRedirected) { return $false }   # 输出进了管道/文件
    return $true
}
```

双击、拖拽时两个都是 `false`，所以窗口会停住，按回车才关 —— 不会黑窗一闪看不到结果。
`dsh-session.cmd | more`、`dsh-session.cmd -Repair > log.txt`、被批处理调用时自动不停。
命令行里嫌烦加 `-NoPause`。

`dsh-session.cmd` 自己只在**非 0 退出**时 `pause` 兜底（脚本崩了才需要看），正常路径一律交给 ps1 决定。

### 菜单

```
    [1] 全部会话                [5] 全量体检（五道关）
    [2] 最近 20 条              [6] 迁移 / 修 header / 还原
    [3] 只看未分组              [7] 工作区清单
    [4] 看会话 ID（可搜）       [0] 退出

    也可以直接输入：
      文件夹路径  →  看这个工作区里的会话（可把文件夹拖进本窗口）
      关键词      →  按标题 / 首条消息搜索

    迁移不用记 ID：进 [6] → [3]，输中文标题片段就行。
```

**平时看不到会话 ID 是正常的**：`[1]` 为了不把表格撑到横向滚动，默认不带 ID 列。
要 ID 就进 `[4]`：

- 直接回车 → 列出**全部**会话，每行末尾是完整 ID
- 输入关键词 → 只列匹配的（比如输「移动测试」就剩一条，一眼看到 ID）

早先这里写死 `-Top 30`，第 31 条以后根本看不到 —— 现在没有条数上限了。

`[4]` 的完整 ID 列宽 44，加上前面四列约 122 列。窗口窄的话控制台会自动折行，把窗口拉宽或
按 `Alt+Space → 属性` 调宽缓冲区就能一行看全。

迁移根本不需要你看 ID —— `[6] → [3]` 的向导里输中文标题片段即可，脚本自己定位；
标题撞车（比如好几条都叫「修复登录」）时它会列出候选带序号让你选。目标工作区也是
从编号列表里挑，不用敲长路径。

写操作集中在 `[6]`，二级菜单里都是「先预览、输入 `yes` 才执行」。迁移向导会先跑一遍干跑，
你看清了再确认。

### 会话 ID 有两种长相

DSH 建的新会话是 `session-<uuid>`，但也存在**老式的纯 `<uuid>`**（实测样本库里就混着两条）。
两种都在 `listArtifacts` 里、都能正常显示、都能迁移。

所以判「这是 ID 还是标题」不能只看 `session-` 前缀，得看像不像一段 UUID：

```powershell
if ($key -match '^(session-)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    # 是 ID
}
```

踩这个坑的后果很隐蔽：把老 ID 当标题去搜，搜不到，还以为是 ID 抄错了。

### 为什么外壳用子进程，不点源

`move-session.ps1` 里有 `exit 2`（拒绝写操作、找不到数据根等）。点源（dot-source）会让
那个 `exit` 直接杀掉整个窗口，菜单就没了。所以外壳用 `& pwsh -File <脚本> @参数` 起子进程，
每次动作回到菜单，状态干净。代价是每步多约 300 ms，值得。

---

## 三、列会话与搜索（`move-session.ps1`）

```powershell
.\dsh-tools\move-session.ps1                            # 全部会话，按工作区分组
.\dsh-tools\move-session.ps1 -Top 20                    # 最近 20 条（平铺，保住时间顺序）
.\dsh-tools\move-session.ps1 -Path "C:\Users\you\WorkBuddy"
.\dsh-tools\move-session.ps1 -Search 登录                # 标题/首条消息/工作区/路径/ID
.\dsh-tools\move-session.ps1 -Ungrouped                 # 只看未分组
.\dsh-tools\move-session.ps1 -Id -Top 30                # 带上完整会话 ID，方便复制
.\dsh-tools\move-session.ps1 -List                      # 只列工作区清单
.\dsh-tools\move-session.ps1 -Title "ffmpeg"            # 单条详情（模糊匹配，多条给候选）
.\dsh-tools\move-session.ps1 -SessionId session-...     # 同上，精确指定
.\dsh-tools\move-session.ps1 -help                      # 短帮助：参数速查 + 列名解释
```

参数全表：

| 参数 | 说明 |
|---|---|
| `-Path` | 只看这个目录对应工作区的会话。精确匹配优先，其次前缀匹配（拖父子目录也能中） |
| `-Search` | 关键词：标题 / 首条消息 / 工作区名 / cwd / 会话 ID |
| `-Ungrouped` | 只看未分组 |
| `-Top N` | 最近 N 条；超过 N 时自动平铺 |
| `-Id` | 列表带上完整会话 ID |
| `-Verify` | 列会话时顺带核 header 真实位置与 DSH 枚举（要跑 node，慢） |
| `-Title` | 按标题模糊匹配；多条命中列出候选让选编号 |
| `-SessionId` | 精确指定会话 |
| `-Repair` | 全量体检，五道关逐条扫 |
| `-List` / `-Workspaces` | 工作区清单 |
| `-Node` | node.exe 路径；省略则自动找（PATH → Program Files → `%LOCALAPPDATA%\Programs`） |
| `-DataRoot` | 数据根，默认 `%USERPROFILE%\.dsh` |
| `-Help` / `-h` / `--help` | 打印短帮助后退出，不碰任何文件 |

忘了哪个参数是干什么的，直接：

```powershell
.\move-session.ps1 -help
```

会给一份分组速查（最常用 / 查询 / 单条 / 诊断 / 其它），末尾还解释列表里那几列分别是什么。
`-h`、`--help` 等价。**`-?` 不算**：它是 PowerShell 引擎的内置开关，脚本还没开始跑就被拦下，
只吐一行语法摘要，改不动。

日常查询不跑 node，位置和大小按索引推算 —— 80 条会话约 0.3 秒。
只有 `-Verify` 和 `-Repair` 会解 zstd，那时才需要 node。

标记含义（表格「标记」列）：`钉` 置顶，`档` 已归档，`无正文` 正文文件已不存在，
`DSH不显示` 见第五节的坑①。

`-Apply` / `-MoveFiles` / `-Yes` **已删除**。传入会立刻打印原因并 `exit 2`，不会静默降级。

### 表格带表头，中文也对得齐

两种模式都先印一行列名 + 一条分隔线：

```
    创建时间    会话名称                                所属工作区                    大小  标记        会话 ID
    ────────────────────────────────────────────────────────────────────────────────────────────────────────────
    2026-10-29  （无标题）                              样例项目工程exe                0MB              session-1a2b3c4d-...
    2026-10-28  demo-修复脚本测试                       样例分析项目数据beta1        0.1MB              session-5e6f7a8b-...
```

按工作区分组时不印「所属工作区」列（工作区就在上面的 `■` 行），表头只印一次再分组列数据；
`-Top` 平铺时才有那一列，因为平铺打散了分组，没有它就看不出会话属于哪儿。

对齐是**按显示宽度**算的，不是按字符个数：汉字占两列，`-f` 的宽度补白只会让列歪掉。
所以表格里用 `Get-TextWidth`（CJK 区段判双宽）+ `Format-Cell`（按宽度截断加 `…`、按宽度补白），
中文标题再长也不会把后面的列推歪。

宽度集中在 `$script:ColDate / ColSize / ColFlag / ColId / ColGroup`，改一处表头和数据一起动。

页脚的「未分组 17 条」按索引算（含正文已删的归档会话）；`-Repair` 里的「未分组 15 条」只算
「有正文、没登记」的那批。差的 2 条是索引残留，不是错。

日常查询以索引为准（80 条，0.3 秒）。如果某条会话正文在、索引丢了，默认列表看不到它，但页脚会报
「正文与索引差 N 条」，`-Repair` 会点名 —— 所以不要忽略这行提示。

`-Id` 是别名，参数真名是 `-ShowId`。原因见第七节的坑①：直接叫 `-Id` 会和 `-Repair` 里的
`foreach ($id in $allIds)` 撞车，PowerShell 变量名不区分大小写，一撞就往 `[switch]` 里塞字符串。

---

## 四、五道关体检

### 为什么体检脚本只读

`move-session.ps1` 只诊断、不改动。写操作全部在 `experiment-move-session.ps1` 里，
因为「能改」不等于「随便改」—— 一次错误的改动可以同时做到两件事：
让整个工作区服务瘫痪（C 关），或者让一条会话静默消失（E 关）。

DSH 启动时，`@deepseek-ai/dsh-session-persistence-jsonl` 的 `assertStoredIdentity()` 会拿
header 里的 `cwd` + `id` 反算文件**应该**在哪：

```
expected = sessions\<encode(header.cwd)>\<header.id>\session.v4.jsonl.zstd
```

实际路径与它不符，就抛：

```
Error: corrupt session log "...": header id "..." and cwd identify "..."
```

而 `@deepseek-ai/dsh-workspace` 的 `WorkspaceRegistry`：

```js
static inject = ["storageDomain", "sessionPersistence"]
```

它在 bootstrap 时遍历**全部** header，遇到一条损坏就整体失败，**不跳过**。于是
`workspaceRegistry` 服务注册不上，`workspaceController`、`sessionController`、
`ui-deliverables` 全部 `pending`，GUI 表现为：

- 工作区列表**全空**
- 新建工作区报 `gateway/service-unavailable: ... active Service "workspaceController" is unavailable`

所以单独做任何一件事都是死路：

| 做法 | 结果 |
|---|---|
| 只改 `workspace.json` 的 `sessionIds`（改登记） | 登记与 header 的 cwd 对不上，会话落到「未分组」 |
| 只改索引的 `identity.cwd` | 不决定归属，header 才是权威，白改 |
| 只移动 `sessions\<编码>\<ID>\` 目录 | **位置与 header 不符 → corrupt → 整个工作区服务瘫痪** |

但这不等于搬不动。**实测迁移成功**（一条会话从 `Downloads` 迁到 `WorkBuddy`，
侧边栏正常显示）。前提是五层同时对齐，见第五节。

### 五道关

| 关 | 检查什么 | 不符的后果 |
|---|---|---|
| **A 登记** | `workspace.json` 里登记的工作区，是否等于 header 的 cwd | 会话落到「未分组」 |
| **B 索引** | `session_projcache` 里的 `cwd` 是否等于 header 的 cwd | 不影响归属，只是索引自述与实际不符 |
| **C 位置** | 文件实际路径是否等于 header 反算的路径 | **致命**：corrupt session log，工作区服务全瘫 |
| **D header** | zstd 能不能解开 | 文件损坏 |
| **E 枚举** | DSH 的 `listArtifacts` 收不收录它 | **静默消失**：前四关全绿也不显示，且不报任何错 |

E 关是 2026-10-29 加的，它是唯一能预测「侧边栏会不会显示」的判据。检测方式是直接 import
DSH 自己的 `@deepseek-ai/dsh-session-persistence-jsonl`，用 `Object.create` 绕过 cordis 构造，
调 `listArtifacts()` 拿真实 id 列表 —— 不复制它的判断逻辑，直接问它本人。

「未分组」（有正文、但不在任何工作区登记表里）**不算错误**，DSH 允许，脚本不动它。
「索引残留」（索引还在、正文文件已不存在）也不算错误，DSH 按正文列举，不受影响。

### 体检输出示例

```
  五道关：
    A 登记       0 条不符（登记的工作区与 header cwd 冲突）
    B 索引       0 条不符（索引 cwd ≠ header cwd）
    C 位置       0 条不符（文件不在 header 指定目录）
    D header     0 条异常（zstd 解不开）
    E 枚举       0 条不符（DSH 的 listArtifacts 里没有它，必不显示）

  未分组 15 条 —— DSH 允许不归类，不算错误。
  索引残留 5 条 —— 索引还在但正文文件已不存在，DSH 按正文列举，不受影响。

  没有发现需要处理的损坏。
  注：C 类为 0 是「能启动」的关键，E 类为 0 是「会显示」的关键。
```

### 关于 node

header 校验要解 zstd，靠 Node 22+ 的 `zlib.zstdDecompressSync`。
找不到 node 时脚本跳过 D 关并在输出里明确标注「结论不完整」，不会假装通过。

---

## 五、迁移会话 —— 可行，但五层必须对齐

2026-10-29 实测通过。脚本做四件事，顺序不能乱：

1. 重压 header 帧（改 cwd，**并补上末尾 `\n`**），其余帧逐字节拼回
2. 删原位置（必须在验证前，否则同一 id 两处会让 `listArtifacts` 抛 `duplicate JSONL session id`）
3. **问 DSH 的 `listArtifacts` 认不认** —— 不认就抛错回滚，不留半成品
4. 改索引 cwd、改工作区登记

```powershell
# 菜单方式（推荐）：dsh-session.cmd → [6] → [3]，先预览再确认
# 向导里输中文标题片段，不用抄 UUID；目标工作区从编号列表里挑。

# 命令行：按标题定位，不用记 ID（需先完全退出 DSH：托盘图标右键 → 退出）
.\experiment-move-session.ps1 -Title "修复登录" -TargetPath "C:\Users\you\WorkBuddy"            # 干跑
.\experiment-move-session.ps1 -Title "修复登录" -TargetPath "C:\Users\you\WorkBuddy" -Apply     # 执行

# 标题撞车时会列出候选带序号让你选；非交互环境则报错让你改用 -SessionId
.\experiment-move-session.ps1 -Title "登录"

# 也可以直接给 ID（脚本化时更稳）
.\experiment-move-session.ps1 -SessionId session-... -TargetPath "C:\Users\you\WorkBuddy" -Apply

# 只补 header 帧的换行（不动位置/索引/登记，不必退 DSH）
.\experiment-move-session.ps1 -Repair

# 还原最近一次 / 指定一次
.\experiment-move-session.ps1 -Restore
.\experiment-move-session.ps1 -Restore -Stamp 20261029-092939-276
```

`-Title` 和 `-SessionId` 同时给时以 `-SessionId` 为准。只给 `-Title` 且唯一命中就直接用，
多条命中就列候选 —— 匹配规则是标题包含关键词、不区分大小写，所以「登录」「修复」「测试」这种
两三个字就够。

会话 ID 从哪来：菜单 `[4]`（每行末尾就是完整 ID），或者 `move-session.ps1 -Id -Top 30`。

### 坑①：header 帧末尾少一个 `\n`，会话静默消失

`assertZstdHeaderFrame` 的判据是「第一个帧恰好是一行 header」，实现上要求
**帧内最后一个字节必须是 `0x0A`**：

```js
function assertZstdHeaderFrame(plaintext) {
  if (plaintext.length === 0 || plaintext.indexOf(10) !== plaintext.length - 1)
    throw new Error("...: first frame is not exactly one header line");
}
```

用 `JSON.stringify()` 重压会得到 206 字节（原始 207），丢掉那个换行。后果链：

1. `readFirstZstdLine` 抛 `SessionPersistenceCorruptionError`
2. `listArtifacts` 捕获后 **`continue`** —— 位置和身份都对，所以不炸，只是静默丢弃
3. 会话不在 artifacts → 启动时 `bootstrap` / reconcile 发现「登记里有、枚举里没有」→ **把登记修剪掉**
4. 侧边栏什么也不显示，且全程无报错

验收判据（实测数字）：

```
修复前  generations: 80  artifacts: 79  mine in artifacts: false
修复后  generations: 80  artifacts: 80  mine in artifacts: true
```

### 坑②：文件能解压 ≠ DSH 会显示

第一版脚本在沙箱里验了「帧数不变、事件流 SHA256 一致、五道关全绿」，然后宣布可以通过 ——
结果是上面那个静默消失。**只有调对方自己的 `listArtifacts` 才算端到端验证。**

### 备份在哪

`C:\Users\you\.dsh\storages\_experiment\<yyyyMMdd-HHmmss-fff>\`，每次写入前自动留四份：
`meta.json`、`workspace.json`、`<会话ID>.json`、`session.v4.jsonl.zstd`。
菜单 `[6] → [1]` 或 `-Backups` 可以列出来看，标了哪份能还原迁移、哪份只是正文快照。

---

## 六、事故复盘

2026-10-28 那次「工作区列表全空 + 无法新建工作区」，完整记录在
**[问题原因和解决.md](<问题原因和解决.md>)**：现象、逐步根因链（含 `assertStoredIdentity`
源码片段）、崩溃日志原文、六步恢复命令、验证结果、备份清单，以及 dsh-purge 造成的排查干扰。

这里不重复，避免两份文档各自漂移。只留操作时必须记住的三条：

1. **位置错了要搬回去，不要反过来改 header。** 会话正文必须待在 header 反算出的目录里
   （迁移是另一回事，见第五节，那是有计划地同时改五层）。
2. **修完必须 `-Repair` 五道关全 0 才算好。** C 类不为 0 就重启，等于再瘫一次。
3. **拿真实报错靠 host 进程。** 崩溃日志在
   `%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*-host.log`，关键字 `corrupt session log`。

---

## 七、脚本铁律（以后所有脚本都适用）

写任何新脚本前先过一遍。前八条来自 10-28 / 10-29 两次事故，后两条来自 10-30 做统一入口时踩的坑。

1. **默认干跑。** 写操作必须显式确认，`-Apply` 之类不能有默认值。
2. **改前备份，粒度到毫秒。** `yyyyMMdd-HHmmss-fff`，否则同一秒内两次操作会互相覆盖备份。
3. **回滚必须覆盖全部副作用，且实测过。** 改 JSON、改字段、移文件、建目录，每一项都要有对应的
   反向操作；只回滚一部分等于没回滚。回滚路径要真跑一遍验证，不能只写在提示里让人自己敲。
4. **验证要端到端，不能只看文件状态。** 「三个文件内容一致」不是验证，「目标程序能正常加载」
   才是。凡涉及第三方应用的私有数据格式，先确认它启动时会校验什么，再决定能改什么。
5. **判据要问对方的实现，不要自己复刻。** 能 import 到对方的模块就直接调它（
   `Object.create(P.prototype)` 绕过依赖注入即可），拿它的真实输出当判据。
   复刻逻辑一定会漏——这次漏的就是一个字节的换行。
6. **私有格式的隐式约定要实测，不能靠"能解压"推断。** zstd 帧结构合法 ≠ 对方的解析器接受；
   `assertZstdHeaderFrame` 这种函数不会写在任何文档里，只能读源码或实测。
7. **不可逆操作先停下来问。** 移动/覆盖/删除他人数据前，把风险讲清楚，别自作主张。
8. **只读能力单独留入口。** 诊断、体检这类功能必须能在不写任何文件的前提下独立运行，
   这样出问题时至少有东西能看。
9. **交互层与业务层分离，外壳用子进程调用引擎。** 引擎里有 `exit`，点源会连窗口一起杀掉。
   另外引擎的 `return` 在点源时行为也会变 —— 别在同一个进程里混两种控制流。
10. **包装器保持纯 ASCII，中文只放进带 BOM 的 ps1。** `cmd.exe` 按 OEM 代码页解码 `.bat`，
    里面写中文必花；`PowerShell 5.1` 读无 BOM 的 UTF-8 也会把中文读成乱码。
    所以 `.cmd` 只做启动，所有提示从 `.ps1`（UTF-8 BOM）出。

`move-session.ps1` 按第 8 条做：纯只读，不需要回滚。写操作全部隔离到
`experiment-move-session.ps1`，它按第 3 条做：三份备份、失败自动回滚、`-Restore` 实测可还原。

### 做统一入口时踩的三个 PowerShell 坑

都不是逻辑错，是语言本身的暗礁。记下来省下次的时间。

**① 参数名和变量名撞车，类型约束会反噬。**

写了 `[switch]$Workspaces`，脚本后面又有 `$workspaces = @(...)`。PowerShell 变量名**不区分大小写**，
所以那个赋值等于往 `[switch]` 里塞 `Object[]`：

```
无法将类型"System.Object[]"的"System.Object[]"值转换为类型"System.Management.Automation.SwitchParameter"
```

改成 `[Alias('Workspaces')][switch]$ShowWorkspaces` 就没事了。报错行号还指向了毫无关系的一行，
找起来极费劲。

同一个坑还有更阴的变体：`[switch]$Id` 撞上 `-Repair` 分支里早就写着的
`foreach ($id in $allIds)`。这条循环把字符串写进 `[switch]`，报错是：

```
无法将类型"session-167f24d3-..."的"System.String"值转换为类型"System.Management.Automation.SwitchParameter"
```

**列表功能一直好好的，只在跑 `-Repair` 时才炸** —— 因为那个 `foreach` 只在体检分支里执行。
修法一样：`[Alias('Id')][switch]$ShowId`。

教训：给已有脚本加参数前，先 grep 一遍变量名（**不区分大小写**），包括循环变量。

**② `@()` 数组化 `List[object]` 在 7.6 会炸。**

```powershell
$rows = New-Object System.Collections.Generic.List[object]
$rows.Add([pscustomobject]@{ A = 1 })
return @($rows)      # Argument types do not match
return $rows.ToArray()   # 正确
```

`@(Collection<PSObject>)` 和 `@(object[])` 都正常，只有泛型 `List<T>` 走这条路会抛。

**③ 数组 splatting 不传具名参数。**

```powershell
$argv = @('-DataRoot', 'C:\x'); & $script @argv   # '-DataRoot' 被当位置参数值
```

数组 splatting 全部是位置参数，`-Name` 在里面只是个字符串。要具名必须用 hashtable：
`$opt = @{ DataRoot = 'C:\x' }; & $script @opt`。
（起子进程时用数组是对的 —— 那里是原生命令行，`-File script -Name value` 才生效。）

---

## 八、已知限制

- **迁移需要五层同时对齐，且必须退出 DSH。** 见第五节。任何一层没对齐都不会报错，
  只会"不显示"，所以迁移完必须看 `-Repair` 的 E 关。
- **header 帧必须保持"一行 JSON + `\n`"。** 自己重压时漏掉换行会让会话静默消失。
- **`-Repair` 只修帧0 的换行，不负责判断你为什么要改它。** 如果帧0 被别的工具改坏了
  （JSON 结构变了、丢了字段），它不会自动猜。
- **未分组不是故障。** 有正文但没登记在任何工作区，DSH 正常显示在「未分组」，脚本不处理。
- **索引残留不是故障。** 索引文件还在、正文已删的会话，DSH 不会列举，可以忽略。
- **只列索引里有的会话。** 日常查询以 `session_projcache` 为准（0.3 秒）。如果某条会话
  正文在、索引丢了，默认列表看不到它 —— 页脚会报「正文与索引差 N 条」提醒，`-Repair` 会点名。
- **菜单不检测 DSH 是否在跑。** `-Apply` / `-Restore` 需要 DSH 完全退出，这条由引擎把关
  （进程名 `DeepSeek Harness`），外壳只提示。
- **超出本文档的操作**（手改 `workspace.json`、挪 `sessions` 目录）一旦让 C 类检查不为 0，
  下次启动就会瘫；一旦让 E 类不为 0，会话就静默消失。改完必须跑 `-Repair` 确认五关全 0。

---

## 九、备份清单

2026-10-28 事故期间留下的 `workspace.json.*` 备份文件、各自含义，以及回滚到故障状态的命令，
见 **[问题原因和解决.md](<问题原因和解决.md>)** 第七节。

那份清单会随后续清理而变化，只维护一处。
