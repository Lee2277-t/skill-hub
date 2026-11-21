<#
.SYNOPSIS
    技能中心 —— 把散落在各处的技能与知识库收拢成一份可检索的索引。

.DESCRIPTION
    问题不是"技能不够"，是"agent 不知道有什么"。

    这个工具做三件事：
      index   扫描技能目录，解析 SKILL.md 的 frontmatter，生成 index.json
      find    按关键词检索索引（给 agent 用，比自己翻目录快）
      sync    把中心库同步进各客户端的 skills 目录，让它们看到同一份
      doctor  找重复、描述过短、frontmatter 坏掉的技能

.EXAMPLE
    .\kb.ps1 index
.EXAMPLE
    .\kb.ps1 find "PPT 排版"
.EXAMPLE
    .\kb.ps1 sync -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Query,
    [string]$Root = '',
    [string]$Hub = '',
    [string[]]$Clients = @('codex', 'qoder', 'workbuddy', 'claude'),
    [int]$Top = 10,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$Prune,
    [switch]$All,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $Hub) { $Hub = Join-Path $env:USERPROFILE '.skill-hub' }
if (-not $Root) { $Root = Join-Path $env:USERPROFILE '.skills' }
$script:Hub = $Hub
$script:IndexPath = Join-Path $Hub 'index.json'
$script:Version = '1.0.0'

# ---------------------------------------------------------------- 配置
#
# 优先读脚本旁边的 skill-hub.config.json，没有就用下面的默认值。
# 配置文件让你不用改代码就能换技能库位置、加知识库、加客户端。

function Expand-PathTemplate {
    param([string]$Template)
    if (-not $Template) { return '' }
    $p = $Template
    if ($p.StartsWith('~')) { $p = $env:USERPROFILE + $p.Substring(1) }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    return $p
}

$script:ConfigPath = Join-Path $PSScriptRoot 'skill-hub.config.json'
$script:Config = $null
if (Test-Path -LiteralPath $script:ConfigPath) {
    try { $script:Config = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
}

if ($script:Config) {
    if ($script:Config.hubDir) { $script:Hub = $script:Config.hubDir }
    if ($script:Config.skillsRoot) { $Root = $script:Config.skillsRoot }
}
$script:IndexPath = Join-Path $script:Hub 'index.json'

# 客户端 skills 目录
$script:ClientDirs = @{}
$clientMap = if ($script:Config -and $script:Config.clients) { $script:Config.clients } else {
    [pscustomobject]@{
        codex = '~/.codex/skills'; qoder = '~/.qoder-cn/skills'
        workbuddy = '~/.workbuddy/skills'; claude = '~/.claude/skills'
        agents = '~/.agents/skills'
    }
}
foreach ($prop in $clientMap.PSObject.Properties) {
    $script:ClientDirs[$prop.Name] = Expand-PathTemplate $prop.Value
}

# 知识库（不是技能，但 agent 同样找不到）
$script:KnowledgeRoots = @()
if ($script:Config -and $script:Config.knowledgeRoots) {
    foreach ($k in $script:Config.knowledgeRoots) {
        $script:KnowledgeRoots += @{ Id = $k.id; Path = (Expand-PathTemplate $k.path); Desc = $k.desc }
    }
}

# 要注入说明的文件
$script:InstructionTargets = @()
if ($script:Config -and $script:Config.instructionTargets) {
    foreach ($x in $script:Config.instructionTargets) {
        $script:InstructionTargets += @{ Label = $x.label; Path = (Expand-PathTemplate $x.path) }
    }
} else {
    $script:InstructionTargets = @(
        @{ Label = 'DSH 全局'; Path = (Join-Path $env:USERPROFILE '.dsh\AGENTS.md') }
        @{ Label = 'Codex 全局'; Path = (Join-Path $env:USERPROFILE '.codex\AGENTS.md') }
    )
}

function Write-H { param($t) Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok { param($t) Write-Host "  OK   $t" -ForegroundColor Green }
function Write-No { param($t) Write-Host "  注意 $t" -ForegroundColor Yellow }
function Write-Bad { param($t) Write-Host "  错误 $t" -ForegroundColor Red }
function Write-Dim { param($t) Write-Host "        $t" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- frontmatter

function Get-Frontmatter {
    <#
      解析 SKILL.md 的 YAML frontmatter。
      要处理 description: > 和 description: | 这种多行块（本库里 08-办公文档 全是这种写法），
      只抓第一行会得到 ">" 或 "|"。
    #>
    param([string]$Path)

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 120 -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) { return $null }
    if ($lines[0].Trim() -ne '---') { return @{ Name = ''; Description = ''; Raw = $false } }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } }
    if ($end -lt 0) { return @{ Name = ''; Description = ''; Raw = $false } }

    $name = ''
    $desc = ''
    $i = 1
    while ($i -lt $end) {
        $line = $lines[$i]
        if ($line -match '^name:\s*(.+)$') { $name = $Matches[1].Trim().Trim('"', "'"); $i++; continue }
        if ($line -match '^(description|summary|when_to_use):\s*(.*)$') {
            $first = $Matches[2].Trim()
            if ($first -eq '>' -or $first -eq '|' -or $first -eq '>-' -or $first -eq '|-') {
                # 块标量：收集后面缩进的行
                $buf = @()
                $i++
                while ($i -lt $end -and ($lines[$i] -match '^\s+\S' -or $lines[$i].Trim() -eq '')) {
                    $buf += $lines[$i].Trim()
                    $i++
                }
                $desc = ($buf | Where-Object { $_ }) -join ' '
            } else {
                $desc = $first.Trim('"', "'")
                $i++
                # 引号包裹的多行
                while ($i -lt $end -and $lines[$i] -match '^\s+\S' -and -not ($lines[$i] -match '^\s*[a-z_]+:')) {
                    $desc += ' ' + $lines[$i].Trim()
                    $i++
                }
            }
            continue
        }
        $i++
    }

    return @{ Name = $name; Description = ($desc -replace '\s+', ' ').Trim(); Raw = $true }
}

# ---------------------------------------------------------------- index

function Invoke-Index {
    $skills = @()
    if (-not (Test-Path -LiteralPath $Root)) {
        Write-Bad "技能库根目录不存在: $Root"; return
    }

    $files = Get-ChildItem -LiteralPath $Root -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue
    Write-Host "  扫描 $(Split-Path $Root -Leaf) 下的 $($files.Count) 个 SKILL.md"

    $hashes = @{}
    foreach ($f in $files) {
        $fm = Get-Frontmatter -Path $f.FullName
        if (-not $fm) { continue }
        $dir = $f.Directory
        $rel = $dir.FullName.Substring($Root.Length).TrimStart('\')
        $parts = $rel.Split('\')
        $category = if ($parts.Count -gt 1) { $parts[0] } else { '(未分类)' }
        if ($category -like '_*') { continue }   # 存档目录，不算技能
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash

        if (-not $hashes.ContainsKey($hash)) { $hashes[$hash] = New-Object System.Collections.Generic.List[string] }
        $hashes[$hash].Add($rel)

        $fileCount = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -ErrorAction SilentlyContinue).Count

        $skills += [pscustomobject]@{
            name        = if ($fm.Name) { $fm.Name } else { $dir.Name }
            folder      = $dir.Name
            category    = $category
            dir         = $rel
            path        = $dir.FullName
            description = $fm.Description
            descLen     = $fm.Description.Length
            hash        = $hash
            files       = $fileCount
            hasRaw      = $fm.Raw
        }
    }

    # 知识库
    $knowledge = @()
    foreach ($k in $script:KnowledgeRoots) {
        if (-not (Test-Path -LiteralPath $k.Path)) { continue }
        $docs = @(Get-ChildItem -LiteralPath $k.Path -Recurse -Include '*.md', '*.txt' -File -ErrorAction SilentlyContinue)
        $topics = @()
        foreach ($d in ($docs | Select-Object -First 60)) {
            $first = Get-Content -LiteralPath $d.FullName -Encoding UTF8 -TotalCount 5 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^#\s+' } | Select-Object -First 1
            $title = if ($first) { ($first -replace '^#\s+', '').Trim() } else { $d.BaseName }
            $topics += $title
        }
        $knowledge += [pscustomobject]@{
            id      = $k.Id
            path    = $k.Path
            desc    = $k.Desc
            docs    = $docs.Count
            topics  = $topics
            bytes   = ($docs | Measure-Object Length -Sum).Sum
        }
    }

    $dups = @()
    foreach ($h in $hashes.Keys) {
        if ($hashes[$h].Count -gt 1) { $dups += ($hashes[$h] -join ' == ') }
    }

    $index = [pscustomobject]@{
        version     = $script:Version
        generated   = (Get-Date).ToString('s')
        root        = (Resolve-Path -LiteralPath $Root).Path
        skillCount  = $skills.Count
        skills      = @($skills | Sort-Object category, folder)
        knowledge   = @($knowledge)
        duplicates  = @($dups)
    }

    if ($Json) { ConvertTo-Json -InputObject $index -Depth 6; return }

    if (-not (Test-Path -LiteralPath $script:Hub)) { New-Item -ItemType Directory -Path $script:Hub -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $index -Depth 6
    [System.IO.File]::WriteAllText($script:IndexPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    Write-H '索引完成'
    Write-Host "  技能: $($skills.Count) 个"
    Write-Host "  分类: $(($skills | Group-Object category).Count) 个"
    Write-Host "  知识库: $($knowledge.Count) 个（$(($knowledge | ForEach-Object { $_.docs } | Measure-Object -Sum).Sum) 篇文档）"
    if ($dups.Count -gt 0) { Write-No "内容完全重复: $($dups.Count) 组" }
    Write-Dim "索引文件: $script:IndexPath"

    Write-Host ''
    $skills | Group-Object category | Sort-Object Name | ForEach-Object {
        Write-Host ('  {0}{1}' -f (Format-CellLocal $_.Name 24), ("{0,3} 个" -f $_.Count))
    }
}

function Format-CellLocal {
    param([string]$Text, [int]$Width)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { if ([int]$ch -gt 127) { $w += 2 } else { $w += 1 } }
    if ($w -ge $Width) {
        $out = ''; $acc = 0
        foreach ($ch in $Text.ToCharArray()) {
            $cw = if ([int]$ch -gt 127) { 2 } else { 1 }
            if ($acc + $cw -gt $Width - 1) { break }
            $out += $ch; $acc += $cw
        }
        return $out + '…' + (' ' * [Math]::Max(0, $Width - $acc - 1))
    }
    return $Text + (' ' * ($Width - $w))
}

# ---------------------------------------------------------------- find

function Read-Index {
    if (-not (Test-Path -LiteralPath $script:IndexPath)) {
        Write-Bad "索引不存在，先运行：kb.ps1 index"; return $null
    }
    return [System.IO.File]::ReadAllText($script:IndexPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Invoke-Find {
    $idx = Read-Index
    if (-not $idx) { return }

    $words = @($Query | ForEach-Object { $_ -split '\s+' } | Where-Object { $_ })
    if ($words.Count -eq 0) { Write-Bad '用法: kb.ps1 find <关键词...>'; return }

    $scored = @()
    foreach ($s in $idx.skills) {
        $score = 0
        foreach ($w in $words) {
            if ($s.name -like "*$w*") { $score += 10 }
            if ($s.category -like "*$w*") { $score += 4 }
            if ($s.folder -like "*$w*") { $score += 6 }
            if ($s.description -like "*$w*") { $score += 3 }
            if ($s.dir -like "*$w*") { $score += 1 }
        }
        if ($score -gt 0) { $scored += [pscustomobject]@{ Score = $score; Skill = $s } }
    }

    # 知识库也算
    $kbHits = @()
    foreach ($k in $idx.knowledge) {
        $score = 0
        foreach ($w in $words) {
            if ($k.id -like "*$w*") { $score += 10 }
            if ($k.desc -like "*$w*") { $score += 3 }
            foreach ($t in $k.topics) { if ($t -like "*$w*") { $score += 2 } }
        }
        if ($score -gt 0) { $kbHits += [pscustomobject]@{ Score = $score; KB = $k } }
    }

    $scored = @($scored | Sort-Object Score -Descending | Select-Object -First $Top)

    if ($Json) {
        [pscustomobject]@{
            query = ($words -join ' ')
            skills = @($scored | ForEach-Object { $_.Skill })
            knowledge = @($kbHits | ForEach-Object { $_.KB })
        } | ConvertTo-Json -Depth 5
        return
    }

    Write-H "检索「$($words -join ' ')」"
    if ($kbHits.Count -gt 0) {
        Write-Host '  知识库:' -ForegroundColor Magenta
        foreach ($h in $kbHits) {
            Write-Host ("    {0}  {1}" -f (Format-CellLocal $h.KB.id 16), $h.KB.desc) -ForegroundColor Magenta
            Write-Dim ("路径: " + $h.KB.path + " · " + $h.KB.docs + " 篇")
        }
    }
    if ($scored.Count -eq 0 -and $kbHits.Count -eq 0) {
        Write-No '没有命中。换个说法，或用 kb.ps1 list 看全部'
        return
    }
    if ($scored.Count -gt 0) {
        Write-Host '  技能:' -ForegroundColor Green
        foreach ($r in $scored) {
            $s = $r.Skill
            Write-Host ("    {0}{1}" -f (Format-CellLocal $s.name 28), $s.category) -ForegroundColor Green
            if ($s.description) { Write-Dim $s.description.Substring(0, [Math]::Min(110, $s.description.Length)) }
            Write-Dim ("SKILL.md: " + (Join-Path $s.path 'SKILL.md'))
        }
    }
}

# ---------------------------------------------------------------- list

function Invoke-List {
    $idx = Read-Index
    if (-not $idx) { return }
    $groups = $idx.skills | Group-Object category | Sort-Object Name
    Write-H "技能库：$($idx.skillCount) 个技能 · $(($groups).Count) 个分类 · 索引更新于 $($idx.generated)"
    foreach ($g in $groups) {
        Write-Host "`n  $($g.Name)" -ForegroundColor Cyan
        foreach ($s in ($g.Group | Sort-Object name)) {
            $short = if ($s.description) { $s.description.Substring(0, [Math]::Min(60, $s.description.Length)) } else { '(无描述)' }
            Write-Host ('    {0}{1}' -f (Format-CellLocal $s.name 26), $short)
        }
    }
    if ($idx.knowledge.Count -gt 0) {
        Write-Host "`n  知识库" -ForegroundColor Magenta
        foreach ($k in $idx.knowledge) {
            Write-Host ('    {0}{1} 篇' -f (Format-CellLocal $k.id 16), $k.docs) -ForegroundColor Magenta
        }
    }
}

# ---------------------------------------------------------------- sync

function Invoke-Sync {
    <#
      默认只装一个"路由器技能"（skill-hub），不把 164 个技能全链进去。
      原因：技能列表会进系统提示，164 条描述反而稀释路由精度，
      而且客户端自己的目录里已经有同名技能的英文版，重复链会冲突。

      需要全量镜像时用 -All（会按 frontmatter 的 name 命名，冲突的跳过）。
    #>
    $idx = Read-Index
    if (-not $idx) { return }

    # 先生成路由器技能
    $routerDir = Join-Path $script:Hub 'skill-hub'
    if (-not $DryRun) { Write-Router -Index $idx -Dir $routerDir }

    $wanted = [ordered]@{}
    if ($All) {
        foreach ($s in $idx.skills) {
            if ($s.category -like '_*') { continue }
            $key = if ($s.name) { $s.name } else { $s.folder }
            if ($wanted.Contains($key)) { continue }
            $wanted[$key] = $s.path
        }
    }

    Write-H $(if ($All) { "同步全量（$($wanted.Count) 个技能 + 路由器）" } else { '同步路由器到各客户端' })

    foreach ($c in $Clients) {
        if (-not $script:ClientDirs.ContainsKey($c)) { Write-No "未知客户端: $c"; continue }
        $dir = $script:ClientDirs[$c]
        if (-not (Test-Path -LiteralPath $dir)) {
            if ($DryRun) { Write-Dim "[$c] 目录不存在，会创建: $dir" }
            else { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }

        $created = 0; $skipped = 0; $conflict = 0
        $pairs = [ordered]@{}
        if (-not $DryRun -or $true) { $pairs['skill-hub'] = $routerDir }
        foreach ($k in $wanted.Keys) { $pairs[$k] = $wanted[$k] }

        foreach ($name in $pairs.Keys) {
            $target = Join-Path $dir $name
            if (Test-Path -LiteralPath $target) {
                $item = Get-Item -LiteralPath $target -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                $conflict++
                continue
            }
            if ($DryRun) { $created++; continue }
            try {
                & cmd /c mklink /J "$target" "$($pairs[$name])" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $created++ } else { $conflict++ }
            } catch { $conflict++ }
        }

        $label = Format-CellLocal "[$c]" 14
        if ($DryRun) { Write-Host "  $label 会新增 $created · 已存在 $skipped · 冲突 $conflict（DryRun）" }
        else { Write-Host "  $label 新增 $created · 已存在 $skipped · 冲突 $conflict" }
    }

    Write-Host ''
    if ($DryRun) { Write-No 'DryRun：没有做任何改动'; return }
    Write-Ok '完成'
    Write-Dim 'skill-hub 现在出现在各客户端的技能列表里；它会让 agent 先检索再动手。'
    if (-not $All) { Write-Dim '想让客户端直接看到全部技能，用：kb.ps1 sync -All' }
}
function Write-Router {
    param($Index, [string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

    $byCat = $Index.skills | Where-Object { $_.category -notlike '_*' } | Group-Object category | Sort-Object Name
    $lines = @()
    $lines += '---'
    $lines += 'name: skill-hub'
    $lines += 'description: 本机技能库与知识库的总入口。当任务涉及 PPT/Word/Excel/PDF、图片与素材、微信小程序、桌面应用与桌宠、本地网页工具、翻译与双语文档、游戏、网站与部署、设计与创意、MV 与音乐视频、GitHub 发布、代码审查、技术选型、知识库检索时，先用本技能检索，再决定用哪个具体技能。也可以用它回答"我有哪些技能"。'
    $lines += '---'
    $lines += ''
    $lines += '# 技能库导航'
    $lines += ''
    $lines += "本机有 $($Index.skillCount) 个技能，按 $($byCat.Count) 个分类组织，索引在 ``$script:IndexPath``。"
    $lines += ''
    $lines += '## 怎么用（重要）'
    $lines += ''
    $lines += '**不要凭记忆猜有没有某个技能。** 先检索：'
    $lines += ''
    $lines += '```powershell'
    $lines += 'powershell -NoProfile -ExecutionPolicy Bypass -File <HUB>\skill-hub.ps1 find "关键词"'
    $lines += '```'
    $lines += ''
    $lines += '命中后读 `SKILL.md` 再动手。没命中就换个说法再试，或用 `kb.ps1 list` 看全量。'
    $lines += ''
    $lines += '## 分类概览'
    $lines += ''
    foreach ($g in $byCat) {
        $names = ($g.Group | Sort-Object name | Select-Object -First 12 | ForEach-Object { $_.name }) -join '、'
        $more = if ($g.Count -gt 12) { " 等 $($g.Count) 个" } else { '' }
        $lines += "- **$($g.Name)**：$names$more"
    }
    if ($Index.knowledge.Count -gt 0) {
        $lines += ''
        $lines += '## 知识库'
        $lines += ''
        foreach ($k in $Index.knowledge) {
            $lines += "- **$($k.id)**（$($k.docs) 篇）：$($k.desc)"
            $lines += "  - 路径：``$($k.path)``"
        }
    }
    $lines += ''
    $lines += '## 新增技能'
    $lines += ''
    $lines += "放到对应分类目录下（``$Root\<分类>\<技能名>\SKILL.md``），然后重跑 ``skill-hub.ps1 index``。"
    $lines += '各客户端通过 `kb.ps1 sync` 拿到同一份，不需要手工复制。'

    [System.IO.File]::WriteAllText((Join-Path $Dir 'SKILL.md'), ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------- install

function Get-RouterBlock {
    param($Index)
    $byCat = $Index.skills | Where-Object { $_.category -notlike '_*' } | Group-Object category | Sort-Object Name
    $catLines = @()
    foreach ($g in $byCat) {
        $catLines += "- $($g.Name)（$($g.Count) 个）"
    }
    $kbLine = ''
    if ($Index.knowledge.Count -gt 0) {
        $k = $Index.knowledge | Select-Object -First 1
        $kbLine = "- 知识库 $($k.id)（$($k.docs) 篇）：``$($k.path)``"
    }

    $lines = @()
    $lines += "<!-- SKILL-HUB:BEGIN 由 skill-hub 生成，重新运行 install 会覆盖这一段 -->"
    $lines += '## 本机技能库：先检索，再用'
    $lines += ''
    $lines += "本机有 $($Index.skillCount) 个技能，索引在 ``$script:IndexPath``。"
    $lines += '**不要凭记忆猜某个能力有没有，也不要自己现写一套流程。** 动手前先检索：'
    $lines += ''
    $lines += '```powershell'
    $lines += 'powershell -NoProfile -ExecutionPolicy Bypass -File <HUB>\skill-hub.ps1 find "关键词"'
    $lines += '```'
    $lines += ''
    $lines += '命中后读它给出的 `SKILL.md` 再执行。没命中就换个说法重试，或 `kb.ps1 list` 看全量。'
    $lines += ''
    $lines += '覆盖范围：'
    $lines += $catLines
    if ($kbLine) { $lines += $kbLine }
    $lines += ''
    $lines += "新增技能放到 `\<分类>\<技能名>\SKILL.md`，然后跑 `skill-hub.ps1 index`。"
    $lines += '<!-- SKILL-HUB:END -->'
    return ($lines -join "`n")
}

function Set-MarkedBlock {
    param([string]$FilePath, [string]$Block, [string]$Label)
    $begin = '<!-- SKILL-HUB:BEGIN'
    $end = '<!-- SKILL-HUB:END -->'

    $existing = ''
    if (Test-Path -LiteralPath $FilePath) { $existing = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8) }

    if ($existing -match [regex]::Escape($begin)) {
        $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
        $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $Block })
        if ($DryRun) { Write-Dim "[$Label] 会替换已有的块" ; return }
        [System.IO.File]::WriteAllText($FilePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "[$Label] 已更新（替换旧块）"
    } else {
        $newText = if ([string]::IsNullOrWhiteSpace($existing)) { $Block } else { $existing.TrimEnd() + "`n`n" + $Block + "`n" }
        if ($DryRun) { Write-Dim "[$Label] 会追加到 $FilePath" ; return }
        $dir = Split-Path $FilePath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($FilePath, $newText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "[$Label] 已写入 $FilePath"
    }
}

function Invoke-Install {
    $idx = Read-Index
    if (-not $idx) { return }
    Write-H "安装路由器指令（$($idx.skillCount) 个技能）"

    $block = Get-RouterBlock -Index $idx
    $targets = @()
    foreach ($x in $script:InstructionTargets) {
        if ($x.Path) { $targets += $x }
    }



    foreach ($t in $targets) {
        Set-MarkedBlock -FilePath $t.Path -Block $block -Label $t.Label
    }

    Write-Host ''
    if ($DryRun) { Write-No 'DryRun：没有写入' }
    else {
        Write-Ok '完成。新开的会话就会带上这段说明。'
        Write-Dim '想撤销：把对应文件里 SKILL-HUB:BEGIN 到 END 之间删掉。'
    }
}
# ---------------------------------------------------------------- adopt

function Get-SuggestCategory {
    param([string]$Name, [string]$Desc)
    $text = "$Name $Desc".ToLower()
    if ($text -match 'mv|音乐|歌词|分镜|song|lyric|video') { return '09-设计与创意' }
    if ($text -match 'ppt|slide|演示|幻灯') { return '08-办公文档' }
    if ($text -match 'word|docx|排版|文档|写作|文案') { return '08-办公文档' }
    if ($text -match '翻译|双语|translat') { return '06-翻译与双语文档' }
    if ($text -match '小程序|miniprogram|miniapp') { return '02-微信小程序' }
    if ($text -match 'electron|桌宠|pet|桌面应用') { return '03-桌面应用与桌宠' }
    if ($text -match '网站|部署|seo|deploy|站点') { return '10-网站与部署' }
    if ($text -match '图片|图像|抠图|素材|image|icon') { return '01-图片与游戏素材' }
    if ($text -match '清理|cleanup|磁盘|storage') { return '11-开发辅助' }
    if ($text -match '语言|写作|措辞|rewrite|plain|copy') { return '08-办公文档' }
    return '00-通用技能'
}

function Invoke-Adopt {
    <#
      把只存在于客户端 skills 目录里的技能并入中心库。
      只复制，不删除、不改动原来的客户端目录。
    #>
    $idx = Read-Index
    if (-not $idx) { return }

    $known = @{}
    foreach ($s in $idx.skills) { $known[$s.name.ToLower()] = $true; $known[$s.folder.ToLower()] = $true }

    $found = @()
    foreach ($c in $script:ClientDirs.Keys) {
        $dir = $script:ClientDirs[$c]
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue) {
            if ($f.FullName -match '\\\\\.system\\\\') { continue }   # 客户端的系统内置技能，不并
            $fm = Get-Frontmatter -Path $f.FullName
            $name = if ($fm -and $fm.Name) { $fm.Name } else { $f.Directory.Name }
            if ($known.ContainsKey($name.ToLower()) -or $known.ContainsKey($f.Directory.Name.ToLower())) { continue }
            $found += [pscustomobject]@{
                Name = $name; Folder = $f.Directory.Name; Source = $f.Directory.FullName
                Desc = if ($fm) { $fm.Description } else { '' }
                Client = $c
            }
        }
    }

    if ($found.Count -eq 0) { Write-Ok '没有需要并入的技能'; return }

    Write-H "发现 $($found.Count) 个只存在于客户端的技能"
    $plan = @()
    foreach ($f in $found) {
        $cat = Get-SuggestCategory -Name "$($f.Name) $($f.Folder)" -Desc $f.Desc
        $dest = Join-Path (Join-Path $Root $cat) $f.Folder
        $plan += [pscustomobject]@{ Item = $f; Category = $cat; Dest = $dest }
        Write-Host ("  {0}{1}{2}" -f (Format-CellLocal $f.Name 34), (Format-CellLocal $cat 18), $(if (Test-Path -LiteralPath $dest) { '(目标已存在，跳过)' } else { '' }))
        Write-Dim ("从 " + $f.Source)
    }

    if ($DryRun) { Write-Host ''; Write-No 'DryRun：没有复制任何东西'; return }
    if (-not $Force -and $plan.Count -gt 0) {
        Write-Host ''
        $a = Read-Host "  复制这些技能到中心库？原目录不会动 (y/N)"
        if ($a -notmatch '^[yY]') { Write-No '已取消'; return }
    }

    $ok = 0; $skip = 0
    foreach ($p in $plan) {
        if (Test-Path -LiteralPath $p.Dest) { $skip++; continue }
        try {
            New-Item -ItemType Directory -Path (Split-Path $p.Dest -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $p.Item.Source -Destination $p.Dest -Recurse -Force -ErrorAction Stop
            $ok++
        } catch { Write-Bad "复制失败 $($p.Item.Name)：$($_.Exception.Message)" }
    }
    Write-Host ''
    Write-Ok "并入 $ok 个 · 跳过 $skip 个"
    Write-Dim '原客户端的目录没动。想让它们共用一份，确认无误后手工删掉旧目录再跑 sync。'
    Write-Dim '重新索引：kb.ps1 index'
}
# ---------------------------------------------------------------- doctor

function Invoke-Doctor {
    $idx = Read-Index
    if (-not $idx) { return }
    Write-H "体检：$($idx.skillCount) 个技能"

    $issues = 0
    if ($idx.duplicates.Count -gt 0) {
        Write-No "内容完全重复：$($idx.duplicates.Count) 组"
        foreach ($d in $idx.duplicates) { Write-Dim $d }
        $issues += $idx.duplicates.Count
    }

    $weak = @($idx.skills | Where-Object { $_.descLen -lt 40 -and $_.category -notlike '_*' })
    if ($weak.Count -gt 0) {
        Write-No "描述太短（路由难命中）：$($weak.Count) 个"
        foreach ($w in ($weak | Select-Object -First 10)) { Write-Dim ("{0}  [{1}] {2}" -f $w.name, $w.category, $(if ($w.description) { $w.description } else { '(空)' })) }
        $issues += $weak.Count
    }

    $noRaw = @($idx.skills | Where-Object { -not $_.hasRaw })
    if ($noRaw.Count -gt 0) {
        Write-No "没有 frontmatter（客户端可能不认）：$($noRaw.Count) 个"
        foreach ($w in ($noRaw | Select-Object -First 5)) { Write-Dim $w.dir }
        $issues += $noRaw.Count
    }

    Write-Host ''
    foreach ($c in $Clients) {
        if (-not $script:ClientDirs.ContainsKey($c)) { continue }
        $d = $script:ClientDirs[$c]
        if (-not (Test-Path -LiteralPath $d)) { Write-Dim ("[{0}] 不存在: {1}" -f $c, $d); continue }
        $n = @(Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue).Count
        Write-Host ("  [{0}] {1} 个技能目录" -f $c, $n)
    }

    Write-Host ''
    if ($issues -eq 0) { Write-Ok '没发现问题' } else { Write-No "共 $issues 处可改进" }
}

# ---------------------------------------------------------------- 入口

function Show-Help {
    Write-Host @"
skill-hub v$script:Version

  skill-hub.ps1 index            扫描技能库，生成 index.json
  skill-hub.ps1 find <关键词>     检索技能与知识库
  skill-hub.ps1 list             按分类列出全部技能
  skill-hub.ps1 sync [-All]      装路由器技能到各客户端（-All 才全量镜像）
  skill-hub.ps1 doctor           查重复、短描述、坏 frontmatter
  skill-hub.ps1 install          把"先检索再动手"的说明写进 DSH/Codex 的 AGENTS.md
  skill-hub.ps1 adopt [-DryRun]  把只在客户端里的技能并入中心库（只复制）

参数
  -Root <路径>      技能库根目录（默认 ~/.skills）
  -Clients <列表>   要同步的客户端（codex,qoder,workbuddy,claude,agents）
  -Top <n>          find 返回条数
  -Json             find/index 输出 JSON
  -DryRun           只演练
"@ -ForegroundColor Gray
}

switch ($Command.ToLower()) {
    'index' { Invoke-Index }
    'find' { Invoke-Find }
    'list' { Invoke-List }
    'sync' { Invoke-Sync }
    'doctor' { Invoke-Doctor }
    'install' { Invoke-Install }
    'adopt' { Invoke-Adopt }
    default { Show-Help }
}
