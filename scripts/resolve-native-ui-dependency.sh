#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="$ROOT/NativeUIDependencies.lock"
LOCAL_LINK="$ROOT/.dependencies/native-ui-design-system"
SDK_LINK="$ROOT/.dependencies/native-sdk"

if [ ! -f "$LOCK_FILE" ]; then
  echo "error: missing Native UI dependency lock: $LOCK_FILE" >&2
  exit 1
fi

# shellcheck source=../NativeUIDependencies.lock
source "$LOCK_FILE"

DESIGN_SYSTEM_DIR="${NATIVE_DESIGN_SYSTEM_DIR:-}"
if [ -z "$DESIGN_SYSTEM_DIR" ] && [ -e "$LOCAL_LINK" ]; then
  DESIGN_SYSTEM_DIR="$LOCAL_LINK"
fi

if [ -z "$DESIGN_SYSTEM_DIR" ]; then
  echo "error: Native UI Design System is not configured" >&2
  echo "run: ./scripts/configure-native-ui-dependency.sh /absolute/path/to/native-ui-design-system" >&2
  echo "or set NATIVE_DESIGN_SYSTEM_DIR for this command" >&2
  exit 1
fi

if [ ! -d "$DESIGN_SYSTEM_DIR" ]; then
  echo "error: Native UI Design System directory does not exist: $DESIGN_SYSTEM_DIR" >&2
  exit 1
fi

DESIGN_SYSTEM_DIR="$(cd "$DESIGN_SYSTEM_DIR" && pwd -P)"
ACTUAL_REVISION="$(git -C "$DESIGN_SYSTEM_DIR" rev-parse HEAD 2>/dev/null || true)"
if [ "$ACTUAL_REVISION" != "$NATIVE_UI_DESIGN_SYSTEM_REVISION" ]; then
  echo "error: Native UI Design System revision mismatch" >&2
  echo "expected: $NATIVE_UI_DESIGN_SYSTEM_REVISION" >&2
  echo "actual:   ${ACTUAL_REVISION:-not a git checkout}" >&2
  exit 1
fi

if ! git -C "$DESIGN_SYSTEM_DIR" diff --quiet \
  || ! git -C "$DESIGN_SYSTEM_DIR" diff --cached --quiet; then
  echo "error: Native UI Design System has uncommitted tracked changes" >&2
  exit 1
fi

if [ ! -x "$DESIGN_SYSTEM_DIR/scripts/check.sh" ]; then
  echo "error: design-system contract is unavailable at $DESIGN_SYSTEM_DIR" >&2
  exit 1
fi

SDK_DIR="$DESIGN_SYSTEM_DIR/node_modules/@native-sdk/cli"
if [ ! -f "$SDK_DIR/build.zig" ] || [ ! -x "$DESIGN_SYSTEM_DIR/node_modules/.bin/native" ]; then
  echo "error: pinned Native SDK is not installed" >&2
  echo "run: $DESIGN_SYSTEM_DIR/scripts/bootstrap.sh" >&2
  exit 1
fi

ACTUAL_SDK_VERSION="$("$DESIGN_SYSTEM_DIR/node_modules/.bin/native" version)"
EXPECTED_SDK_VERSION="native $NATIVE_SDK_VERSION (commit $NATIVE_SDK_UPSTREAM_COMMIT, automation protocol v6)"
if [ "$ACTUAL_SDK_VERSION" != "$EXPECTED_SDK_VERSION" ]; then
  echo "error: Native SDK version mismatch" >&2
  echo "expected: $EXPECTED_SDK_VERSION" >&2
  echo "actual:   $ACTUAL_SDK_VERSION" >&2
  exit 1
fi

mkdir -p "$ROOT/.dependencies"
TEMP_LINK="$ROOT/.dependencies/.native-sdk.$$"
trap 'rm -f "$TEMP_LINK"' EXIT
ln -s "$SDK_DIR" "$TEMP_LINK"
rm -f "$SDK_LINK"
mv "$TEMP_LINK" "$SDK_LINK"
trap - EXIT

printf '%s\n' "$DESIGN_SYSTEM_DIR"
