<#
.SYNOPSIS
    Intune remediation, remediation half: start the collector service that a
    self-update left stopped.

.DESCRIPTION
    Pair of detect.ps1. Intune runs it on any non-zero detection exit, so it
    checks the same gate again before it touches anything: the service is
    installed, Stopped, not Disabled, and the exe it runs reports File Version
    >= 0.17.0.0. Only then it starts the service and waits for it to report
    Running. It never installs, uninstalls, reconfigures or restarts anything:
    a service that is already running, missing, Disabled, or stopped under an
    older or unreadable exe is left as it is.

    Exit 0 when the service is Running afterwards (or was never this script's
    to start), exit 1 when it could not be started in time or the gate could
    not be checked. One line of output, which Intune shows in the device
    report.

    Runs as SYSTEM (Intune default), PowerShell 5.1, 64-bit or 32-bit.
#>

$ErrorActionPreference = 'Stop'

$ServiceName = 'licenseware-collector'
$FixedFrom = New-Object System.Version 0, 17, 0, 0
$DefaultExe = "$env:ProgramData\Licenseware\bin\LicensewareCollector.exe"
$StartTimeout = [TimeSpan]::FromSeconds(60)
$StopTimeout = [TimeSpan]::FromSeconds(30)

# Same as detect.ps1: the exe the service really runs. The SCM quotes the path
# only when it holds a space.
function Get-ServiceExe {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $cmd = (Get-ItemProperty -Path $key -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if ($cmd -and $cmd -match '^\s*(?:"([^"]+)"|(.+?\.exe))(?:\s|$)') {
        if ($Matches[1]) { return $Matches[1] }
        return $Matches[2]
    }
    return $DefaultExe
}

try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        'collector service not installed: nothing to start'
        exit 0
    }
    if ($svc.StartType -eq 'Disabled') {
        'collector service is Disabled: left alone'
        exit 0
    }
    if ($svc.Status -eq 'Running') {
        'collector service already running'
        exit 0
    }

    $exe = Get-ServiceExe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        "collector exe not found, so its version cannot be checked: $exe (left alone)"
        exit 0
    }
    $info = (Get-Item -LiteralPath $exe).VersionInfo
    $version = New-Object System.Version $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
    if ($version -lt $FixedFrom) {
        "collector exe is $version (before $FixedFrom): left alone"
        exit 0
    }

    # A service that is still stopping cannot be started yet.
    if ($svc.Status -eq 'StopPending') {
        $svc.WaitForStatus('Stopped', $StopTimeout)
        $svc.Refresh()
    }
    if ($svc.Status -eq 'Stopped') {
        Start-Service -Name $ServiceName
    }
    $svc.WaitForStatus('Running', $StartTimeout)
    $svc.Refresh()

    "collector service started, now $($svc.Status)"
    exit 0
}
catch {
    "could not start the collector service: $($_.Exception.Message)"
    exit 1
}
