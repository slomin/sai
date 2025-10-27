#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

GO_CMD="go"
OUTPUT_DIR="$PROJECT_ROOT/build"
OUTPUT_BIN="$OUTPUT_DIR/sai"
INSTALL_PATH="/usr/local/bin/sai"

echo "Building sai binary..."
mkdir -p "$OUTPUT_DIR"
(
  cd "$PROJECT_ROOT" &&
  $GO_CMD build -o "$OUTPUT_BIN" ./cmd/sai
)

echo "Copying binary to $INSTALL_PATH (requires sudo)..."
sudo cp "$OUTPUT_BIN" "$INSTALL_PATH"
sudo chmod 755 "$INSTALL_PATH"

if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing $INSTALL_PATH..."
  sudo codesign --force --sign - "$INSTALL_PATH"
fi

if command -v xattr >/dev/null 2>&1; then
  echo "Clearing macOS quarantine flags..."
  sudo xattr -r -d com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
  sudo xattr -r -d com.apple.provenance "$INSTALL_PATH" 2>/dev/null || true
fi

echo "✅ Installed sai to $INSTALL_PATH"
if [ -f "$HOME/.zshrc" ]; then
  echo "Reloading ~/.zshrc..."
  # shellcheck source=/dev/null
  source "$HOME/.zshrc"
fi

echo "You can now run 'sai' globally."
