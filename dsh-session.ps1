#Requires -Version 5.1
<#
.SYNOPSIS
    DSH 会话工具统一入口。双击、拖文件夹、命令行三种启动方式都能用，一个窗口看完全部会话。

.DESCRIPTION
    ── 它跟另外两个脚本的关系 ──

    dsh-session.ps1（本文件）  交互外壳。负责启动方式、菜单、暂停窗口。
    move-session.ps1           只读引擎。列会话 / 搜索 / 详情 / 五道关体检。
    experiment-move-session.ps1 写操作引擎。迁移 / 修 header / 还原。

    外壳自己不做业务，只把动作转发给引擎。所以命令行用法和原来完全一致，
    原来记的命令不用改。

    ── 三种启动方式 ──

    ① 双击 dsh-session.cmd        进菜单。菜单里可以直接把文件夹拖进窗口，
                                  也可以粘贴路径或输关键词。
    ② 把文件夹拖到 .cmd 图标上    不走菜单，直接列出该目录对应工作区的会话。
                                  拖 .dsh 数据根进来则整库换数据根。
    ③ 命令行                      dsh-session.cmd -Repair
                                  dsh-session.cmd -Search gif
                                  dsh-session.cmd -Top 20 -Id

    ── 优先级（严格按这个顺序）──

    1 拖进来的裸路径 / -Path    有就直接用，不再问
    2 明确动作参数              转发给引擎，执行完退出
    3 都没有                    交互环境进菜单；管道/批处理则列全部会话后退出

    ── 窗口停住的判定 ──

    输入或输出被重定向（管道、批处理、`| more`）时不停，否则双击后按回车才关。
    命令行里嫌烦加 -NoPause。

.PARAMETER Bare
    拖进来的文件夹、粘贴的路径都落在这里（没有 -Path 前缀）。

.PARAMETER Path
    显式指定目录。等价于把文件夹拖进来。

.PARAMETER Search
    关键词搜标题 / 首条消息 / 工作区 / 路径 / ID。

.PARAMETER Top
    只看最近 N 条。

.PARAMETER Id
    列表里带上完整会话 ID，方便复制去 -SessionId。

.PARAMETER Verify
    列表同时核 header 与 DSH 枚举（慢，但能看出"文件在却不显示"）。

.PARAMETER Repair
    全量体检（五道关）。转发 move-session.ps1 -Repair。

.PARAMETER FixHeader
    只重压 header 帧补终止换行。历史遗留的"会话静默消失"用这个修。

.PARAMETER Restore
    还原备份。默认最近一次，可用 -Stamp 指定。

.PARAMETER Backups
    列出所有备份目录。

.PARAMETER TargetPath
    配合 -Apply 使用：迁移的目标工作区目录。

.EXAMPLE
    .\dsh-session.cmd
    双击效果：进菜单。

.EXAMPLE
    .\dsh-session.cmd "C:\Work\my-project"
    看这个工作区里有哪些会话。

.EXAMPLE
    .\dsh-session.cmd -Repair -NoPause
    静默体检，适合被别的脚本调用。
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Bare,

    [string]$Path,
    [string]$Search,
    [switch]$Ungrouped,
    [switch]$Id,
    [int]$Top = 0,
    [switch]$Verify,

    [switch]$Repair,
    [switch]$List,
    [string]$SessionId,
    [string]$Title,

    [switch]$Backups,
    [switch]$FixHeader,
    [switch]$Restore,
    [string]$Stamp,
    [switch]$Apply,
    [string]$TargetPath,

    [string]$Node,
    [string]$DataRoot = (Join-Path $env:USERPROFILE '.dsh'),

    # 不放 '?' 进别名：-? 是 PowerShell 内置开关，脚本还没跑就被引擎拦下了。
    [Alias('help', 'h')]
    [switch]$ShowHelp,

    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$ToolDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Engine  = Join-Path $ToolDir 'move-session.ps1'
$Mover   = Join-Path $ToolDir 'experiment-move-session.ps1'

# 只读引擎是硬依赖：没有它什么都看不到。
# 写操作引擎缺了只禁写操作，不连累查会话 —— 只想看清单的场景不该被一个迁移脚本拦住。
if (-not (Test-Path -LiteralPath $Engine)) {
    Write-Host "缺少只读引擎：$Engine" -ForegroundColor Red
    Write-Host 'dsh-session.ps1 必须和 move-session.ps1 放在同一个文件夹。' -ForegroundColor Yellow
    exit 2
}
$HasMover = Test-Path -LiteralPath $Mover

# 当前宿主进程，用来起子进程。子进程而非点源：引擎里有 exit 2，
# 点源会把整个窗口一起干掉，还留不住菜单状态。
function Get-HostExe {
    try {
        $p = (Get-Process -Id $PID).Path
        if ($p) { return $p }
    } catch {}
    try { return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch {}
    return 'powershell.exe'
}
$HostExe = Get-HostExe

function Say2 {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

# 管道/批处理里不停窗。两个都查：`| more` 只重定向输出，被调用时只重定向输入。
function Test-Interactive {
    if ($NoPause) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    if ([Console]::IsOutputRedirected) { return $false }
    return $true
}

function Wait-Key {
    param([string]$Prompt = '按回车继续')
    if (Test-Interactive) { [void](Read-Host $Prompt) }
}

function Wait-Exit {
    if (Test-Interactive) {
        Write-Host ''
        [void](Read-Host '按回车关闭窗口')
    }
}

# 把开关和值拼成命令行。只认 bool 和标量，不传 switch 对象，避免类型惊喜。
function Invoke-Child {
    param([string]$Script, [hashtable]$Opts)

    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script)
    foreach ($k in @($Opts.Keys | Sort-Object)) {
        $v = $Opts[$k]
        if ($null -eq $v) { continue }
        if ($v -is [bool]) { if ($v) { $argv += "-$k" }; continue }
        $s = [string]$v
        if ($s -eq '') { continue }
        $argv += "-$k"
        $argv += $s
    }
    & $HostExe @argv
}

function Invoke-Engine { param([hashtable]$Opts) Invoke-Child -Script $Engine -Opts $Opts }

function Invoke-Mover {
    param([hashtable]$Opts)
    if (-not $HasMover) {
        Say2 ''
        Say2 '  写操作引擎不在，这一项用不了。' 'Red'
        Say2 ("  缺的文件：{0}" -f $Mover) 'DarkGray'
        Say2 '  查会话、搜索、体检都不受影响。' 'DarkGray'
        return
    }
    Invoke-Child -Script $Mover -Opts $Opts
}

# ---------------------------------------------------------------- 目标识别

# 拖进来的可能是工作区目录、普通目录、文件，也可能是 .dsh 数据根。
# 判据只用一条：这个目录下有 storages\workspace.json 就是数据根。
function Resolve-Inputs {
    param([string[]]$Inputs)

    $paths = @()
    $others = @()
    $dataRoot = $null
    $unknown = @()

    foreach ($raw in $Inputs) {
        if (-not $raw) { continue }
        $s = $raw.Trim().Trim('"').Trim("'").Trim()
        if (-not $s) { continue }

        # 拖进来的路径不会以 - 开头。以 - 开头的一律当拼错的参数，
        # 否则会被当成目录去匹配工作区，报出"没有工作区指向这个目录：-Bogus"这种误导。
        if ($s.StartsWith('-')) { $unknown += $s; continue }

        $cand = $s.TrimEnd('\', '/')
        if (-not $cand) { $cand = $s }

        # 用字符串拼而不是 Join-Path：Join-Path 'Z:\x' 对不存在的驱动器会抛
        # "找不到驱动器"，把一次普通的路径判空变成脚本崩溃。
        if (Test-Path -LiteralPath ($cand + '\storages\workspace.json')) {
            $dataRoot = $cand
            continue
        }

        # 像不像路径：盘符开头、UNC、或当前确实存在。
        # 不像的（"移动测试"这种）交给调用方当关键词，不能硬说"目录不存在"。
        $looksPath = ($cand -match '^[A-Za-z]:') -or $cand.StartsWith('\\') -or (Test-Path -LiteralPath $cand)

        if ($looksPath) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $cand = Split-Path -Parent $cand }
            $paths += $cand
        }
        else {
            $others += $s
        }
    }

    return [pscustomobject]@{
        Paths    = @($paths)
        Others   = @($others)
        DataRoot = $dataRoot
        Unknown  = @($unknown)
    }
}

# ---------------------------------------------------------------- 备份列表

function Show-Backups {
    $expRoot = Join-Path $DataRoot 'storages\_experiment'
    Say2 ''
    Say2 '实验备份（迁移 / 修 header 之前自动留的档）' 'Cyan'
    Say2 ("目录 {0}" -f $expRoot) 'DarkGray'
    Say2 ''

    if (-not (Test-Path -LiteralPath $expRoot)) {
        Say2 '  还没有任何备份。' 'DarkGray'
        return
    }
    $dirs = @(Get-ChildItem -LiteralPath $expRoot -Directory | Sort-Object Name -Descending)
    if ($dirs.Count -eq 0) {
        Say2 '  还没有任何备份。' 'DarkGray'
        return
    }
    foreach ($d in $dirs) {
        $files = @(Get-ChildItem -LiteralPath $d.FullName -File | Sort-Object Name)
        $hasWs = @($files | Where-Object { $_.Name -eq 'workspace.json' }).Count -gt 0
        $kind = if ($hasWs) { '整档（可还原迁移）' } else { '只含正文（-headerfix 类）' }
        Say2 ("  {0}" -f $d.Name) 'White'
        Say2 ("      {0}   {1} 个文件" -f $kind, $files.Count) 'DarkGray'
        foreach ($f in $files) { Say2 ("        {0}  {1} B" -f $f.Name, $f.Length) 'DarkGray' }
    }
    Say2 ''
    Say2 '  还原最近一次：-Restore      指定某次：-Restore -Stamp <目录名>' 'Gray'
}

# ---------------------------------------------------------------- -help

function Show-Usage {
    Say2 ''
    Say2 '  DSH 会话工具 · 统一入口' 'Cyan'
    Say2 ("  数据根  {0}" -f $DataRoot) 'DarkGray'
    Say2 ''
    Say2 '  怎么启动' 'White'
    Say2 '    双击 dsh-session.cmd               进菜单' 'Gray'
    Say2 '    把文件夹拖到 .cmd 图标上            直接看这个工作区里的会话' 'Gray'
    Say2 '    把 .dsh 目录拖上去                  整库换成那个数据根' 'Gray'
    Say2 '    dsh-session.cmd <目录>              同上，命令行写法' 'Gray'
    Say2 ''
    Say2 '  最常用' 'White'
    Say2 '    dsh-session.cmd                     进菜单（无参数、交互环境）' 'Gray'
    Say2 '    dsh-session.cmd -Repair             全量体检，五道关逐条扫' 'Gray'
    Say2 '    dsh-session.cmd -Top 20             最近 20 条（带表头）' 'Gray'
    Say2 '    dsh-session.cmd -Search gif         搜标题 / 首条消息 / 工作区 / 路径 / ID' 'Gray'
    Say2 ''
    Say2 '  查询（转给 move-session.ps1）' 'White'
    Say2 '    -Path <目录>     -Search <关键词>    -Ungrouped      -Top <N>' 'Gray'
    Say2 '    -Id              -Verify             -List           -Title <关键词>' 'Gray'
    Say2 '    -SessionId <id>' 'Gray'
    Say2 ''
    Say2 '  写操作（转给 experiment-move-session.ps1）' 'White'
    Say2 '    -Backups                        列备份，纯读' 'Gray'
    Say2 '    -FixHeader                      只重压 header 帧补换行，DSH 不必退' 'Gray'
    Say2 '    -Restore [-Stamp <目录名>]      还原备份，要退 DSH' 'Gray'
    Say2 '    -Apply -TargetPath <目录>       迁移，要退 DSH；先不带 -Apply 干跑' 'Gray'
    Say2 ''
    Say2 '  其它' 'White'
    Say2 '    -NoPause                        结束后不停窗（管道 / 批处理用）' 'Gray'
    Say2 '    -Node <路径>                     node.exe，省略则自动找' 'Gray'
    Say2 '    -DataRoot <目录>                 数据根，默认 %USERPROFILE%\.dsh' 'Gray'
    Say2 '    -Help                           这份帮助（也可以 -h / --help）' 'Gray'
    Say2 ''
    Say2 '  列表里那几列是什么、每道关查什么：move-session.ps1 -help' 'DarkGray'
    Say2 ''
}

# ---------------------------------------------------------------- 菜单

function Show-Menu {
    try { Clear-Host } catch {}
    Say2 ''
    Say2 '  ============================================================' 'DarkCyan'
    Say2 '    DSH 会话工具' 'White'
    Say2 ("    数据根  {0}" -f $DataRoot) 'DarkGray'
    Say2 '  ============================================================' 'DarkCyan'
    Say2 ''
    Say2 '    [1] 全部会话                [5] 全量体检（五道关）' 'Gray'
    Say2 '    [2] 最近 20 条              [6] 迁移 / 修 header / 还原' 'Gray'
    Say2 '    [3] 只看未分组              [7] 工作区清单（含文件夹路径）' 'Gray'
    Say2 '    [4] 看会话 ID（可搜）       [0] 退出' 'Gray'
    Say2 ''
    Say2 '    也可以直接输入：' 'DarkGray'
    Say2 '      文件夹路径  →  看这个工作区里的会话（可把文件夹拖进本窗口）' 'DarkGray'
    Say2 ('      ' + $DataRoot + '  →  切换数据根') 'DarkGray'
    Say2 '      关键词      →  按标题 / 首条消息搜索' 'DarkGray'
    Say2 ''
    Say2 '    不知道工作区文件夹在哪？进 [7]，那一列路径就是。' 'DarkGray'
    Say2 '    迁移不用记 ID：进 [6] → [3]，输中文标题片段就行。' 'DarkGray'
    Say2 ''
    Say2 '  ------------------------------------------------------------' 'DarkCyan'
}

# 解析 -List 的输出，拿到 编号 → 路径 的映射。
# 格式是我们自己定的（`  [1] C:\path`），改格式时记得同步这里。
function Get-WorkspaceMap {
    $map = @{}
    try {
        $out = & $HostExe -NoProfile -ExecutionPolicy Bypass -File $Engine -List -DataRoot $DataRoot 2>$null
    } catch { return $map }
    foreach ($line in @($out)) {
        $m = [regex]::Match("$line", '^\s*\[(\d+)\]\s+(.+?)\s*$')
        if ($m.Success) { $map[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return $map
}

function Invoke-MigrateWizard {
    Say2 ''
    Say2 '  迁移会话到另一个工作区' 'Cyan'
    Say2 '  不用记会话 ID —— 输中文标题片段就行，脚本自己找。' 'DarkGray'
    Say2 '  前提：DSH 已从托盘完全退出（右键托盘图标 → 退出）。' 'Yellow'
    Say2 ''
    Say2 '  ── 现有会话（最近 15 条）──' 'DarkGray'
    Invoke-Engine @{ Top = 15; DataRoot = $DataRoot; Node = $Node }
    Say2 ''
    Say2 '  没看到目标？记住标题里的几个字，照样能搜到。' 'DarkGray'
    Say2 ''

    $key = "$(Read-Host '  会话：输标题片段或会话 ID（留空取消）')".Trim().Trim('"')
    if (-not $key) { Say2 '  已取消。' 'DarkGray'; return }

    # 目标工作区：列出来给编号，省得手敲长路径
    $wsMap = Get-WorkspaceMap
    Say2 ''
    if ($wsMap.Count -gt 0) {
        Say2 '  可迁到的工作区：' 'DarkGray'
        foreach ($k in @($wsMap.Keys | Sort-Object { [int]$_ })) {
            Say2 ("    [{0}] {1}" -f $k, $wsMap[$k]) 'Gray'
        }
        Say2 ''
    }

    $tgt = "$(Read-Host '  目标：输上面编号，或粘/拖一个目录（留空取消）')".Trim().Trim('"')
    if (-not $tgt) { Say2 '  已取消。' 'DarkGray'; return }
    if ($wsMap.ContainsKey($tgt)) { $tgt = $wsMap[$tgt] }

    $o = @{ TargetPath = $tgt; DataRoot = $DataRoot }
    if ($Node) { $o.Node = $Node }
    # 会话 ID 有两种长相：新的 session-<uuid>，老的纯 <uuid>（本机真有两条）。
    # 只判 session- 前缀会把老 ID 当成标题去搜，搜不到还以为是写错了。
    if ($key -match '^(session-)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $o.SessionId = $key
    }
    else { $o.Title = $key }

    Say2 ''
    Say2 '  ── 预览，不写入 ──' 'DarkGray'
    Invoke-Mover $o

    Say2 ''
    $ok = Read-Host '  确认执行？输入 yes 回车，其它取消'
    if ("$ok".Trim() -ne 'yes') { Say2 '  已取消，什么都没动。' 'DarkGray'; return }

    Say2 ''
    Say2 '  ── 执行 ──' 'Yellow'
    $o.Apply = $true
    Invoke-Mover $o
}

function Invoke-WriteMenu {
    while ($true) {
        try { Clear-Host } catch {}
        Say2 ''
        Say2 '  写操作 —— 只有这几项会改文件' 'Cyan'
        Say2 ("  数据根  {0}" -f $DataRoot) 'DarkGray'
        Say2 ''
        Say2 '    [1] 看备份列表' 'Gray'
        Say2 '    [2] 修 header 缺换行（不动位置，DSH 不必退）' 'Gray'
        Say2 '    [3] 迁移一条会话到别的工作区（要退 DSH）' 'Gray'
        Say2 '    [4] 还原最近一次备份（要退 DSH）' 'Gray'
        Say2 '    [5] 还原指定备份' 'Gray'
        Say2 '    [0] 返回' 'Gray'
        Say2 ''
        $c = "$(Read-Host '  选择')".Trim()

        switch ($c) {
            ''  { return }
            '0' { return }
            '1' { Show-Backups; Wait-Key }
            '2' {
                Say2 ''
                Say2 '  --- 修 header 帧终止换行 ---' 'Yellow'
                Say2 '  只重压帧0，事件流一字不动。DSH 可以开着。' 'DarkGray'
                Say2 ''
                Invoke-Mover @{ Repair = $true; DataRoot = $DataRoot; Node = $Node }
                Wait-Key
            }
            '3' { Invoke-MigrateWizard; Wait-Key }
            '4' {
                Say2 ''
                Say2 '  --- 还原最近一次备份 ---' 'Yellow'
                Say2 '  会删掉迁移后的新位置目录，并恢复 workspace.json。' 'DarkGray'
                $ok = Read-Host '  确认？输入 yes 回车，其它取消'
                if ("$ok".Trim() -eq 'yes') {
                    Invoke-Mover @{ Restore = $true; DataRoot = $DataRoot; Node = $Node }
                }
                else { Say2 '  已取消。' 'DarkGray' }
                Wait-Key
            }
            '5' {
                Show-Backups
                Say2 ''
                $st = "$(Read-Host '  输入目录名（留空取消）')".Trim()
                if ($st) {
                    Invoke-Mover @{ Restore = $true; Stamp = $st; DataRoot = $DataRoot; Node = $Node }
                }
                else { Say2 '  已取消。' 'DarkGray' }
                Wait-Key
            }
            default { Say2 '  没有这个编号。' 'Red'; Start-Sleep -Milliseconds 700 }
        }
    }
}

function Invoke-Menu {
    while ($true) {
        Show-Menu
        $line = "$(Read-Host '  选择或输入')".Trim().Trim('"').Trim("'").Trim()
        if ($line -eq '' -or $line -eq '0') { return }

        switch ($line) {
            '1' { Invoke-Engine @{ DataRoot = $DataRoot; Node = $Node }; Wait-Key }
            '2' { Invoke-Engine @{ Top = 20; DataRoot = $DataRoot; Node = $Node }; Wait-Key }
            '3' { Invoke-Engine @{ Ungrouped = $true; DataRoot = $DataRoot; Node = $Node }; Wait-Key }
            '4' {
                # 以前这里写死 Top=30，第 31 条以后根本看不到。
                # 现在：先问一句找哪条 —— 有词就搜（结果少、好找），没词就把全部列出来。
                Say2 ''
                Say2 '  看会话 ID' 'Cyan'
                Say2 '  直接回车 = 列出全部会话（带完整 ID）；输关键词 = 只列匹配的，好找。' 'DarkGray'
                Say2 ''
                $kw = "$(Read-Host '  找哪条？（关键词，可留空）')".Trim().Trim('"').Trim("'").Trim()
                Say2 ''
                if ($kw) {
                    Invoke-Engine @{ Id = $true; Search = $kw; DataRoot = $DataRoot; Node = $Node }
                }
                else {
                    Invoke-Engine @{ Id = $true; DataRoot = $DataRoot; Node = $Node }
                }
                Wait-Key
            }
            '5' { Invoke-Engine @{ Repair = $true; DataRoot = $DataRoot; Node = $Node }; Wait-Key }
            '6' {
                if ($HasMover) { Invoke-WriteMenu }
                else {
                    Say2 ''
                    Say2 '  写操作引擎不在，这一项用不了。' 'Red'
                    Say2 ("  缺的文件：{0}" -f $Mover) 'DarkGray'
                    Say2 '  查会话、搜索、体检都不受影响。' 'DarkGray'
                    Wait-Key
                }
            }
            '7' { Invoke-Engine @{ List = $true; DataRoot = $DataRoot; Node = $Node }; Wait-Key }
            default {
                # 不是编号 → 当路径 / 数据根 / 关键词。
                # 走和命令行、拖拽同一套 Resolve-Inputs，免得菜单里粘 .dsh 路径没有反应。
                $r = Resolve-Inputs -Inputs @($line)

                if ($r.DataRoot) {
                    if ($r.DataRoot -ieq $DataRoot) {
                        Say2 ''
                        Say2 ("  本来就是这个数据根：{0}" -f $DataRoot) 'DarkGray'
                    }
                    else {
                        $script:DataRoot = $r.DataRoot
                        Say2 ''
                        Say2 ("  数据根已切换到：{0}" -f $DataRoot) 'Green'
                    }
                    Say2 '  看会话用 [1]，看工作区清单用 [7]。' 'DarkGray'
                }
                elseif (@($r.Paths).Count -gt 0) {
                    $d = @($r.Paths)[0]
                    if (Test-Path -LiteralPath $d -PathType Container) {
                        Invoke-Engine @{ Path = $d; DataRoot = $DataRoot; Node = $Node }
                    }
                    else {
                        Say2 ''
                        Say2 ("  目录不存在：{0}" -f $d) 'Red'
                        Say2 '  拖进来的路径带引号也没关系，脚本会去掉。' 'DarkGray'
                    }
                }
                elseif (@($r.Others).Count -gt 0) {
                    # 不像路径的那部分当关键词（输「移动测试」不该被说成"目录不存在"）
                    Invoke-Engine @{ Search = @($r.Others)[0]; DataRoot = $DataRoot; Node = $Node }
                }
                else {
                    Invoke-Engine @{ Search = $line; DataRoot = $DataRoot; Node = $Node }
                }
                Wait-Key
            }
        }
    }
}

# ---------------------------------------------------------------- 入口

# -help 必须在解析路径之前拦下，否则 --help 会被当成目录去匹配工作区。
# 手敲 -help 时 PowerShell 命中 [Alias] 进 $ShowHelp；传值/拖拽时值会落到 $Bare。
if (-not $ShowHelp -and $Bare) {
    foreach ($b in $Bare) {
        $probe = "$b".Trim().ToLowerInvariant().TrimStart('-', '/')
        if (@('help', 'h', '?') -contains $probe) { $ShowHelp = $true; break }
    }
}
if ($ShowHelp) {
    Show-Usage
    Wait-Exit
    exit 0
}

$inputs = @()
if ($Path) { $inputs += $Path }
if ($Bare) { $inputs += $Bare }

$resolved = Resolve-Inputs -Inputs $inputs
if ($resolved.DataRoot) { $DataRoot = $resolved.DataRoot }
$targets = @($resolved.Paths)

if (@($resolved.Unknown).Count -gt 0) {
    Say2 ''
    Say2 ("  不认识的参数：{0}" -f (@($resolved.Unknown) -join ' ')) 'Red'
    Say2 '  参数表见同目录 README.md 第三节。' 'DarkGray'
    Say2 '  只想看会话：直接双击 dsh-session.cmd，什么都不用带。' 'DarkGray'
    Wait-Exit
    exit 2
}

# 不像路径的裸值当关键词：`dsh-session.cmd 移动测试` 应该搜，而不是说"目录不存在"。
$bareSearch = $null
if (-not $Search -and $targets.Count -eq 0 -and @($resolved.Others).Count -gt 0) {
    $bareSearch = @($resolved.Others)[0]
}

$hasWrite = ($FixHeader -or $Restore -or $Backups -or $Apply)
$hasAction = ($Repair -or $List -or $SessionId -or $Title -or $Search -or $Ungrouped -or $Id -or ($Top -gt 0) -or $Verify -or $bareSearch)

# ① 写操作：单次动作，执行完就退，不进菜单
if ($hasWrite) {

    if ($Backups) {
        Show-Backups
        Wait-Exit
        exit 0
    }

    if (-not $HasMover) {
        Say2 ''
        Say2 '  写操作引擎不在，迁移 / 修 header / 还原都用不了。' 'Red'
        Say2 ("  缺的文件：{0}" -f $Mover) 'DarkGray'
        Say2 '  查会话、搜索、体检都不受影响；-Backups 也还能用。' 'DarkGray'
        Wait-Exit
        exit 2
    }

    $o = @{ DataRoot = $DataRoot }
    if ($Node)      { $o.Node = $Node }
    if ($SessionId) { $o.SessionId = $SessionId }
    if ($Title)     { $o.Title = $Title }
    if ($Stamp)     { $o.Stamp = $Stamp }

    if ($FixHeader) { $o.Repair = $true }
    elseif ($Restore) { $o.Restore = $true }
    elseif ($Apply) {
        if (-not $TargetPath) {
            Say2 ''
            Say2 '  -Apply 需要配合 -TargetPath <目标工作区目录>。' 'Red'
            Say2 '  先不带 -Apply 跑一次看预览。' 'DarkGray'
            Wait-Exit
            exit 2
        }
        $o.Apply = $true
        $o.TargetPath = $TargetPath
        if (-not $SessionId) { $o.Remove('SessionId') }
    }

    Invoke-Mover $o
    Wait-Exit
    exit 0
}

# ② 有目录 → 每个目录列一次
if ($targets.Count -gt 0) {
    foreach ($t in $targets) {
        $o = @{ Path = $t; DataRoot = $DataRoot }
        if ($Node)      { $o.Node = $Node }
        if ($Id)        { $o.Id = $true }
        if ($Top -gt 0) { $o.Top = $Top }
        if ($Verify)    { $o.Verify = $true }
        Invoke-Engine $o
    }
    Wait-Exit
    exit 0
}

# ③ 明确动作 → 转发一次
if ($hasAction) {
    $o = @{ DataRoot = $DataRoot }
    if ($Node)      { $o.Node = $Node }
    if ($Repair)    { $o.Repair = $true }
    if ($List)      { $o.List = $true }
    if ($SessionId) { $o.SessionId = $SessionId }
    if ($Title)     { $o.Title = $Title }
    if ($Search)    { $o.Search = $Search }
    elseif ($bareSearch) { $o.Search = $bareSearch }
    if ($Ungrouped) { $o.Ungrouped = $true }
    if ($Id)        { $o.Id = $true }
    if ($Top -gt 0) { $o.Top = $Top }
    if ($Verify)    { $o.Verify = $true }

    Invoke-Engine $o
    Wait-Exit
    exit 0
}

# ④ 什么都没有：交互进菜单，否则列全部（管道场景不该卡住等输入）
if (Test-Interactive) {
    Invoke-Menu
    Wait-Exit
    exit 0
}

Invoke-Engine @{ DataRoot = $DataRoot; Node = $Node }
exit 0
