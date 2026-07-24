#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d -t quickshot-atomic-replace)"
HELPER="$TEMP_ROOT/atomic-replace"
trap 'rm -rf "$TEMP_ROOT"' EXIT

xcrun clang -Wall -Wextra -Werror \
  "$ROOT/scripts/atomic-replace.c" \
  -o "$HELPER"

mkdir -p "$TEMP_ROOT/current.app" "$TEMP_ROOT/staged.app"
printf 'old\n' > "$TEMP_ROOT/current.app/version"
printf 'new\n' > "$TEMP_ROOT/staged.app/version"

"$HELPER" "$TEMP_ROOT/staged.app" "$TEMP_ROOT/current.app"
test "$(cat "$TEMP_ROOT/current.app/version")" = "new"
test "$(cat "$TEMP_ROOT/staged.app/version")" = "old"

mkdir -p "$TEMP_ROOT/first.app"
printf 'first\n' > "$TEMP_ROOT/first.app/version"
"$HELPER" "$TEMP_ROOT/first.app" "$TEMP_ROOT/installed.app"
test "$(cat "$TEMP_ROOT/installed.app/version")" = "first"
test ! -e "$TEMP_ROOT/first.app"

echo "AtomicReplaceTests: OK"
