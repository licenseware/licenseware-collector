$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

$CDN_BASE_URL = "https://cdn.licenseware-collector.com"
$INSTALL_DIR = "$env:LOCALAPPDATA\LicensewareCollector\bin"
$LOG_DIR = "$env:LOCALAPPDATA\LicensewareCollector\logs"
$LOG_FILE = Join-Path $LOG_DIR "install.log"
$TEMP_DIR = ""

function Initialize-Logging {
  if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
  }

  Write-Log "========== Licenseware Collector Installation Started =========="
  Write-Log "Timestamp: $(Get-Date)"
  Write-Log "User: $env:USERNAME"
  Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
}

function Write-Log {
  param(
    [string]$Message
  )

  var timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  var logMessage = "[$timestamp] $Message"

  Add-Content -Path $LOG_FILE -Value $logMessage
  Write-Host $logMessage
}

function Write-LogError {
  param(
    [string]$Message
  )

  var timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  var logMessage = "[$timestamp] ERROR: $Message"

  Add-Content -Path $LOG_FILE -Value $logMessage
  Write-Host $logMessage -ForegroundColor Red
}

function Cleanup {
  if ($TEMP_DIR -and (Test-Path $TEMP_DIR)) {
    Write-Log "Cleaning up temporary directory: $TEMP_DIR"
    Remove-Item -Path $TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
  }
}

trap {
  Write-LogError "Installation failed: $_"
  Cleanup
  exit 1
}

function Check-RequiredCommand {
  param(
    [string]$Command
  )

  var resolvedCmd = Get-Command $Command -ErrorAction SilentlyContinue

  if (-not $resolvedCmd) {
    Write-LogError "Required command not found: $Command"
    return $false
  }

  Write-Log "✓ Found required command: $Command ($($resolvedCmd.Source))"
  return $true
}

function Validate-RequiredTools {
  Write-Log "Validating required tools..."

  var requiredTools = @("curl", "Expand-Archive", "Get-FileHash")

  foreach ($tool in $requiredTools) {
    if ($tool -eq "Expand-Archive" -or $tool -eq "Get-FileHash") {
      if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-LogError "Missing required PowerShell cmdlet: $tool"
        exit 1
      }
    } else {
      if (-not (Check-RequiredCommand $tool)) {
        Write-LogError "Missing required command: $tool"
        exit 1
      }
    }
  }

  Write-Log "✓ All required tools validated"
}

function Detect-System {
  Write-Log "Detecting system architecture..."

  var arch = $env:PROCESSOR_ARCHITECTURE

  if ($arch -eq "AMD64") {
    var detectedArch = "amd64"
  } elseif ($arch -eq "ARM64") {
    var detectedArch = "arm64"
  } else {
    Write-LogError "Unsupported architecture: $arch"
    exit 1
  }

  Write-Log "Detected Architecture: $detectedArch"
  return $detectedArch
}

function Create-TempDir {
  $TEMP_DIR = New-Item -ItemType Directory -Path "$env:TEMP\LicensewareCollector_$(Get-Random)" -Force
  Write-Log "Created temporary directory: $TEMP_DIR"
}

function Download-Checksums {
  Write-Log "Downloading checksums from CDN..."

  var checksumsUrl = "$CDN_BASE_URL/checksums.txt"
  var checksumPath = Join-Path $TEMP_DIR "checksums.txt"

  try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumPath -TimeoutSec 30 -MaximumRetryCount 3 -RetryIntervalSec 2
    Write-Log "✓ Checksums downloaded successfully"
  } catch {
    Write-LogError "Failed to download checksums from $checksumsUrl : $_"
    return $false
  }
}

function Download-Binary {
  param(
    [string]$Filename
  )

  var url = "$CDN_BASE_URL/$Filename"
  var filepath = Join-Path $TEMP_DIR $Filename

  Write-Log "Downloading $Filename from $url..."

  try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $filepath -TimeoutSec 300 -MaximumRetryCount 3 -RetryIntervalSec 5

    if (-not (Test-Path $filepath)) {
      Write-LogError "Downloaded file not found: $filepath"
      return $false
    }

    var fileSize = (Get-Item $filepath).Length / 1MB
    Write-Log "✓ Downloaded $Filename ($('{0:F2}' -f $fileSize) MB)"
    return $true
  } catch {
    Write-LogError "Failed to download $Filename : $_"
    return $false
  }
}

function Validate-Checksum {
  param(
    [string]$Filename
  )

  var filepath = Join-Path $TEMP_DIR $Filename
  var checksumFile = Join-Path $TEMP_DIR "checksums.txt"

  Write-Log "Validating checksum for $Filename..."

  try {
    var checksumContent = Get-Content $checksumFile | Where-Object { $_ -match $Filename }

    if (-not $checksumContent) {
      Write-LogError "Checksum entry not found for $Filename"
      return $false
    }

    var expectedHash = ($checksumContent -split " ")[0]
    var actualHash = (Get-FileHash -Path $filepath -Algorithm SHA256).Hash.ToLower()

    if ($expectedHash.ToLower() -ne $actualHash) {
      Write-LogError "Checksum mismatch for $Filename"
      Write-LogError "Expected: $expectedHash"
      Write-LogError "Actual: $actualHash"
      return $false
    }

    Write-Log "✓ Checksum validated for $Filename"
    return $true
  } catch {
    Write-LogError "Checksum validation failed for $Filename : $_"
    return $false
  }
}

function Extract-Binary {
  param(
    [string]$Filename
  )

  var filepath = Join-Path $TEMP_DIR $Filename

  Write-Log "Extracting $Filename..."

  try {
    if ($Filename -like "*.zip") {
      Expand-Archive -Path $filepath -DestinationPath $TEMP_DIR -Force
    } else {
      Write-LogError "Unsupported file format: $Filename"
      return $false
    }

    Write-Log "✓ Extracted $Filename"
    return $true
  } catch {
    Write-LogError "Failed to extract $Filename : $_"
    return $false
  }
}

function Install-Binary {
  param(
    [string]$Filename
  )

  var binaryName = $Filename -replace "_.*", ""
  var binaryName = $binaryName -replace "\.zip", ".exe"
  var extractedBinary = Join-Path $TEMP_DIR $binaryName

  Write-Log "Installing $binaryName to $INSTALL_DIR..."

  if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
  }

  if (-not (Test-Path $extractedBinary)) {
    Write-LogError "Extracted binary not found: $extractedBinary"
    return $false
  }

  try {
    Copy-Item -Path $extractedBinary -Destination "$INSTALL_DIR\$binaryName" -Force
    Write-Log "✓ Installed $binaryName to $INSTALL_DIR\$binaryName"
    return $true
  } catch {
    Write-LogError "Failed to install binary : $_"
    return $false
  }
}

function Download-AndInstall-Binaries {
  var arch = Detect-System
  var blobs = @()

  if ($arch -eq "amd64") {
    $blobs = @("LicensewareCollector.exe")
  } else {
    Write-LogError "No binary available for Windows $arch"
    return $false
  }

  if (-not (Download-Checksums)) {
    return $false
  }

  foreach ($blob in $blobs) {
    if (-not (Download-Binary $blob)) {
      return $false
    }

    if (-not (Validate-Checksum $blob)) {
      return $false
    }

    if (-not (Extract-Binary $blob)) {
      return $false
    }

    if (-not (Install-Binary $blob)) {
      return $false
    }
  }

  Write-Log "✓ All binaries downloaded and installed successfully"
  return $true
}

function Update-PATH {
  Write-Log "Updating PATH configuration..."

  var userPath = [Environment]::GetEnvironmentVariable("Path", "User")

  if ($userPath -notlike "*$INSTALL_DIR*") {
    var newPath = "$userPath;$INSTALL_DIR"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Log "✓ Added $INSTALL_DIR to user PATH"
    Write-Log "Please restart your terminal to use the new PATH"
  } else {
    Write-Log "✓ $INSTALL_DIR already in PATH"
  }
}

function Main {
  Initialize-Logging
  Validate-RequiredTools
  Create-TempDir

  if (Download-AndInstall-Binaries) {
    Update-PATH
    Write-Log "========== Installation Completed Successfully =========="
    Write-Log "Binaries installed to: $INSTALL_DIR"
    Write-Log "Log file: $LOG_FILE"
    Cleanup
    exit 0
  } else {
    Write-LogError "Installation failed"
    Cleanup
    exit 1
  }
}

Main
