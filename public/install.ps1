param(
    [string]$InstallPath = "$env:ProgramFiles\LicensewareCollector"
)

$ErrorActionPreference = "Stop"

$Repo = "licenseware/collector"
$BinaryName = "LicensewareCollector.exe"
$CdnBaseUrl = "https://cdn.licenseware-collector.com"

function Get-LatestRelease {
    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Method Get
        return $response.tag_name
    }
    catch {
        Write-Error "Failed to get latest release: $_"
        exit 1
    }
}

function Download-FromGcs {
    param([string]$Version)

    $url = "$CdnBaseUrl/$BinaryName"
    $tempFile = Join-Path $env:TEMP $BinaryName

    Write-Host "Attempting to download from CDN: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing
        return $tempFile
    }
    catch {
        Write-Host "CDN download failed: $_"
        return $null
    }
}

function Download-FromGitHub {
    param([string]$Version)

    $url = "https://github.com/$Repo/releases/download/$Version/$BinaryName"
    $tempFile = Join-Path $env:TEMP $BinaryName

    Write-Host "Downloading from GitHub: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing
        return $tempFile
    }
    catch {
        Write-Error "GitHub download failed: $_"
        exit 1
    }
}

function Verify-Signature {
    param([string]$FilePath)

    Write-Host "Verifying signature..."
    $sig = Get-AuthenticodeSignature -FilePath $FilePath

    if ($sig.Status -eq 'Valid') {
        Write-Host "✓ Signature verified successfully"
        return $true
    }
    else {
        Write-Warning "Signature verification failed: $($sig.Status)"
        $response = Read-Host "Continue anyway? (y/N)"
        return ($response -eq 'y' -or $response -eq 'Y')
    }
}

function Install-Binary {
    param([string]$SourcePath)

    if (-not (Test-Path $InstallPath)) {
        Write-Host "Creating installation directory: $InstallPath"
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }

    $destination = Join-Path $InstallPath $BinaryName
    Write-Host "Installing to: $destination"
    Copy-Item -Path $SourcePath -Destination $destination -Force

    $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($currentPath -notlike "*$InstallPath*") {
        Write-Host "Adding to system PATH..."
        [Environment]::SetEnvironmentVariable(
            "Path",
            "$currentPath;$InstallPath",
            "Machine"
        )
        $env:Path = "$env:Path;$InstallPath"
    }
}

function Main {
    Write-Host "Licenseware Collector Installer"
    Write-Host "================================"
    Write-Host ""

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning "This script should be run as Administrator for proper installation"
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -ne 'y' -and $response -ne 'Y') {
            exit 1
        }
    }

    $version = Get-LatestRelease
    Write-Host "Latest version: $version"
    Write-Host ""

    $downloadedFile = Download-FromGcs -Version $version
    if (-not $downloadedFile) {
        Write-Host "Trying GitHub..."
        $downloadedFile = Download-FromGitHub -Version $version
    }

    if (-not (Verify-Signature -FilePath $downloadedFile)) {
        Remove-Item $downloadedFile -Force
        exit 1
    }

    Install-Binary -SourcePath $downloadedFile
    Remove-Item $downloadedFile -Force

    Write-Host ""
    Write-Host "✓ Installation complete!"
    Write-Host "Run 'LicensewareCollector --version' to verify the installation"
    Write-Host ""
    Write-Host "Note: You may need to restart your terminal for PATH changes to take effect"
}

Main
