#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/QuickShot.app"
BIN="$APP/Contents/MacOS/QuickShot"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
MAX_OVERLAY_MS="${MAX_OVERLAY_MS:-250}"
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

if ! echo "$logs" | rg -q "capture trigger accepted"; then
  echo "Observed capture verification: no capture trigger found in the last ${WINDOW_SECONDS}s." >&2
  exit 1
fi

if [ "$REQUIRE_HOTKEY_EVENT" = "1" ] && ! echo "$logs" | rg -q "hotkey event received"; then
  echo "Observed capture verification: no hotkey event found in the last ${WINDOW_SECONDS}s." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "capture overlay ready"; then
  echo "Observed capture verification: overlay readiness was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay begin"; then
  echo "Observed capture verification: overlay begin was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay activation completed"; then
  echo "Observed capture verification: deferred overlay activation was not observed." >&2
  exit 1
fi

if [ "$ALLOW_PERMISSION_PREFLIGHT" != "1" ] && echo "$logs" | rg -q "capture permission preflight .*phase=trigger"; then
  echo "Observed capture verification: hotkey path performed permission preflight despite cached access." >&2
  exit 1
fi

if echo "$logs" | rg -q "old frame accepted|cache frame accepted|source=responsive|source=validated|latest-active-stream|capture frozen ready"; then
  echo "Observed capture verification: stale or frozen-frame vocabulary appeared in the live-selection path." >&2
  exit 1
fi

if echo "$logs" | rg -q "overlay cursor hide failed"; then
  echo "Observed capture verification: cursor suppression failed." >&2
  exit 1
fi

if [ "$REQUIRE_COMPLETED_SELECTION" = "1" ]; then
  if ! echo "$logs" | rg -q "capture fresh region ready width=[0-9]+ height=[0-9]+"; then
    echo "Observed capture verification: completed fresh region capture was not observed." >&2
    exit 1
  fi
  if ! echo "$logs" | rg -q "capture clipboard copied width=[0-9]+ height=[0-9]+"; then
    echo "Observed capture verification: clipboard copy of the cropped image was not observed." >&2
    exit 1
  fi
  if ! echo "$logs" | rg -q "capture delivery outcome=completed"; then
    echo "Observed capture verification: completed image delivery outcome was not observed." >&2
    exit 1
  fi
  if ! echo "$logs" | rg -q "overlay dismiss"; then
    echo "Observed capture verification: overlay dismissal was not observed." >&2
    exit 1
  fi
  if ! echo "$logs" | rg -q "overlay cursor restored"; then
    echo "Observed capture verification: cursor restoration was not observed." >&2
    exit 1
  fi
  if ! echo "$logs" | rg -q "capture end outcome=completed"; then
    echo "Observed capture verification: completed capture session end was not observed." >&2
    exit 1
  fi
fi

overlay_ms="$(echo "$logs" | sed -n 's/.*capture overlay ready ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"
fresh_ms="$(echo "$logs" | sed -n 's/.*capture fresh region ready width=[0-9]* height=[0-9]* ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"
overlay_construct_ms="$(echo "$logs" | sed -n 's/.*capture hot path overlay constructed ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"

if [ -z "$overlay_ms" ]; then
  echo "Observed capture verification: could not parse overlay readiness timing." >&2
  exit 1
fi

if ! awk -v ms="$overlay_ms" -v max="$MAX_OVERLAY_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Observed capture verification: overlay ready took ${overlay_ms}ms, max ${MAX_OVERLAY_MS}ms." >&2
  exit 1
fi

source="menu-or-unknown"
if echo "$logs" | rg -q "hotkey event received"; then
  source="hotkey"
fi

completed_selection="no"
if echo "$logs" | rg -q "capture fresh region ready width=[0-9]+ height=[0-9]+"; then
  completed_selection="yes"
fi

delivery_outcome="none"
if echo "$logs" | rg -q "capture delivery outcome=completed"; then
  delivery_outcome="completed"
elif echo "$logs" | rg -q "capture delivery outcome=fresh-capture-failed"; then
  delivery_outcome="fresh-capture-failed"
elif echo "$logs" | rg -q "capture delivery outcome=handoff-failed"; then
  delivery_outcome="handoff-failed"
fi

echo "Observed capture verification passed: source=${source} fresh=${fresh_ms:-n/a}ms overlay=${overlay_ms}ms overlayConstruct=${overlay_construct_ms:-n/a}ms completedSelection=${completed_selection} deliveryOutcome=${delivery_outcome} pid=$pid"
