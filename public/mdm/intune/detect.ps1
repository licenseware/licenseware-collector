<#
.SYNOPSIS
    Intune remediation, detection half: is the collector service stopped under
    a 0.17.0 or newer binary?

.DESCRIPTION
    Agents up to 0.16.0 update themselves by stopping their own Windows
    service and starting it again from inside it. The second half never runs,
    so a host that took the 0.17.0 update has the new exe on disk and a
    STOPPED service until its next boot. This detects exactly that state and
    nothing else, so remediate.ps1 can start the service.

    Exit 1 (not compliant, run remediate.ps1): the service is installed,
    Stopped, not Disabled, and the exe it runs reports File Version >= 0.17.0.
    Exit 0 (compliant): anything else, including a collector that is not
    installed, running, deliberately Disabled, or still on an older exe (an old
    exe that is stopped is not this problem, so it is left alone).
    A check that fails (an unreachable service manager, an unreadable exe)
    exits 0 and says why on stdout: Intune runs the remediation on ANY
    non-zero detection exit, and a check that cannot decide must not start
    anything. remediate.ps1 applies the same gate again before it acts.

    Runs as SYSTEM (Intune default), PowerShell 5.1, 64-bit or 32-bit. One line
    of output, which Intune shows in the device report. Changes nothing.
#>

$ErrorActionPreference = 'Stop'

$ServiceName = 'licenseware-collector'
$FixedFrom = New-Object System.Version 0, 17, 0, 0
$DefaultExe = "$env:ProgramData\Licenseware\bin\LicensewareCollector.exe"

# The exe the service really runs: older layouts keep it elsewhere. The SCM
# quotes the path only when it holds a space.
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
        'collector service not installed'
        exit 0
    }
    if ($svc.Status -ne 'Stopped') {
        "collector service is $($svc.Status)"
        exit 0
    }
    if ($svc.StartType -eq 'Disabled') {
        'collector service is stopped and Disabled: left alone'
        exit 0
    }

    $exe = Get-ServiceExe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        "collector service is stopped, exe not found: $exe"
        exit 0
    }
    $info = (Get-Item -LiteralPath $exe).VersionInfo
    $version = New-Object System.Version $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
    if ($version -lt $FixedFrom) {
        "collector service is stopped on $version (before $FixedFrom): left alone"
        exit 0
    }

    "collector service is stopped under $version"
    exit 1
}
catch {
    "detection failed, nothing to remediate: $($_.Exception.Message)"
    exit 0
}
