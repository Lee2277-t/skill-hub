# skill-hub 自测：在临时目录里造技能库，验证索引、检索、块标量解析、护栏。
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

$tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'skill-hub.ps1'
if (-not (Test-Path -LiteralPath $tool)) { throw "找不到 skill-hub.ps1: $tool" }

$work = Join-Path $env:TEMP ('skill-hub-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$skills = Join-Path $work 'skills'
$hub = Join-Path $work 'hub'
New-Item -ItemType Directory -Path $skills, $hub -Force | Out-Null

function Test-That {
    param([string]$Label, [scriptblock]$Condition)
    try {
        if (& $Condition) { $script:Pass++; Write-Host "  [OK]   $Label" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  [FAIL] $Label" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  [FAIL] $Label ($($_.Exception.Message))" -ForegroundColor Red }
}

function Invoke-Hub {
    param([string[]]$Arguments)
    $all = $Arguments + @('-Root', $skills, '-Hub', $hub)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $tool @all 2>&1
    return @{ Output = ($out -join "`n"); Code = $LASTEXITCODE }
}

function New-Skill {
    param([string]$Category, [string]$Name, [string]$Description, [string]$Body = '# do it')
    $dir = Join-Path (Join-Path $skills $Category) $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $text = "---`nname: $Name`ndescription: $Description`n---`n$Body"
    [System.IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), $text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "`n=== skill-hub 自测 ===" -ForegroundColor Cyan

try {
    New-Skill -Category '01-办公' -Name 'ppt-master' -Description '生成可编辑的 PPTX 演示文稿'
    New-Skill -Category '02-开发' -Name 'code-review' -Description '审查代码改动，找逻辑错误与遗漏的边界情况'
    New-Skill -Category '02-开发' -Name 'block-scalar' -Description ">`n  多行描述的第一行`n  第二行说明"
    New-Skill -Category '_archive' -Name 'old-skill' -Description '应当被排除的存档技能'

    Write-Host "`n1. 索引" -ForegroundColor Cyan
    $r = Invoke-Hub @('index')
    Test-That '索引命令成功' { $r.Code -eq 0 }
    Test-That '索引文件已生成' { Test-Path -LiteralPath (Join-Path $hub 'index.json') }
    $idx = [System.IO.File]::ReadAllText((Join-Path $hub 'index.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Test-That '收录 3 个技能（排除 _ 开头的存档）' { @($idx.skills).Count -eq 3 }
    Test-That '分类正确识别' { @($idx.skills | Where-Object { $_.category -eq '02-开发' }).Count -eq 2 }

    Write-Host "`n2. 块标量解析" -ForegroundColor Cyan
    Test-That '多行 description 被完整解析' {
        [bool](@($idx.skills) | Where-Object { $_.description -match '第二行说明' })
    }

    Write-Host "`n3. 检索" -ForegroundColor Cyan
    $r = Invoke-Hub @('find', 'PPT')
    Test-That '中文关键词能命中' { $r.Output -match 'ppt-master' }
    $r = Invoke-Hub @('find', '代码')
    Test-That '描述里的词能命中' { $r.Output -match 'code-review' }
    $r = Invoke-Hub @('find', '完全不存在的词xyz')
    Test-That '无结果时给出提示而不是报错' { $r.Output -match '没有命中' }
    Test-That '检索结果带 SKILL.md 路径' { (Invoke-Hub @('find', 'PPT')).Output -match 'SKILL\.md' }

    Write-Host "`n4. 输出格式" -ForegroundColor Cyan
    $r = Invoke-Hub @('list')
    Test-That 'list 按分类分组' { $r.Output -match '01-办公' -and $r.Output -match '02-开发' }
    Test-That 'list 不包含存档分类' { $r.Output -notmatch 'old-skill' }
    $r = Invoke-Hub @('index', '-Json')
    Test-That 'index 支持 JSON 输出' { $r.Output -match '"skillCount"' }

    Write-Host "`n5. 护栏" -ForegroundColor Cyan
    $r = & powershell -NoProfile -ExecutionPolicy Bypass -File $tool index -Root (Join-Path $work 'nope') -Hub $hub 2>&1
    Test-That '根目录不存在时明确报错' { ($r -join "`n") -match '不存在' }
    $r = Invoke-Hub @('doctor')
    Test-That 'doctor 能跑' { $r.Output -match '体检' }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== 结果 ===" -ForegroundColor Cyan
Write-Host ("  通过 {0} · 失败 {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 }
exit 0
