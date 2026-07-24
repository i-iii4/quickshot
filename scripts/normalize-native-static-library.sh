#!/bin/bash
set -euo pipefail

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  echo "usage: $0 /absolute/path/to/library.a" >&2
  exit 64
fi

ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd -P)/$(basename "$ARCHIVE")"
TEMP_ROOT="$(mktemp -d -t quickshot-native-archive)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

(cd "$TEMP_ROOT" && ar -x "$ARCHIVE")
OBJECTS=("$TEMP_ROOT"/*.o)
if [ ! -e "${OBJECTS[0]}" ]; then
  echo "error: static archive contains no object files: $ARCHIVE" >&2
  exit 1
fi

chmod 600 "${OBJECTS[@]}"
xcrun libtool -static -o "$TEMP_ROOT/normalized.a" "${OBJECTS[@]}"
mv "$TEMP_ROOT/normalized.a" "$ARCHIVE"
