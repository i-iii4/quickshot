#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d -t quickshot-direct-probe)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/probe.swift" <<'SWIFT'
import AppKit
import CoreGraphics

@main
struct Probe {
    static func main() async {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            fputs("directCapture=permission-denied\n", stderr)
            exit(2)
        }

        let displays = NSScreen.screens.compactMap { screen -> CaptureDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return CaptureDisplay(id: id,
                                  frame: screen.frame,
                                  quartzBounds: CGDisplayBounds(id))
        }
        let repeatCount = max(1, Int(ProcessInfo.processInfo.environment["CAPTURE_REPEAT"] ?? "1") ?? 1)
        var timings: [Double] = []
        var sizes = ""
        for _ in 0..<repeatCount {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let batch = try await DirectScreenSnapshotProvider()
                    .capture(sessionID: UUID(), displays: displays)
                timings.append((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                sizes = batch.screens
                    .sorted { $0.displayID < $1.displayID }
                    .map { "\($0.displayID):\($0.image.width)x\($0.image.height)" }
                    .joined(separator: ",")
            } catch {
                fputs("directCapture=error \(error)\n", stderr)
                exit(1)
            }
        }
        let sorted = timings.sorted()
        let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        print("directCapture=ok displays=\(sizes) runs=\(timings.count) min=\(String(format: "%.2f", sorted.first ?? 0))ms p95=\(String(format: "%.2f", sorted[p95Index]))ms max=\(String(format: "%.2f", sorted.last ?? 0))ms")
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
  Sources/CaptureTypes.swift \
  Sources/CoordinateMath.swift \
  Sources/DirectScreenSnapshotProvider.swift \
  "$tmpdir/probe.swift" \
  -o "$tmpdir/probe"

"$tmpdir/probe"
