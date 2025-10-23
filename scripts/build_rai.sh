#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAI_DIR="$ROOT_DIR/rai"
BUILD_DIR="$ROOT_DIR/build"

echo "Building rai (release profile)…"
cargo build --release --manifest-path "$RAI_DIR/Cargo.toml"

mkdir -p "$BUILD_DIR"
cp "$RAI_DIR/target/release/rai" "$BUILD_DIR/rai"

echo "Done. Binary available at $BUILD_DIR/rai"
