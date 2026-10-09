import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A save owns a frozen, fully composited sheet. No editable source image is
/// read after preparation, and no animation frame is drawn with AppKit.
nonisolated enum StitchAnimationExporter {
    nonisolated enum Format: String, CaseIterable, Sendable {
        case mp4, gif
        var pathExtension: String { rawValue }
        var contentType: UTType { self == .mp4 ? .mpeg4Movie : .gif }
        var framesPerSecond: Int { self == .mp4 ? 30 : 20 }
    }

    nonisolated enum ExportError: LocalizedError {
        case invalidSnapshot, renderFailed, writerFailed, timedOut

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: return "The folded screenshot cannot be prepared for animation."
            case .renderFailed: return "A frame of the folded screenshot could not be rendered."
            case .writerFailed: return "The screenshot animation could not be written."
            case .timedOut: return "The screenshot animation stopped making progress."
            }
        }
    }

    /// Immutable geometry and pixels keep an export alive after its editor closes.
    nonisolated struct Plan: @unchecked Sendable {
        let width: Int
        let height: Int
        let source: StitchAccordionProjection.Source
        fileprivate let pixels: CGImage
        fileprivate let background: BeautifyRenderer.PaperBackground
        nonisolated(unsafe) fileprivate let videoSettings: [String: Any]

        var size: CGSize { CGSize(width: width, height: height) }
        var duration: Double { StitchAnimationExporter.duration }
    }

    static let duration: Double = 1.8

    /// Hold the flat sheet, reveal the fold, then hold the finished composition.
    static func foldProgress(at seconds: Double) -> CGFloat {
        guard seconds.isFinite else { return 0 }
        let t = max(0, min(1, (seconds - 0.25) / 0.9))
        return CGFloat(t * t * (3 - 2 * t))
    }

    @MainActor
    static func prepare(document: StitchDocument, presentation: ScreenshotPresentation.Prepared,
                        maxDimension: Int = 1600) throws -> Plan {
        guard maxDimension >= 2,
              let source = StitchAccordionProjection.Source(document: document),
              let projection = source.projection(), projection.hasProjectedOutput,
              presentation.projection?.hasProjectedOutput == true,
              presentation.projection?.documentBounds == source.documentBounds,
              presentation.sourceSize.width.isFinite, presentation.sourceSize.height.isFinite,
              presentation.sourceSize.width > 0, presentation.sourceSize.height > 0,
              abs(presentation.sourceSize.width / source.documentBounds.width
                  - presentation.sourceSize.height / source.documentBounds.height)
                <= max(presentation.sourceSize.width / source.documentBounds.width,
                       presentation.sourceSize.height / source.documentBounds.height) * 0.005,
              let background = presentation.paperBackground,
              background.contentSize == presentation.sourceSize,
              background.imageSize.width.isFinite, background.imageSize.height.isFinite,
              background.imageSize.width > 0, background.imageSize.height > 0,
              background.padding.isFinite, background.padding >= 0,
              [background.shadowRadius, background.shadowAlpha, background.shadowOffset,
               background.contactRadius, background.contactAlpha, background.contactOffset]
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw ExportError.invalidSnapshot }
        let limit = min(1600, maxDimension)
        let factor = min(1, CGFloat(limit) / CGFloat(max(background.pixels.width, background.pixels.height)))
        // One even canvas applies to every frame and both encoders. The rounding
        // is the usual subpixel aspect adjustment required by H.264 dimensions.
        let width = max(2, Int((CGFloat(background.pixels.width) * factor).rounded(.down)) / 2 * 2)
        let height = max(2, Int((CGFloat(background.pixels.height) * factor).rounded(.down)) / 2 * 2)
        return Plan(width: width, height: height, source: source, pixels: presentation.pixels,
                    background: background,
                    videoSettings: VideoEncodingSettings.outputSettings(width: width, height: height,
                        fps: Format.mp4.framesPerSecond, codec: .h264, quality: .high))
    }

    /// Call inside a MediaExportCoordinator job. Publication and cancellation
    /// share the same lock; a completed replacement cannot become a cancelled save.
    static func export(_ plan: Plan, to destination: URL, format: Format = .mp4,
                       cancellation: MediaExportCancellation = MediaExportCancellation(),
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            let work = try await MediaExportIO.perform { () throws -> Work in
                try cancellation.check()
                let save = try AtomicMediaSave(destinationURL: destination)
                return Work(save: save, frames: try FrameRenderer(plan: plan))
            }
            switch format {
            case .gif:
                try await MediaExportIO.perform {
                    try writeGIF(work, cancellation: cancellation, progress: progress)
                }
            case .mp4:
                let pump = try await MediaExportIO.perform {
                    try MoviePump(work: work, settings: plan.videoSettings,
                                  cancellation: cancellation, progress: progress)
                }
                try await pump.run()
            }
            try await MediaExportIO.perform {
                try cancellation.check()
                try work.save.commit(beforePublish: { try cancellation.beginPublication() })
                progress(1)
            }
        }, onCancel: { cancellation.cancel() })
    }

    private nonisolated struct Work: @unchecked Sendable {
        let save: AtomicMediaSave
        let frames: FrameRenderer
    }

    private static func writeGIF(_ work: Work, cancellation: MediaExportCancellation,
                                 progress: @escaping @Sendable (Double) -> Void) throws {
        try cancellation.check()
        let encoder = try GIFEncoder(url: work.save.stagingURL)
        let fps = Format.gif.framesPerSecond
        let count = Int((duration * Double(fps)).rounded())
        for index in 0..<count {
            try cancellation.check()
            try autoreleasepool {
                let time = CMTime(value: Int64(index), timescale: CMTimeScale(fps))
                let frame = try work.frames.frame(progress: foldProgress(at: time.seconds))
                let pixels = try pixelBuffer(for: frame)
                try cancellation.check()
                try encoder.addFrame(pixels, at: time)
            }
            progress(Double(index + 1) / Double(count) * 0.96)
        }
        try cancellation.check()
        try encoder.finish(at: CMTime(seconds: duration, preferredTimescale: 600))
    }

    /// A serial render queue owns this cache. Static holds reuse one frame; the
    /// next fold frame replaces it, so memory never grows with frame count.
    private nonisolated final class FrameRenderer: @unchecked Sendable {
        let source: StitchAccordionProjection.Source
        let texture: CGImage
        let background: BeautifyRenderer.PaperBackground
        nonisolated(unsafe) private var lastProgress: CGFloat?
        nonisolated(unsafe) private var lastFrame: CGImage?

        init(plan: Plan) throws {
            source = plan.source
            let factor = min(CGFloat(plan.width) / CGFloat(plan.background.pixels.width),
                             CGFloat(plan.height) / CGFloat(plan.background.pixels.height))
            let width = max(1, Int((CGFloat(plan.pixels.width) * factor).rounded()))
            let height = max(1, Int((CGFloat(plan.pixels.height) * factor).rounded()))
            texture = try resized(plan.pixels, width: width, height: height)
            let pixels = try resized(plan.background.pixels, width: plan.width, height: plan.height)
            let original = plan.background
            background = BeautifyRenderer.PaperBackground(pixels: pixels,
                imageSize: original.imageSize, contentSize: original.contentSize,
                padding: original.padding, shadowRadius: original.shadowRadius,
                shadowAlpha: original.shadowAlpha, shadowOffset: original.shadowOffset,
                contactRadius: original.contactRadius, contactAlpha: original.contactAlpha,
                contactOffset: original.contactOffset)
        }

        func frame(progress: CGFloat) throws -> CGImage {
            if progress == lastProgress, let lastFrame { return lastFrame }
            guard let projection = source.projection(progress: progress) else { throw ExportError.renderFailed }
            let sheet: CGImage
            if projection.hasProjectedOutput {
                guard let warped = StitchAccordionWarp.render(texture, projection: projection) else {
                    throw ExportError.renderFailed
                }
                sheet = warped
            } else { sheet = texture }
            guard let image = BeautifyRenderer.renderPaper(image: sheet, background: background) else {
                throw ExportError.renderFailed
            }
            lastProgress = progress
            lastFrame = image
            return image
        }
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        if width == image.width, height == image.height { return image }
        guard width > 0, height > 0, width <= 1600, height <= 1600,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.renderFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ExportError.renderFailed }
        return result
    }

    private static func pixelBuffer(for image: CGImage, pool: CVPixelBufferPool? = nil) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status: CVReturn
        if let pool { status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        else {
            status = CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        }
        guard status == kCVReturnSuccess, let buffer,
              CVPixelBufferGetWidth(buffer) == image.width, CVPixelBufferGetHeight(buffer) == image.height,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ExportError.renderFailed }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ExportError.renderFailed }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // MP4 and GIF are opaque. Even a transparent custom backdrop has a
        // defined matte, instead of undefined RGB under the paper cutouts.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return buffer
    }

    /// AssetWriter pulls frames only when its encoder is ready. Two-frame
    /// batches yield to cancellation and a watchdog on the same serial queue.
    private nonisolated final class MoviePump: @unchecked Sendable {
        private let queue = DispatchQueue(label: "macshot.stitch-animation", qos: .userInitiated)
        private let work: Work
        private let cancellation: MediaExportCancellation
        private let report: @Sendable (Double) -> Void
        nonisolated(unsafe) private let writer: AVAssetWriter
        nonisolated(unsafe) private let input: AVAssetWriterInput
        nonisolated(unsafe) private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        nonisolated(unsafe) private var continuation: CheckedContinuation<Void, Error>?
        nonisolated(unsafe) private var watchdog: DispatchSourceTimer?
        nonisolated(unsafe) private var frameIndex = 0
        nonisolated(unsafe) private var finishing = false
        nonisolated(unsafe) private var completed = false
        nonisolated(unsafe) private var scheduledDrain = false
        nonisolated(unsafe) private var lastActivity = ProcessInfo.processInfo.systemUptime

        init(work: Work, settings: [String: Any], cancellation: MediaExportCancellation,
             progress: @escaping @Sendable (Double) -> Void) throws {
            self.work = work
            self.cancellation = cancellation
            report = progress
            writer = try AVAssetWriter(outputURL: work.save.stagingURL, fileType: .mp4)
            writer.metadata = VideoFrameCadence.metadata(for: CMTime(value: 1, timescale: 30))
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.mediaTimeScale = 600
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: work.frames.background.pixels.width,
                    kCVPixelBufferHeightKey as String: work.frames.background.pixels.height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ])
            guard writer.canAdd(input) else { throw ExportError.writerFailed }
            writer.add(input)
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    do {
                        try self.cancellation.check()
                        guard self.writer.startWriting() else { throw self.writer.error ?? ExportError.writerFailed }
                        self.writer.startSession(atSourceTime: .zero)
                        self.lastActivity = ProcessInfo.processInfo.systemUptime
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                        timer.setEventHandler { [weak self] in self?.checkProgress() }
                        self.watchdog = timer
                        timer.resume()
                        self.input.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.drain() }
                    } catch { self.complete(.failure(error)) }
                }
            }
        }

        private func checkProgress() {
            guard !completed else { return }
            if cancellation.isCancelled { complete(.failure(CancellationError())) }
            else if writer.status == .failed { complete(.failure(writer.error ?? ExportError.writerFailed)) }
            else if ProcessInfo.processInfo.systemUptime - lastActivity > 60 {
                complete(.failure(ExportError.timedOut))
            }
        }

        private func drain() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !completed, !finishing else { return }
            do {
                let fps = Format.mp4.framesPerSecond
                let count = Int((duration * Double(fps)).rounded())
                var batch = 0
                while input.isReadyForMoreMediaData, !completed, batch < 2 {
                    try cancellation.check()
                    if frameIndex == count {
                        finishing = true
                        input.markAsFinished()
                        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
                        lastActivity = ProcessInfo.processInfo.systemUptime
                        writer.finishWriting { [weak self] in
                            guard let self else { return }
                            self.queue.async {
                                guard !self.completed else { return }
                                self.complete(self.writer.status == .completed ? .success(())
                                    : .failure(self.writer.error ?? ExportError.writerFailed))
                            }
                        }
                        return
                    }
                    try autoreleasepool {
                        let time = CMTime(value: Int64(frameIndex), timescale: CMTimeScale(fps))
                        let image = try work.frames.frame(progress: foldProgress(at: time.seconds))
                        let pixels = try pixelBuffer(for: image, pool: adaptor.pixelBufferPool)
                        try cancellation.check()
                        guard adaptor.append(pixels, withPresentationTime: time) else {
                            throw writer.error ?? ExportError.writerFailed
                        }
                    }
                    frameIndex += 1
                    batch += 1
                    lastActivity = ProcessInfo.processInfo.systemUptime
                    report(Double(frameIndex) / Double(count) * 0.96)
                }
                if input.isReadyForMoreMediaData, !completed, !scheduledDrain {
                    scheduledDrain = true
                    queue.async { [weak self] in
                        self?.scheduledDrain = false
                        self?.drain()
                    }
                }
            } catch { complete(.failure(error)) }
        }

        private func complete(_ result: Result<Void, Error>) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !completed else { return }
            completed = true
            watchdog?.cancel()
            watchdog = nil
            if case .failure = result, writer.status == .writing { writer.cancelWriting() }
            let callback = continuation
            continuation = nil
            callback?.resume(with: result)
        }
    }
}
