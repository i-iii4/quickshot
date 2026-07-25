import AppKit
import Foundation
import UniformTypeIdentifiers

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

private final class PreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func waitUntilReleased() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
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
        guard let readyDrag = store.beginDrag(of: first) else {
            fail("a prepared screenshot must start dragging")
        }
        require(!readyDrag.usesFilePromise,
                "a prepared screenshot must expose its direct image pasteboard item")
        guard let readyItem = readyDrag.pasteboardWriter as? NSPasteboardItem else {
            fail("a prepared screenshot must use NSPasteboardItem")
        }
        require(readyItem.types.contains(.png), "prepared drag item must contain PNG")
        require(readyItem.types.contains(.tiff), "prepared drag item must contain TIFF")
        require(readyItem.types.contains(.fileURL), "prepared drag item must contain a file URL")
        store.finishDrag(readyDrag)

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
        await testImmediateDragWhilePreparing()
        await testHundredArtifactResourceLifecycle()
        print("CaptureArtifactTests: passed")
    }

    @MainActor
    private static func testImmediateDragWhilePreparing() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShotImmediateDrag-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = PreparationGate()
        let counter = PreparationCounter()
        let store = CaptureArtifactStore(
            rootURL: root,
            preparer: { payload, url in
                counter.increment()
                gate.waitUntilReleased()
                return Clipboard.prepareImage(cgImage: payload.image, fileURL: url)
            },
            currentPasteboardFiles: { [] },
            publishClipboard: { _ in })

        let artifact = try! store.admit(
            sequence: CaptureSequence(rawValue: 41),
            image: makeImage(red: 0.4))
        await waitUntil { gate.hasStarted }

        guard let payload = store.beginDrag(of: artifact) else {
            fail("drag must begin while image preparation is still running")
        }
        require(payload.usesFilePromise,
                "an unprepared screenshot must use a non-blocking file promise")
        guard let provider = payload.pasteboardWriter as? NSFilePromiseProvider else {
            fail("unprepared drag must expose NSFilePromiseProvider")
        }
        require(provider.fileType == UTType.png.identifier,
                "file promise must advertise PNG")
        guard let delegate = provider.delegate else {
            fail("file promise delegate must remain retained")
        }
        require(delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
            .hasSuffix(".png"),
                "promised drag filename must use the PNG extension")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "QuickShotImmediateDrag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        require(pasteboard.writeObjects([provider]),
                "AppKit refused to publish the file promise")
        guard let receiver = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil)?.first as? NSFilePromiseReceiver else {
            fail("AppKit could not read the published file promise")
        }
        require(receiver.fileTypes == [UTType.png.identifier],
                "file-promise receiver did not preserve the PNG type")

        gate.release()
        let destination = root.appendingPathComponent("PromisedScreenshot.png")
        let promiseError: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(
                provider,
                writePromiseTo: destination,
                completionHandler: { error in
                    continuation.resume(returning: error)
                })
        }
        require(promiseError == nil, "file promise failed: \(String(describing: promiseError))")
        require(FileManager.default.fileExists(atPath: destination.path),
                "file promise did not write the dragged PNG")
        require((try? Data(contentsOf: destination).isEmpty) == false,
                "file promise wrote an empty PNG")
        require(counter.count == 1,
                "file promise must reuse automatic preparation instead of encoding again")

        store.releaseCard(artifact)
        require(FileManager.default.fileExists(atPath: artifact.fileURL.path),
                "active drag must retain the artifact after its card is removed")
        store.finishDrag(payload)
        require(!FileManager.default.fileExists(atPath: artifact.fileURL.path),
                "finishing the last drag lease must remove the source artifact file")
        store.finishDrag(payload)
        store.shutdown()
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
