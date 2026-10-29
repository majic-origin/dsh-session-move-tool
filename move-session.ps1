#Requires -Version 5.1
<#
.SYNOPSIS
    DSH 会话清单与只读体检。不写入、不移动、不改名任何文件。

.DESCRIPTION
    ── 三件事 ──

    1 列会话      列出全部会话、按工作区分组、看某个工作区的、搜索、看单条详情。
    2 全量体检    五道关逐条核验：登记 / 索引 / 位置 / header / DSH 枚举。
    3 解释原理    告诉你要修什么、往哪个方向修、为什么只能那样修。

    日常从 dsh-session.cmd 进（双击就行），本脚本也可以单独命令行调用。

    ── 为什么"会话归属"这么麻烦 ──

    DSH 的会话正文 session.v4.jsonl.zstd 不是普通文件：它 zstd 压缩后的第一行
    header 里写死了自己的身份（id + cwd）。DSH 启动时
    （@deepseek-ai/dsh-session-persistence-jsonl 的 assertStoredIdentity）用 header 里的
    cwd 反算这个文件「应该」在哪：

        expected = sessions\<encode(header.cwd)>\<header.id>\session.v4.jsonl.zstd

    文件实际位置与它不符，就抛 `corrupt session log`。而
    @deepseek-ai/dsh-workspace 的 WorkspaceRegistry 在 bootstrap 时遍历全部 header，
    遇到一条损坏就整体失败，不做跳过 —— 于是 workspaceRegistry 服务注册不上，
    workspaceController / sessionController / ui-deliverables 全部 pending，
    GUI 表现为「工作区列表全空 + 新建工作区报 gateway/service-unavailable」。

    所以归属由 header 里的 cwd 唯一决定：
    - 移动 sessions 目录而不改 header → 位置错误 → corrupt → 整个工作区服务瘫痪
    - 只改 workspace.json 的 sessionIds → 登记与 header 的 cwd 对不上 → 落到「未分组」

    ── 五道关（-Repair 逐条查）──

    A 登记     workspace.json 的 sessionIds 与 header cwd 是否一致
    B 索引     session_projcache\<id>.json 的 identity.cwd 与 header cwd 是否一致
    C 位置     文件是否在 header 指定的目录里        ← 不为 0 会让 DSH 起不来
    D header   zstd 第一帧能否解开、id/cwd 能否读出
    E 枚举     DSH 自己的 listArtifacts 是否收录     ← 不为 0 会让会话凭空消失

    C 类和 E 类必须为 0。C 类出事是"整个工作区列表全空"，E 类出事是"就那么一条不见"。

    ── 迁移（已实测可行，2026-10-29）──

    改 header 帧 + 搬目录 + 同步索引 + 重登记，四步之后 DSH 就认。
    但有五条必须同时满足，少一条就失败（帧0 末尾还必须有那个 \n，少一个字节就静默不显示）。
    本脚本不做写入，迁移用同目录的 experiment-move-session.ps1，它带完整备份和一键还原。

    本脚本 0 写入。旧版的 -Apply / -MoveFiles 已彻底移除，传入只会报错退出。

.PARAMETER Title
    按标题看单条会话的完整诊断。模糊匹配，多条命中列出候选。

.PARAMETER SessionId
    精确指定会话。

.PARAMETER Repair
    全量体检：扫描每一个会话，逐项检查上面五道关。

.PARAMETER List
    只列工作区清单与会话数。（-Workspaces 是它的别名）

.PARAMETER Path
    只看某个目录对应工作区的会话。把文件夹拖进窗口时，外壳会把路径塞到这里。
    精确匹配优先，其次前缀匹配（所以拖父目录或子目录也能命中）。

.PARAMETER Ungrouped
    只看未分组的会话。未分组是 DSH 允许的正常状态，不是损坏。

.PARAMETER Search
    关键词搜标题 / 首条消息 / 工作区名 / cwd / 会话 ID。

.PARAMETER Id
    列表里带上完整会话 ID，方便复制去 -SessionId。

.PARAMETER Top
    只看最近 N 条（0 = 全部）。超过 N 时自动改成平铺，保住"最近"的顺序。

.PARAMETER Verify
    列会话时顺带核 header 真实位置与 DSH 枚举（要跑 node，慢）。
    不加时位置和大小按索引推算 —— 日常够用。

.PARAMETER Node
    node.exe 路径。省略则自动找（PATH → Program Files → %LOCALAPPDATA%\Programs）。
    header 校验依赖 node 的 zstd 解压（Node 22+ 才有），找不到就跳过并明确标注。

.PARAMETER DataRoot
    数据根目录，默认 %USERPROFILE%\.dsh。

.EXAMPLE
    .\move-session.ps1
    全部会话，按工作区分组。

.EXAMPLE
    .\move-session.ps1 -Path "C:\Work\my-project" -Id

.EXAMPLE
    .\move-session.ps1 -Search gif -Top 10

.EXAMPLE
    .\move-session.ps1 -Repair

.EXAMPLE
    .\move-session.ps1 -Title "用ffmpeg将视频制作成GIF"

.NOTES
    本脚本 0 写入。要迁移会话请用 experiment-move-session.ps1（需退出 DSH）。
#>
param(
    [Parameter(Position = 0)]
    [string]$Title,

    [string]$SessionId,

    [switch]$Repair,
    [switch]$List,

    # 注意：不能叫 -Workspaces。PowerShell 变量名不区分大小写，会把下面
    # $workspaces = @(...) 的赋值当成给 [switch] 赋 Object[]，直接抛类型错误。
    [Alias('Workspaces')]
    [switch]$ShowWorkspaces,

    # 只看某个目录对应工作区的会话。把文件夹拖进窗口/图标时，外壳脚本会把它塞到这里。
    [string]$Path,

    [switch]$Ungrouped,
    [string]$Search,

    # 列表里附带完整会话 ID（要复制去 -SessionId 时用）
    # 不能直接叫 -Id：PowerShell 变量名不区分大小写，-Repair 分支里的
    # `foreach ($id in $allIds)` 会往 [switch] 里塞字符串，直接抛类型错误。
    [Alias('Id')]
    [switch]$ShowId,

    # 列表时顺带做 header 扫描与 DSH 枚举核验（慢，但能看出"文件在却不显示"的会话）
    [switch]$Verify,

    # 只看最近 N 条（0 = 全部）。超过 N 时自动改成平铺，保留"最近"的顺序。
    [int]$Top = 0,

    [string]$Node,

    # -help / -h / --help：打印短帮助后退出，不碰任何文件
    # 不放 '?' 进别名：-? 是 PowerShell 内置开关，会在脚本执行前被引擎拦下，
    # 只打印一行语法摘要，拦不住也改不了，所以干脆不宣传它。
    [Alias('help', 'h')]
    [switch]$ShowHelp,

    [string]$DataRoot = (Join-Path $env:USERPROFILE '.dsh'),

    # 以下三个是已删除的写入口，保留名字只是为了在误用时给出明确报错。
    [switch]$Apply,
    [switch]$MoveFiles,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$WsFile   = Join-Path $DataRoot 'storages\workspace.json'
$PcDir    = Join-Path $DataRoot 'storages\session_projcache\sessions'
$SessRoot = Join-Path $DataRoot 'sessions'

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

# ---------------------------------------------------------------- -help

function Show-Usage {
    Write-Host ''
    Write-Host '  DSH 会话清单与只读体检' -ForegroundColor Cyan
    Write-Host '  本脚本 0 写入。迁移 / 修 header / 还原在 experiment-move-session.ps1。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  最常用' -ForegroundColor White
    Write-Host '    .\move-session.ps1                     列全部会话（按工作区分组）' -ForegroundColor Gray
    Write-Host '    .\move-session.ps1 -Top 20             最近 20 条（平铺 + 表头）' -ForegroundColor Gray
    Write-Host '    .\move-session.ps1 -Repair             全量体检，五道关逐条扫' -ForegroundColor Gray
    Write-Host '    .\move-session.ps1 -Title "ffmpeg"     看某条会话的详情' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  查询' -ForegroundColor White
    Write-Host '    -Path <目录>           只看这个目录对应工作区的会话（拖父子目录都能中）' -ForegroundColor Gray
    Write-Host '    -Search <关键词>       标题 / 首条消息 / 工作区名 / cwd / 会话 ID' -ForegroundColor Gray
    Write-Host '    -Ungrouped             只看未分组' -ForegroundColor Gray
    Write-Host '    -Top <N>               最近 N 条；0=全部，超过 N 时自动平铺' -ForegroundColor Gray
    Write-Host '    -Id                    列表带上完整会话 ID（参数真名 -ShowId）' -ForegroundColor Gray
    Write-Host '    -Verify                顺带核 header 真实位置与 DSH 枚举（要跑 node，慢）' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  单条' -ForegroundColor White
    Write-Host '    -Title <关键词>        按标题模糊匹配；多条命中列出候选让选编号' -ForegroundColor Gray
    Write-Host '    -SessionId <id>        精确指定会话' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  诊断' -ForegroundColor White
    Write-Host '    -Repair                全量体检，五道关逐条扫' -ForegroundColor Gray
    Write-Host '    -List                  工作区清单（别名 -Workspaces）' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  其它' -ForegroundColor White
    Write-Host '    -Node <路径>           node.exe；省略则自动找（PATH → Program Files → %LOCALAPPDATA%）' -ForegroundColor Gray
    Write-Host '    -DataRoot <目录>       数据根，默认 %USERPROFILE%\.dsh' -ForegroundColor Gray
    Write-Host '    -Help                  这份帮助（也可以 -h / --help；-? 是 PowerShell 内置的，只给语法行）' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  列表里那五列是什么' -ForegroundColor White
    Write-Host '    创建时间   索引里的 createdAt，转成本地时间，只到日' -ForegroundColor Gray
    Write-Host '    会话名称   索引里的 title，即侧边栏显示的名字；空的话是（无标题）' -ForegroundColor Gray
    Write-Host '    工作区     登记在 workspace.json 的哪个工作区；没登记就是「未分组」' -ForegroundColor Gray
    Write-Host '    大小       正文 session.v4.jsonl.zstd 的实际字节数' -ForegroundColor Gray
    Write-Host '    会话 ID    正文目录名，也就是 -SessionId 要填的那个值' -ForegroundColor Gray
    Write-Host '    标记       钉=置顶  档=归档  无正文=正文文件没了  DSH不显示=见坑①' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  交互入口：双击 dsh-session.cmd（菜单 / 拖文件夹进来都行）' -ForegroundColor DarkGray
    Write-Host ''
}

# 两条路都要认：
#   手敲 `.\move-session.ps1 -help` 时 → PowerShell 把 -help 当参数名，命中 [Alias] 进 $ShowHelp
#   程序传 `& $f '-help'` 或 `-File $f -help` 时 → 变量/字面值会被当成位置参数塞进 $Title
# 所以 $Title 里再剥一层 -/ 前缀比对一次，任何一个叫 help/h/? 的都当求帮助。
if ($ShowHelp) { Show-Usage; exit 0 }
if ($Title) {
    $probe = $Title.Trim().ToLowerInvariant().TrimStart('-', '/')
    if (@('help', 'h', '?') -contains $probe) { Show-Usage; exit 0 }
}

# ---------------------------------------------------------------- 拒绝写入

if ($Apply -or $MoveFiles -or $Yes) {
    Say ''
    Say '拒绝执行：本脚本是只读的。' 'Red'
    Say ''
    Say '  -Apply / -MoveFiles / -Yes 已删除。写操作全部搬到了' 'Yellow'
    Say '  experiment-move-session.ps1 —— 它要备份、要验证、要回滚，' 'Yellow'
    Say '  混在体检脚本里就变成"能改但不负责"。' 'Yellow'
    Say ''
    Say '  迁移 / 修 header / 还原：' 'Gray'
    Say '    .\dsh-session.cmd                     菜单 → [6]' 'Gray'
    Say '    .\experiment-move-session.ps1 -SessionId <id> -TargetPath <dir>   （先干跑）' 'Gray'
    Say ''
    Say '  只看状态：' 'Gray'
    Say '    .\move-session.ps1            全部会话' 'Gray'
    Say '    .\move-session.ps1 -Repair    五道关体检' 'Gray'
    Say ''
    exit 2
}

# ---------------------------------------------------------------- 基础

function Read-JsonFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Resolve-NodeExe {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        return $null
    }
    $cmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @((Join-Path $env:ProgramFiles 'nodejs\node.exe'),
                     (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# 读每个会话 zstd 的 header。JS 只输出 ASCII（非 ASCII 一律转成 \uXXXX），
# 避免中文路径在 PowerShell 管道里被代码页破坏。
$HeaderScanJs = @'
const fs = require('fs');
const pathm = require('path');
const zlib = require('zlib');

const root = process.env.DSH_SESSIONS_ROOT;
const targets = [];
for (const d of fs.readdirSync(root)) {
  const dir = pathm.join(root, d);
  try { if (!fs.statSync(dir).isDirectory()) continue; } catch { continue; }
  for (const s of fs.readdirSync(dir)) {
    const log = pathm.join(dir, s, 'session.v4.jsonl.zstd');
    if (fs.existsSync(log)) targets.push(log);
  }
}
function encode(p) {
  let s = p.replace(/:/g, '').replace(/[\\/]/g, '-');
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    out += c > 127 ? '~' + c.toString(16).toUpperCase().padStart(4, '0') : s[i];
  }
  return '--' + out + '--';
}
function firstLine(file) {
  return new Promise((res, rej) => {
    const st = fs.createReadStream(file);
    const dz = zlib.createZstdDecompress();
    let buf = '';
    let done = false;
    const fin = (e, v) => {
      if (done) return;
      done = true;
      try { st.destroy(); dz.destroy(); } catch (e) {}
      if (e) rej(e); else res(v);
    };
    dz.on('data', (c) => {
      buf += c.toString('utf8');
      const i = buf.indexOf('\n');
      if (i >= 0) fin(null, buf.slice(0, i));
      else if (buf.length > 1048576) fin(null, buf);
    });
    dz.on('error', (e) => fin(e));
    st.on('error', (e) => fin(e));
    st.pipe(dz);
  });
}
(async () => {
  const out = [];
  for (const file of targets) {
    const rec = { file: file, id: null, cwd: null, expected: null, size: 0, error: null };
    try { rec.size = fs.statSync(file).size; } catch (e) {}
    try {
      const obj = JSON.parse(await firstLine(file));
      rec.id = obj.id || null;
      rec.cwd = obj.cwd || null;
      if (obj.cwd && obj.id) rec.expected = pathm.join(root, encode(obj.cwd), obj.id, 'session.v4.jsonl.zstd');
    } catch (e) { rec.error = String((e && e.message) || e); }
    out.push(rec);
  }
  const s = JSON.stringify(out).replace(/[\u007f-\uffff]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
  process.stdout.write(s);
})().catch((e) => { process.stderr.write('SCAN_FAILED: ' + e.message); process.exit(1); });
'@

function Get-HeaderScan {
    param([string]$NodeExe, [string]$SessionsRoot)
    $env:DSH_SESSIONS_ROOT = $SessionsRoot
    $raw = $HeaderScanJs | & $NodeExe - 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String) }
    return @((($raw | Out-String).Trim()) | ConvertFrom-Json)
}

# ---------------------------------------------------------------- 第五道关：DSH 自己的枚举

# 这一关才是权威：DSH 启动时用 dsh-session-persistence-jsonl 的 listArtifacts()
# 枚举会话，凡是被它跳过的会话，即使文件、索引、登记全都对，侧边栏也不会显示。
# 已知的跳过原因之一：header 帧末尾必须带换行（assertZstdHeaderFrame），
# 少了那个字节，readFirstZstdLine 抛 corruption，listArtifacts 会静默 continue。
$ArtifactsJs = @'
const url = process.env.DSH_PERSISTENCE_MODULE;
const root = process.env.DSH_SESSIONS_ROOT;
(async () => {
  const mod = await import(url);
  const P = mod.default;
  const inst = Object.create(P.prototype);
  inst.root = root;
  inst.compression = 'zstd';
  const art = await inst.listArtifacts();
  const ids = art.map((a) => a.header.id);
  // 同时报告每条会话的 header 帧末字节，便于定位 assertZstdHeaderFrame 失败项
  const terminated = {};
  for (const a of art) terminated[a.header.id] = true;
  const gens = await inst.listGenerations();
  const genIds = [];
  for (const g of gens) {
    // 会话 ID 有两种：session-<uuid> 和老式的纯 <uuid>，两种都得抓。
    const m = String(g.sourcePath).match(/(?:session-)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
    if (m) genIds.push(m[0]);
  }
  const skipped = genIds.filter((id) => !terminated[id]);
  const out = { ids, skipped };
  process.stdout.write(JSON.stringify(out).replace(/[\u007f-\uffff]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')));
})().catch((e) => { process.stderr.write('ARTIFACTS_FAILED: ' + e.message); process.exit(1); });
'@

function Resolve-PersistenceModule {
    $rel = 'resources\app\dsh\node_modules\@deepseek-ai\dsh-session-persistence-jsonl\lib\index.js'
    $candidates = @()

    # 运行中的 DSH 进程目录最可信
    $proc = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) {
        $candidates += Join-Path (Split-Path $proc.Path -Parent) $rel
    }
    if ($env:DSH_APP_DIR) { $candidates += Join-Path $env:DSH_APP_DIR $rel }

    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates += Join-Path $base ('DeepSeek Harness\' + $rel) }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

function Get-DshArtifacts {
    param([string]$NodeExe, [string]$ModulePath, [string]$SessionsRoot)
    $env:DSH_PERSISTENCE_MODULE = ([System.Uri]::new($ModulePath)).AbsoluteUri
    $env:DSH_SESSIONS_ROOT = $SessionsRoot
    $raw = $ArtifactsJs | & $NodeExe - 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String) }
    return ((($raw | Out-String).Trim()) | ConvertFrom-Json)
}

# ---------------------------------------------------------------- 载入

if (-not (Test-Path -LiteralPath $WsFile)) {
    Say "找不到 $WsFile" 'Red'
    exit 2
}

$ws = Read-JsonFile $WsFile
$workspaces = @(
    foreach ($p in $ws.tables.workspaces.PSObject.Properties) {
        [pscustomobject]@{
            Id         = $p.Name
            Title      = $p.Value.title
            Path       = $p.Value.path
            SessionIds = @($p.Value.sessionIds)
        }
    }
)
$workspaces = @($workspaces | Sort-Object Path)

$nodeExe = Resolve-NodeExe $Node

# ---------------------------------------------------------------- 会话清单

function ConvertTo-WorkspaceEncoding {
    param([string]$Path)
    $s = $Path -replace ':', '' -replace '[\\/]', '-'
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -gt 127) { [void]$sb.Append(('~{0:X4}' -f [int]$ch)) } else { [void]$sb.Append($ch) }
    }
    return "--$($sb.ToString())--"
}

# 把一个目录名对上工作区。先精确，再前缀（兼容拖进来的是子目录或父目录）。
function Resolve-WorkspaceByPath {
    param([string]$Want)
    if (-not $Want) { return $null }
    $w = $Want.Trim().Trim('"').TrimEnd('\', '/')
    if (-not $w) { return $null }

    foreach ($ws in $workspaces) {
        if ($ws.Path -and $ws.Path.TrimEnd('\', '/') -ieq $w) { return $ws.Path }
    }
    foreach ($ws in $workspaces) {
        if (-not $ws.Path) { continue }
        $p = $ws.Path.TrimEnd('\', '/')
        if ($p.StartsWith($w, [StringComparison]::OrdinalIgnoreCase) -or
            $w.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $ws.Path }
    }
    return $null
}

# 会话清单：以索引（session_projcache）为准，只做 JSON 解析，不解 zstd —— 快。
# 需要 header 真实路径时由调用方传 -HeaderById（-Verify 分支）。
function Get-SessionRows {
    param([hashtable]$HeaderById)

    if (-not (Test-Path -LiteralPath $PcDir)) { return @() }

    $groupOf = @{}
    $ownerPathOf = @{}
    foreach ($w in $workspaces) {
        foreach ($s in $w.SessionIds) { $groupOf[$s] = $w.Title; $ownerPathOf[$s] = $w.Path }
    }
    $pinned = @($ws.global.pinnedSessionIds)
    $archived = @($ws.global.archivedSessionIds)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $PcDir -File -Filter *.json) {
        $sid = $f.BaseName
        $j = $null
        try { $j = Read-JsonFile $f.FullName } catch { continue }

        $cwd = $null; $title = $null; $first = $null; $created = $null
        try { $cwd = $j.record.identity.cwd } catch {}
        try { $title = $j.record.rows.title.val } catch {}
        try { $first = $j.record.rows.titleInput.val.first.text } catch {}
        try {
            $ms = [int64]$j.record.identity.createdAt
            if ($ms -gt 0) { $created = [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime }
        } catch {}

        # 正文：优先用 header 扫出来的真实位置，没有就按 encode(cwd) 推算
        $body = $null
        if ($HeaderById -and $HeaderById.ContainsKey($sid)) { $body = $HeaderById[$sid].file }
        elseif ($cwd) { $body = Join-Path (Join-Path $SessRoot (ConvertTo-WorkspaceEncoding $cwd)) $sid }

        $mb = 0
        $hasBody = $false
        if ($body) {
            $log = if ($body -like '*.zstd') { $body } else { Join-Path $body 'session.v4.jsonl.zstd' }
            if (Test-Path -LiteralPath $log) {
                $hasBody = $true
                $mb = [math]::Round((Get-Item -LiteralPath $log).Length / 1MB, 1)
            }
        }

        $rows.Add([pscustomobject]@{
            Id         = $sid
            Title      = $title
            FirstMsg   = $first
            Cwd        = $cwd
            Group      = $(if ($groupOf[$sid]) { $groupOf[$sid] } else { '未分组' })
            OwnerPath  = $(if ($ownerPathOf[$sid]) { $ownerPathOf[$sid] } else { $null })
            Pinned     = ($pinned -contains $sid)
            Archived   = ($archived -contains $sid)
            Created    = $created
            MB         = $mb
            HasBody    = $hasBody
            Enumerated = $null
        })
    }
    # 注意：不能写 @($rows)。PowerShell 7.6 对 List[object] 做 @() 数组化会抛
    # "Argument types do not match"，ToArray() 才是安全的转换。
    return $rows.ToArray()
}

function Select-SessionRows {
    param($Rows, [string]$PathFilter, [switch]$OnlyUngrouped, [string]$Keyword)

    $sel = @($Rows)
    if ($PathFilter) {
        $p = $PathFilter.TrimEnd('\', '/')
        $sel = @($sel | Where-Object { $_.OwnerPath -and ($_.OwnerPath.TrimEnd('\', '/') -ieq $p) })
    }
    if ($OnlyUngrouped) {
        $sel = @($sel | Where-Object { $_.Group -eq '未分组' })
    }
    if ($Keyword) {
        $sel = @($sel | Where-Object {
            ($_.Title    -and $_.Title    -like "*$Keyword*") -or
            ($_.FirstMsg -and $_.FirstMsg -like "*$Keyword*") -or
            ($_.Group    -and $_.Group    -like "*$Keyword*") -or
            ($_.Cwd      -and $_.Cwd      -like "*$Keyword*") -or
            ($_.Id                        -like "*$Keyword*")
        })
    }
    return @($sel)
}

# ---------------------------------------------------------------- 表格排版
# 终端里汉字占两列，而 -f 的宽度补白按"字符个数"算，所以中文一多整张表就歪。
# 下面按显示宽度补白，中文表格才对得齐。

function Get-TextWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or   # 谚文字母
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or   # CJK 部首 / 汉字 / 假名
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or   # 谚文音节
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or   # CJK 兼容汉字
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or   # CJK 兼容形式
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or   # 全角 ASCII
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 }
        else { $w += 1 }
    }
    return $w
}

function Format-Cell {
    param([string]$Text, [int]$Width, [switch]$Right)

    if (-not $Text) { $Text = '' }
    $Text = $Text -replace '\s+', ' '

    $w = Get-TextWidth $Text
    if ($w -gt $Width) {
        $sb = New-Object System.Text.StringBuilder
        $acc = 0
        foreach ($ch in $Text.ToCharArray()) {
            $cw = if ((Get-TextWidth ([string]$ch)) -eq 2) { 2 } else { 1 }
            if ($acc + $cw -gt $Width - 1) { break }
            [void]$sb.Append($ch)
            $acc += $cw
        }
        $Text = $sb.ToString() + '…'
        $w = $acc + 1
    }

    $pad = $Width - $w
    if ($pad -lt 0) { $pad = 0 }
    if ($Right) { return (' ' * $pad) + $Text }
    return $Text + (' ' * $pad)
}

function Get-SessionFlags {
    param($Row)
    $flag = @()
    if ($Row.Pinned)   { $flag += '钉' }
    if ($Row.Archived) { $flag += '档' }
    if (-not $Row.HasBody)          { $flag += '无正文' }
    if ($Row.Enumerated -eq $false) { $flag += 'DSH不显示' }
    return ($flag -join ' ')
}

# 列宽集中在这里，改一处表头和数据就一起动。
$script:ColDate  = 10
$script:ColSize  = 6
$script:ColFlag  = 10
$script:ColId    = 44      # session- + 36 位 uuid
$script:ColGroup = 26
$script:Gap      = 2

function Write-TableHeader {
    param([int]$TitleWidth, [switch]$WithGroup, [switch]$WithId)

    $cells = @((Format-Cell '创建时间' $script:ColDate), (Format-Cell '会话名称' $TitleWidth))
    if ($WithGroup) { $cells += (Format-Cell '所属工作区' $script:ColGroup) }
    $cells += (Format-Cell '大小' $script:ColSize -Right)
    $cells += (Format-Cell '标记' $script:ColFlag)
    if ($WithId) { $cells += (Format-Cell '会话 ID' $script:ColId) }

    $lineW = $script:ColDate + $script:Gap + $TitleWidth
    if ($WithGroup) { $lineW += $script:Gap + $script:ColGroup }
    $lineW += $script:Gap + $script:ColSize + $script:Gap + $script:ColFlag
    if ($WithId) { $lineW += $script:Gap + $script:ColId }

    Say ('    ' + ($cells -join (' ' * $script:Gap))) 'DarkGray'
    Say ('    ' + ([string]::new([char]0x2500, $lineW))) 'DarkGray'
}

function Write-SessionLine {
    param($Row, [switch]$WithId, [switch]$WithGroup, [int]$TitleWidth = 42)

    $d = if ($Row.Created) { $Row.Created.ToString('yyyy-MM-dd') } else { '' }
    $t = if ($Row.Title) { $Row.Title } else { '（无标题）' }

    $cells = @((Format-Cell $d $script:ColDate), (Format-Cell $t $TitleWidth))
    if ($WithGroup) { $cells += (Format-Cell $Row.Group $script:ColGroup) }
    $cells += (Format-Cell ("{0}MB" -f $Row.MB) $script:ColSize -Right)
    $cells += (Format-Cell (Get-SessionFlags $Row) $script:ColFlag)
    if ($WithId) { $cells += $Row.Id }

    Say ('    ' + ($cells -join (' ' * $script:Gap))) 'White'
}

function Show-SessionTable {
    param($Rows, [switch]$WithId, [switch]$Flat)

    $list = @($Rows | Sort-Object -Property @{Expression = { if ($_.Created) { $_.Created } else { [datetime]'1900-01-01' } }} -Descending)
    if ($list.Count -eq 0) { Say '  没有匹配的会话。' 'DarkGray'; return }

    if ($Flat) {
        # 平铺：没有 ■ 工作区行，所以要把工作区列出来
        Say ''
        Write-TableHeader -TitleWidth 38 -WithGroup -WithId:$WithId
        foreach ($r in $list) {
            Write-SessionLine -Row $r -WithId:$WithId -WithGroup -TitleWidth 38
        }
        return
    }

    $byGroup = @($list | Group-Object -Property Group)
    $named   = @($byGroup | Where-Object { $_.Name -ne '未分组' } | Sort-Object -Property Name)
    $unnamed = @($byGroup | Where-Object { $_.Name -eq '未分组' })
    $ordered = @($named) + @($unnamed)

    # 表头只印一次：它是全局说明，每个组都重复就成了噪音
    Say ''
    Write-TableHeader -TitleWidth 44 -WithId:$WithId

    foreach ($g in $ordered) {
        $one = @($g.Group)[0]
        Say ''
        $suffix = if ($g.Count -gt 1) { "  ·  $($g.Count) 条" } else { '' }
        Say ("  ■ {0}{1}" -f $g.Name, $suffix) 'Cyan'
        if ($one.OwnerPath) { Say ("    {0}" -f $one.OwnerPath) 'DarkGray' }

        foreach ($r in @($g.Group)) { Write-SessionLine -Row $r -WithId:$WithId -TitleWidth 44 }
    }
}

# ---------------------------------------------------------------- -List / -Workspaces

if ($List -or $ShowWorkspaces) {
    Say ''
    Say 'DSH 工作区（只读）' 'Cyan'
    Say ''
    for ($i = 0; $i -lt $workspaces.Count; $i++) {
        $w = $workspaces[$i]
        Say ("  [{0}] {1}" -f ($i + 1), $w.Path) 'White'
        Say ("      {0} 条会话" -f $w.SessionIds.Count) 'DarkGray'
    }
    $total = (@($workspaces | ForEach-Object { $_.SessionIds }) | Where-Object { $_ }).Count
    Say ''
    Say ("共 {0} 个工作区，{1} 条已登记会话" -f $workspaces.Count, $total) 'DarkGray'
    Say '全部会话：.\move-session.ps1    全量体检：.\move-session.ps1 -Repair' 'DarkGray'
    return
}

# ---------------------------------------------------------------- 默认：列会话

if (-not $Repair -and -not $Title -and -not $SessionId) {

    $pathFilter = $null
    if ($Path) {
        $pathFilter = Resolve-WorkspaceByPath $Path
        if (-not $pathFilter) {
            $want = $Path.Trim().Trim('"').TrimEnd('\', '/')
            Say ''
            Say ("没有工作区指向这个目录：{0}" -f $want) 'Yellow'

            # 常见的"输错地方"：数据根、正文目录、索引目录。各自给一句话说清该输什么。
            # 用字符串拼而不是 Join-Path：Join-Path 'Z:\x' 对不存在的驱动器会抛。
            if (Test-Path -LiteralPath ($want + '\storages\workspace.json')) {
                Say ''
                Say '  这是 DSH 的数据根，不是工作区目录。' 'Gray'
                Say '  想换数据根：在菜单里直接粘这个路径（外壳会识别），或加 -DataRoot。' 'Gray'
            }
            elseif ((Split-Path -Leaf $want) -ieq 'sessions') {
                Say ''
                Say '  这看着像会话正文目录（sessions），不是工作区目录。' 'Gray'
                Say '  工作区目录指的是你在 DSH 里新建工作区时指定的那个项目文件夹。' 'Gray'
            }
            elseif ((Split-Path -Leaf $want) -ieq 'storages') {
                Say ''
                Say '  这是 storages（DSH 的索引和登记），不是工作区目录。' 'Gray'
                Say '  想换数据根就用它的上一级。' 'Gray'
            }

            # 名字接近的（用户可能只记得项目名的一个片段）
            $leaf = Split-Path -Leaf $want
            if ($leaf) {
                $near = @($workspaces | Where-Object { $_.Path -and ($_.Path -like "*$leaf*") })
                if ($near.Count -gt 0) {
                    Say ''
                    Say '  名字里有这段的：' 'Gray'
                    foreach ($n in $near) { Say ('    ' + (Format-Cell $n.Title 26) + '  ' + $n.Path) 'White' }
                }
            }

            # 干脆把全部工作区路径摊开 —— 问"工作区文件夹在哪"，这就是答案
            Say ''
            Say '  现有工作区（左边是名字，右边就是文件夹路径，可直接复制）：' 'Gray'
            foreach ($w in $workspaces) {
                Say ('    ' + (Format-Cell $w.Title 26) + '  ' + $w.Path) 'White'
            }
            Say ''
            Say '  这些路径同时也是磁盘上的真实目录，可以直接在资源管理器里打开。' 'DarkGray'
            Say '  想看某个工作区的会话：把它的文件夹拖进窗口，或粘上面任意一行右边的路径。' 'DarkGray'
            return
        }
    }

    # -Verify：把 header 真实位置和 DSH 枚举结果一起核上（慢，但能看见"文件在却不显示"）
    $headerById = $null
    if ($Verify) {
        if (-not $nodeExe) {
            Say '  注意  未找到 node，header 校验跳过，位置与大小按索引推算。' 'Yellow'
        }
        else {
            try {
                $hs = Get-HeaderScan -NodeExe $nodeExe -SessionsRoot $SessRoot
                $headerById = @{}
                foreach ($h in $hs) { if ($h.id) { $headerById[$h.id] = $h } }
            }
            catch { Say ("  注意  header 扫描失败：{0}" -f $_.Exception.Message) 'Yellow' }
        }
    }

    $rows = Get-SessionRows -HeaderById $headerById

    if ($Verify -and $headerById -and $nodeExe) {
        $persist = Resolve-PersistenceModule
        if ($persist) {
            try {
                $art = Get-DshArtifacts -NodeExe $nodeExe -ModulePath $persist -SessionsRoot $SessRoot
                $ids = @($art.ids)
                foreach ($r in $rows) { $r.Enumerated = ($ids -contains $r.Id) }
            }
            catch { Say ("  注意  DSH 枚举失败：{0}" -f $_.Exception.Message) 'Yellow' }
        }
    }

    $sel = Select-SessionRows -Rows $rows -PathFilter $pathFilter -OnlyUngrouped:$Ungrouped -Keyword $Search

    # -Top：只看最近 N 条，改成平铺（分组会打散"最近"的语义）
    $useFlat = $false
    if ($Top -gt 0 -and @($sel).Count -gt $Top) {
        $sel = @($sel |
            Sort-Object -Property @{Expression = { if ($_.Created) { $_.Created } else { [datetime]'1900-01-01' } }} -Descending |
            Select-Object -First $Top)
        $useFlat = $true
    }

    $bodyCount = 0
    if (Test-Path -LiteralPath $SessRoot) {
        $bodyCount = @(Get-ChildItem -LiteralPath $SessRoot -Recurse -Depth 2 -File -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue).Count
    }

    $filtered = ($pathFilter -or $Ungrouped -or $Search)

    Say ''
    if ($pathFilter)    { Say ("DSH 会话 · {0}" -f $pathFilter) 'Cyan' }
    elseif ($Ungrouped) { Say 'DSH 会话 · 未分组' 'Cyan' }
    elseif ($Search)    { Say ("DSH 会话 · 搜索 «{0}»" -f $Search) 'Cyan' }
    elseif ($Top -gt 0) { Say ("DSH 会话 · 最近 {0} 条" -f $Top) 'Cyan' }
    else                { Say 'DSH 会话 · 全部' 'Cyan' }
    Say ("数据根 {0}" -f $DataRoot) 'DarkGray'

    Show-SessionTable -Rows $sel -WithId:$ShowId -Flat:$useFlat

    $unCount = @($rows | Where-Object { $_.Group -eq '未分组' }).Count
    Say ''
    if ($filtered) {
        Say ("  显示 {0} 条   （全库：索引 {1} 条 / 正文 {2} 个 / 未分组 {3} 条）" -f `
            @($sel).Count, @($rows).Count, $bodyCount, $unCount) 'DarkGray'
    }
    else {
        Say ("  索引 {0} 条 / 正文 {1} 个 / 未分组 {2} 条" -f @($rows).Count, $bodyCount, $unCount) 'DarkGray'
        if ($bodyCount -ne @($rows).Count) {
            Say ("  正文与索引差 {0} 条 —— 用 -Repair 看是哪几条。" -f [math]::Abs($bodyCount - @($rows).Count)) 'Yellow'
        }
    }
    if (-not $ShowId) { Say '  要会话 ID：菜单里选 [4]（可带关键词搜），或命令行加 -Id' 'DarkGray' }
    Say '  某条详情：-Title "关键词"   全量体检：-Repair   工作区清单：-List' 'DarkGray'
    return
}

# ---------------------------------------------------------------- 扫描

$headers = $null
$scanError = $null
if ($nodeExe) {
    try { $headers = Get-HeaderScan $nodeExe $SessRoot }
    catch { $scanError = $_.Exception.Message }
}
$headerById = @{}
if ($headers) { foreach ($h in $headers) { if ($h.id) { $headerById[$h.id] = $h } } }

# 第五道关的数据源：直接问 DSH 自己的 persistence 模块
$artifactIds = $null
$artifactSkipped = @()
$artifactError = $null
$persistenceModule = $null
if ($nodeExe) {
    $persistenceModule = Resolve-PersistenceModule
    if ($persistenceModule) {
        try {
            $art = Get-DshArtifacts -NodeExe $nodeExe -ModulePath $persistenceModule -SessionsRoot $SessRoot
            $artifactIds = @($art.ids)
            $artifactSkipped = @($art.skipped)
        }
        catch { $artifactError = $_.Exception.Message }
    }
}

function Get-Diagnosis {
    param([string]$Id)

    $owners = @($workspaces | Where-Object { $_.SessionIds -contains $Id })
    $owner = if ($owners.Count -ge 1) { $owners[0] } else { $null }
    $h = $headerById[$Id]

    $pcPath = Join-Path $PcDir "$Id.json"
    $pcExists = Test-Path -LiteralPath $pcPath
    $pcCwd = $null
    $title = $null
    if ($pcExists) {
        try {
            $j = Read-JsonFile $pcPath
            $title = $j.record.rows.title.val
        } catch {}
        $txt = [System.IO.File]::ReadAllText($pcPath)
        $m = [regex]::Match($txt, '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { $pcCwd = ($m.Groups[1].Value -replace '\\\\', '\') }
    }

    $actualFile = $null
    if ($h) { $actualFile = $h.file }
    else {
        foreach ($d in Get-ChildItem -LiteralPath $SessRoot -Directory -ErrorAction SilentlyContinue) {
            $c = Join-Path (Join-Path $d.FullName $Id) 'session.v4.jsonl.zstd'
            if (Test-Path -LiteralPath $c) { $actualFile = $c; break }
        }
    }

    $problems = New-Object System.Collections.Generic.List[string]

    if ($h -and $h.error) { $problems.Add("D header：解析失败 — $($h.error)") }

    if ($h -and $h.expected -and $actualFile) {
        $a = ($actualFile -replace '/', '\').TrimEnd('\')
        $e = ($h.expected -replace '/', '\').TrimEnd('\')
        if ($a -ine $e) {
            $problems.Add("C 位置：文件在 $actualFile")
            $problems.Add("          但 header 说应在 $($h.expected)")
        }
    }

    if ($h -and $h.cwd -and $pcCwd -and ($pcCwd.TrimEnd('\') -ine $h.cwd.TrimEnd('\'))) {
        $problems.Add("B 索引：索引 cwd=$pcCwd，header cwd=$($h.cwd)")
    }

    # 「未分组」不进 problems —— 它是 DSH 允许的正常状态，不是损坏。
    if ($owners.Count -gt 1) {
        $problems.Add("A 登记：同时登记在 $($owners.Count) 个工作区")
    }
    elseif ($owner -and $h -and $h.cwd -and ($h.cwd.TrimEnd('\') -ine $owner.Path.TrimEnd('\'))) {
        $problems.Add("A 登记：登记在 $($owner.Path)，header cwd 却是 $($h.cwd)")
    }

    # E 关：DSH 自己的枚举口径。这一关不过，前四关全绿也不显示。
    if ($null -ne $artifactIds) {
        if ($artifactIds -notcontains $Id) {
            $problems.Add('E 枚举：DSH 的 listArtifacts 里没有这条会话，侧边栏不会显示')
        }
    }

    return [pscustomobject]@{
        Id       = $Id
        Title    = $title
        Owner    = $owner
        Owners   = $owners
        Header   = $h
        PcCwd    = $pcCwd
        File     = $actualFile
        Problems = @($problems)
        Ok       = ($problems.Count -eq 0)
    }
}

# ---------------------------------------------------------------- 全量体检

if ($Repair) {
    Say ''
    Say 'DSH 会话体检（只读，不改任何文件）' 'Cyan'
    Say ''
    Say ("  数据根  {0}" -f $DataRoot) 'DarkGray'
    Say ("  Node    {0}" -f $(if ($nodeExe) { $nodeExe } else { '未找到' })) 'DarkGray'
    if (-not $nodeExe) {
        Say '  注意    未找到 node，header 校验已跳过 —— 下面的结论不完整。' 'Yellow'
        Say '          可用 -Node "C:\Program Files\nodejs\node.exe" 指定，header 校验需要 Node 22+ 的 zstd 支持。' 'Yellow'
    }
    elseif ($scanError) {
        Say ("  注意    header 扫描失败：{0}" -f $scanError) 'Yellow'
    }

    # 以「正文 ∪ 索引」为准，而不是只看登记表 —— 未分组的会话正好落在登记表外。
    $allIds = New-Object System.Collections.Generic.List[string]
    if ($headers) { foreach ($h in $headers) { if ($h.id -and -not $allIds.Contains($h.id)) { $allIds.Add($h.id) } } }
    if (Test-Path -LiteralPath $PcDir) {
        foreach ($f in Get-ChildItem -LiteralPath $PcDir -File -Filter *.json) {
            if (-not $allIds.Contains($f.BaseName)) { $allIds.Add($f.BaseName) }
        }
    }

    $results = @(foreach ($id in $allIds) { Get-Diagnosis $id })

    $mismA = @($results | Where-Object { @($_.Problems | Where-Object { $_ -like 'A *' }).Count -gt 0 })
    $mismB = @($results | Where-Object { @($_.Problems | Where-Object { $_ -like 'B *' }).Count -gt 0 })
    $mismC = @($results | Where-Object { @($_.Problems | Where-Object { $_ -like 'C *' }).Count -gt 0 })
    $mismD = @($results | Where-Object { @($_.Problems | Where-Object { $_ -like 'D *' }).Count -gt 0 })
    $mismE = @($results | Where-Object { @($_.Problems | Where-Object { $_ -like 'E *' }).Count -gt 0 })
    $bad     = @($results | Where-Object { -not $_.Ok })
    $noBody  = @($results | Where-Object { -not $_.File })
    $orphans = @($results | Where-Object { $_.File -and $_.Owners.Count -eq 0 })

    $pcCount = if (Test-Path -LiteralPath $PcDir) { @(Get-ChildItem -LiteralPath $PcDir -File -Filter *.json).Count } else { 0 }

    Say ''
    Say ("  正文 {0} 个 · 索引 {1} 个 · 去重 {2} 条" -f `
        $(if ($headers) { $headers.Count } else { 0 }), $pcCount, $allIds.Count) 'DarkGray'
    Say ''
    Say '  五道关：' 'Cyan'
    Say ("    A 登记     {0,3} 条不符（登记的工作区与 header cwd 冲突）" -f $mismA.Count) $(if ($mismA.Count) { 'Yellow' } else { 'Green' })
    Say ("    B 索引     {0,3} 条不符（索引 cwd ≠ header cwd）" -f $mismB.Count) $(if ($mismB.Count) { 'Yellow' } else { 'Green' })
    Say ("    C 位置     {0,3} 条不符（文件不在 header 指定目录）" -f $mismC.Count) $(if ($mismC.Count) { 'Red' } else { 'Green' })
    Say ("    D header   {0,3} 条异常（zstd 解不开）" -f $mismD.Count) $(if ($mismD.Count) { 'Red' } else { 'Green' })
    if ($null -eq $artifactIds) {
        $why = if (-not $nodeExe) { '未找到 node' } elseif ($artifactError) { "调用失败：$artifactError" } else { '未找到 DSH 的 persistence 模块' }
        Say ("    E 枚举     跳过（{0}）" -f $why) 'DarkGray'
    }
    else {
        Say ("    E 枚举     {0,3} 条不符（DSH 的 listArtifacts 里没有它，必不显示）" -f $mismE.Count) $(if ($mismE.Count) { 'Red' } else { 'Green' })
    }

    Say ''
    if ($orphans.Count -gt 0) {
        Say ("  未分组 {0} 条 —— DSH 允许不归类，不算错误。" -f $orphans.Count) 'DarkGray'
    }
    if ($noBody.Count -gt 0) {
        Say ("  索引残留 {0} 条 —— 索引还在但正文文件已不存在，DSH 按正文列举，不受影响。" -f $noBody.Count) 'DarkGray'
    }

    if ($bad.Count -eq 0) {
        Say ''
        Say '  没有发现需要处理的损坏。' 'Green'
        Say ''
        Say '  注：C 类为 0 是「能启动」的关键，E 类为 0 是「会显示」的关键。' 'DarkGray'
        return
    }

    Say ''
    Say ("  需要处理 {0} 条：" -f $bad.Count) 'Yellow'
    foreach ($r in $bad) {
        Say ''
        Say ("  {0}" -f $r.Id) 'White'
        if ($r.Title) { Say ("    {0}" -f $r.Title) 'DarkGray' }
        foreach ($p in $r.Problems) { Say ("    - {0}" -f $p) 'Yellow' }
    }

    if ($mismC.Count -gt 0) {
        Say ''
        Say '  C 类问题必须修，否则 DSH 启动时会抛 corrupt session log，' 'Red'
        Say '  整个工作区服务瘫痪（列表全空、新建报 service-unavailable）。' 'Red'
        Say '  修法只有一个方向：把文件搬回 header 指定的目录，绝不反过来改 header。' 'Yellow'
    }

    if ($mismE.Count -gt 0) {
        Say ''
        Say '  E 类问题：这些会话 DSH 枚举不到，侧边栏不会显示 —— 前四关全绿也没用。' 'Red'
        Say '  最常见原因是 header 帧的最后一个字节不是换行。DSH 的' 'Yellow'
        Say '  assertZstdHeaderFrame 要求 "第一个帧恰好是一行 header"，' 'Yellow'
        Say '  少那个 \n（207 变 206 字节）就会让 readFirstZstdLine 抛 corruption，' 'Yellow'
        Say '  listArtifacts 静默 continue，会话凭空消失且不报错。' 'Yellow'
        Say ''
        Say '  修复（只重压帧0，事件流不动，需 DSH 退出）：' 'Gray'
        Say '    .\experiment-move-session.ps1 -Repair' 'Gray'
    }
    return
}

# ---------------------------------------------------------------- 单条诊断

if (-not $SessionId) {
    if (-not (Test-Path -LiteralPath $PcDir)) { Say "找不到 $PcDir" 'Red'; exit 2 }
    $hits = @(
        foreach ($f in Get-ChildItem -LiteralPath $PcDir -File -Filter *.json) {
            try { $j = Read-JsonFile $f.FullName } catch { continue }
            $t = $j.record.rows.title.val
            if ($t -and $t -like "*$Title*") { [pscustomobject]@{ Id = $f.BaseName; Title = $t } }
        }
    )
    if ($hits.Count -eq 0) { Say "没有标题匹配 «$Title» 的会话。" 'Red'; return }
    if ($hits.Count -gt 1) {
        Say ''
        Say ("标题匹配到 {0} 条，选择一条看详情：" -f $hits.Count) 'Cyan'
        for ($i = 0; $i -lt $hits.Count; $i++) {
            $s = Get-Diagnosis $hits[$i].Id
            $where = if ($s.Owner) { $s.Owner.Title } else { '未分组' }
            Say ("  [{0}] {1}" -f ($i + 1), $hits[$i].Title) 'White'
            Say ("      {0}   当前在：{1}" -f $hits[$i].Id, $where) 'DarkGray'
        }
        Say ''
        $pick = Read-Host "输入编号（1-$($hits.Count)，回车取消）"
        if (-not $pick) { Say '已取消。' 'DarkGray'; return }
        $n = 0
        if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $hits.Count) {
            Say "编号无效：$pick" 'Red'; return
        }
        $SessionId = $hits[$n - 1].Id
    }
    else { $SessionId = $hits[0].Id }
}

$d = Get-Diagnosis $SessionId

Say ''
Say '会话详情（只读）' 'Cyan'
Say ''
Say ("  ID          {0}" -f $d.Id) 'DarkGray'
Say ("  标题        {0}" -f $d.Title) 'White'
Say ("  登记在      {0}" -f $(if ($d.Owner) { "$($d.Owner.Title)  ($($d.Owner.Path))" } else { '未分组' })) 'Gray'
Say ("  正文文件    {0}" -f $(if ($d.File) { $d.File } else { '（找不到）' })) 'Gray'
if ($d.Header -and -not $d.Header.error) {
    Say ("  header cwd  {0}" -f $d.Header.cwd) 'Gray'
    Say ("  header 认定 {0}" -f $d.Header.expected) 'Gray'
}
Say ("  索引 cwd    {0}" -f $(if ($d.PcCwd) { $d.PcCwd } else { '（无）' })) 'Gray'
if ($null -eq $artifactIds) {
    Say '  DSH 枚举    跳过（未找到 persistence 模块）' 'DarkGray'
}
elseif ($artifactIds -contains $d.Id) {
    Say '  DSH 枚举    在 listArtifacts 里' 'Green'
}
else {
    Say '  DSH 枚举    不在 listArtifacts 里 —— 这条会话不会被侧边栏显示' 'Red'
}
Say ''

if ($d.Ok) {
    Say '  五道关一致，这条会话健康。' 'Green'
}
else {
    Say '  发现不一致：' 'Yellow'
    foreach ($p in $d.Problems) { Say ("    - {0}" -f $p) 'Yellow' }
}
Say ''
Say '  迁移是可行的（2026-10-29 实测通过），但五个条件必须同时满足：' 'DarkGray'
Say '    1 header.cwd 改成目标目录，且 header 帧末尾必须带 \n' 'DarkGray'
Say '    2 正文目录搬到 encode(header.cwd) 对应位置' 'DarkGray'
Say '    3 索引 identity.cwd 同步' 'DarkGray'
Say '    4 workspace.json 登记到目标工作区' 'DarkGray'
Say '    5 DSH 的 listArtifacts 必须收录它（本关 E）' 'DarkGray'
Say '  只做其中一两条无效：只改登记会落到未分组，只搬文件会 corrupt。' 'DarkGray'
Say '  完整迁移用：.\experiment-move-session.ps1 -Apply（需先退出 DSH）' 'Gray'
Say ''
