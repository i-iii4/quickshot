#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/QuickShot.app"
BIN="$APP/Contents/MacOS/QuickShot"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
MAX_OVERLAY_MS="${MAX_OVERLAY_MS:-120}"
MAX_MOUSE_UP_TO_CARD_MS="${MAX_MOUSE_UP_TO_CARD_MS:-100}"
ALLOW_PERMISSION_PREFLIGHT="${ALLOW_PERMISSION_PREFLIGHT:-0}"
REQUIRE_HOTKEY_EVENT="${REQUIRE_HOTKEY_EVENT:-0}"
REQUIRE_COMPLETED_SELECTION="${REQUIRE_COMPLETED_SELECTION:-0}"

pid="$(pgrep -f "$BIN" | head -1 || true)"
if [ -z "$pid" ]; then
  echo "QuickShot is not running from $BIN." >&2
  exit 1
fi

predicate="processID == $pid AND subsystem == \"com.iiii.quickshot\" AND category == \"capture\""
logs="$(/usr/bin/log show --last "${WINDOW_SECONDS}s" --info --debug --style compact --predicate "$predicate" 2>/dev/null || true)"
echo "$logs" | tail -120

for token in "capture trigger accepted" "capture direct batch ready" \
             "capture frozen ready" "capture overlay ready" \
             "overlay begin" "mode=frozen" "overlay activation completed"; do
  if ! echo "$logs" | rg -q "$token"; then
    echo "Observed capture verification: missing '$token'." >&2
    exit 1
  fi
done

if [ "$REQUIRE_HOTKEY_EVENT" = "1" ] && ! echo "$logs" | rg -q "hotkey event received"; then
  echo "Observed capture verification: no hotkey event found." >&2
  exit 1
fi

if [ "$ALLOW_PERMISSION_PREFLIGHT" != "1" ] \
   && echo "$logs" | rg -q "capture permission preflight .*phase=trigger"; then
  echo "Observed capture verification: hotkey path performed uncached permission preflight." >&2
  exit 1
fi

if echo "$logs" | rg -q "old frame accepted|cache frame accepted|latest-active-stream|fresh region|system capture launched"; then
  echo "Observed capture verification: retired or stale capture vocabulary appeared." >&2
  exit 1
fi

if echo "$logs" | rg -q "overlay (activation rejected|activation timed out|activation lost|cursor suppression failed)"; then
  echo "Observed capture verification: selector presentation ownership failed." >&2
  exit 1
fi

if [ "$REQUIRE_COMPLETED_SELECTION" = "1" ]; then
  for token in "capture crop complete" "capture clipboard copied" \
               "capture delivery outcome=completed" "overlay dismiss" \
               "overlay cursor lease released" "capture end outcome=completed"; do
    if ! echo "$logs" | rg -q "$token"; then
      echo "Observed capture verification: completed selection missing '$token'." >&2
      exit 1
    fi
  done
fi

overlay_ms="$(echo "$logs" | sed -n 's/.*capture overlay ready ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"
snapshot_ms="$(echo "$logs" | sed -n 's/.*capture direct batch ready .* ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"
mouse_up_ms="$(echo "$logs" | sed -n 's/.*mouseUpToCardMs=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"

if [ -z "$overlay_ms" ]; then
  echo "Observed capture verification: could not parse overlay timing." >&2
  exit 1
fi
if ! awk -v ms="$overlay_ms" -v max="$MAX_OVERLAY_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Observed capture verification: overlay ready took ${overlay_ms}ms, max ${MAX_OVERLAY_MS}ms." >&2
  exit 1
fi
if [ "$REQUIRE_COMPLETED_SELECTION" = "1" ]; then
  if [ -z "$mouse_up_ms" ]; then
    echo "Observed capture verification: could not parse mouse-up delivery timing." >&2
    exit 1
  fi
  if ! awk -v ms="$mouse_up_ms" -v max="$MAX_MOUSE_UP_TO_CARD_MS" 'BEGIN { exit !(ms <= max) }'; then
    echo "Observed capture verification: mouse-up delivery took ${mouse_up_ms}ms, max ${MAX_MOUSE_UP_TO_CARD_MS}ms." >&2
    exit 1
  fi
fi

source="menu-or-unknown"
if echo "$logs" | rg -q "hotkey event received"; then source="hotkey"; fi
completed="no"
if echo "$logs" | rg -q "capture delivery outcome=completed"; then completed="yes"; fi

echo "Observed capture verification passed: source=${source} snapshot=${snapshot_ms:-n/a}ms overlay=${overlay_ms}ms mouseUp=${mouse_up_ms:-n/a}ms completed=${completed} pid=$pid"
