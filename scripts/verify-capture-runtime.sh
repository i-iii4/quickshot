#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/QuickShot.app"
BIN="$APP/Contents/MacOS/QuickShot"
MAX_OVERLAY_MS="${MAX_OVERLAY_MS:-250}"
MAX_CACHE_HIT_MS="${MAX_CACHE_HIT_MS:-50}"
CAPTURE_REPEAT="${CAPTURE_REPEAT:-3}"

./build.sh >/tmp/quickshot-build.log

old_pids="$(pgrep -f "$BIN" || true)"
if [ -n "$old_pids" ]; then
  kill $old_pids || true
  sleep 2
fi

open "$APP"
sleep 1
pid="$(pgrep -f "$BIN" | head -1)"
if [ -z "$pid" ]; then
  echo "QuickShot did not start." >&2
  exit 1
fi

predicate="processID == $pid AND subsystem == \"com.iiii.quickshot\""

cache_ready=false
for _ in {1..30}; do
  logs="$(/usr/bin/log show --last 30s --info --debug --style compact --predicate "$predicate" 2>/dev/null || true)"
  if echo "$logs" | rg -q "capture cache first frame"; then
    cache_ready=true
    break
  fi
  sleep 0.25
done

if [ "$cache_ready" != true ]; then
  echo "ScreenFrameCache did not produce a frame for QuickShot pid $pid." >&2
  /usr/bin/log show --last 30s --info --debug --style compact --predicate "$predicate" | tail -80 >&2 || true
  exit 1
fi

tmpdir="$(mktemp -d -t quickshot-runtime-verify)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/send_hotkey.swift" <<'SWIFT'
import CoreGraphics
import Foundation

func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

let screenshotFlags: CGEventFlags = [.maskCommand, .maskShift]
post(21, down: true, flags: screenshotFlags)   // "4"
post(21, down: false, flags: screenshotFlags)
Thread.sleep(forTimeInterval: 0.35)
post(53, down: true)                            // Escape
post(53, down: false)
SWIFT

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macos26.0" \
  -swift-version 5 \
  -framework CoreGraphics \
  "$tmpdir/send_hotkey.swift" \
  -o "$tmpdir/send_hotkey"

for _ in $(seq 1 "$CAPTURE_REPEAT"); do
  "$tmpdir/send_hotkey"
  sleep 0.45
done
sleep 0.5

logs="$(/usr/bin/log show --last 20s --info --debug --style compact --predicate "$predicate")"
echo "$logs" | tail -80

if echo "$logs" | rg -q "capture cache miss|capture cache pending|capture cache unavailable|cache wait expired|falling back|one-shot"; then
  echo "Runtime regression: warm capture did not use immediate stream-cache hit." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "capture cache hit"; then
  echo "Runtime regression: capture cache hit was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "capture overlay ready"; then
  echo "Runtime regression: frozen overlay readiness was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay begin"; then
  echo "Runtime regression: overlay begin was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay cursor hidden"; then
  echo "Runtime regression: cursor suppression was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay cursor restored"; then
  echo "Runtime regression: cursor restoration was not observed." >&2
  exit 1
fi

if echo "$logs" | rg -q "overlay cursor hide failed"; then
  echo "Runtime regression: cursor suppression failed." >&2
  exit 1
fi

hit_count="$(echo "$logs" | rg -c "capture cache hit|capture cache late hit" || true)"
if ! awk -v hits="$hit_count" -v expected="$CAPTURE_REPEAT" 'BEGIN { exit !(hits >= expected) }'; then
  echo "Runtime regression: observed ${hit_count} cache hit(s), expected at least ${CAPTURE_REPEAT}." >&2
  exit 1
fi

cache_ms="$(echo "$logs" | awk '
  /capture cache (late )?hit/ {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^ms=/) {
        sub(/^ms=/, "", $i)
        value = $i + 0
        if (value > max) max = value
      }
    }
  }
  END { if (max != "") print max }
')"
overlay_ms="$(echo "$logs" | sed -n 's/.*capture overlay ready ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"

if ! awk -v ms="$cache_ms" -v max="$MAX_CACHE_HIT_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Runtime regression: cache hit took ${cache_ms}ms, max ${MAX_CACHE_HIT_MS}ms." >&2
  exit 1
fi

if ! awk -v ms="$overlay_ms" -v max="$MAX_OVERLAY_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Runtime regression: overlay ready took ${overlay_ms}ms, max ${MAX_OVERLAY_MS}ms." >&2
  exit 1
fi

echo "Capture runtime verification passed: cache=${cache_ms}ms overlay=${overlay_ms}ms pid=$pid"
