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

COUNT=${1:-10}
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT <= 0 )); then
  echo "Usage: ${0##*/} [positive-count]" >&2
  exit 1
fi

: "${SAI_BINARY:=sai}"
PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build:$PATH"

echo "Using sai binary: $(command -v "$SAI_BINARY")"

script_start=$(python3 - <<'PY'
import time
print(time.time())
PY
)

declare -a durations=()

for ((i = 0; i < COUNT; ++i)); do
  prompt_index=$((i % ${#PROMPTS[@]}))
  prompt=${PROMPTS[$prompt_index]}

  echo
  echo ">>> sai $prompt"

  start=$(python3 - <<'PY'
import time
print(time.time())
PY
)

  "$SAI_BINARY" "$prompt"

  finish=$(python3 - <<'PY'
import time
print(time.time())
PY
)

  elapsed=$(python3 - "$start" "$finish" <<'PY'
import sys
start=float(sys.argv[1])
finish=float(sys.argv[2])
print(f"{finish-start:.3f}")
PY
)
  durations+=("$elapsed")
done

script_finish=$(python3 - <<'PY'
import time
print(time.time())
PY
)

python3 - "$script_start" "$script_finish" "${durations[@]}" <<'PY'
import statistics
import sys

if len(sys.argv) < 3:
    sys.exit(0)

start = float(sys.argv[1])
finish = float(sys.argv[2])
durations = [float(x) for x in sys.argv[3:]]

total = sum(durations)
median = statistics.median(durations) if durations else 0.0
wall = finish - start

print()
print('[Summary]')
print(f'  Iterations       : {len(durations)}')
print(f'  Sum durations    : {total:.3f}s')
print(f'  Median duration  : {median:.3f}s')
print(f'  Total wall-clock : {wall:.3f}s')
PY
