#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [Alias("t")]
    [string]$Token = $env:TOKEN
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up Invoke-WebRequest significantly

$script:CDN_BASE_URL = "https://cdn.licenseware-collector.com"
$script:INSTALL_DIR = Join-Path $env:USERPROFILE ".licenseware-collector\bin"
$script:LOG_DIR = Join-Path $env:USERPROFILE ".licenseware-collector"
$script:LOG_FILE = Join-Path $script:LOG_DIR "install.log"
$script:TEMP_DIR = $null
$script:OS_TYPE = $null
$script:ARCH_TYPE = $null
$script:CLEANUP_ON_FAILURE = if ($env:CLEANUP_ON_FAILURE -eq "false") { $false } else { $true }

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $prefix = if ($Level -eq "ERROR") { "ERROR: " } else { "" }
    $logMessage = "[$timestamp] $prefix$Message"

    if ($Level -eq "ERROR") {
        Write-Host $logMessage -ForegroundColor Red
    } else {
        Write-Host $logMessage
    }

    Add-Content -Path $script:LOG_FILE -Value $logMessage -ErrorAction SilentlyContinue
}

function Initialize-Logging {
    if (-not (Test-Path $script:LOG_DIR)) {
        New-Item -ItemType Directory -Path $script:LOG_DIR -Force | Out-Null
    }

    if (-not (Test-Path $script:LOG_FILE)) {
        New-Item -ItemType File -Path $script:LOG_FILE -Force | Out-Null
    }

    Write-Log "========== Licenseware Collector Installation Started =========="
    Write-Log "Timestamp: $(Get-Date)"
    Write-Log "User: $env:USERNAME"
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
}

function Remove-TempDirectory {
    if ($script:TEMP_DIR -and (Test-Path $script:TEMP_DIR)) {
        Write-Log "Cleaning up temporary directory: $script:TEMP_DIR"
        Remove-Item -Path $script:TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-RequiredCommand {
    param([string]$Command)

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Log "Required command not found: $Command" -Level ERROR
        return $false
    }

    Write-Log "✓ Found required command: $Command ($($cmd.Source))"
    return $true
}

function Test-RequiredTools {
    Write-Log "Validating required tools..."

    # PowerShell has most of what we need built-in
    # Check for tar if we need to extract .tar.gz on older Windows
    $tarAvailable = Get-Command tar -ErrorAction SilentlyContinue

    if (-not $tarAvailable -and $script:OS_TYPE -eq "windows") {
        Write-Log "Note: tar not found, will use .NET for extraction if needed"
    }

    Write-Log "✓ All required tools validated"
}

function Get-SystemInfo {
    Write-Log "Detecting operating system and architecture..."

    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $script:OS_TYPE = "windows"
    } else {
        # Fallback for Windows PowerShell 5.1
        if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
            $script:OS_TYPE = "windows"
        } else {
            Write-Log "Unsupported operating system" -Level ERROR
            throw "Unsupported operating system"
        }
    }

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch) {
        "X64" { $script:ARCH_TYPE = "amd64" }
        "Arm64" { $script:ARCH_TYPE = "arm64" }
        "Arm" { $script:ARCH_TYPE = "arm" }
        "X86" { $script:ARCH_TYPE = "386" }
        default {
            # Fallback detection
            if ([Environment]::Is64BitOperatingSystem) {
                $script:ARCH_TYPE = "amd64"
            } else {
                $script:ARCH_TYPE = "386"
            }
        }
    }

    Write-Log "Detected OS: $script:OS_TYPE, Architecture: $script:ARCH_TYPE"
}

function New-TempDirectory {
    $script:TEMP_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "licenseware-install-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:TEMP_DIR -Force | Out-Null
    Write-Log "Created temporary directory: $script:TEMP_DIR"
}

function Get-Checksums {
    Write-Log "Downloading checksums from CDN..."
    $checksumsUrl = "$script:CDN_BASE_URL/checksums.txt"
    $checksumsPath = Join-Path $script:TEMP_DIR "checksums.txt"

    try {
        Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing -TimeoutSec 30
        Write-Log "✓ Checksums downloaded successfully"
    } catch {
        Write-Log "Failed to download checksums from $checksumsUrl`: $_" -Level ERROR
        throw
    }
}

function Get-Binary {
    param([string]$Filename)

    $url = "$script:CDN_BASE_URL/$Filename"
    $filepath = Join-Path $script:TEMP_DIR $Filename

    Write-Log "Downloading $Filename from $url..."

    try {
        Invoke-WebRequest -Uri $url -OutFile $filepath -UseBasicParsing -TimeoutSec 300

        if (-not (Test-Path $filepath)) {
            throw "Downloaded file not found: $filepath"
        }

        $size = (Get-Item $filepath).Length / 1MB
        Write-Log "✓ Downloaded $Filename ($([math]::Round($size, 2)) MB)"
    } catch {
        Write-Log "Failed to download $Filename`: $_" -Level ERROR
        throw
    }
}

function Test-Checksum {
    param([string]$Filename)

    $filepath = Join-Path $script:TEMP_DIR $Filename
    $checksumsPath = Join-Path $script:TEMP_DIR "checksums.txt"

    Write-Log "Validating checksum for $Filename..."

    $checksumContent = Get-Content $checksumsPath -Raw
    if ($checksumContent -notmatch [regex]::Escape($Filename)) {
        Write-Log "Checksum entry not found for $Filename, skipping validation"
        return
    }

    $checksumLine = Get-Content $checksumsPath | Where-Object { $_ -match [regex]::Escape($Filename) } | Select-Object -First 1
    $expectedChecksum = ($checksumLine -split '\s+')[0]

    $actualChecksum = (Get-FileHash -Path $filepath -Algorithm SHA256).Hash.ToLower()

    if ($expectedChecksum.ToLower() -ne $actualChecksum) {
        Write-Log "Checksum validation failed for $Filename" -Level ERROR
        Write-Log "Expected: $expectedChecksum" -Level ERROR
        Write-Log "Actual: $actualChecksum" -Level ERROR
        throw "Checksum validation failed"
    }

    Write-Log "✓ Checksum validated for $Filename"
}

function Expand-Binary {
    param([string]$Filename)

    $filepath = Join-Path $script:TEMP_DIR $Filename

    Write-Log "Extracting $Filename..."

    try {
        if ($Filename -like "*.zip") {
            Expand-Archive -Path $filepath -DestinationPath $script:TEMP_DIR -Force
        } elseif ($Filename -like "*.tar.gz" -or $Filename -like "*.tgz") {
            # Use tar command (available on Windows 10+, Linux, macOS)
            $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
            if ($tarCmd) {
                Push-Location $script:TEMP_DIR
                try {
                    & tar -xzf $filepath
                    if ($LASTEXITCODE -ne 0) {
                        throw "tar extraction failed with exit code $LASTEXITCODE"
                    }
                } finally {
                    Pop-Location
                }
            } else {
                # Fallback: manual .tar.gz extraction using .NET
                $gzipPath = $filepath
                $tarPath = $filepath -replace '\.gz$', ''

                # Decompress gzip
                $gzipStream = [System.IO.File]::OpenRead($gzipPath)
                $tarStream = [System.IO.File]::Create($tarPath)
                $decompressionStream = [System.IO.Compression.GZipStream]::new($gzipStream, [System.IO.Compression.CompressionMode]::Decompress)
                $decompressionStream.CopyTo($tarStream)
                $decompressionStream.Close()
                $tarStream.Close()
                $gzipStream.Close()

                Write-Log "Note: tar command not available, extracted gzip only. Manual tar extraction may be needed." -Level ERROR
                throw "tar command not available for .tar.gz extraction"
            }
        } else {
            throw "Unsupported file format: $Filename"
        }

        Write-Log "✓ Extracted $Filename"
    } catch {
        Write-Log "Failed to extract $Filename`: $_" -Level ERROR
        throw
    }
}

function Install-Binary {
    param([string]$Filename)

    $binaryName = "LicensewareCollector"
    $extractedBinary = Join-Path $script:TEMP_DIR $binaryName

    if ($Filename -eq "LicensewareCollector.exe") {
        $extractedBinary = Join-Path $script:TEMP_DIR "LicensewareCollector.exe"
        $binaryName = "LicensewareCollector.exe"
    } elseif ($script:OS_TYPE -eq "windows") {
        $exePath = Join-Path $script:TEMP_DIR "$binaryName.exe"
        if (Test-Path $exePath) {
            $extractedBinary = $exePath
            $binaryName = "$binaryName.exe"
        }
    }

    Write-Log "Installing $binaryName to $script:INSTALL_DIR..."

    if (-not (Test-Path $script:INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $script:INSTALL_DIR -Force | Out-Null
    }

    if (-not (Test-Path $extractedBinary)) {
        $possibleBinaries = Get-ChildItem -Path $script:TEMP_DIR -Recurse -File |
            Where-Object { $_.Name -match "licenseware|collector" -and $_.Name -notmatch "\.(tar|gz|zip|txt)$" }

        if ($possibleBinaries) {
            $extractedBinary = $possibleBinaries[0].FullName
            $binaryName = $possibleBinaries[0].Name
            Write-Log "Found binary at: $extractedBinary"
        } else {
            Write-Log "Extracted binary not found: $extractedBinary" -Level ERROR
            throw "Binary not found after extraction"
        }
    }

    $destinationPath = Join-Path $script:INSTALL_DIR $(if ($script:OS_TYPE -eq "windows" -and $binaryName -notlike "*.exe") { "$binaryName.exe" } else { $binaryName })

    Copy-Item -Path $extractedBinary -Destination $destinationPath -Force

    # On Unix-like systems, we might need to set execute permission
    if ($script:OS_TYPE -ne "windows" -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod +x $destinationPath
    }

    Write-Log "✓ Installed $binaryName to $destinationPath"
}

function Install-AllBinaries {
    $blobs = @()

    switch ($script:OS_TYPE) {
        "windows" {
            if ($script:ARCH_TYPE -ne "amd64") {
                Write-Log "Windows is only supported on amd64 architecture. Detected: $script:ARCH_TYPE" -Level ERROR
                throw "Unsupported Windows architecture. Only amd64 is supported."
            }
            $blobs = @("LicensewareCollector.exe")
        }
        default {
            Write-Log "Unsupported operating system for binary download" -Level ERROR
            throw "Unsupported OS"
        }
    }

    Get-Checksums

    foreach ($blob in $blobs) {
        Get-Binary -Filename $blob
        Test-Checksum -Filename $blob

        if ($blob -notlike "*.exe") {
            Expand-Binary -Filename $blob
        }

        Install-Binary -Filename $blob
    }

    Write-Log "✓ All binaries downloaded and installed successfully"
}

function Update-PathEnvironment {
    Write-Log "Updating PATH configuration..."

    if ($script:OS_TYPE -eq "windows") {
        $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")

        if ($currentPath -notlike "*$script:INSTALL_DIR*") {
            $newPath = if ($currentPath) { "$currentPath;$script:INSTALL_DIR" } else { $script:INSTALL_DIR }
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            $env:Path = "$env:Path;$script:INSTALL_DIR"
            Write-Log "✓ Added $script:INSTALL_DIR to User PATH"
            Write-Log "Note: You may need to restart your terminal for PATH changes to take effect"
        } else {
            Write-Log "✓ $script:INSTALL_DIR already in PATH"
        }
    } else {
        # On Linux/macOS with PowerShell, update shell config similar to bash script
        $shellRc = switch ($env:SHELL) {
            { $_ -like "*zsh" }  { Join-Path $env:HOME ".zshrc" }
            { $_ -like "*fish" } { Join-Path $env:HOME ".config/fish/config.fish" }
            default              { Join-Path $env:HOME ".bashrc" }
        }

        if (-not (Test-Path $shellRc)) {
            New-Item -ItemType File -Path $shellRc -Force | Out-Null
        }

        $content = Get-Content $shellRc -Raw -ErrorAction SilentlyContinue
        $exportLine = "export PATH=`"`$PATH:$script:INSTALL_DIR`""

        if ($content -notmatch [regex]::Escape($script:INSTALL_DIR)) {
            Add-Content -Path $shellRc -Value "`n$exportLine"
            Write-Log "✓ Added $script:INSTALL_DIR to PATH in $shellRc"
            Write-Log "Please run: source $shellRc"
        } else {
            Write-Log "✓ $script:INSTALL_DIR already in PATH"
        }

        $env:PATH = "$env:PATH`:$script:INSTALL_DIR"
    }
}

function Register-Collector {
    $binaryName = if ($script:OS_TYPE -eq "windows") { "LicensewareCollector.exe" } else { "LicensewareCollector" }
    $binaryPath = Join-Path $script:INSTALL_DIR $binaryName

    Write-Log "Registering collector..."

    if (-not (Test-Path $binaryPath)) {
        Write-Log "Binary not found at $binaryPath" -Level ERROR
        throw "Binary not found"
    }

    if ([string]::IsNullOrWhiteSpace($script:Token)) {
        Write-Log "No token provided, registration failed" -Level ERROR
        throw "Token required for registration"
    }

    try {
        $output = & $binaryPath -t $script:Token register 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Collector registration output: $output" -Level ERROR
            throw "Registration command failed with exit code $LASTEXITCODE"
        }
        Write-Log "✓ Collector registered successfully"
    } catch {
        Write-Log "Failed to register collector: $_" -Level ERROR
        throw
    }
}

function Main {
    $script:Token = $Token  # Capture param in script scope

    try {
        Initialize-Logging

        if ($Token) {
            Write-Log "Token provided via command-line argument"
        }

        Test-RequiredTools
        Get-SystemInfo
        New-TempDirectory
        Install-AllBinaries
        Update-PathEnvironment
        Register-Collector

        Write-Log "========== Installation Completed Successfully =========="
        Write-Log "Binaries installed to: $script:INSTALL_DIR"
        Write-Log "Log file: $script:LOG_FILE"

    } catch {
        Write-Log "Installation failed: $_" -Level ERROR

        if ($script:CLEANUP_ON_FAILURE) {
            Remove-TempDirectory
        } else {
            Write-Log "Temporary directory preserved for debugging: $script:TEMP_DIR"
        }

        exit 1
    } finally {
        if ($script:CLEANUP_ON_FAILURE -and $LASTEXITCODE -eq 0) {
            Remove-TempDirectory
        }
    }
}

Main
