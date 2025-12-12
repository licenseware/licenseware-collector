#Requires -Version 5.1

<#
.SYNOPSIS
    Installs Licenseware Collector on Windows.
.PARAMETER Token
    Registration token for the collector.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [Alias("t")]
    [string]$Token = $env:TOKEN
)

$ErrorActionPreference = "Stop"

$CDN_BASE_URL = "https://cdn.licenseware-collector.com"
$INSTALL_DIR = Join-Path $env:USERPROFILE ".licenseware-collector\bin"
$LOG_DIR = Join-Path $env:USERPROFILE ".licenseware-collector"
$LOG_FILE = Join-Path $LOG_DIR "install.log"
$BINARY_NAME = "LicensewareCollector.exe"
$DOWNLOAD_FILENAME = "LicensewareCollector.exe"
$script:TEMP_DIR = $null
$CLEANUP_ON_FAILURE = if ($env:CLEANUP_ON_FAILURE -eq "false") { $false } else { $true }

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $prefix = if ($Level -eq "ERROR") { "ERROR: " } else { "" }
    $logEntry = "[$timestamp] $prefix$Message"

    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }

    Add-Content -Path $LOG_FILE -Value $logEntry

    if ($Level -eq "ERROR") {
        Write-Error $logEntry
    } else {
        Write-Host $logEntry
    }
}

function Initialize-Logging {
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }

    Write-Log "========== Licenseware Collector Installation Started =========="
    Write-Log "Timestamp: $(Get-Date)"
    Write-Log "User: $env:USERNAME"
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
}

function Remove-TempDir {
    if ($script:TEMP_DIR -and (Test-Path $script:TEMP_DIR)) {
        Write-Log "Cleaning up temporary directory: $script:TEMP_DIR"
        Remove-Item -Path $script:TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-Architecture {
    Write-Log "Validating system architecture..."

    $arch = [System.Environment]::Is64BitOperatingSystem
    if (-not $arch) {
        Write-Log "Unsupported architecture: 32-bit systems are not supported" -Level ERROR
        throw "Only 64-bit Windows (amd64) is supported"
    }

    $procArch = $env:PROCESSOR_ARCHITECTURE
    if ($procArch -ne "AMD64") {
        Write-Log "Unsupported processor architecture: $procArch" -Level ERROR
        throw "Only AMD64 architecture is supported"
    }

    Write-Log "[OK] Architecture validated: Windows amd64"
}

function New-TempDirectory {
    $script:TEMP_DIR = Join-Path $env:TEMP "licenseware-install-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TEMP_DIR -Force | Out-Null
    Write-Log "Created temporary directory: $script:TEMP_DIR"
}

function Get-Checksums {
    Write-Log "Downloading checksums from CDN..."
    $checksumsUrl = "$CDN_BASE_URL/checksums.txt"
    $checksumsPath = Join-Path $script:TEMP_DIR "checksums.txt"

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing -TimeoutSec 30
        Write-Log "[OK] Checksums downloaded successfully"
        return $checksumsPath
    } catch {
        Write-Log "Failed to download checksums from $checksumsUrl : $_" -Level ERROR
        throw
    }
}

function Get-Binary {
    Write-Log "Downloading $DOWNLOAD_FILENAME from CDN..."
    $binaryUrl = "$CDN_BASE_URL/$DOWNLOAD_FILENAME"
    $binaryPath = Join-Path $script:TEMP_DIR $DOWNLOAD_FILENAME

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $binaryUrl -OutFile $binaryPath -UseBasicParsing -TimeoutSec 300

        if (-not (Test-Path $binaryPath)) {
            throw "Downloaded file not found: $binaryPath"
        }

        $fileSize = (Get-Item $binaryPath).Length / 1MB
        $fileSizeRounded = [math]::Round($fileSize, 2)
        Write-Log "[OK] Downloaded $DOWNLOAD_FILENAME ($fileSizeRounded MB)"
        return $binaryPath
    } catch {
        Write-Log "Failed to download $DOWNLOAD_FILENAME : $_" -Level ERROR
        throw
    }
}

function Test-Checksum {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$ChecksumsPath
    )

    $filename = Split-Path $FilePath -Leaf
    Write-Log "Validating checksum for $filename..."

    if (-not (Test-Path $ChecksumsPath)) {
        Write-Log "Checksums file not found, skipping validation"
        return
    }

    $checksumLine = Get-Content $ChecksumsPath | Where-Object { $_ -match $filename }

    if (-not $checksumLine) {
        Write-Log "Checksum entry not found for $filename, skipping validation"
        return
    }

    $expectedChecksum = ($checksumLine -split '\s+')[0]
    $actualChecksum = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()

    if ($expectedChecksum.ToLower() -ne $actualChecksum) {
        Write-Log "Checksum validation failed for $filename" -Level ERROR
        Write-Log "Expected: $expectedChecksum" -Level ERROR
        Write-Log "Actual: $actualChecksum" -Level ERROR
        throw "Checksum mismatch"
    }

    Write-Log "[OK] Checksum validated for $filename"
}

function Install-Binary {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    Write-Log "Installing $BINARY_NAME to $INSTALL_DIR..."

    if (-not (Test-Path $INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    }

    $destinationPath = Join-Path $INSTALL_DIR $BINARY_NAME

    Copy-Item -Path $SourcePath -Destination $destinationPath -Force

    if (-not (Test-Path $destinationPath)) {
        Write-Log "Failed to copy binary to $INSTALL_DIR" -Level ERROR
        throw "Installation failed"
    }

    Write-Log "[OK] Installed $BINARY_NAME to $destinationPath"
}

function Update-Path {
    Write-Log "Updating PATH configuration..."

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    if ($currentPath -split ';' | Where-Object { $_ -eq $INSTALL_DIR }) {
        Write-Log "[OK] $INSTALL_DIR already in PATH"
        return
    }

    $newPath = if ($currentPath) { "$currentPath;$INSTALL_DIR" } else { $INSTALL_DIR }
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

    # Update current session
    $env:PATH = "$env:PATH;$INSTALL_DIR"

    Write-Log "[OK] Added $INSTALL_DIR to user PATH"
    Write-Log "Note: Restart your terminal for PATH changes to take effect in new sessions"
}

function Register-Collector {
    $binaryPath = Join-Path $INSTALL_DIR $BINARY_NAME

    Write-Log "Registering collector..."

    if (-not (Test-Path $binaryPath)) {
        Write-Log "Binary not found at $binaryPath" -Level ERROR
        throw "Registration failed: binary not found"
    }

    & $binaryPath

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Registration failed with exit code $LASTEXITCODE" -Level ERROR
        throw "Registration failed"
    }

    Write-Log "[OK] Collector registered successfully"
}

function Main {
    try {
        Initialize-Logging
        Test-Architecture
        New-TempDirectory

        $checksumsPath = Get-Checksums
        $binaryPath = Get-Binary
        Test-Checksum -FilePath $binaryPath -ChecksumsPath $checksumsPath
        Install-Binary -SourcePath $binaryPath
        Update-Path
        Register-Collector

        Write-Log "========== Installation Completed Successfully =========="
        Write-Log "Binary installed to: $INSTALL_DIR\$BINARY_NAME"
        Write-Log "Log file: $LOG_FILE"

        Remove-TempDir
    } catch {
        Write-Log "Installation failed: $_" -Level ERROR
        if ($CLEANUP_ON_FAILURE) {
            Remove-TempDir
        } else {
            Write-Log "Temporary directory preserved for debugging: $script:TEMP_DIR"
        }
        exit 1
    }
}

Main
