# 长河 V2.1 文档审计器
# 用途：验证规格文档是否断引用、是否有占位、章节是否齐备、参数是否带标记、风险编号是否可被引用。
# 用法：pwsh -File "ideas/长河/audit.ps1"
# 退出码：0 = 全绿；1 = 存在失败项
# 纪律：脚本失败要修文档，不准放宽脚本（V2.1 §0.5）。

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)
$specPath  = Join-Path $scriptDir '长河_核心设计文档_V2.1.md'

$script:fail = 0
$script:warn = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) {
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0} :: {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:fail++
    }
}
function Warn([string]$Name, [string]$Detail) {
    Write-Host ("[WARN] {0} :: {1}" -f $Name, $Detail) -ForegroundColor Yellow
    $script:warn++
}

Write-Host "== 长河 V2.1 文档审计 ==" -ForegroundColor Cyan
Write-Host ("规格文件: {0}" -f $specPath)

Check '规格文件存在' (Test-Path -LiteralPath $specPath) '未找到 V2.1 规格文件'
if (-not (Test-Path -LiteralPath $specPath)) { exit 1 }

$text  = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8
$lines = $text -split "`r?`n"

# ---------- 1. 章节齐备 ----------
$chapters = @()
foreach ($l in $lines) { if ($l -match '^##\s+§(\d+)') { $chapters += [int]$Matches[1] } }
$missing = @(0..10 | Where-Object { $chapters -notcontains $_ })
Check '章节 §0~§10 齐备' ($missing.Count -eq 0) ("缺少: " + ($missing -join ','))

# ---------- 2. 子章节编号集合 ----------
$subs = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($l in $lines) {
    if ($l -match '^#{3,4}\s+(\d+(?:\.\d+)+)\s') { [void]$subs.Add($Matches[1]) }
}

# ---------- 3. 交叉引用可解析 ----------
$refs = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($m in [regex]::Matches($text, '§(\d+(?:\.\d+)*)')) { [void]$refs.Add($m.Groups[1].Value) }
$badRefs = @()
foreach ($r in $refs) {
    if ($r -match '\.') { if (-not $subs.Contains($r)) { $badRefs += "§$r" } }
    else { if ($chapters -notcontains [int]$r) { $badRefs += "§$r" } }
}
Check '所有 §x.y 交叉引用可解析' ($badRefs.Count -eq 0) ("断引用: " + ($badRefs -join ', '))

# ---------- 4. 无占位 ----------
$placeholderPattern = 'TODO|TBD|FIXME|待补|占位|XXX'
$hits = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $placeholderPattern) { $hits += ("L{0}: {1}" -f ($i + 1), $lines[$i].Trim()) }
}
Check '无 TODO / 待补 / 占位' ($hits.Count -eq 0) ($hits -join ' | ')

# ---------- 5. 参数表每行带标记 ----------
$paramStart = -1; $paramEnd = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^###\s+10\.1') { $paramStart = $i }
    elseif ($paramStart -ge 0 -and $lines[$i] -match '^###\s+10\.2') { $paramEnd = $i; break }
}
Check '参数表 §10.1 存在' ($paramStart -ge 0 -and $paramEnd -gt $paramStart) '未找到 §10.1 参数表边界'
$untagged = @()
if ($paramStart -ge 0 -and $paramEnd -gt $paramStart) {
    for ($i = $paramStart + 1; $i -lt $paramEnd; $i++) {
        $l = $lines[$i].Trim()
        if (-not $l.StartsWith('|')) { continue }
        if ($l -match '^\|[\s:\-\|]+\|$') { continue }
        if ($l -match '^\|\s*参数\s*\|') { continue }
        if ($l -notmatch '【(锁|标定|实测)】') { $untagged += ("L{0}: {1}" -f ($i + 1), $l) }
    }
}
Check '参数表每行都带【锁/标定/实测】' ($untagged.Count -eq 0) ($untagged -join ' | ')

# ---------- 6. 风险编号可被引用 ----------
$riskStart = -1; $riskEnd = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^###\s+10\.2') { $riskStart = $i }
    elseif ($riskStart -ge 0 -and $lines[$i] -match '^###\s+10\.3') { $riskEnd = $i; break }
}
$riskBlock = if ($riskStart -ge 0 -and $riskEnd -gt $riskStart) { ($lines[$riskStart..$riskEnd] -join "`n") } else { '' }
$missingRisks = @('R-01', 'R-02', 'R-06') | Where-Object { $riskBlock -notmatch [regex]::Escape($_) }
Check '风险 R-01 / R-02 / R-06 在 §10.2 存在' ($missingRisks.Count -eq 0) ("缺少: " + ($missingRisks -join ','))

# ---------- 7. 代码围栏成对 ----------
$fenceCount = ([regex]::Matches($text, '(?m)^' + '```')).Count
Check '代码围栏成对' (($fenceCount % 2) -eq 0) ("围栏数: " + $fenceCount)

# ---------- 8. 相对链接可达 ----------
$mdFiles = @(
    $specPath,
    (Join-Path $scriptDir 'README.md'),
    (Join-Path $scriptDir '内核白皮书.md'),
    (Join-Path $repoRoot  'README.md')
)
$badLinks = @()
foreach ($f in $mdFiles) {
    if (-not (Test-Path -LiteralPath $f)) { $badLinks += "缺文件: $f"; continue }
    $dir = Split-Path -Parent $f
    $body = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($body, '\]\(([^)\s]+)\)')) {
        $t = $m.Groups[1].Value
        if ($t -match '^(https?:|#|mailto:)') { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $dir $t))
        if (-not (Test-Path -LiteralPath $target)) { $badLinks += ("{0} -> {1}" -f (Split-Path -Leaf $f), $t) }
    }
}
Check '相对链接全部可达' ($badLinks.Count -eq 0) ($badLinks -join ' | ')

# ---------- 9. 口径性表述 ----------
if ($text -match '完全一样') {
    $hasCorrection = ($text -match '一套内核，三种外壳') -and ($text -match '数据结构同一套')
    if (-not $hasCorrection) { Warn '出现"完全一样"但缺少"一套内核，三种外壳 / 数据结构同一套"的纠正口径' '' }
}

# ---------- 汇总 ----------
Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ("== 审计通过 == 失败 {0} 项，警告 {1} 项" -f $script:fail, $script:warn) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("== 审计失败 == 失败 {0} 项，警告 {1} 项" -f $script:fail, $script:warn) -ForegroundColor Red
    exit 1
}
