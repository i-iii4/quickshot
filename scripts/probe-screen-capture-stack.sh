#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d -t quickshot-sck-probe)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/probe.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import ScreenCaptureKit

@main
struct Probe {
    static func main() async {
        let access = CGPreflightScreenCaptureAccess()
        print("preflight=\(access)")

        let loaders: [(String, () async throws -> SCShareableContent)] = [
            ("excluding false/all", { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }),
            ("excluding false/onScreen", { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }),
            ("excluding true/onScreen", { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }),
            ("currentProcess", { try await SCShareableContent.currentProcess }),
            ("current", { try await SCShareableContent.current }),
        ]

        for (label, loader) in loaders {
            do {
                let content = try await loader()
                let displays = content.displays.map { String($0.displayID) }.joined(separator: ",")
                print("content \(label): displays=\(displays) windows=\(content.windows.count) apps=\(content.applications.count)")
            } catch {
                print("content \(label): error=\(error)")
            }
        }

        guard access else { return }

        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let rect = CGRect(x: displayBounds.midX, y: displayBounds.midY, width: 16, height: 16)
        let config = SCScreenshotConfiguration()
        config.showsCursor = false
        config.displayIntent = .local
        config.dynamicRange = .sdr

        do {
            let output = try await SCScreenshotManager.captureScreenshot(rect: rect, configuration: config)
            if let image = output.sdrImage ?? output.hdrImage {
                print("captureScreenshotRect=ok size=\(image.width)x\(image.height)")
            } else {
                print("captureScreenshotRect=missing-image")
            }
        } catch {
            print("captureScreenshotRect=error \(error)")
        }

        await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    print("captureImageInRect=ok size=\(image.width)x\(image.height)")
                } else {
                    print("captureImageInRect=error \(String(describing: error))")
                }
                continuation.resume()
            }
        }
    }
}
SWIFT

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macos26.0" \
  -swift-version 5 \
  -parse-as-library \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  "$tmpdir/probe.swift" \
  -o "$tmpdir/probe"

"$tmpdir/probe"

png="$tmpdir/screencapture.png"
if /usr/sbin/screencapture -x -R 10,10,16,16 "$png" 2>"$tmpdir/screencapture.err"; then
  if [ -f "$png" ]; then
    echo "screencaptureCLI=ok $(sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null | tr '\n' ' ')"
  else
    echo "screencaptureCLI=missing-file"
  fi
else
  echo "screencaptureCLI=error $(tr '\n' ' ' <"$tmpdir/screencapture.err")"
fi
