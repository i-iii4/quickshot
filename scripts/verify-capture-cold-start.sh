#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/QuickShot.app"
BIN="$APP/Contents/MacOS/QuickShot"
COLD_HOTKEY_DELAY="${COLD_HOTKEY_DELAY:-0.05}"
COLD_WAIT_SECONDS="${COLD_WAIT_SECONDS:-4.00}"
MAX_COLD_OVERLAY_MS="${MAX_COLD_OVERLAY_MS:-120}"

if [ "${QUICKSHOT_ALLOW_SYNTHETIC_INPUT:-0}" != "1" ]; then
  cat >&2 <<'EOF'
verify-capture-cold-start.sh posts synthetic hotkey events and opens the capture overlay.
Set QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1 to run it intentionally.
For non-interruptive verification, use scripts/verify-capture-observed.sh after a manual capture.
EOF
  exit 2
fi

./build.sh >/tmp/quickshot-cold-build.log

tmpdir="$(mktemp -d -t quickshot-cold-verify)"
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
post(21, down: true, flags: screenshotFlags)
post(21, down: false, flags: screenshotFlags)
Thread.sleep(forTimeInterval: 0.10)
SWIFT

cat >"$tmpdir/send_escape.swift" <<'SWIFT'
import CoreGraphics
import Foundation

guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
    exit(0)
}
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.10)
SWIFT

for source in send_hotkey send_escape; do
  xcrun swiftc \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos26.0" \
    -swift-version 5 \
    -framework CoreGraphics \
    "$tmpdir/${source}.swift" \
    -o "$tmpdir/$source"
done

old_pids="$(pgrep -f "$BIN" || true)"
if [ -n "$old_pids" ]; then
  kill $old_pids || true
  sleep 0.6
fi

open "$APP"
for _ in {1..40}; do
  pid="$(pgrep -f "$BIN" | head -1 || true)"
  if [ -n "$pid" ]; then break; fi
  sleep 0.05
done

if [ -z "${pid:-}" ]; then
  echo "QuickShot did not start." >&2
  exit 1
fi

predicate="processID == $pid AND subsystem == \"com.iiii.quickshot\""
hotkey_ready=false
for _ in {1..40}; do
  logs="$(/usr/bin/log show --last 10s --info --debug --style compact --predicate "$predicate" 2>/dev/null || true)"
  if echo "$logs" | rg -q "app hotkey registered"; then
    hotkey_ready=true
    break
  fi
  sleep 0.05
done

if [ "$hotkey_ready" != true ]; then
  echo "Cold-start regression: QuickShot did not report hotkey registration." >&2
  exit 1
fi

sleep "$COLD_HOTKEY_DELAY"
"$tmpdir/send_hotkey"
sleep "$COLD_WAIT_SECONDS"
"$tmpdir/send_escape"
sleep 0.5

logs="$(/usr/bin/log show --last 15s --info --debug --style compact --predicate "$predicate" 2>/dev/null || true)"
echo "$logs" | tail -100

if ! echo "$logs" | rg -q "capture trigger accepted"; then
  echo "Cold-start regression: capture did not start after synthetic hotkey." >&2
  exit 1
fi

if echo "$logs" | rg -q "old frame accepted|cache frame accepted|latest-active-stream|fresh region|system capture launched"; then
  echo "Cold-start regression: retired or stale capture vocabulary appeared." >&2
  exit 1
fi

for token in "capture direct batch ready" "capture frozen ready" "mode=frozen"; do
  if ! echo "$logs" | rg -q "$token"; then
    echo "Cold-start regression: missing '$token'." >&2
    exit 1
  fi
done

if ! echo "$logs" | rg -q "capture overlay ready"; then
  echo "Cold-start regression: overlay did not become ready." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay dismiss"; then
  echo "Cold-start regression: overlay dismiss was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay cursor restored"; then
  echo "Cold-start regression: cursor restoration was not observed." >&2
  exit 1
fi

overlay_ms="$(echo "$logs" | sed -n 's/.*capture overlay ready ms=\([0-9.]*\).*/\1/p' | tail -1)"
if ! awk -v ms="$overlay_ms" -v max="$MAX_COLD_OVERLAY_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Cold-start regression: overlay ready took ${overlay_ms}ms, max ${MAX_COLD_OVERLAY_MS}ms." >&2
  exit 1
fi

echo "Capture cold-start verification passed: overlay=${overlay_ms}ms pid=$pid"
