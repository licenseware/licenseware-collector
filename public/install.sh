#!/bin/bash

set -euo pipefail

CDN_BASE_URL="https://cdn.licenseware-collector.com"
LOG_FILE="${HOME}/.licenseware-collector/install.log"
INSTALL_DIR="${HOME}/.licenseware-collector/bin"
TEMP_DIR=""
OS_TYPE=""
ARCH_TYPE=""

function initializeLogging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  logMessage "========== Licenseware Collector Installation Started =========="
  logMessage "Timestamp: $(date)"
  logMessage "User: $(whoami)"
  logMessage "Shell: $SHELL"
}

function logMessage() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local message="[$timestamp] $1"
  echo "$message" | tee -a "$LOG_FILE"
}

function logError() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local message="[$timestamp] ERROR: $1"
  echo "$message" | tee -a "$LOG_FILE" >&2
}

function cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    logMessage "Cleaning up temporary directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}

function trapExit() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    logError "Installation failed with exit code $exit_code"
  fi
  cleanup
  exit $exit_code
}

trap trapExit EXIT

function checkRequiredCommand() {
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    logError "Required command not found: $cmd"
    return 1
  fi
  logMessage "✓ Found required command: $cmd ($(command -v "$cmd"))"
  return 0
}

function validateRequiredTools() {
  logMessage "Validating required tools..."
  local required_tools=("curl" "tar" "sha256sum" "mkdir" "rm")

  for tool in "${required_tools[@]}"; do
    checkRequiredCommand "$tool" || {
      logError "Missing required tool: $tool"
      exit 1
    }
  done
  logMessage "✓ All required tools validated"
}

function detectSystem() {
  logMessage "Detecting operating system and architecture..."

  case "$(uname -s)" in
    Linux*)
      OS_TYPE="linux"
      ;;
    Darwin*)
      OS_TYPE="darwin"
      ;;
    *)
      logError "Unsupported operating system: $(uname -s)"
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64)
      ARCH_TYPE="amd64"
      ;;
    arm64|aarch64)
      ARCH_TYPE="arm64"
      ;;
    armv7l|armv6l)
      ARCH_TYPE="arm"
      ;;
    *)
      logError "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac

  logMessage "Detected OS: $OS_TYPE, Architecture: $ARCH_TYPE"
}

function createTempDir() {
  TEMP_DIR=$(mktemp -d)
  logMessage "Created temporary directory: $TEMP_DIR"
}

function downloadChecksums() {
  logMessage "Downloading checksums from CDN..."
  local checksums_url="${CDN_BASE_URL}/checksums.txt"

  if ! curl -fsSL --max-time 30 --retry 3 --retry-delay 2 "$checksums_url" -o "$TEMP_DIR/checksums.txt"; then
    logError "Failed to download checksums from $checksums_url"
    return 1
  fi

  logMessage "✓ Checksums downloaded successfully"
}

function downloadBinary() {
  local filename=$1
  local url="${CDN_BASE_URL}/${filename}"
  local filepath="$TEMP_DIR/$filename"

  logMessage "Downloading $filename from $url..."

  if ! curl -fsSL --max-time 300 --retry 3 --retry-delay 5 "$url" -o "$filepath"; then
    logError "Failed to download $filename"
    return 1
  fi

  if [ ! -f "$filepath" ]; then
    logError "Downloaded file not found: $filepath"
    return 1
  fi

  logMessage "✓ Downloaded $filename ($(du -h "$filepath" | cut -f1))"
}

function validateChecksum() {
  local filename=$1
  local filepath="$TEMP_DIR/$filename"

  logMessage "Validating checksum for $filename..."

  if ! grep -q "$filename" "$TEMP_DIR/checksums.txt"; then
    logError "Checksum entry not found for $filename"
    return 1
  fi

  if ! (cd "$TEMP_DIR" && sha256sum -c checksums.txt 2>&1 | grep -q "$filename"); then
    logError "Checksum validation failed for $filename"
    return 1
  fi

  logMessage "✓ Checksum validated for $filename"
}

function extractBinary() {
  local filename=$1
  local filepath="$TEMP_DIR/$filename"

  logMessage "Extracting $filename..."

  if [ "${filename##*.}" = "gz" ]; then
    if ! tar -xzf "$filepath" -C "$TEMP_DIR"; then
      logError "Failed to extract $filename"
      return 1
    fi
  else
    logError "Unsupported file format: $filename"
    return 1
  fi

  logMessage "✓ Extracted $filename"
}

function installBinary() {
  local filename=$1
  local binary_name="${filename%%_*}"
  local extracted_binary="$TEMP_DIR/$binary_name"

  logMessage "Installing $binary_name to $INSTALL_DIR..."

  mkdir -p "$INSTALL_DIR"

  if [ ! -f "$extracted_binary" ]; then
    logError "Extracted binary not found: $extracted_binary"
    return 1
  fi

  if ! cp "$extracted_binary" "$INSTALL_DIR/$binary_name"; then
    logError "Failed to copy binary to $INSTALL_DIR"
    return 1
  fi

  if ! chmod +x "$INSTALL_DIR/$binary_name"; then
    logError "Failed to set executable permission"
    return 1
  fi

  logMessage "✓ Installed $binary_name to $INSTALL_DIR/$binary_name"
}

function downloadAndInstallBinaries() {
  local blobs=("collector_linux_amd64.tar.gz" "collector_linux_arm64.tar.gz")

  case "$OS_TYPE" in
    linux)
      case "$ARCH_TYPE" in
        amd64)
          blobs=("collector_linux_amd64.tar.gz")
          ;;
        arm64)
          blobs=("collector_linux_arm64.tar.gz")
          ;;
        *)
          logError "No binary available for Linux $ARCH_TYPE"
          return 1
          ;;
      esac
      ;;
    darwin)
      blobs=("LicensewareCollector-macOS.zip")
      ;;
    *)
      logError "Unsupported operating system for binary download"
      return 1
      ;;
  esac

  downloadChecksums || return 1

  for blob in "${blobs[@]}"; do
    downloadBinary "$blob" || return 1
    validateChecksum "$blob" || return 1
    extractBinary "$blob" || return 1
    installBinary "$blob" || return 1
  done

  logMessage "✓ All binaries downloaded and installed successfully"
}

function updatePATH() {
  logMessage "Updating PATH configuration..."

  local shell_rc=""
  local current_shell=$(basename "$SHELL")

  case "$current_shell" in
    zsh)
      shell_rc="${HOME}/.zshrc"
      ;;
    bash)
      shell_rc="${HOME}/.bashrc"
      ;;
    ksh)
      shell_rc="${HOME}/.kshrc"
      ;;
    fish)
      shell_rc="${HOME}/.config/fish/config.fish"
      ;;
    *)
      shell_rc="${HOME}/.bashrc"
      logMessage "Unknown shell $current_shell, defaulting to .bashrc"
      ;;
  esac

  if [ ! -f "$shell_rc" ]; then
    logMessage "Shell config file not found at $shell_rc, creating it"
    touch "$shell_rc"
  fi

  if ! grep -q "export PATH=\"\$PATH:$INSTALL_DIR\"" "$shell_rc" && ! grep -q "set -gx PATH \$PATH $INSTALL_DIR" "$shell_rc"; then
    if [ "$current_shell" = "fish" ]; then
      echo "" >> "$shell_rc"
      echo "set -gx PATH \$PATH $INSTALL_DIR" >> "$shell_rc"
    else
      echo "" >> "$shell_rc"
      echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$shell_rc"
    fi
    logMessage "✓ Added $INSTALL_DIR to PATH in $shell_rc"
    logMessage "Please run: source $shell_rc"
  else
    logMessage "✓ $INSTALL_DIR already in PATH"
  fi
}

function main() {
  initializeLogging
  validateRequiredTools
  detectSystem
  createTempDir
  downloadAndInstallBinaries
  updatePATH
  logMessage "========== Installation Completed Successfully =========="
  logMessage "Binaries installed to: $INSTALL_DIR"
  logMessage "Log file: $LOG_FILE"
}

main "$@"
