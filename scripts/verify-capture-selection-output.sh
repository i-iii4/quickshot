#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/QuickShot.app"
BIN="$APP/Contents/MacOS/QuickShot"
MAX_OVERLAY_MS="${MAX_OVERLAY_MS:-250}"

./build.sh >/tmp/quickshot-selection-build.log

old_pids="$(pgrep -f "$BIN" || true)"
if [ -n "$old_pids" ]; then
  kill $old_pids || true
  sleep 1
fi

open "$APP"
sleep 1
pid="$(pgrep -f "$BIN" | head -1 || true)"
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
  exit 1
fi

tmpdir="$(mktemp -d -t quickshot-selection-output)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/selection_output_probe.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

private let targetColor = NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.34, alpha: 1)
private let selectionSize = NSSize(width: 160, height: 100)

final class SolidView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        targetColor.setFill()
        dirtyRect.fill()
    }
}

final class ProbeApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var startPoint: NSPoint = .zero
    private var endPoint: NSPoint = .zero
    private var screen: NSScreen!
    private var startedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let main = NSScreen.main else { fail("No main screen") }
        screen = main

        let frame = NSRect(x: main.frame.midX - 190,
                           y: main.frame.midY - 140,
                           width: 380,
                           height: 280)
        startPoint = NSPoint(x: frame.minX + 90, y: frame.minY + 90)
        endPoint = NSPoint(x: startPoint.x + selectionSize.width,
                           y: startPoint.y + selectionSize.height)

        let w = NSWindow(contentRect: frame,
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        w.isOpaque = true
        w.backgroundColor = targetColor
        w.hasShadow = false
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = SolidView(frame: NSRect(origin: .zero, size: frame.size))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        w.displayIfNeeded()
        window = w

        NSPasteboard.general.clearContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.performSelectionGesture()
        }
        pollClipboard()
    }

    private func performSelectionGesture() {
        warp(to: startPoint)
        Thread.sleep(forTimeInterval: 0.05)
        postKey(21, down: true, flags: [.maskCommand, .maskShift])
        postKey(21, down: false, flags: [.maskCommand, .maskShift])
        Thread.sleep(forTimeInterval: 0.06)

        postMouse(.leftMouseDown, at: startPoint)
        for step in 1...10 {
            let t = CGFloat(step) / 10
            let p = NSPoint(x: startPoint.x + (endPoint.x - startPoint.x) * t,
                            y: startPoint.y + (endPoint.y - startPoint.y) * t)
            postMouse(.leftMouseDragged, at: p)
            Thread.sleep(forTimeInterval: 0.018)
        }
        postMouse(.leftMouseUp, at: endPoint)
    }

    private func pollClipboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let data = NSPasteboard.general.data(forType: .png) {
                self.verifyPNG(data)
                NSApp.terminate(nil)
                return
            }
            if Date().timeIntervalSince(self.startedAt) > 7 {
                self.fail("Timed out waiting for clipboard PNG")
            }
            self.pollClipboard()
        }
    }

    private func verifyPNG(_ data: Data) {
        guard let rep = NSBitmapImageRep(data: data) else { fail("Clipboard PNG is not decodable") }
        let expectedAspect = selectionSize.width / selectionSize.height
        let actualAspect = CGFloat(rep.pixelsWide) / CGFloat(max(1, rep.pixelsHigh))
        guard rep.pixelsWide >= 120,
              rep.pixelsHigh >= 75,
              abs(actualAspect - expectedAspect) < 0.04 else {
            fail(String(format: "Unexpected PNG geometry: %dx%d aspect=%.3f expectedAspect=%.3f",
                        rep.pixelsWide, rep.pixelsHigh, actualAspect, expectedAspect))
        }

        guard let center = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB) else {
            fail("Cannot sample center pixel")
        }
        let centerRGB = rgb(center)
        var samples = 0
        var outliers = 0
        let sampleStep = 3
        for y in stride(from: 3, to: max(3, rep.pixelsHigh - 3), by: sampleStep) {
            for x in stride(from: 3, to: max(3, rep.pixelsWide - 3), by: sampleStep) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                samples += 1
                let c = rgb(color)
                let distance = abs(c.r - centerRGB.r) + abs(c.g - centerRGB.g) + abs(c.b - centerRGB.b)
                if distance > 0.18 { outliers += 1 }
            }
        }
        let outlierRatio = samples == 0 ? 1 : Double(outliers) / Double(samples)
        guard outlierRatio < 0.006 else {
            fail(String(format: "PNG is not uniform enough: outliers=%d samples=%d ratio=%.4f center=(%.3f,%.3f,%.3f)",
                        outliers, samples, outlierRatio, centerRGB.r, centerRGB.g, centerRGB.b))
        }

        print(String(format: "Selection output probe passed: size=%dx%d outliers=%d/%d center=(%.3f,%.3f,%.3f)",
                     rep.pixelsWide, rep.pixelsHigh, outliers, samples, centerRGB.r, centerRGB.g, centerRGB.b))
    }

    private func rgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (color.redComponent, color.greenComponent, color.blueComponent)
    }

    private func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at appKitPoint: NSPoint) {
        let cgPoint = quartzPoint(for: appKitPoint)
        guard let event = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: cgPoint,
                                  mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func warp(to appKitPoint: NSPoint) {
        CGWarpMouseCursorPosition(quartzPoint(for: appKitPoint))
    }

    private func quartzPoint(for appKitPoint: NSPoint) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y)
    }

    private func fail(_ message: String) -> Never {
        fputs("Selection output probe failed: \(message)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = ProbeApp()
app.delegate = delegate
app.run()
SWIFT

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macos26.0" \
  -swift-version 5 \
  -framework AppKit \
  -framework CoreGraphics \
  "$tmpdir/selection_output_probe.swift" \
  -o "$tmpdir/selection_output_probe"

"$tmpdir/selection_output_probe"
sleep 0.5

logs="$(/usr/bin/log show --last 20s --info --debug --style compact --predicate "$predicate" 2>/dev/null || true)"
echo "$logs" | tail -100

if echo "$logs" | rg -q "capture cache pending|capture cache unavailable|cache wait expired|falling back|one-shot"; then
  echo "Selection output regression: warm selection did not use immediate stream-cache hit." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "capture crop complete width=[0-9]+ height=[0-9]+"; then
  echo "Selection output regression: crop completion was not observed." >&2
  exit 1
fi

if ! echo "$logs" | rg -q "overlay cursor restored"; then
  echo "Selection output regression: cursor restoration was not observed." >&2
  exit 1
fi

overlay_ms="$(echo "$logs" | sed -n 's/.*capture overlay ready ms=\([0-9.]*\).*/\1/p' | tail -1)"
if ! awk -v ms="$overlay_ms" -v max="$MAX_OVERLAY_MS" 'BEGIN { exit !(ms <= max) }'; then
  echo "Selection output regression: overlay ready took ${overlay_ms}ms, max ${MAX_OVERLAY_MS}ms." >&2
  exit 1
fi

echo "Capture selection output verification passed: overlay=${overlay_ms}ms pid=$pid"
