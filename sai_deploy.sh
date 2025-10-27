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

echo "✅ Installed sai to $INSTALL_PATH"
if [ -f "$HOME/.zshrc" ]; then
  echo "Reloading ~/.zshrc..."
  # shellcheck source=/dev/null
  source "$HOME/.zshrc"
fi

echo "You can now run 'sai' globally."
