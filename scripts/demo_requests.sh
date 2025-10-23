#!/usr/bin/env bash
set -euo pipefail

PROMPTS=(
  "list hidden files in this directory"
  "show me the last 5 git commits"
  "how do I create a new python virtualenv here?"
  "run tests for this project"
  "compress all markdown files into docs.tar.gz"
  "find TODO comments recursively"
  "what branch am I on?"
  "set an environment variable just for this command"
  "start a simple http server on port 9000"
  "clean up build artifacts"
)

: "${SAI_BINARY:=sai}"
PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build:$PATH"

echo "Using sai binary: $(command -v "$SAI_BINARY")"

for prompt in "${PROMPTS[@]}"; do
  echo
  echo ">>> sai $prompt"
  "$SAI_BINARY" "$prompt"
done
