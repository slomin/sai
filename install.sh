#!/usr/bin/env bash

set -euo pipefail

# SAI Installer
# Downloads and installs the latest version of SAI

REPO="slomin/sai"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="sai"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}==>${NC} $1"
}

warn() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

error() {
    echo -e "${RED}Error:${NC} $1"
    exit 1
}

# Detect OS and architecture
detect_platform() {
    local os
    local arch

    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            os="darwin"
            ;;
        Linux)
            os="linux"
            ;;
        *)
            error "Unsupported OS: $os"
            ;;
    esac

    case "$arch" in
        x86_64 | amd64)
            arch="amd64"
            ;;
        arm64 | aarch64)
            arch="arm64"
            ;;
        *)
            error "Unsupported architecture: $arch"
            ;;
    esac

    echo "${os}-${arch}"
}

# Get the latest release version
get_latest_version() {
    local version
    version=$(curl -sf https://api.github.com/repos/$REPO/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$version" ]; then
        error "Failed to fetch latest version"
    fi

    echo "$version"
}

# Main installation function
main() {
    info "SAI Installer"
    echo ""

    # Check for required commands
    for cmd in curl uname; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command not found: $cmd"
        fi
    done

    # Detect platform
    local platform
    platform=$(detect_platform)
    info "Detected platform: $platform"

    # Get latest version
    local version
    version=$(get_latest_version)
    info "Latest version: $version"

    # Construct download URL
    local binary_name="sai-${platform}"
    local download_url="https://github.com/$REPO/releases/download/$version/$binary_name"

    info "Downloading from: $download_url"

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    # Download binary
    local temp_file
    temp_file=$(mktemp)
    if ! curl -fsSL "$download_url" -o "$temp_file"; then
        error "Failed to download SAI"
    fi

    # Make executable
    chmod +x "$temp_file"

    # Move to install directory
    mv "$temp_file" "$INSTALL_DIR/$BINARY_NAME"

    # Remove macOS quarantine attribute (if on macOS)
    if [[ "$platform" == darwin-* ]]; then
        info "Removing macOS quarantine attribute..."
        if command -v xattr >/dev/null 2>&1; then
            xattr -d com.apple.quarantine "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null || true
        fi
    fi

    echo ""
    info "✅ SAI installed successfully to: $INSTALL_DIR/$BINARY_NAME"
    echo ""

    # Check if install directory is in PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        warn "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add it to your shell configuration:"
        echo ""
        echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
        echo "  source ~/.zshrc"
        echo ""
    else
        info "You can now run: sai --help"
    fi

    # Suggest configuration
    echo ""
    info "Next steps:"
    echo "  1. Configure your endpoint: sai --settings"
    echo "  2. Start chatting: sai"
    echo ""
}

main "$@"
