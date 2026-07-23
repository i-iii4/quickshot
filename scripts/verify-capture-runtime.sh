#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/QuickShot.app"
BIN="$APP/Contents/MacOS/QuickShot"
MAX_OVERLAY_MS="${MAX_OVERLAY_MS:-120}"
CAPTURE_REPEAT="${CAPTURE_REPEAT:-3}"

if [ "${QUICKSHOT_ALLOW_SYNTHETIC_INPUT:-0}" != "1" ]; then
  cat >&2 <<'EOF'
verify-capture-runtime.sh posts synthetic hotkey events and opens the capture overlay.
Set QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1 to run it intentionally.
For non-interruptive verification, use scripts/verify-capture-observed.sh after a manual capture.
EOF
  exit 2
fi

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

if echo "$logs" | rg -q "old frame accepted|cache frame accepted|latest-active-stream|fresh region|system capture launched"; then
  echo "Runtime regression: retired or stale capture vocabulary appeared." >&2
  exit 1
fi

for token in "capture direct batch ready" "capture frozen ready" "mode=frozen"; do
  if ! echo "$logs" | rg -q "$token"; then
    echo "Runtime regression: missing '$token'." >&2
    exit 1
  fi
done

if ! echo "$logs" | rg -q "capture overlay ready"; then
  echo "Runtime regression: overlay readiness was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay begin"; then
  echo "Runtime regression: overlay begin was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay cursor lease acquired"; then
  echo "Runtime regression: cursor suppression was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay cursor lease released"; then
  echo "Runtime regression: cursor restoration was not observed." >&2
  exit 1
fi

if echo "$logs" | rg -q "overlay cursor suppression failed"; then
  echo "Runtime regression: cursor suppression failed." >&2
  exit 1
fi

overlay_ms="$(echo "$logs" | sed -n 's/.*capture overlay ready ms=\([0-9.]*\).*/\1/p' | awk 'max < $1 { max = $1 } END { if (NR) print max }')"

if ! awk -v ms="$overlay_ms" -v max="$MAX_OVERLAY_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Runtime regression: overlay ready took ${overlay_ms}ms, max ${MAX_OVERLAY_MS}ms." >&2
  exit 1
fi

echo "Capture runtime verification passed: overlay=${overlay_ms}ms pid=$pid"
