param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$TaskName = '3xfixc-chkdsk3'
$InstallDir = 'C:\ProgramData\3xfixc-chkdsk3'
$RuntimeScript = Join-Path $InstallDir 'run.ps1'
$StateFile = Join-Path $InstallDir 'pass.txt'
$RunLog = Join-Path $InstallDir 'run.log'
$InstallLog = Join-Path $InstallDir 'install.log'
$TimeoutFile = Join-Path $InstallDir 'autochk_timeout.txt'
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if ($SelfTest) {
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw ("PowerShell parse failed: " + (($parseErrors | ForEach-Object { $_.Message }) -join '; '))
    }

    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    $required = @(
        'echo y |',
        'C: /f /r /x /b',
        '$count -ge 3',
        'Unregister-ScheduledTask -TaskName $TaskName',
        'C:\ProgramData\3xfixc-chkdsk3',
        'New-ScheduledTaskPrincipal -UserId ''SYSTEM'' -RunLevel Highest',
        'Restart-Computer -Force'
    )

    foreach ($needle in $required) {
        if (-not $source.Contains($needle)) {
            throw "Self-test missing required script fragment: $needle"
        }
    }

    'SELFTEST: PASS'
    exit 0
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Start-Process -FilePath $PowerShellExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

try {
    $timeoutText = & "$env:SystemRoot\System32\chkntfs.exe" /t 2>&1 | Out-String
    if ($timeoutText -match '(\d+)') {
        Set-Content -LiteralPath $TimeoutFile -Value $Matches[1] -NoNewline -Encoding ASCII
        & "$env:SystemRoot\System32\chkntfs.exe" /t:0 | Out-Null
    }
} catch {
    Add-Content -LiteralPath $InstallLog -Value ("{0} failed to capture/set AUTOCHK timeout: {1}" -f (Get-Date -Format o), $_.Exception.Message) -Encoding UTF8
}

$RuntimeCode = @'
$ErrorActionPreference = 'Stop'

$TaskName = '3xfixc-chkdsk3'
$InstallDir = 'C:\ProgramData\3xfixc-chkdsk3'
$StateFile = Join-Path $InstallDir 'pass.txt'
$RunLog = Join-Path $InstallDir 'run.log'
$TimeoutFile = Join-Path $InstallDir 'autochk_timeout.txt'

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

function Write-RunLog([string]$Message) {
    Add-Content -LiteralPath $RunLog -Value ("{0} {1}" -f (Get-Date -Format o), $Message) -Encoding UTF8
}

function Remove-ChkdskRunner {
    Write-RunLog 'pass count reached 3; restoring AUTOCHK timeout and removing scheduled task/helper files'

    try {
        if (Test-Path -LiteralPath $TimeoutFile) {
            $oldTimeout = (Get-Content -LiteralPath $TimeoutFile -Raw).Trim()
            if ($oldTimeout -match '^\d+$') {
                & "$env:SystemRoot\System32\chkntfs.exe" "/t:$oldTimeout" | Out-Null
            }
        }
    } catch {
        try { Write-RunLog ("AUTOCHK timeout restore failed: " + $_.Exception.Message) } catch {}
    }

    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { schtasks.exe /Delete /TN $TaskName /F | Out-Null } catch {}

    $cleanup = "/d /c timeout /t 5 /nobreak >nul & rmdir /s /q `"$InstallDir`""
    Start-Process -WindowStyle Hidden -FilePath "$env:ComSpec" -ArgumentList $cleanup
}

try {
    $count = 0
    if (Test-Path -LiteralPath $StateFile) {
        $raw = (Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop).Trim()
        if ($raw) {
            if ($raw -notmatch '^\d+$') {
                Write-RunLog "invalid pass state '$raw'; cleaning up to avoid an unsafe reboot loop"
                Remove-ChkdskRunner
                exit 1
            }
            $count = [int]$raw
        }
    }

    if ($count -ge 3) {
        Remove-ChkdskRunner
        exit 0
    }

    $pass = $count + 1
    Set-Content -LiteralPath $StateFile -Value $pass -NoNewline -Encoding ASCII
    Write-RunLog "scheduling chkdsk pass $pass of 3"

    $chkdsk = "$env:SystemRoot\System32\chkdsk.exe"
    $command = "echo y | `"$chkdsk`" C: /f /r /x /b"
    $output = & "$env:SystemRoot\System32\cmd.exe" /d /c $command 2>&1
    Add-Content -LiteralPath $RunLog -Value ($output | Out-String) -Encoding UTF8

    Write-RunLog "rebooting for chkdsk pass $pass of 3"
    try {
        Restart-Computer -Force -ErrorAction Stop
    } catch {
        shutdown.exe /r /f /t 10 /c "3xfixc chkdsk pass $pass of 3" | Out-Null
    }
} catch {
    try { Write-RunLog ("ERROR: " + $_.Exception.Message) } catch {}
    exit 1
}
'@

Set-Content -LiteralPath $RuntimeScript -Value $RuntimeCode -Encoding UTF8
Set-Content -LiteralPath $StateFile -Value '0' -NoNewline -Encoding ASCII

$action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RuntimeScript`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Runs chkdsk C: /f /r /x /b for exactly three boot cycles, then removes itself.' `
    -Force | Out-Null

Add-Content -LiteralPath $InstallLog -Value ("{0} installed scheduled task and starting pass 1" -f (Get-Date -Format o)) -Encoding UTF8

& $RuntimeScript
