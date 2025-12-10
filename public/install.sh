#!/bin/bash

set -e

REPO="licenseware/collector"
BINARY_NAME="collector"
INSTALL_DIR="/usr/local/bin"
CDN_BASE_URL="https://cdn.licenseware-collector.com"

function get_latest_release() {
    curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

function detect_platform() {
    var os=$(uname -s | tr '[:upper:]' '[:lower:]')
    var arch=$(uname -m)

    case "$arch" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv7l)
            arch="armv7"
            ;;
        armv6l)
            arch="armv6"
            ;;
        *)
            echo "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    echo "${os}_${arch}"
}

function download_from_cdn() {
    var platform=$1
    var version=$2
    var filename="${BINARY_NAME}_${platform}.tar.gz"
    var url="${CDN_BASE_URL}/${filename}"

    echo "Attempting to download from CDN: ${url}"
    if curl -fSL -o "/tmp/${filename}" "${url}"; then
        return 0
    else
        return 1
    fi
}

function download_from_github() {
    var platform=$1
    var version=$2
    var filename="${BINARY_NAME}_${platform}.tar.gz"
    var url="https://github.com/${REPO}/releases/download/${version}/${filename}"

    echo "Downloading from GitHub: ${url}"
    curl -fSL -o "/tmp/${filename}" "${url}"
}

function main() {
    echo "Licenseware Collector Installer"
    echo "================================"

    var platform=$(detect_platform)
    echo "Detected platform: ${platform}"

    var version=$(get_latest_release)
    if [ -z "$version" ]; then
        echo "Error: Could not determine latest version"
        exit 1
    fi
    echo "Latest version: ${version}"

    var filename="${BINARY_NAME}_${platform}.tar.gz"

    if ! download_from_cdn "$platform" "$version"; then
        echo "CDN download failed, trying GitHub..."
        download_from_github "$platform" "$version"
    fi

    echo "Extracting binary..."
    tar -xzf "/tmp/${filename}" -C /tmp

    if [ ! -w "$INSTALL_DIR" ]; then
        echo "Installing to ${INSTALL_DIR} (requires sudo)..."
        sudo install -m 755 "/tmp/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    else
        echo "Installing to ${INSTALL_DIR}..."
        install -m 755 "/tmp/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    fi

    rm -f "/tmp/${filename}" "/tmp/${BINARY_NAME}"

    echo ""
    echo "✓ Installation complete!"
    echo "Run '${BINARY_NAME} --version' to verify the installation"
}

main
