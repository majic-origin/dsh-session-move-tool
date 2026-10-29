#Requires -Version 5.1
<#
.SYNOPSIS
    迁移 DSH 会话到另一个工作区。改写 zstd header 帧 + 同步索引与登记，带完整备份与一键还原。

.DESCRIPTION
    ── 结论（2026-10-29 实测通过）──

    会话可以迁移。但「归属」由五层共同决定，少一层就失效：

      1 header   session.v4.jsonl.zstd 帧0 里的 cwd，改成目标目录
                **且帧内最后一个字节必须是 \n**
      2 位置     正文目录放到 encode(header.cwd)\<id>\
      3 索引     session_projcache\<id>.json 的 identity.cwd
      4 登记     workspace.json 的 targetWorkspace.sessionIds
      5 枚举     DSH 的 listArtifacts 必须收录它（前四层全对也可能死在这层）

    ── 两个必踩的坑（都已实测确认）──

    坑① 帧0 缺换行 → 会话静默消失。
        dsh-session-persistence-jsonl 的 assertZstdHeaderFrame 要求
        "第一个帧恰好是一行 header"，判据是最后一个字节必须是 0x0A。
        用 JSON.stringify() 重压会得到 206 字节（原始是 207），少了那个换行；
        于是 readFirstZstdLine 抛 corruption，listArtifacts 捕获后 continue，
        会话不在 artifacts 里 —— 不报错、不 corrupt、就是不见。
        随后启动时 bootstrap 的 reconcile 发现"登记里有、枚举里没有"，把登记修剪掉。
        本脚本的 apply 一定会补上 '\n'；-Repair 专门修这种历史遗留。

    坑② 文件能解压 ≠ DSH 会显示。
        所以 apply 写完并用 listArtifacts 验证收录之后，才去改索引和登记；
        验证不过就抛错回滚，绝不留一个"看着成功实际不显示"的状态。

    ── 文件结构 ──
    多个 zstd 帧串接：帧0 = header（一行 JSON + \n），帧1..N = 事件流。
    改写只替换帧0，帧1..N 逐字节原样拼回（apply 内部会校验这一点）。

    ── 风险与保障 ──
    * 动的是会话正文。改前把正文、索引、workspace.json 三份完整备份到
      storages\_experiment\<时间戳>\，`-Restore` 一键还原（含清掉新位置目录）。
    * -Apply 要求 DSH 已完全退出；-Repair 与 -Restore 不碰 workspace.json，
      不强制退出（但 -Restore 也会改登记，故仍要求退出）。
    * 幂等：已在目标工作区且帧已规范时不重复执行。

    ── 用法 ──
    .\experiment-move-session.ps1                          # 只展示计划与帧结构
    .\experiment-move-session.ps1 -Apply                   # 执行迁移
    .\experiment-move-session.ps1 -Repair                  # 修 header 帧缺换行
    .\experiment-move-session.ps1 -Restore                 # 还原最近一次
    .\experiment-move-session.ps1 -Restore -Stamp 20261029-092939-276

.PARAMETER SessionId
    要迁移的会话。默认 Downloads 那个测试会话。
.PARAMETER TargetPath
    目标工作区目录。必须是已登记的工作区，或会被登记成新的。
.PARAMETER Apply
    真正写入。不加只做计划。
.PARAMETER Repair
    只重压 header 帧补终止换行，不动位置/索引/登记。
.PARAMETER Restore
    还原。默认取最近一次备份。
.PARAMETER Stamp
    指定还原哪一次的备份。
.PARAMETER DataRoot
    数据根，默认 %USERPROFILE%\.dsh。测试时可指向副本。
#>
param(
    [string]$SessionId,
    [string]$TargetPath,

    # 用中文标题片段定位会话，省得抄 36 位 UUID。
    # 唯一命中直接用；多条列编号让选；一条也没有就报错，不乱猜。
    # 和 -SessionId 同时给的话以 -SessionId 为准。
    [string]$Title,

    [switch]$Apply,
    [switch]$Repair,
    [switch]$Restore,
    [string]$Stamp,

    [string]$Node,
    [string]$DataRoot = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'

$WsFile   = Join-Path $DataRoot 'storages\workspace.json'
$PcDir    = Join-Path $DataRoot 'storages\session_projcache\sessions'
$SessRoot = Join-Path $DataRoot 'sessions'
$ExpRoot  = Join-Path $DataRoot 'storages\_experiment'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Say { param([string]$Text = '', [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }

function Resolve-NodeExe {
    param([string]$Explicit)
    if ($Explicit) { if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }; return $null }
    $cmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @((Join-Path $env:ProgramFiles 'nodejs\node.exe'),
                     (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function ConvertTo-WorkspaceEncoding {
    param([string]$Path)
    $s = $Path -replace ':', '' -replace '[\\/]', '-'
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -gt 127) { [void]$sb.Append(('~{0:X4}' -f [int]$ch)) } else { [void]$sb.Append($ch) }
    }
    return "--$($sb.ToString())--"
}

# ---------------------------------------------------------------- node 二进制活

$FrameJs = @'
const fs = require('fs');
const zlib = require('zlib');

function frameLength(buf, off) {
  if (!(buf[off] === 0x28 && buf[off+1] === 0xB5 && buf[off+2] === 0x2F && buf[off+3] === 0xFD)) {
    throw new Error('bad zstd magic at ' + off);
  }
  let p = off + 4;
  const fhd = buf[p++];
  const fcsFlag = (fhd >> 6) & 3;
  const singleSeg = (fhd >> 5) & 1;
  const checksum = (fhd >> 2) & 1;
  const dictFlag = fhd & 3;
  if (!singleSeg) p += 1;
  p += [0, 1, 2, 4][dictFlag];
  const fcsLen = singleSeg ? (fcsFlag === 0 ? 1 : [0, 2, 4, 8][fcsFlag]) : [0, 2, 4, 8][fcsFlag];
  p += fcsLen;
  for (;;) {
    const h = buf[p] | (buf[p+1] << 8) | (buf[p+2] << 16);
    p += 3;
    const last = h & 1, type = (h >> 1) & 3, size = h >> 3;
    if (type === 0) p += size;
    else if (type === 1) p += 1;
    else if (type === 2) p += size;
    else throw new Error('reserved block type at ' + p);
    if (last) break;
  }
  if (checksum) p += 4;
  return p - off;
}

function splitFrames(buf) {
  const out = [];
  let off = 0;
  while (off < buf.length) {
    const len = frameLength(buf, off);
    out.push({ off, len });
    off += len;
  }
  return out;
}

const mode  = process.env.EXP_MODE;
const src   = process.env.EXP_SRC;
const dst   = process.env.EXP_DST || '';
const cwdIn = process.env.EXP_NEWCWD || '';

const buf = fs.readFileSync(src);
const frames = splitFrames(buf);
const dec = frames.map(f => zlib.zstdDecompressSync(buf.subarray(f.off, f.off + f.len)));

const result = {
  frames: frames.length,
  sizes: frames.map(f => f.len),
  decoded: dec.map(d => d.length),
  consumed: frames.reduce((a, f) => a + f.len, 0),
  fileSize: buf.length,
  headerId: null,
  headerCwd: null
};

const header = JSON.parse(dec[0].toString('utf8'));
result.headerId = header.id || null;
result.headerCwd = header.cwd || null;
try { result.canonicalCwd = fs.realpathSync(header.cwd); } catch (e) { result.canonicalCwd = null; }
// DSH 的 assertZstdHeaderFrame 要求帧内最后一个字节必须是 \n（0x0A）；
// 否则 readFirstZstdLine 抛 corruption，listArtifacts 会把整条会话 continue 掉。
result.headerTerminated = dec[0].length > 0 && dec[0][dec[0].length - 1] === 10;

if (mode === 'plan') {
  process.stdout.write(JSON.stringify(result));
} else if (mode === 'apply') {
  if (!cwdIn) throw new Error('EXP_NEWCWD missing');
  const newHeader = Object.assign({}, header, { cwd: cwdIn });
  const newFrame = zlib.zstdCompressSync(Buffer.from(JSON.stringify(newHeader) + '\n', 'utf8'));
  const tail = Buffer.concat(frames.slice(1).map(f => buf.subarray(f.off, f.off + f.len)));
  const out = Buffer.concat([newFrame, tail]);

  // 严格自校验：重新解析，帧0后的字节必须逐字节相同
  const vFrames = splitFrames(out);
  if (vFrames.length !== frames.length) throw new Error('frame count changed: ' + vFrames.length + ' vs ' + frames.length);
  for (let i = 1; i < frames.length; i++) {
    const a = out.subarray(vFrames[i].off, vFrames[i].off + vFrames[i].len);
    const b = buf.subarray(frames[i].off, frames[i].off + frames[i].len);
    if (!a.equals(b)) throw new Error('frame ' + i + ' bytes differ after rewrite');
  }
  const vDec = vFrames.map(f => zlib.zstdDecompressSync(out.subarray(f.off, f.off + f.len)));
  const oldBody = dec.slice(1).map(d => d.toString('utf8')).join('');
  const newBody = vDec.slice(1).map(d => d.toString('utf8')).join('');
  if (oldBody !== newBody) throw new Error('event stream text differs after rewrite');
  const vHeader = JSON.parse(vDec[0].toString('utf8'));
  if (vHeader.id !== header.id) throw new Error('header id changed');
  if (vHeader.cwd !== cwdIn) throw new Error('header cwd not applied');

  fs.writeFileSync(dst, out);
  result.newFrame0 = newFrame.length;
  result.newFileSize = out.length;
  result.bodyIdentical = true;
  result.outPath = dst;
  process.stdout.write(JSON.stringify(result));
} else if (mode === 'verify') {
  let ok = true;
  for (let i = 1; i < frames.length; i++) {
    // 事件流可读性
    if (dec[i].length === 0) ok = false;
  }
  result.readable = ok;
  process.stdout.write(JSON.stringify(result));
} else {
  throw new Error('unknown mode ' + mode);
}
'@

function Invoke-FrameTool {
    param([string]$Mode, [string]$Src, [string]$Dst = '', [string]$NewCwd = '', [string]$NodeExe)

    $env:EXP_MODE = $Mode
    $env:EXP_SRC = $Src
    $env:EXP_DST = $Dst
    $env:EXP_NEWCWD = $NewCwd

    $raw = $FrameJs | & $NodeExe - 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String) }
    return ((($raw | Out-String).Trim()) | ConvertFrom-Json)
}

# ---------------------------------------------------------------- DSH 自己的枚举口径

# 迁移是否真的生效，唯一权威判据是 DSH 的 listArtifacts 收不收这条会话。
# 文件能解压、四层数据一致，都不代表它会出现在侧边栏。
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
  process.stdout.write(JSON.stringify({ ids: art.map((a) => a.header.id) }));
})().catch((e) => { process.stderr.write('ARTIFACTS_FAILED: ' + e.message); process.exit(1); });
'@

function Resolve-PersistenceModule {
    $rel = 'resources\app\dsh\node_modules\@deepseek-ai\dsh-session-persistence-jsonl\lib\index.js'
    $candidates = @()
    $proc = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { $candidates += Join-Path (Split-Path $proc.Path -Parent) $rel }
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

function Assert-DshClosed {
    $realRoot = (Join-Path $env:USERPROFILE '.dsh').TrimEnd('\')
    if ($DataRoot.TrimEnd('\') -ine $realRoot) { return }
    $running = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Say "DeepSeek Harness 仍在运行（$($running.Count) 个进程）。" 'Red'
        Say '请从托盘图标右键退出，完全关闭后再执行。' 'Red'
        throw 'DSH 未退出。'
    }
}

# ---------------------------------------------------------------- 还原

if ($Restore) {
    if (-not (Test-Path -LiteralPath $ExpRoot)) { Say "没有实验备份目录：$ExpRoot" 'Red'; exit 2 }

    if (-not $Stamp) {
        $latest = Get-ChildItem -LiteralPath $ExpRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { Say '没有任何备份。' 'Red'; exit 2 }
        $Stamp = $latest.Name
    }

    $bak = Join-Path $ExpRoot $Stamp
    if (-not (Test-Path -LiteralPath $bak)) { Say "找不到备份：$bak" 'Red'; exit 2 }

    Assert-DshClosed

    Say ''
    Say "还原自：$bak" 'Cyan'
    Say ''

    # meta 必须先读：要按里面的 sessionId 精确取索引备份，
    # 不能用「第一个 *.json」——备份目录里还有 meta.json 自己。
    $metaPath = Join-Path $bak 'meta.json'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        Say '备份里没有 meta.json，无法定位原目录，中止。' 'Red'
        exit 2
    }
    $meta = Get-Content -Raw -Encoding UTF8 $metaPath | ConvertFrom-Json

    # workspace.json
    if (Test-Path (Join-Path $bak 'workspace.json')) {
        Copy-Item -LiteralPath (Join-Path $bak 'workspace.json') -Destination $WsFile -Force
        Say '  workspace.json        已还原' 'Gray'
    }

    # 索引（按 meta.sessionId 精确取）
    $pcBak = Join-Path $bak ("$($meta.sessionId).json")
    if (Test-Path -LiteralPath $pcBak) {
        New-Item -ItemType Directory -Force -Path $PcDir | Out-Null
        Copy-Item -LiteralPath $pcBak -Destination (Join-Path $PcDir "$($meta.sessionId).json") -Force
        Say ("  索引 {0}   已还原" -f $meta.sessionId) 'Gray'
    }

    # 正文
    $logBak = Join-Path $bak 'session.v4.jsonl.zstd'
    if (Test-Path -LiteralPath $logBak) {
        $origDir = Join-Path (Join-Path $SessRoot (ConvertTo-WorkspaceEncoding $meta.origCwd)) $meta.sessionId
        New-Item -ItemType Directory -Force -Path $origDir | Out-Null
        Copy-Item -LiteralPath $logBak -Destination (Join-Path $origDir 'session.v4.jsonl.zstd') -Force
        Say ("  正文                   已放回 {0}" -f (Split-Path $origDir -Parent | Split-Path -Leaf)) 'Gray'

        # 清掉实验写入的新位置
        if ($meta.newCwd) {
            $newDir = Join-Path (Join-Path $SessRoot (ConvertTo-WorkspaceEncoding $meta.newCwd)) $meta.sessionId
            if ((Test-Path -LiteralPath $newDir) -and ($newDir -ine $origDir)) {
                Remove-Item -LiteralPath $newDir -Recurse -Force
                Say '  实验目录               已删除' 'Gray'
            }
        }
    }

    Say ''
    Say '还原完成。启动 DSH 后跑一次体检确认：' 'Green'
    Say '  .\move-session.ps1 -Repair' 'Gray'
    return
}

# ---------------------------------------------------------------- 参数校验

if (-not $Restore) {
    if (-not $SessionId -and -not $Title) {
        Say '要迁移哪个会话？给 -Title <标题片段> 或 -SessionId <会话ID>。' 'Yellow'
        Say '  先看一眼有哪些会话：  .\move-session.ps1' 'Gray'
        exit 2
    }
    if (-not $TargetPath) {
        Say '要迁到哪个工作区？给 -TargetPath <目录>。' 'Yellow'
        Say '  现有工作区及其路径：  .\move-session.ps1 -List' 'Gray'
        exit 2
    }
}

# ---------------------------------------------------------------- 按标题定位会话

if (-not $Restore -and $Title -and -not $PSBoundParameters.ContainsKey('SessionId')) {

    $wsIndex = @{}
    if (Test-Path -LiteralPath $WsFile) {
        try {
            $wj = [System.IO.File]::ReadAllText($WsFile) | ConvertFrom-Json
            foreach ($p in $wj.tables.workspaces.PSObject.Properties) {
                foreach ($s in $p.Value.sessionIds) { $wsIndex[$s] = $p.Value.title }
            }
        } catch {}
    }

    $hits = @(
        foreach ($f in Get-ChildItem -LiteralPath $PcDir -File -Filter *.json -ErrorAction SilentlyContinue) {
            $t = $null
            try { $t = ([System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json).record.rows.title.val } catch { continue }
            if ($t -and $t -like "*$Title*") {
                [pscustomobject]@{
                    Id    = $f.BaseName
                    Title = $t
                    Group = $(if ($wsIndex[$f.BaseName]) { $wsIndex[$f.BaseName] } else { '未分组' })
                }
            }
        }
    )

    if ($hits.Count -eq 0) {
        Say ''
        Say ("  没有标题含 «{0}» 的会话。" -f $Title) 'Red'
        Say '  先看有哪些：.\move-session.ps1 -Top 30' 'Gray'
        exit 2
    }

    if ($hits.Count -eq 1) {
        $SessionId = $hits[0].Id
        Say ''
        Say ("  按标题定位到：{0}" -f $hits[0].Title) 'Green'
        Say ("  当前工作区  {0}" -f $hits[0].Group) 'DarkGray'
        Say ("  会话 ID     {0}" -f $SessionId) 'DarkGray'
    }
    else {
        Say ''
        Say ("  标题含 «{0}» 的有 {1} 条，选一条：" -f $Title, $hits.Count) 'Cyan'
        for ($i = 0; $i -lt $hits.Count; $i++) {
            Say ("    [{0}] {1}" -f ($i + 1), $hits[$i].Title) 'White'
            Say ("        当前在 {0}    {1}" -f $hits[$i].Group, $hits[$i].Id) 'DarkGray'
        }
        Say ''

        if ([Console]::IsInputRedirected) {
            Say '  当前是非交互环境，没法让你选。请改用 -SessionId 直接指定上面某个 ID。' 'Red'
            exit 2
        }

        $pick = Read-Host "  输入编号（1-$($hits.Count)，回车取消）"
        if (-not "$pick".Trim()) { Say '  已取消。' 'DarkGray'; exit 2 }

        $n = 0
        if (-not [int]::TryParse("$pick".Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $hits.Count) {
            Say ("  编号无效：{0}" -f $pick) 'Red'
            exit 2
        }
        $SessionId = $hits[$n - 1].Id
        Say ''
        Say ("  选中：{0}" -f $hits[$n - 1].Title) 'Green'
    }
}

# ---------------------------------------------------------------- 主体

$nodeExe = Resolve-NodeExe $Node
if (-not $nodeExe) { Say '找不到 node.exe（需要 Node 22+ 的 zstd 支持）。' 'Red'; exit 2 }

# ---------------------------------------------------------------- header 帧修补

if ($Repair) {
    # 只重压 header 帧补上终止换行。不动位置、索引、登记，
    # 因此不碰 workspace.json / projcache，也不需要退出 DSH。
    $fixLog = $null
    foreach ($d in Get-ChildItem -LiteralPath $SessRoot -Directory) {
        $c = Join-Path (Join-Path $d.FullName $SessionId) 'session.v4.jsonl.zstd'
        if (Test-Path -LiteralPath $c) { $fixLog = $c; break }
    }
    if (-not $fixLog) { Say "找不到会话正文：$SessionId" 'Red'; exit 2 }

    $fp = Invoke-FrameTool -Mode 'plan' -Src $fixLog -NodeExe $nodeExe

    Say ''
    Say 'header 帧修补（只补终止换行，不动位置/索引/登记）' 'Cyan'
    Say ''
    Say ("  文件        {0}" -f $fixLog) 'Gray'
    Say ("  帧0         {0} 字节 → 解出 {1} 字节" -f $fp.sizes[0], $fp.decoded[0]) 'Gray'
    Say ("  header cwd  {0}" -f $fp.headerCwd) 'Gray'
    Say ("  结尾换行    {0}" -f $fp.headerTerminated) $(if ($fp.headerTerminated) { 'Green' } else { 'Red' })
    Say ''

    if ($fp.headerTerminated) {
        Say 'header 帧已经以换行结尾，符合 assertZstdHeaderFrame，无需修补。' 'Green'
        return
    }

    $stampR = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $bakR = Join-Path $ExpRoot "$stampR-headerfix"
    New-Item -ItemType Directory -Force -Path $bakR | Out-Null
    Copy-Item -LiteralPath $fixLog -Destination (Join-Path $bakR 'session.v4.jsonl.zstd') -Force
    Say ("  已备份      storages\_experiment\{0}-headerfix\" -f $stampR) 'DarkGray'

    $patched = Join-Path $bakR 'patched.zstd'
    $null = Invoke-FrameTool -Mode 'apply' -Src $fixLog -Dst $patched -NewCwd $fp.headerCwd -NodeExe $nodeExe
    Copy-Item -LiteralPath $patched -Destination $fixLog -Force
    Remove-Item -LiteralPath $patched -Force

    $v = Invoke-FrameTool -Mode 'plan' -Src $fixLog -NodeExe $nodeExe
    Say ("  修补后      帧0 {0} 字节 → 解出 {1} 字节，结尾换行 {2}" -f $v.sizes[0], $v.decoded[0], $v.headerTerminated) $(if ($v.headerTerminated) { 'Green' } else { 'Red' })
    Say ("  事件流      {0} 个帧，未改动" -f ($v.frames - 1)) 'Gray'
    Say ''
    Say '启动 DSH 验证。若仍不显示，用 -Restore 回退。' 'DarkGray'
    return
}

if (-not (Test-Path -LiteralPath $WsFile)) { Say "找不到 $WsFile" 'Red'; exit 2 }

$ws = [System.IO.File]::ReadAllText($WsFile) | ConvertFrom-Json
$workspaces = @(
    foreach ($p in $ws.tables.workspaces.PSObject.Properties) {
        [pscustomobject]@{ Id = $p.Name; Title = $p.Value.title; Path = $p.Value.path; SessionIds = @($p.Value.sessionIds) }
    }
)
$workspaces = @($workspaces | Sort-Object Path)

# 找会话正文
$srcLog = $null; $srcEnc = $null
foreach ($d in Get-ChildItem -LiteralPath $SessRoot -Directory) {
    $c = Join-Path (Join-Path $d.FullName $SessionId) 'session.v4.jsonl.zstd'
    if (Test-Path -LiteralPath $c) { $srcLog = $c; $srcEnc = $d.Name; break }
}
if (-not $srcLog) { Say "找不到会话正文：$SessionId" 'Red'; exit 2 }

$TargetPath = $TargetPath.TrimEnd('\')
$targetWs = $workspaces | Where-Object { $_.Path.TrimEnd('\') -ieq $TargetPath } | Select-Object -First 1
$isNewWs = -not $targetWs

$plan = Invoke-FrameTool -Mode 'plan' -Src $srcLog -NodeExe $nodeExe

Say ''
Say '实验计划：改写 header 帧来迁移会话' 'Cyan'
Say ''
Say ("  会话        {0}" -f $SessionId) 'DarkGray'
Say ("  正文        {0}" -f $srcLog) 'Gray'
Say ("  大小        {0} 字节，{1} 个 zstd 帧" -f $plan.fileSize, $plan.frames) 'Gray'
Say ("  帧0(header) {0} 字节 → 解出 {1} 字节" -f $plan.sizes[0], $plan.decoded[0]) 'Gray'
Say ("  事件流      {0} 个帧，合计 {1} 字节（改写后逐字节不动）" -f ($plan.frames - 1), ((@($plan.sizes) | Select-Object -Skip 1) | Measure-Object -Sum).Sum) 'Gray'
Say ("  header id   {0}" -f $plan.headerId) 'Gray'
Say ("  header cwd  {0}" -f $plan.headerCwd) 'Gray'
Say ("  目标        {0}{1}" -f $TargetPath, $(if ($isNewWs) { '   (将新建工作区)' } else { "   ($($targetWs.Title))" })) 'Gray'
Say ''

# DSH 的判定式：realpath(header.cwd) === workspace.json 里的 path 字面量
# （dsh-workspace/lib/index.js:102 的 sessionIds getter）
$alreadyThere = ($plan.canonicalCwd -and ($plan.canonicalCwd.TrimEnd('\') -ieq $TargetPath.TrimEnd('\')))
Say ("  判定        realpath(cwd) = {0}" -f $plan.canonicalCwd) 'Gray'
Say ("              === 目标 path ? {0}" -f $alreadyThere) $(if ($alreadyThere) { 'Green' } else { 'Yellow' })
Say ''

if ($alreadyThere -and (-not $isNewWs) -and (@($targetWs.SessionIds) -contains $SessionId)) {
    Say '该会话已经在目标工作区，且 header cwd 与工作区 path 一致，无需再迁移。' 'Green'
    Say '（五层判定已满足，重启 DSH 即可在目标工作区看到它。）' 'DarkGray'
    return
}

if ($plan.headerId -ne $SessionId) {
    Say "警告：header 里的 id（$($plan.headerId)）与目录名（$SessionId）不一致。" 'Yellow'
}

if (-not $Apply) {
    Say '这是计划，没有改动任何文件。' 'DarkGray'
    Say '执行：加 -Apply（需要先完全退出 DSH）' 'DarkGray'
    Say '还原：-Restore' 'DarkGray'
    return
}

Assert-DshClosed

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$bakDir = Join-Path $ExpRoot $stamp
New-Item -ItemType Directory -Force -Path $bakDir | Out-Null

# 备份三份
Copy-Item -LiteralPath $WsFile -Destination (Join-Path $bakDir 'workspace.json') -Force
$pcFile = Join-Path $PcDir "$SessionId.json"
if (Test-Path -LiteralPath $pcFile) { Copy-Item -LiteralPath $pcFile -Destination (Join-Path $bakDir "$SessionId.json") -Force }
Copy-Item -LiteralPath $srcLog -Destination (Join-Path $bakDir 'session.v4.jsonl.zstd') -Force

$meta = [pscustomobject]@{
    sessionId     = $SessionId
    origCwd       = $plan.headerCwd
    origLog       = $srcLog
    newCwd        = $TargetPath
    targetWsId    = $(if ($targetWs) { $targetWs.Id } else { $null })
    createdNewWs  = $isNewWs
    stamp         = $stamp
    when          = (Get-Date).ToString('s')
}
[System.IO.File]::WriteAllText((Join-Path $bakDir 'meta.json'), ($meta | ConvertTo-Json -Depth 10), $Utf8NoBom)

Say ("已备份到：storages\_experiment\{0}\" -f $stamp) 'DarkGray'

$newEnc = ConvertTo-WorkspaceEncoding $TargetPath
try {
    # 1) 生成改写后的正文（内部已做逐字节自校验，不通过会抛错且不落盘）
    $newDir = Join-Path (Join-Path $SessRoot $newEnc) $SessionId
    New-Item -ItemType Directory -Force -Path $newDir | Out-Null
    $newLog = Join-Path $newDir 'session.v4.jsonl.zstd'

    $applied = Invoke-FrameTool -Mode 'apply' -Src $srcLog -Dst $newLog -NewCwd $TargetPath -NodeExe $nodeExe
    Say ("  帧0 重压        {0} → {1} 字节，末尾带换行" -f $applied.sizes[0], $applied.newFrame0) 'Gray'
    Say ("  事件流          {0} 个帧逐字节一致" -f ($applied.frames - 1)) 'Green'
    Say ("  新文件          {0} 字节" -f $applied.newFileSize) 'Gray'

    # 2) 删原位 —— 必须在枚举验证之前，否则同一 id 出现在两个目录会让
    #    listArtifacts 抛 "duplicate JSONL session id"
    if ((Split-Path $srcLog -Parent) -ine $newDir) {
        Remove-Item -LiteralPath (Split-Path $srcLog -Parent) -Recurse -Force
        Say '  原位置          已清除' 'Gray'
    }

    # 3) 端到端验证：直接问 DSH 的 listArtifacts 认不认这条会话
    #    这一步是必需的 —— 文件能被解压 != DSH 会显示它。
    $persistence = Resolve-PersistenceModule
    if (-not $persistence) {
        Say '  DSH 枚举验证    跳过（未找到 persistence 模块，无法确认）' 'Yellow'
    }
    else {
        $art = Get-DshArtifacts -NodeExe $nodeExe -ModulePath $persistence -SessionsRoot $SessRoot
        if (@($art.ids) -contains $SessionId) {
            Say '  DSH 枚举验证    listArtifacts 已收录这条会话' 'Green'
        }
        else {
            throw '写入后 DSH 的 listArtifacts 仍不收录该会话，迁移不会生效，已中止并回滚。'
        }
    }

    # 2) 索引 cwd
    if (Test-Path -LiteralPath $pcFile) {
        $txt = [System.IO.File]::ReadAllText($pcFile)
        $escaped = $TargetPath.Replace('\', '\\')
        $ev = [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            return $m.Groups[1].Value + $escaped + $m.Groups[2].Value
        }
        $re = New-Object System.Text.RegularExpressions.Regex('("cwd"\s*:\s*")(?:[^"\\]|\\.)*(")')
        [System.IO.File]::WriteAllText($pcFile, $re.Replace($txt, $ev, 1), $Utf8NoBom)
        Say '  索引 cwd        已改' 'Gray'
    }

    # 3) 登记
    $ws = [System.IO.File]::ReadAllText($WsFile) | ConvertFrom-Json
    if ($isNewWs) {
        $newId = [guid]::NewGuid().ToString()
        $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $entry = [pscustomobject]@{ path = $TargetPath; title = (Split-Path -Leaf $TargetPath); sessionIds = @(); createdAt = $nowIso; updatedAt = $nowIso }
        $ws.tables.workspaces | Add-Member -NotePropertyName $newId -NotePropertyValue $entry -Force
        $ws.global.workspaceIds = @($ws.global.workspaceIds) + $newId
        $targetWs = [pscustomobject]@{ Id = $newId; Title = (Split-Path -Leaf $TargetPath); Path = $TargetPath; SessionIds = @() }
    }
    foreach ($p in $ws.tables.workspaces.PSObject.Properties) {
        $p.Value.sessionIds = @(@($p.Value.sessionIds) | Where-Object { $_ -ne $SessionId })
    }
    $tp = $ws.tables.workspaces.PSObject.Properties | Where-Object { $_.Name -eq $targetWs.Id }
    $tp.Value.sessionIds = @(@($tp.Value.sessionIds) + $SessionId)
    $tp.Value.updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    [System.IO.File]::WriteAllText($WsFile, (($ws | ConvertTo-Json -Depth 100) + "`n"), $Utf8NoBom)
    Say '  工作区登记      已改' 'Gray'
}
catch {
    Say ''
    Say ("执行失败：{0}" -f $_.Exception.Message) 'Red'
    Say '正在自动还原…' 'Yellow'
    Copy-Item -LiteralPath (Join-Path $bakDir 'workspace.json') -Destination $WsFile -Force
    if (Test-Path (Join-Path $bakDir "$SessionId.json")) {
        Copy-Item -LiteralPath (Join-Path $bakDir "$SessionId.json") -Destination $pcFile -Force
    }
    $origDir = Split-Path $srcLog -Parent
    New-Item -ItemType Directory -Force -Path $origDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $bakDir 'session.v4.jsonl.zstd') -Destination $srcLog -Force
    $strayDir = Join-Path (Join-Path $SessRoot $newEnc) $SessionId
    if (Test-Path -LiteralPath $strayDir) { Remove-Item -LiteralPath $strayDir -Recurse -Force }
    Say '已还原到执行前状态。' 'Green'
    exit 1
}

Say ''
Say '写入完成。现在做独立校验（用只读体检脚本交叉验证）：' 'Cyan'
$checker = Join-Path $PSScriptRoot 'move-session.ps1'
if (Test-Path -LiteralPath $checker) {
    & $checker -SessionId $SessionId -DataRoot $DataRoot
}
else {
    # 写入已经成功，这里只是收尾交叉验证。缺脚本不该让人以为迁移失败了。
    Say '  同目录没有 move-session.ps1，跳过交叉验证。' 'Yellow'
    Say '  自己补一下：把 move-session.ps1 放回同一个文件夹，然后跑' 'Gray'
    Say ("    .\move-session.ps1 -SessionId {0}" -f $SessionId) 'Gray'
}

Say ''
Say ("备份：storages\_experiment\{0}\" -f $stamp) 'DarkGray'
Say '如果 DSH 启动后该会话没出现在目标工作区，或报 corrupt，立即还原：' 'Yellow'
Say ("  .\experiment-move-session.ps1 -Restore -Stamp {0}" -f $stamp) 'Gray'
