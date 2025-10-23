#!/usr/bin/env zsh
# Convenience wrapper for `rai` that disables globbing and honours $RAI_BIN.

rai() {
  emulate -L zsh
  setopt local_options no_aliases no_glob

  local bin="${RAI_BIN:-/Users/jan/0Projects/sai/build/rai}"
  "$bin" "$@"
}
