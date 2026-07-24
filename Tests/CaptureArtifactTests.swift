import AppKit
import Foundation

private final class PreparationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class ClipboardRecorder {
    var publications: [[Clipboard.PreparedImage]] = []
}

@main
struct CaptureArtifactTests {
    @MainActor
    static func main() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShotArtifactTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = PreparationCounter()
        let recorder = ClipboardRecorder()
        let store = CaptureArtifactStore(
            rootURL: root,
            limits: .init(maximumCardCount: 1, maximumEstimatedBytes: 16 * 1024 * 1024),
            preparer: { payload, url in
                counter.increment()
                return Clipboard.prepareImage(cgImage: payload.image, fileURL: url)
            },
            currentPasteboardFiles: { [] },
            publishClipboard: { recorder.publications.append($0) })

        let firstSequence = CaptureSequence(rawValue: 1)
        store.registerCapture(firstSequence)
        let first = try! store.admit(sequence: firstSequence, image: makeImage(red: 1))
        _ = await first.preparedImage()
        await waitUntil { recorder.publications.count == 1 }
        require(counter.count == 1, "one artifact must encode exactly once")
        require(FileManager.default.fileExists(atPath: first.fileURL.path),
                "prepared artifact file must exist while leased")

        store.copy(first)
        await waitUntil { recorder.publications.count == 2 }
        require(counter.count == 1, "manual copy must reuse the prepared artifact")

        store.releaseCard(first)
        require(FileManager.default.fileExists(atPath: first.fileURL.path),
                "current pasteboard lease must retain a removed card file")

        let secondSequence = CaptureSequence(rawValue: 2)
        store.registerCapture(secondSequence)
        let second = try! store.admit(sequence: secondSequence, image: makeImage(red: 0))
        _ = await second.preparedImage()
        await waitUntil { recorder.publications.count == 3 }
        require(!FileManager.default.fileExists(atPath: first.fileURL.path),
                "superseding the pasteboard must remove an unleased old file")

        let thirdSequence = CaptureSequence(rawValue: 3)
        store.registerCapture(thirdSequence)
        do {
            _ = try store.admit(sequence: thirdSequence, image: makeImage(red: 0.5))
            fail("card budget must reject the third retained card")
        } catch CaptureArtifactStore.AdmissionError.countLimit {
            store.markCaptureFailed(thirdSequence)
        } catch {
            fail("unexpected budget error: \(error)")
        }

        store.releaseCard(second)
        store.shutdown()
        await testHundredArtifactResourceLifecycle()
        print("CaptureArtifactTests: passed")
    }

    @MainActor
    private static func testHundredArtifactResourceLifecycle() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShotArtifactStress-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = PreparationCounter()
        let recorder = ClipboardRecorder()
        let store = CaptureArtifactStore(
            rootURL: root,
            limits: .production,
            preparer: { _, url in
                counter.increment()
                let data = Data([0x51, 0x53])
                try? data.write(to: url, options: .atomic)
                return Clipboard.PreparedImage(png: data, tiff: nil, fileURL: url)
            },
            currentPasteboardFiles: { [] },
            publishClipboard: { recorder.publications.append($0) })

        var artifacts: [CaptureArtifact] = []
        for rawValue in 1...100 {
            let sequence = CaptureSequence(rawValue: UInt64(rawValue))
            store.registerCapture(sequence)
            do {
                artifacts.append(try store.admit(
                    sequence: sequence,
                    image: makeImage(red: CGFloat(rawValue) / 100)))
            } catch {
                fail("production budget rejected artifact \(rawValue): \(error)")
            }
        }

        for artifact in artifacts {
            _ = await artifact.preparedImage()
        }
        await waitUntil { counter.count == 100 }
        require(store.cardCount == 100, "stress store lost a retained card")
        require(store.estimatedCardBytes <= 1_073_741_824,
                "stress store exceeded the declared byte budget")

        let overflow = CaptureSequence(rawValue: 101)
        store.registerCapture(overflow)
        do {
            _ = try store.admit(sequence: overflow, image: makeImage(red: 0))
            fail("production card limit accepted artifact 101")
        } catch CaptureArtifactStore.AdmissionError.countLimit(let maximum) {
            require(maximum == 100, "production count limit changed unexpectedly")
            store.markCaptureFailed(overflow)
        } catch {
            fail("unexpected production budget error: \(error)")
        }

        artifacts.forEach(store.releaseCard)
        store.shutdown()
        let leasedFiles = directoryFileCount(root)
        require(leasedFiles <= 1,
                "shutdown left \(leasedFiles) files after all card leases ended")

        let cleanupStore = CaptureArtifactStore(
            rootURL: root,
            limits: .production,
            preparer: { _, _ in Clipboard.PreparedImage(png: nil,
                                                        tiff: nil,
                                                        fileURL: nil) },
            currentPasteboardFiles: { [] },
            publishClipboard: { _ in })
        cleanupStore.shutdown()
        require(directoryFileCount(root) == 0,
                "startup cleanup left an unleased artifact file")
    }

    private static func directoryFileCount(_ root: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]))?.count ?? 0
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        require(condition(), "asynchronous artifact operation timed out")
    }

    private static func makeImage(red: CGFloat) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: 32,
                                height: 32,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedRed: red, green: 0.25, blue: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("CaptureArtifactTests failed: \(message)\n", stderr)
        exit(1)
    }
}
