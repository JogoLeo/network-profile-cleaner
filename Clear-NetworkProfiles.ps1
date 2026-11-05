<#
=============================================================
 Windows 网络配置清理工具
 ---------------------------------------------------------
 作用：把 Windows 记住的所有网络（NetworkList\Profiles）
       带序号列出来，选中的一次性删除。

 用法：双击「一键清理网络配置.bat」，或右键本文件
       →「使用 PowerShell 运行」（会自动请求管理员权限）

 特性：
   - 自动备份注册表到脚本目录下的 backup\ 子目录
   - 当前正在使用的网络会被锁定，无法删除
   - 同时清理指向被删网络的 Signatures 残留条目
   - 支持 3 / 1-10 / 1,5-10 / all 等输入方式
=============================================================
#>

$ErrorActionPreference = 'Stop'

# ---------------- 自提权 ----------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  >> 需要管理员权限，正在请求提权，请在弹出的窗口点「是」...' -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Definition }
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $self)) `
            -Verb RunAs | Out-Null
    } catch {
        Write-Host '  >> 提权被拒绝，无法继续。请右键「以管理员身份运行」。' -ForegroundColor Red
        Read-Host '按回车键退出'
    }
    exit
}

# ---------------- 路径常量 ----------------
$RegBase     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList'
$ProfilesKey = Join-Path $RegBase 'Profiles'
$SigRoots    = @(
    (Join-Path $RegBase 'Signatures\Unmanaged'),
    (Join-Path $RegBase 'Signatures\Managed')
)
$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$BackupDir   = Join-Path $ScriptDir 'backup'

try { $Host.UI.RawUI.WindowTitle = 'Windows 网络配置清理工具' } catch { }

# ---------------- 显示宽度处理（中文占 2 字符宽） ----------------
function Get-DisplayWidth([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return 0 }
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 }
        else { $w += 1 }
    }
    return $w
}

function Format-Cell([string]$s, [int]$width) {
    if ($null -eq $s) { $s = '' }
    $dw = Get-DisplayWidth $s
    if ($dw -ge $width) { return $s }
    return $s + (' ' * ($width - $dw))
}

# ---------------- SYSTEMTIME 解析 ----------------
function ConvertFrom-SystemTime([byte[]]$b) {
    if (-not $b -or $b.Length -lt 16) { return $null }
    $y  = [BitConverter]::ToUInt16($b, 0)
    $mo = [BitConverter]::ToUInt16($b, 2)
    $d  = [BitConverter]::ToUInt16($b, 6)
    $h  = [BitConverter]::ToUInt16($b, 8)
    $mi = [BitConverter]::ToUInt16($b, 10)
    $s  = [BitConverter]::ToUInt16($b, 12)
    if ($y -lt 1900 -or $mo -lt 1 -or $mo -gt 12 -or $d -lt 1 -or $d -gt 31) { return $null }
    if ($h -gt 23 -or $mi -gt 59 -or $s -gt 59) { return $null }
    try { return (New-Object DateTime($y, $mo, $d, $h, $mi, $s)) } catch { return $null }
}

# ---------------- 扫描 ----------------
function Get-ProfileList {
    $active = @{}
    try {
        foreach ($cp in (Get-NetConnectionProfile -ErrorAction Stop)) {
            if ($cp.Name) { $active[$cp.Name] = $true }
        }
    } catch { }

    $result = New-Object System.Collections.ArrayList

    foreach ($k in @(Get-ChildItem -Path $ProfilesKey -ErrorAction SilentlyContinue)) {
        $guid = $k.PSChildName

        $name = ''
        try {
            $name = [string]$k.GetValue('ProfileName', '',
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } catch { }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(未命名)' }

        $desc = ''
        try {
            $desc = [string]$k.GetValue('Description', '',
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } catch { }

        $nt = 0
        try { $nt = [int]$k.GetValue('NameType', 0) } catch { }

        # NameType: 6 = 以太网(含 USB 共享/虚拟网卡), 71 = Wi-Fi, 其它归入「其它」
        if ($nt -eq 6)       { $cat = 'eth';  $catLabel = '以太网'; $order = 0 }
        elseif ($nt -eq 71)  { $cat = 'wifi'; $catLabel = 'Wi-Fi';  $order = 1 }
        else                 { $cat = 'other';$catLabel = '其它';   $order = 2 }

        $last = $null
        try {
            $raw = $k.GetValue('DateLastConnected', $null)
            if ($raw -is [byte[]]) { $last = ConvertFrom-SystemTime $raw }
        } catch { }

        $num = 0
        $m = [regex]::Match($name, '(\d+)\s*$')
        if ($m.Success) { $num = [int]$m.Groups[1].Value }

        $obj = New-Object PSObject -Property @{
            Guid        = $guid
            Name        = $name
            Description = $desc
            NameType    = $nt
            Category    = $cat
            CatLabel    = $catLabel
            Order       = $order
            Num         = $num
            LastSeen    = $last
            IsActive    = $active.ContainsKey($name)
        }
        [void]$result.Add($obj)
    }

    return @($result | Sort-Object -Property @{Expression={$_.Order}}, @{Expression={$_.Num}}, @{Expression={$_.Name}})
}

function Get-SignatureCount([string[]]$guids) {
    if (-not $guids -or $guids.Count -eq 0) { return 0 }
    $set = @{}
    foreach ($g in $guids) { $set[$g.ToUpper()] = $true }
    $n = 0
    # 结构：Signatures\Unmanaged\<hash>  —— ProfileGuid 直接挂在这一层的键上
    foreach ($root in $SigRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($sig in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $pg = ''
            try { $pg = [string]$sig.GetValue('ProfileGuid', '') } catch { }
            if ($pg -and $set.ContainsKey($pg.ToUpper())) { $n++ }
        }
    }
    return $n
}

# ---------------- 删除 ----------------
function Remove-ProfileSet {
    param([object[]]$Targets)

    $ok = 0
    $fail = @()
    foreach ($p in $Targets) {
        $path = Join-Path $ProfilesKey $p.Guid
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $ok++
            Write-Host ('    [OK]   {0}' -f $p.Name) -ForegroundColor DarkGreen
        } catch {
            $fail += $p.Name
            Write-Host ('    [FAIL] {0}  -- {1}' -f $p.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }

    $sigRemoved = 0
    $set = @{}
    foreach ($p in $Targets) { $set[$p.Guid.ToUpper()] = $true }
    foreach ($root in $SigRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($sig in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $pg = ''
            try { $pg = [string]$sig.GetValue('ProfileGuid', '') } catch { }
            if ($pg -and $set.ContainsKey($pg.ToUpper())) {
                try {
                    Remove-Item -LiteralPath $sig.PSPath -Recurse -Force -ErrorAction Stop
                    $sigRemoved++
                } catch { }
            }
        }
    }

    return [PSCustomObject]@{ Ok = $ok; Fail = @($fail); SigRemoved = $sigRemoved }
}

# ---------------- 备份 ----------------
function Copy-RegistryKeyRecursive {
    param($Source, $Dest)
    foreach ($vn in $Source.GetValueNames()) {
        $val  = $Source.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $Source.GetValueKind($vn)
        $Dest.SetValue($vn, $val, $kind)
    }
    foreach ($sk in $Source.GetSubKeyNames()) {
        $s = $Source.OpenSubKey($sk)
        $d = $Dest.CreateSubKey($sk)
        Copy-RegistryKeyRecursive -Source $s -Dest $d
        $s.Close(); $d.Close()
    }
}

function New-RegistryBackup {
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destRoot = 'Software\_NetworkListBackup'
    $destPath = "$destRoot\$stamp"

    # 1) 注册表内快照（纯托管，不依赖任何外部程序）
    $src = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
              'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList')
    if (-not $src) { throw '无法读取 NetworkList 注册表项，已中止。' }

    $dst = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($destPath)
    Copy-RegistryKeyRecursive -Source $src -Dest $dst
    $dst.Close(); $src.Close()

    # 只保留最近 5 份快照
    try {
        $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($destRoot)
        $names = @($root.GetSubKeyNames() | Sort-Object)
        if ($names.Count -gt 5) {
            for ($i = 0; $i -lt ($names.Count - 5); $i++) {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("$destRoot\$($names[$i])", $false)
            }
        }
        $root.Close()
    } catch { }

    # 2) 额外导出一份 .reg（方便手动回滚，失败不影响主流程）
    $regFile = $null
    try {
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
        $candidate = Join-Path $BackupDir ('NetworkList-{0}.reg' -f $stamp)
        & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList' $candidate /y 2>&1 | Out-Null
        if (Test-Path -LiteralPath $candidate) { $regFile = $candidate }
    } catch { $regFile = $null }

    return [PSCustomObject]@{
        HivePath = "HKCU\$destPath"
        RegFile  = $regFile
    }
}

# ---------------- 输入解析 ----------------
function ConvertTo-Selection([string]$text, [int]$max) {
    $set = New-Object System.Collections.Generic.SortedSet[int]
    $parts = $text -split '[,，;；\s]+' | Where-Object { $_ -ne '' }
    if ($parts.Count -eq 0) { return $null }

    foreach ($part in $parts) {
        if ($part -match '^(\d+)\s*[-~—–]\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            if ($a -lt 1) { $a = 1 }
            if ($b -gt $max) { $b = $max }
            if ($a -le $b) { foreach ($i in ($a..$b)) { [void]$set.Add($i) } }
        }
        elseif ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $max) { [void]$set.Add($n) }
            else { return $null }
        }
        else {
            return $null
        }
    }
    if ($set.Count -eq 0) { return $null }
    return $set
}

# ---------------- 界面 ----------------
function Show-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '            Windows 网络配置清理工具' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
}

function Show-Summary($all) {
    $eth  = @($all | Where-Object { $_.Category -eq 'eth' })
    $wifi = @($all | Where-Object { $_.Category -eq 'wifi' })
    $oth  = @($all | Where-Object { $_.Category -eq 'other' })

    Write-Host ''
    Write-Host ('  共发现 {0} 个已记住的网络配置' -f $all.Count) -ForegroundColor White
    Write-Host ('    以太网类（USB 共享 / 有线）  {0,4} 条' -f $eth.Count) -ForegroundColor Gray
    Write-Host ('    Wi-Fi 热点类                 {0,4} 条' -f $wifi.Count) -ForegroundColor Gray
    Write-Host ('    其它 / 虚拟网卡              {0,4} 条' -f $oth.Count) -ForegroundColor Gray

    $act = @($all | Where-Object { $_.IsActive })
    Write-Host ''
    if ($act.Count -gt 0) {
        $names = ($act | ForEach-Object { $_.Name }) -join '、'
        Write-Host ('  当前正在使用：{0}   （已锁定，不会被删除）' -f $names) -ForegroundColor Green
    } else {
        Write-Host '  当前没有检测到活动网络连接' -ForegroundColor DarkGray
    }
}

function Show-ProfileTable($view) {
    Write-Host ''
    Write-Host ('  {0}{1}{2}{3}{4}' -f
        (Format-Cell '  #' 5),
        (Format-Cell '网络名称' 26),
        (Format-Cell '类型' 8),
        (Format-Cell '最后连接' 18),
        'GUID') -ForegroundColor DarkCyan
    Write-Host ('  {0}' -f ('-' * 74)) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $view.Count; $i++) {
        $p   = $view[$i]
        $idx = ('{0}' -f ($i + 1)).PadLeft(4)
        $nm  = Format-Cell $p.Name 26
        $cl  = Format-Cell $p.CatLabel 8
        $ts  = if ($p.LastSeen) { $p.LastSeen.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        $ts  = Format-Cell $ts 18
        $gd  = $p.Guid.Trim('{', '}').Substring(0, 8)

        $line = '  {0}  {1}{2}{3}{4}' -f $idx, $nm, $cl, $ts, $gd

        if ($p.IsActive) {
            Write-Host $line -ForegroundColor Green -NoNewline
            Write-Host '  <== 当前使用（锁定）' -ForegroundColor Green
        } else {
            Write-Host $line
        }
    }
    Write-Host ''
}

# ---------------- 主循环 ----------------
Show-Banner
Write-Host ''
Write-Host '  说明：每次手机开 USB 共享，Windows 会新建一个"网络 N"配置。' -ForegroundColor DarkGray
Write-Host '        这里把它们列出来，选中即可批量删除。' -ForegroundColor DarkGray

$firstRun = $true
while ($true) {
    if (-not $firstRun) {
        Write-Host ''
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    }
    $firstRun = $false

    $all = Get-ProfileList
    if ($all.Count -eq 0) {
        Write-Host '  没有读到任何网络配置。' -ForegroundColor Yellow
        break
    }

    Show-Summary $all

    Write-Host ''
    Write-Host '  选择要查看的范围：' -ForegroundColor White
    Write-Host '    [e] 以太网类   —— 手机 USB 共享产生的"网络 N"都在这（推荐）' -ForegroundColor Gray
    Write-Host '    [w] Wi-Fi 类   —— 连过的热点记录' -ForegroundColor Gray
    Write-Host '    [a] 全部' -ForegroundColor Gray
    Write-Host '    [q] 退出' -ForegroundColor Gray
    $scope = Read-Host '  请输入'
    if ($null -eq $scope) { return }
    $scope = $scope.Trim().ToLower()

    switch ($scope) {
        'q' { return }
        'w' { $view = @($all | Where-Object { $_.Category -eq 'wifi' }) }
        'a' { $view = $all }
        default { $view = @($all | Where-Object { $_.Category -eq 'eth' }) }
    }

    if ($view.Count -eq 0) {
        Write-Host '  该分类下没有网络配置。' -ForegroundColor Yellow
        continue
    }

    Show-ProfileTable $view

    $lockedCount = @($view | Where-Object { $_.IsActive }).Count
    Write-Host '  输入要删除的序号：' -ForegroundColor White
    Write-Host '    单个      3' -ForegroundColor DarkGray
    Write-Host '    连续      1-10' -ForegroundColor DarkGray
    Write-Host '    混合      1,5-10,20' -ForegroundColor DarkGray
    Write-Host '    全部      all' -ForegroundColor DarkGray
    Write-Host '    返回      b      退出  q' -ForegroundColor DarkGray
    $inputText = Read-Host '  序号'

    if ($null -eq $inputText) { return }
    $inputText = $inputText.Trim()
    if ($inputText -eq '' -or $inputText.ToLower() -eq 'b') { continue }
    if ($inputText.ToLower() -eq 'q') { return }

    if ($inputText.ToLower() -eq 'all') {
        $picked = @(0..($view.Count - 1) | Where-Object { -not $view[$_].IsActive })
    } else {
        $sel = ConvertTo-Selection $inputText $view.Count
        if ($null -eq $sel) {
            Write-Host '  输入格式不对，或序号超出范围（1-' -NoNewline -ForegroundColor Red
            Write-Host ($view.Count.ToString() + '）。') -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        $picked = @($sel | ForEach-Object { $_ - 1 } | Where-Object { -not $view[$_].IsActive })
        $skipped = $sel.Count - $picked.Count
        if ($skipped -gt 0) {
            Write-Host ('  已自动排除 {0} 项（当前正在使用，删了会断网）。' -f $skipped) -ForegroundColor Yellow
        }
    }

    if ($picked.Count -eq 0) {
        Write-Host '  没有可删除的项。' -ForegroundColor Yellow
        continue
    }

    # ---- 确认 ----
    $targets = @($picked | ForEach-Object { $view[$_] })

    Write-Host ''
    Write-Host ('  ------------------------------------------------------------') -ForegroundColor DarkCyan
    Write-Host ('  即将删除以下 {0} 项网络配置：' -f $targets.Count) -ForegroundColor Yellow
    Write-Host ''
    foreach ($p in $targets) {
        $ts = if ($p.LastSeen) { $p.LastSeen.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        Write-Host ('    {0}{1}{2}{3}' -f
            (Format-Cell $p.Name 26),
            (Format-Cell $p.CatLabel 8),
            (Format-Cell $ts 18),
            $p.Guid.Trim('{', '}').Substring(0, 8)) -ForegroundColor Gray
    }

    $sigCount = Get-SignatureCount ($targets | ForEach-Object { $_.Guid })
    Write-Host ''
    Write-Host ('  同时会清理 {0} 条关联的网络签名（Signatures 残留）。' -f $sigCount) -ForegroundColor Gray
    Write-Host '  删除前会自动备份注册表。' -ForegroundColor Gray
    Write-Host ''
    $ans = Read-Host '  确认删除？输入 y 执行，其它任意键取消'
    if ($null -eq $ans) { $ans = '' }

    if ($ans.Trim().ToLower() -ne 'y') {
        Write-Host '  已取消，未做任何修改。' -ForegroundColor Yellow
        continue
    }

    # ---- 备份 ----
    try {
        $bak = New-RegistryBackup
        Write-Host ''
        Write-Host '  备份完成：' -ForegroundColor DarkGreen
        Write-Host ('    注册表快照  {0}' -f $bak.HivePath) -ForegroundColor DarkGray
        if ($bak.RegFile) {
            Write-Host ('    .reg 文件   {0}' -f $bak.RegFile) -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '  已中止，没有删除任何内容。' -ForegroundColor Red
        continue
    }

    # ---- 执行删除 ----
    Write-Host ''
    Write-Host '  开始删除...' -ForegroundColor White
    $r    = Remove-ProfileSet -Targets $targets
    $ok   = $r.Ok
    $fail = @($r.Fail)
    $sigRemoved = $r.SigRemoved

    # ---- 结果 ----
    Write-Host ''
    Write-Host ('  ============================================================') -ForegroundColor DarkCyan
    Write-Host ('  完成：成功删除 {0} 项，失败 {1} 项，清理签名 {2} 条。' -f $ok, $fail.Count, $sigRemoved) -ForegroundColor Green
    if ($fail.Count -gt 0) {
        Write-Host ('  失败项：{0}' -f ($fail -join '、')) -ForegroundColor Red
    }

    $left = @(Get-ProfileList | Where-Object { $_.Category -eq 'eth' })
    Write-Host ('  当前剩余以太网类网络：{0} 条' -f $left.Count) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  提示：重新插拔 USB 共享后，新网络会从最小可用编号开始命名。' -ForegroundColor DarkGray
    Write-Host '        如果编号仍持续增长，是手机端网卡 MAC 每次随机导致签名变化，' -ForegroundColor DarkGray
    Write-Host '        这种情况只能定期跑一次本工具清理。' -ForegroundColor DarkGray
}

Write-Host ''
Read-Host '按回车键退出'
