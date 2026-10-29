#Requires -Version 5.1
<#
.SYNOPSIS
    已合并进 move-session.ps1。本文件只做转发，旧命令照样能用。

.DESCRIPTION
    会话列表功能已经并进 move-session.ps1 —— 那个脚本现在既能体检也能列会话，
    不用再开第二个窗口看清单。

    本文件保留下来只为两件事：
      1 你手头记着的 `.\list-sessions.ps1 -Search 登录` 这类命令不会突然失效
      2 别人（或别的脚本）调它的时候不会断

    新写的命令请直接用：
      .\dsh-session.cmd                  （双击也行，一个窗口搞定全部）
      .\move-session.ps1                 等价：列全部会话
      .\move-session.ps1 -Search 登录
      .\move-session.ps1 -SessionId <id> 等价旧的 -Detail

.PARAMETER Search
    关键词搜标题 / 首条消息 / 工作区 / 路径 / ID。

.PARAMETER Detail
    会话 ID，看单条详情。等价 move-session.ps1 -SessionId。

.PARAMETER Ungrouped
    只看未分组。

.PARAMETER DataRoot
    数据根，默认 %USERPROFILE%\.dsh。
#>
param(
    [string]$Search,
    [string]$Detail,
    [switch]$Ungrouped,
    [string]$DataRoot = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'

# 兼容 GNU 风格写法：--Search 登录 / --Detail <id> / --Ungrouped
if ($Search -like '--*') {
    $gnuName = $Search.TrimStart('-').ToLower()
    $gnuVal  = $Detail
    $Detail  = $null
    switch ($gnuName) {
        'search'    { $Search = $gnuVal }
        'detail'    { $Detail = $gnuVal; $Search = $null }
        'ungrouped' { $Ungrouped = $true; $Search = $null }
        'all'       { $Search = $null }
        default     { Write-Host "不认识的选项 -$gnuName。可用：-Search / -Detail / -Ungrouped" -ForegroundColor Red; exit 2 }
    }
}

$ToolDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Engine  = Join-Path $ToolDir 'move-session.ps1'

if (-not (Test-Path -LiteralPath $Engine)) {
    Write-Host "找不到 $Engine" -ForegroundColor Red
    Write-Host 'move-session.ps1 必须和本文件在同一个文件夹。' -ForegroundColor Yellow
    exit 2
}

# 注意：必须用 hashtable splatting。数组 splatting（@argv）传的是位置参数，
# 里面写的 '-DataRoot' 会被当成一个字符串值，而不是参数名。
$opt = @{ DataRoot = $DataRoot }
if     ($Detail)    { $opt.SessionId = $Detail }
elseif ($Search)    { $opt.Search    = $Search }
elseif ($Ungrouped) { $opt.Ungrouped = $true }

& $Engine @opt
exit $LASTEXITCODE
