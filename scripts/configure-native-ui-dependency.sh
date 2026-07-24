#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${1:-}"
LOCAL_LINK="$ROOT/.dependencies/native-ui-design-system"

if [ -z "$SOURCE_DIR" ]; then
  echo "usage: $0 /absolute/path/to/native-ui-design-system" >&2
  exit 64
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
mkdir -p "$ROOT/.dependencies"
rm -f "$LOCAL_LINK"
ln -s "$SOURCE_DIR" "$LOCAL_LINK"

NATIVE_DESIGN_SYSTEM_DIR="$SOURCE_DIR" \
  "$ROOT/scripts/resolve-native-ui-dependency.sh" >/dev/null

echo "Native UI dependency configured: $SOURCE_DIR"
