import CoreGraphics
import Foundation

@main
struct DirectScreenSnapshotProviderTests {
    static func main() async {
        do {
            try testDirectSymbolIsAvailable()
            try testPixelCropUsesActualImageSize()
            try testFrozenScreenCrop()
            try testAvailabilityCheckDoesNotCapturePixels()
            try await testProviderOwnsFreshImagesPerSession()
            try await testProviderSerializesCompositorRequests()
            try await testProviderFailsAtomically()
            try await testProviderRejectsExcessiveDisplaySkew()
            try await testCancellationDiscardsSynchronousResult()
            try await testDuplicateDisplaysFailBeforeCapture()
            try await testHundredFakeBackendLifecycles()
            print("DirectScreenSnapshotProviderTests: passed")
        } catch {
            fputs("DirectScreenSnapshotProviderTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testDirectSymbolIsAvailable() throws {
        try require(DirectScreenSnapshotProvider.isDirectCaptureAvailable,
                    "CGWindowListCreateImage runtime symbol is unavailable")
    }

    private static func testPixelCropUsesActualImageSize() throws {
        let frame = CGRect(x: -900, y: 100, width: 900, height: 600)
        let selection = CGRect(x: -810, y: 220, width: 180, height: 150)
        let crop = CoordinateMath.pixelCropRect(globalSelection: selection,
                                                displayFrame: frame,
                                                imageSize: CGSize(width: 1800, height: 1200))
        try require(crop == CGRect(x: 180, y: 660, width: 360, height: 300),
                    "Unexpected mixed-origin crop: \(crop)")
    }

    private static func testFrozenScreenCrop() throws {
        let image = try solidImage(width: 400, height: 200, red: 0.2)
        let frozen = FrozenScreen(displayID: 7,
                                  frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                  image: image)
        let crop = frozen.crop(globalSelection: CGRect(x: 50, y: 25, width: 50, height: 25))
        try require(crop?.width == 100 && crop?.height == 50,
                    "Frozen crop ignored actual pixel dimensions")
    }

    private static func testProviderOwnsFreshImagesPerSession() async throws {
        let recorder = CaptureRecorder()
        let provider = DirectScreenSnapshotProvider { bounds in
            try recorder.capture(bounds: bounds)
        }
        let displays = [
            CaptureDisplay(id: 11,
                           frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                           quartzBounds: CGRect(x: 0, y: 0, width: 200, height: 100)),
            CaptureDisplay(id: 12,
                           frame: CGRect(x: -100, y: 0, width: 100, height: 100),
                           quartzBounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        ]

        let firstID = UUID()
        let secondID = UUID()
        let first = try await provider.capture(sessionID: firstID, displays: displays)
        let second = try await provider.capture(sessionID: secondID, displays: displays)

        try require(first.sessionID == firstID && second.sessionID == secondID,
                    "Provider changed session ownership")
        try require(Set(first.screens.map(\.displayID)) == Set([11, 12]),
                    "First batch lost a display")
        try require(Set(second.screens.map(\.displayID)) == Set([11, 12]),
                    "Second batch lost a display")
        try require(recorder.callCount == 4,
                    "Provider reused a previous frame; calls=\(recorder.callCount)")
    }

    private static func testAvailabilityCheckDoesNotCapturePixels() throws {
        let recorder = CaptureRecorder()
        _ = DirectScreenSnapshotProvider { bounds in
            try recorder.capture(bounds: bounds)
        }
        _ = DirectScreenSnapshotProvider.isDirectCaptureAvailable
        try require(recorder.callCount == 0,
                    "Backend availability must not perform a preparatory screenshot")
    }

    private static func testProviderFailsAtomically() async throws {
        let provider = DirectScreenSnapshotProvider { bounds in
            if bounds.minX < 0 {
                throw CaptureError.snapshotUnavailable("synthetic failure")
            }
            return try solidImage(width: 20, height: 20, red: 0.4)
        }
        let displays = [
            CaptureDisplay(id: 1,
                           frame: CGRect(x: 0, y: 0, width: 20, height: 20),
                           quartzBounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
            CaptureDisplay(id: 2,
                           frame: CGRect(x: -20, y: 0, width: 20, height: 20),
                           quartzBounds: CGRect(x: -20, y: 0, width: 20, height: 20))
        ]
        do {
            _ = try await provider.capture(sessionID: UUID(), displays: displays)
            throw TestFailure("Provider returned a partial batch")
        } catch CaptureError.snapshotUnavailable {
            return
        }
    }

    private static func testProviderSerializesCompositorRequests() async throws {
        let recorder = CaptureConcurrencyRecorder()
        let provider = DirectScreenSnapshotProvider { bounds in
            try recorder.capture(bounds: bounds)
        }
        let displays = (0..<4).map { index in
            CaptureDisplay(id: CGDirectDisplayID(index + 1),
                           frame: CGRect(x: index * 20, y: 0, width: 20, height: 20),
                           quartzBounds: CGRect(x: index * 20, y: 0, width: 20, height: 20))
        }

        async let first = provider.capture(sessionID: UUID(), displays: displays)
        async let second = provider.capture(sessionID: UUID(), displays: displays)
        let batches = try await [first, second]

        try require(batches.allSatisfy { $0.screens.map(\.displayID) == displays.map(\.id) },
                    "Serial provider changed display ordering")
        try require(recorder.maximumInFlight == 1,
                    "Compositor requests overlapped; max=\(recorder.maximumInFlight)")
        try require(batches.allSatisfy {
            $0.captureCompletedAt >= $0.captureStartedAt
                && $0.maximumDisplaySkew >= 0
        }, "Provider did not report batch timing")
    }

    private static func testProviderRejectsExcessiveDisplaySkew() async throws {
        let provider = DirectScreenSnapshotProvider(maximumAcceptedDisplaySkew: 0.001) { bounds in
            Thread.sleep(forTimeInterval: 0.004)
            return try solidImage(width: max(1, Int(bounds.width)),
                                  height: max(1, Int(bounds.height)),
                                  red: 0.2)
        }
        let displays = [
            CaptureDisplay(id: 31,
                           frame: CGRect(x: 0, y: 0, width: 20, height: 20),
                           quartzBounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
            CaptureDisplay(id: 32,
                           frame: CGRect(x: 20, y: 0, width: 20, height: 20),
                           quartzBounds: CGRect(x: 20, y: 0, width: 20, height: 20))
        ]
        do {
            _ = try await provider.capture(sessionID: UUID(), displays: displays)
            throw TestFailure("Provider accepted an out-of-contract display skew")
        } catch CaptureError.snapshotUnavailable {
            return
        }
    }

    private static func testCancellationDiscardsSynchronousResult() async throws {
        let provider = DirectScreenSnapshotProvider { bounds in
            Thread.sleep(forTimeInterval: 0.03)
            return try solidImage(width: max(1, Int(bounds.width)),
                                  height: max(1, Int(bounds.height)),
                                  red: 0.3)
        }
        let display = CaptureDisplay(id: 41,
                                     frame: CGRect(x: 0, y: 0, width: 20, height: 20),
                                     quartzBounds: CGRect(x: 0, y: 0, width: 20, height: 20))
        let task = Task {
            try await provider.capture(sessionID: UUID(), displays: [display])
        }
        try await Task.sleep(for: .milliseconds(2))
        task.cancel()
        do {
            _ = try await task.value
            throw TestFailure("Cancelled capture published its synchronous result")
        } catch is CancellationError {
            return
        }
    }

    private static func testDuplicateDisplaysFailBeforeCapture() async throws {
        let recorder = CaptureRecorder()
        let provider = DirectScreenSnapshotProvider { bounds in
            try recorder.capture(bounds: bounds)
        }
        let display = CaptureDisplay(id: 51,
                                     frame: CGRect(x: 0, y: 0, width: 20, height: 20),
                                     quartzBounds: CGRect(x: 0, y: 0, width: 20, height: 20))
        do {
            _ = try await provider.capture(sessionID: UUID(), displays: [display, display])
            throw TestFailure("Duplicate display identifiers were accepted")
        } catch CaptureError.snapshotUnavailable {
            try require(recorder.callCount == 0,
                        "Duplicate display validation ran after pixel capture")
        }
    }

    private static func testHundredFakeBackendLifecycles() async throws {
        let provider = DirectScreenSnapshotProvider { bounds in
            let index = Int(bounds.minX)
            if index % 13 == 0 {
                throw CaptureError.snapshotUnavailable("planned fake failure")
            }
            if index % 5 == 0 {
                Thread.sleep(forTimeInterval: 0.0005)
            }
            return try solidImage(width: 2, height: 2,
                                  red: CGFloat(index % 10) / 10)
        }

        let allPassed = await withTaskGroup(of: Bool.self,
                                            returning: Bool.self) { group in
            for index in 0..<100 {
                group.addTask {
                    if index % 3 == 0 {
                        await Task.yield()
                    }
                    let sessionID = UUID()
                    let display = CaptureDisplay(
                        id: CGDirectDisplayID(index + 1),
                        frame: CGRect(x: index, y: 0, width: 2, height: 2),
                        quartzBounds: CGRect(x: index, y: 0, width: 2, height: 2))
                    do {
                        let batch = try await provider.capture(
                            sessionID: sessionID,
                            displays: [display])
                        return index % 13 != 0
                            && batch.sessionID == sessionID
                            && batch.screens.map(\.displayID) == [display.id]
                    } catch CaptureError.snapshotUnavailable {
                        return index % 13 == 0
                    } catch {
                        return false
                    }
                }
            }

            for await passed in group where !passed {
                return false
            }
            return true
        }
        try require(allPassed,
                    "100 fake-backend lifecycles leaked, reordered, or misowned a result")
    }

    private static func solidImage(width: Int, height: Int, red: CGFloat) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure("Could not create test bitmap")
        }
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestFailure("Could not materialize test bitmap")
        }
        return image
    }

    private static func require(_ condition: @autoclosure () -> Bool,
                                _ message: @autoclosure () -> String) throws {
        if !condition() { throw TestFailure(message()) }
    }
}

private final class CaptureConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var maximum = 0

    var maximumInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func capture(bounds: CGRect) throws -> CGImage {
        lock.lock()
        inFlight += 1
        maximum = max(maximum, inFlight)
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.005)

        lock.lock()
        inFlight -= 1
        lock.unlock()
        return try makeImage(width: max(1, Int(bounds.width)),
                             height: max(1, Int(bounds.height)))
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            throw TestFailure("Could not make concurrency-test image")
        }
        return image
    }
}

private final class CaptureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func capture(bounds: CGRect) throws -> CGImage {
        lock.lock()
        calls += 1
        let generation = calls
        lock.unlock()
        return try makeImage(width: max(1, Int(bounds.width)),
                             height: max(1, Int(bounds.height)),
                             red: CGFloat(generation % 10) / 10)
    }

    private func makeImage(width: Int, height: Int, red: CGFloat) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure("Could not create recorder bitmap")
        }
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestFailure("Could not materialize recorder bitmap")
        }
        return image
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
