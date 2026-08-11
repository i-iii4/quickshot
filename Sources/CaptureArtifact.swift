import AppKit
import CoreGraphics
import ImageIO
import OSLog
import UniformTypeIdentifiers

struct CaptureImagePayload: @unchecked Sendable {
    let image: CGImage
}

@MainActor
final class CaptureArtifact {
    typealias Preparer = @Sendable (CaptureImagePayload, URL) -> Clipboard.PreparedImage

    let id: UUID
    let sequence: CaptureSequence
    let previewImage: CGImage
    let estimatedSourceBytes: Int
    let fileURL: URL

    private var sourceImage: CGImage?
    private var prepared: Clipboard.PreparedImage?
    private var preparationTask: Task<Clipboard.PreparedImage, Never>?
    private let preparer: Preparer

    fileprivate var hasCardLease = true
    fileprivate var hasClipboardLease = false
    fileprivate var pinLeaseCount = 0
    fileprivate var dragLeaseCount = 0

    init(sequence: CaptureSequence,
         image: CGImage,
         fileURL: URL,
         id: UUID = UUID(),
         preparer: @escaping Preparer = { payload, url in
             Clipboard.prepareImage(cgImage: payload.image, fileURL: url)
         }) {
        self.id = id
        self.sequence = sequence
        self.sourceImage = image
        self.previewImage = Self.makePreview(from: image)
        self.estimatedSourceBytes = image.bytesPerRow * image.height
        self.fileURL = fileURL
        self.preparer = preparer
    }

    var preparedImageIfReady: Clipboard.PreparedImage? { prepared }
    var isPreparing: Bool { preparationTask != nil && prepared == nil }
    var hasAnyLease: Bool {
        hasCardLease || hasClipboardLease || pinLeaseCount > 0 || dragLeaseCount > 0
    }

    func preparedImage() async -> Clipboard.PreparedImage {
        if let prepared { return prepared }
        if let preparationTask {
            let value = await preparationTask.value
            if prepared == nil { finishPreparation(value) }
            return value
        }
        guard let sourceImage else {
            return Clipboard.PreparedImage(png: nil, tiff: nil, fileURL: nil)
        }

        let payload = CaptureImagePayload(image: sourceImage)
        let fileURL = fileURL
        let preparer = preparer
        let task = Task.detached(priority: .userInitiated) {
            preparer(payload, fileURL)
        }
        preparationTask = task
        let value = await task.value
        finishPreparation(value)
        return value
    }

    func fullImage() -> CGImage? {
        if let sourceImage { return sourceImage }
        guard let png = prepared?.png,
              let source = CGImageSourceCreateWithData(png as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    fileprivate func removeOwnedFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func finishPreparation(_ value: Clipboard.PreparedImage) {
        guard prepared == nil else { return }
        prepared = value
        preparationTask = nil
        sourceImage = nil
    }

    private static func makePreview(from image: CGImage,
                                    maximumPixelDimension: Int = 1280) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maximumPixelDimension else { return image }

        let scale = CGFloat(maximumPixelDimension) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

@MainActor
final class CaptureArtifactDragPayload {
    let pasteboardWriter: any NSPasteboardWriting
    let usesFilePromise: Bool

    fileprivate let artifact: CaptureArtifact
    fileprivate var hasFinished = false

    fileprivate init(artifact: CaptureArtifact,
                     pasteboardWriter: any NSPasteboardWriting,
                     usesFilePromise: Bool) {
        self.artifact = artifact
        self.pasteboardWriter = pasteboardWriter
        self.usesFilePromise = usesFilePromise
    }
}

private final class CaptureArtifactPromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}

private final class CaptureArtifactFilePromiseDelegate: NSObject,
    NSFilePromiseProviderDelegate,
    @unchecked Sendable {
    typealias Prepare = @MainActor @Sendable () async -> Clipboard.PreparedImage

    private let promisedFileName: String
    private let prepare: Prepare

    @MainActor
    init(artifact: CaptureArtifact) {
        promisedFileName = "QuickShot-\(artifact.sequence.rawValue).png"
        prepare = { [artifact] in
            await artifact.preparedImage()
        }
        super.init()
    }

    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        promisedFileName
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = CaptureArtifactPromiseCompletion(completionHandler)
        let prepare = prepare
        Task { @MainActor in
            let prepared = await prepare()
            guard let png = prepared.png else {
                completion(NSError(
                    domain: "com.iiii.quickshot.drag",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Screenshot PNG is unavailable"]))
                return
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try png.write(to: url, options: .atomic)
                }.value
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}

@MainActor
final class CaptureArtifactStore {
    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "capture")
    struct Limits {
        let maximumCardCount: Int
        let maximumEstimatedBytes: Int

        static let production = Limits(maximumCardCount: 100,
                                       maximumEstimatedBytes: 1_073_741_824)
    }

    enum AdmissionError: Error, CustomStringConvertible {
        case countLimit(Int)
        case byteLimit(Int)
        case duplicateSequence(CaptureSequence)

        var description: String {
            switch self {
            case .countLimit(let maximum):
                return "Screenshot limit reached (\(maximum))"
            case .byteLimit(let maximum):
                return "Screenshot memory budget reached (\(maximum) bytes)"
            case .duplicateSequence(let sequence):
                return "Duplicate capture sequence \(sequence.rawValue)"
            }
        }
    }

    typealias ClipboardPublisher = @MainActor ([Clipboard.PreparedImage]) -> Void

    private let rootURL: URL
    private let limits: Limits
    private let preparer: CaptureArtifact.Preparer
    private let publishClipboard: ClipboardPublisher
    private var artifacts: [CaptureSequence: CaptureArtifact] = [:]
    private var deliveryState = CaptureDeliveryState()
    private var clipboardSequences: Set<CaptureSequence> = []
    private var startupPasteboardFiles: Set<URL>

    init(rootURL: URL = FileManager.default.temporaryDirectory
             .appendingPathComponent("QuickShotArtifacts", isDirectory: true),
         limits: Limits = .production,
         preparer: @escaping CaptureArtifact.Preparer = { payload, url in
             Clipboard.prepareImage(cgImage: payload.image, fileURL: url)
         },
         currentPasteboardFiles: () -> Set<URL> = {
             Set((NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
                 guard let value = item.string(forType: .fileURL) else { return nil }
                 return URL(string: value)?.standardizedFileURL
             })
         },
         publishClipboard: @escaping ClipboardPublisher = { prepared in
             Clipboard.copy(preparedImages: prepared)
         }) {
        self.rootURL = rootURL
        self.limits = limits
        self.preparer = preparer
        self.publishClipboard = publishClipboard
        self.startupPasteboardFiles = currentPasteboardFiles()
        prepareWorkingDirectory()
        removeCrashLeftovers()
    }

    var cardCount: Int {
        artifacts.values.filter(\.hasCardLease).count
    }

    var estimatedCardBytes: Int {
        artifacts.values.filter(\.hasCardLease).reduce(0) {
            $0 + $1.estimatedSourceBytes
        }
    }

    func registerCapture(_ sequence: CaptureSequence) {
        deliveryState.accept(sequence)
    }

    func admit(sequence: CaptureSequence, image: CGImage) throws -> CaptureArtifact {
        guard artifacts[sequence] == nil else {
            throw AdmissionError.duplicateSequence(sequence)
        }
        guard cardCount < limits.maximumCardCount else {
            throw AdmissionError.countLimit(limits.maximumCardCount)
        }
        let estimatedBytes = image.bytesPerRow * image.height
        guard estimatedCardBytes <= limits.maximumEstimatedBytes - estimatedBytes else {
            throw AdmissionError.byteLimit(limits.maximumEstimatedBytes)
        }

        let artifact = CaptureArtifact(
            sequence: sequence,
            image: image,
            fileURL: rootURL.appendingPathComponent("\(UUID().uuidString).png"),
            preparer: preparer)
        artifacts[sequence] = artifact
        beginAutomaticPreparation(of: artifact)
        return artifact
    }

    func markCaptureFailed(_ sequence: CaptureSequence) {
        if let commit = deliveryState.markFailed(sequence) {
            publishAutomaticClipboard(for: commit)
        }
        removeIfUnused(sequence)
    }

    func copy(_ artifact: CaptureArtifact, feedback: @escaping @MainActor () -> Void = {}) {
        Task { @MainActor [weak self, weak artifact] in
            guard let self, let artifact else { return }
            let prepared = await artifact.preparedImage()
            guard !prepared.isEmpty, self.artifacts[artifact.sequence] === artifact else { return }
            self.replaceClipboardLeases(with: [artifact])
            self.publishClipboard([prepared])
            feedback()
        }
    }

    func copyAll(_ requestedArtifacts: [CaptureArtifact],
                 feedback: @escaping @MainActor () -> Void = {}) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var retained: [CaptureArtifact] = []
            var prepared: [Clipboard.PreparedImage] = []
            for artifact in requestedArtifacts.sorted(by: { $0.sequence < $1.sequence }) {
                guard self.artifacts[artifact.sequence] === artifact else { continue }
                let value = await artifact.preparedImage()
                guard !value.isEmpty else { continue }
                retained.append(artifact)
                prepared.append(value)
            }
            guard !prepared.isEmpty else { return }
            self.replaceClipboardLeases(with: retained)
            self.publishClipboard(prepared)
            feedback()
        }
    }

    func beginDrag(of artifact: CaptureArtifact) -> CaptureArtifactDragPayload? {
        guard artifacts[artifact.sequence] === artifact else { return nil }

        let writer: any NSPasteboardWriting
        let usesFilePromise: Bool
        if let prepared = artifact.preparedImageIfReady {
            guard let item = Clipboard.pasteboardItem(preparedImage: prepared) else {
                return nil
            }
            writer = item
            usesFilePromise = false
        } else {
            let delegate = CaptureArtifactFilePromiseDelegate(artifact: artifact)
            let provider = NSFilePromiseProvider(
                fileType: UTType.png.identifier,
                delegate: delegate)
            // The provider's delegate is weak. Retain it for the complete
            // drag and destination-write lifecycle through userInfo.
            provider.userInfo = delegate
            writer = provider
            usesFilePromise = true
        }

        artifact.dragLeaseCount += 1
        Self.log.info(
            "capture drag payload ready sequence=\(artifact.sequence.rawValue, privacy: .public) mode=\(usesFilePromise ? "file-promise" : "direct", privacy: .public)")
        return CaptureArtifactDragPayload(
            artifact: artifact,
            pasteboardWriter: writer,
            usesFilePromise: usesFilePromise)
    }

    func finishDrag(_ payload: CaptureArtifactDragPayload) {
        guard !payload.hasFinished else { return }
        payload.hasFinished = true
        let artifact = payload.artifact
        artifact.dragLeaseCount = max(0, artifact.dragLeaseCount - 1)
        Self.log.info(
            "capture drag payload released sequence=\(artifact.sequence.rawValue, privacy: .public)")
        removeIfUnused(artifact.sequence)
    }

    func retainPin(_ artifact: CaptureArtifact) {
        guard artifacts[artifact.sequence] === artifact else { return }
        artifact.pinLeaseCount += 1
    }

    func releasePin(_ artifact: CaptureArtifact) {
        artifact.pinLeaseCount = max(0, artifact.pinLeaseCount - 1)
        removeIfUnused(artifact.sequence)
    }

    func releaseCard(_ artifact: CaptureArtifact) {
        artifact.hasCardLease = false
        removeIfUnused(artifact.sequence)
    }

    func shutdown() {
        deliveryState.invalidateAll()
        for artifact in artifacts.values {
            artifact.hasCardLease = false
            artifact.pinLeaseCount = 0
            artifact.dragLeaseCount = 0
        }
        for sequence in Array(artifacts.keys) {
            removeIfUnused(sequence)
        }
    }

    private func beginAutomaticPreparation(of artifact: CaptureArtifact) {
        Task { @MainActor [weak self, weak artifact] in
            guard let self, let artifact else { return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let prepared = await artifact.preparedImage()
            let prepareMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            guard self.artifacts[artifact.sequence] === artifact else {
                artifact.removeOwnedFile()
                return
            }
            if prepared.isEmpty {
                self.markCaptureFailed(artifact.sequence)
            } else if let commit = self.deliveryState.markReady(artifact.sequence) {
                self.publishAutomaticClipboard(for: commit)
            }
            Self.log.info("capture artifact prepared sequence=\(artifact.sequence.rawValue, privacy: .public) prepareMs=\(prepareMs, privacy: .public)")
            self.removeIfUnused(artifact.sequence)
        }
    }

    private func publishAutomaticClipboard(for sequence: CaptureSequence) {
        guard let artifact = artifacts[sequence],
              let prepared = artifact.preparedImageIfReady,
              !prepared.isEmpty else { return }
        replaceClipboardLeases(with: [artifact])
        publishClipboard([prepared])
        Self.log.info("capture clipboard copied sequence=\(sequence.rawValue, privacy: .public)")
        Self.log.info("capture delivery outcome=completed sequence=\(sequence.rawValue, privacy: .public)")
    }

    private func replaceClipboardLeases(with retained: [CaptureArtifact]) {
        let retainedSequences = Set(retained.map(\.sequence))
        for sequence in clipboardSequences.subtracting(retainedSequences) {
            artifacts[sequence]?.hasClipboardLease = false
            removeIfUnused(sequence)
        }
        for artifact in retained {
            artifact.hasClipboardLease = true
        }
        clipboardSequences = retainedSequences

        for url in startupPasteboardFiles where !retained.contains(where: {
            $0.fileURL.standardizedFileURL == url
        }) {
            try? FileManager.default.removeItem(at: url)
        }
        startupPasteboardFiles.removeAll()
    }

    private func removeIfUnused(_ sequence: CaptureSequence) {
        guard let artifact = artifacts[sequence], !artifact.hasAnyLease else { return }
        guard !artifact.isPreparing else { return }
        artifact.removeOwnedFile()
        artifacts.removeValue(forKey: sequence)
        clipboardSequences.remove(sequence)
    }

    private func prepareWorkingDirectory() {
        try? FileManager.default.createDirectory(at: rootURL,
                                                 withIntermediateDirectories: true)
    }

    private func removeCrashLeftovers() {
        let fileManager = FileManager.default
        if let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for url in urls where !startupPasteboardFiles.contains(url.standardizedFileURL) {
                try? fileManager.removeItem(at: url)
            }
        }

        let legacyRoot = fileManager.temporaryDirectory
        if let urls = try? fileManager.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for url in urls where url.lastPathComponent.hasPrefix("QuickShot-")
                && url.pathExtension.lowercased() == "png"
                && !startupPasteboardFiles.contains(url.standardizedFileURL) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
