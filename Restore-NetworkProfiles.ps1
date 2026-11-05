<#
=============================================================
 网络配置恢复工具（配套 Clear-NetworkProfiles.ps1）
 ---------------------------------------------------------
 从清理工具生成的注册表快照中，把删掉的网络配置补回来。

 恢复方式为「补齐式」：只创建当前不存在的项，
 不会覆盖或改动你现有的网络配置。
=============================================================
#>

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  >> 需要管理员权限，正在请求提权...' -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Definition }
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $self)) `
            -Verb RunAs | Out-Null
    } catch {
        Write-Host '  >> 提权被拒绝。' -ForegroundColor Red
        Read-Host '按回车键退出'
    }
    exit
}

try { $Host.UI.RawUI.WindowTitle = 'Windows 网络配置恢复工具' } catch { }

$SnapRoot = 'Software\_NetworkListBackup'
$LiveRoot = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList'

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

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host '            Windows 网络配置恢复工具' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host ''

$root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SnapRoot)
if (-not $root) {
    Write-Host '  没有找到任何备份快照。' -ForegroundColor Yellow
    Write-Host '  （快照由「一键清理网络配置.bat」在删除前自动创建）' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '按回车键退出'
    return
}

$stamps = @($root.GetSubKeyNames() | Sort-Object -Descending)
$root.Close()

if ($stamps.Count -eq 0) {
    Write-Host '  没有找到任何备份快照。' -ForegroundColor Yellow
    Read-Host '按回车键退出'
    return
}

Write-Host ('  可用快照 {0} 份（新的在前）：' -f $stamps.Count) -ForegroundColor White
Write-Host ''

$i = 0
foreach ($s in $stamps) {
    $i++
    $sk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$SnapRoot\$s")
    $pc = 0; $sc = 0
    try {
        $p = $sk.OpenSubKey('Profiles')
        if ($p) { $pc = $p.SubKeyCount; $p.Close() }
        $g = $sk.OpenSubKey('Signatures\Unmanaged')
        if ($g) { $sc = $g.SubKeyCount; $g.Close() }
    } catch { }
    $sk.Close()

    $t = $s
    try {
        $t = [datetime]::ParseExact($s, 'yyyyMMdd-HHmmss', $null).ToString('yyyy-MM-dd HH:mm:ss')
    } catch { }

    Write-Host ('    [{0}]  {1}   Profiles {2,4} 条   Signatures {3,4} 条' -f $i, $t, $pc, $sc) -ForegroundColor Gray
}

Write-Host ''
$pick = Read-Host '  选择要恢复的快照序号（直接回车取消）'
$pick = $pick.Trim()
if ($pick -eq '' -or $pick -notmatch '^\d+$') { Write-Host '  已取消。' -ForegroundColor Yellow; Read-Host '按回车键退出'; return }

$n = [int]$pick
if ($n -lt 1 -or $n -gt $stamps.Count) { Write-Host '  序号超出范围。' -ForegroundColor Red; Read-Host '按回车键退出'; return }

$stamp   = $stamps[$n - 1]
$snapKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$SnapRoot\$stamp")
$liveKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($LiveRoot, $true)

if (-not $liveKey) { Write-Host '  无法打开实时注册表项。' -ForegroundColor Red; Read-Host '按回车键退出'; return }

# 找出快照中当前不存在的项
$toAdd = @()
foreach ($sec in @('Profiles', 'Signatures\Unmanaged')) {
    $srcSec  = $snapKey.OpenSubKey($sec)
    if (-not $srcSec) { continue }
    $liveSec = $liveKey.OpenSubKey($sec, $true)
    if (-not $liveSec) { $liveSec = $liveKey.CreateSubKey($sec) }

    foreach ($cn in $srcSec.GetSubKeyNames()) {
        if (-not $liveSec.OpenSubKey($cn)) {
            $name = ''
            try {
                $k = $srcSec.OpenSubKey($cn)
                $name = [string]$k.GetValue('ProfileName', '')
                $k.Close()
            } catch { }
            $toAdd += [PSCustomObject]@{ Section = $sec; Key = $cn; Name = $name }
        }
    }
    $srcSec.Close(); $liveSec.Close()
}

if ($toAdd.Count -eq 0) {
    Write-Host ''
    Write-Host '  该快照中的配置已全部存在于系统中，无需恢复。' -ForegroundColor Green
    $snapKey.Close(); $liveKey.Close()
    Read-Host '按回车键退出'
    return
}

Write-Host ''
Write-Host ('  可恢复 {0} 项（仅补齐当前缺失的，不动现有配置）：' -f $toAdd.Count) -ForegroundColor Yellow
Write-Host ''
$show = @($toAdd | Where-Object { $_.Section -eq 'Profiles' })
$shown = 0
foreach ($t in $show) {
    if ($shown -ge 20) { Write-Host '    ...' -ForegroundColor DarkGray; break }
    Write-Host ('    {0}' -f $(if ($t.Name) { $t.Name } else { $t.Key.Substring(0, 12) })) -ForegroundColor Gray
    $shown++
}
if ($toAdd.Count -gt $show.Count) {
    Write-Host ('    （另有 {0} 条网络签名残留）' -f ($toAdd.Count - $show.Count)) -ForegroundColor DarkGray
}

Write-Host ''
$ans = Read-Host '  确认恢复？输入 y 执行'
if ($ans.Trim().ToLower() -ne 'y') {
    Write-Host '  已取消。' -ForegroundColor Yellow
    $snapKey.Close(); $liveKey.Close()
    Read-Host '按回车键退出'
    return
}

$done = 0
$errs = @()
foreach ($t in $toAdd) {
    try {
        $src = $snapKey.OpenSubKey("$($t.Section)\$($t.Key)")
        $dst = $liveKey.CreateSubKey("$($t.Section)\$($t.Key)")
        Copy-RegistryKeyRecursive -Source $src -Dest $dst
        $src.Close(); $dst.Close()
        $done++
    } catch {
        $errs += $t.Key
    }
}

$snapKey.Close(); $liveKey.Close()

Write-Host ''
Write-Host ('  完成：恢复 {0} 项，失败 {1} 项。' -f $done, $errs.Count) -ForegroundColor Green
if ($errs.Count -gt 0) { Write-Host ('  失败：{0}' -f ($errs -join ', ')) -ForegroundColor Red }
Write-Host ''
Read-Host '按回车键退出'
