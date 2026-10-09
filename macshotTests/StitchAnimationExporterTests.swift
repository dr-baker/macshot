import AppKit
import AVFoundation
import ImageIO
import XCTest

@MainActor
final class StitchAnimationExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testAnimationCadenceHasStableEndpointsAndSmoothFold() {
        XCTAssertEqual(StitchAnimationExporter.duration, 1.8)
        XCTAssertEqual(StitchAnimationExporter.foldProgress(at: 0), 0)
        XCTAssertEqual(StitchAnimationExporter.foldProgress(at: 0.25), 0)
        XCTAssertEqual(StitchAnimationExporter.foldProgress(at: 0.7), 0.5, accuracy: 0.000001)
        XCTAssertEqual(StitchAnimationExporter.foldProgress(at: 1.15), 1, accuracy: 0.000001)
        XCTAssertEqual(StitchAnimationExporter.foldProgress(at: 1.8), 1)
        XCTAssertEqual(StitchAnimationExporter.Format.mp4.framesPerSecond, 30)
        XCTAssertEqual(StitchAnimationExporter.Format.gif.framesPerSecond, 20)
        let values = (0...180).map { StitchAnimationExporter.foldProgress(at: Double($0) / 100) }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertLessThan(values[26] - values[25], values[71] - values[70])
        XCTAssertEqual(StitchAnimationExporter.foldProgress(at: .nan), 0)
    }

    func testMP4EncodesAllFramesWithFixedDimensionsColorAndFinalFold() async throws {
        let fixture = try makeFixture()
        let output = directory.appendingPathComponent("paper.mp4")
        try await StitchAnimationExporter.export(fixture.plan, to: output)
        let asset = AVAsset(url: output)
        XCTAssertEqual(asset.duration.seconds, 1.8, accuracy: 1.0 / 600)
        XCTAssertTrue(asset.tracks(withMediaType: .audio).isEmpty)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, fixture.plan.size)
        XCTAssertEqual(track.nominalFrameRate, 30, accuracy: 0.01)
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(video)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = video.copyNextSampleBuffer() {
            let pixels = try XCTUnwrap(sample.imageBuffer)
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), fixture.plan.width)
            XCTAssertEqual(CVPixelBufferGetHeight(pixels), fixture.plan.height)
            count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, 54)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try generator.copyCGImage(at: .zero, actualTime: nil)
        let last = try generator.copyCGImage(at: CMTime(value: 53, timescale: 30), actualTime: nil)
        try assertEndpoints(first: first, last: last, fixture: fixture, tolerance: 0.09)
    }

    func testGIFStreamsCoalescedHoldsAndLoopsWithTheSameComposite() async throws {
        let fixture = try makeFixture()
        let output = directory.appendingPathComponent("paper.gif")
        try await StitchAnimationExporter.export(fixture.plan, to: output, format: .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        XCTAssertGreaterThan(count, 10)
        XCTAssertLessThan(count, 36, "Static endpoint holds are coalesced by the streaming GIF encoder")
        var delays: [Double] = []
        for index in 0..<count {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, fixture.plan.width)
            XCTAssertEqual(image.height, fixture.plan.height)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            delays.append(try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double))
        }
        XCTAssertEqual(delays.reduce(0, +), 1.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(delays.first), 0.30, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(delays.last), 0.65)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [String: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount as String] as? Int, 0)
        try assertEndpoints(first: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)),
            last: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, count - 1, nil)),
            fixture: fixture, tolerance: 0.07)
    }

    func testRetinaPointSizeKeepsPixelGeometryAndBackgroundPaddingInBothEncoders() async throws {
        let fixture = try makeFixture(sourceScale: 2)
        XCTAssertEqual(fixture.prepared.sourceSize, NSSize(width: 64, height: 48))
        XCTAssertEqual(fixture.plan.source.documentBounds.size, NSSize(width: 128, height: 96))
        XCTAssertEqual(fixture.plan.size, NSSize(width: 176, height: 144))
        for format in StitchAnimationExporter.Format.allCases {
            let output = directory.appendingPathComponent("retina." + format.pathExtension)
            try await StitchAnimationExporter.export(fixture.plan, to: output, format: format)
            let first: CGImage, last: CGImage
            if format == .gif {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetCount(source) - 1, nil))
            } else {
                let asset = AVAsset(url: output)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                first = try generator.copyCGImage(at: .zero, actualTime: nil)
                last = try generator.copyCGImage(at: CMTime(value: 53, timescale: 30), actualTime: nil)
            }
            XCTAssertEqual(first.width, 176)
            XCTAssertEqual(first.height, 144)
            try assertEndpoints(first: first, last: last, fixture: fixture, tolerance: 0.09)
        }
    }

    func testCancellationDuringBothEncodersPreservesExistingDestination() async throws {
        let fixture = try makeFixture()
        let original = Data("The user's previous export".utf8)
        for format in StitchAnimationExporter.Format.allCases {
            let output = directory.appendingPathComponent("existing." + format.pathExtension)
            try original.write(to: output)
            let cancellation = MediaExportCancellation()
            do {
                try await StitchAnimationExporter.export(fixture.plan, to: output, format: format,
                    cancellation: cancellation, progress: { fraction in
                        if fraction > 0.35 { cancellation.cancel() }
                    })
                XCTFail("A cancelled animation was published")
            } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertEqual(try Data(contentsOf: output), original)
            XCTAssertTrue(cancellation.isCancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["existing.gif", "existing.mp4"], "Staging frames and partial movies stay outside the destination folder")
    }

    func testPlanIsBoundedAndIndependentOfLaterEditorChanges() async throws {
        var fixture = try makeFixture(maxDimension: 96)
        XCTAssertLessThanOrEqual(max(fixture.plan.width, fixture.plan.height), 96)
        XCTAssertEqual(fixture.plan.width % 2, 0)
        XCTAssertEqual(fixture.plan.height % 2, 0)
        fixture.document.style.accordionWidth = 0
        fixture.document.style.accordionPerspective = 0
        fixture.document.pieces.removeAll()
        let output = directory.appendingPathComponent("frozen.gif")
        try await StitchAnimationExporter.export(fixture.plan, to: output, format: .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 10)
        let final = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetCount(source) - 1, nil))
        XCTAssertEqual(final.width, fixture.plan.width)
        XCTAssertEqual(final.height, fixture.plan.height)
        let background = try color(final, x: 1, y: 1)
        XCTAssertGreaterThan(background.blueComponent, 0.75)
        XCTAssertLessThan(background.redComponent, 0.15)
    }

    func testCompletedAtomicReplacementCannotBeReportedAsCancelled() async throws {
        let fixture = try makeFixture()
        let output = directory.appendingPathComponent("replacement.gif")
        try Data("Previous export".utf8).write(to: output)
        let cancellation = MediaExportCancellation()
        try await StitchAnimationExporter.export(fixture.plan, to: output, format: .gif,
            cancellation: cancellation, progress: { fraction in
                if fraction == 1 { XCTAssertFalse(cancellation.cancel()) }
            })
        XCTAssertFalse(cancellation.isCancelled)
        XCTAssertFalse(cancellation.canCancel)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 10)
    }

    func testInvalidOrUndecoratedSnapshotsFailBeforeCreatingOutput() throws {
        let fixture = try makeFixture()
        let raw = ScreenshotPresentation.Prepared(pixels: fixture.prepared.pixels,
            sourceSize: fixture.prepared.sourceSize, projection: fixture.prepared.projection,
            cornerRadius: 0, paperBackground: nil)
        XCTAssertThrowsError(try StitchAnimationExporter.prepare(document: fixture.document, presentation: raw))
        var other = fixture.document
        other.style.transition = .wave
        XCTAssertThrowsError(try StitchAnimationExporter.prepare(document: other, presentation: fixture.prepared))
        XCTAssertThrowsError(try StitchAnimationExporter.prepare(document: fixture.document,
            presentation: fixture.prepared, maxDimension: 0))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testExportParticipatesInCoordinatorDrainAfterEditorStateIsReleased() async throws {
        var fixture: Fixture? = try makeFixture()
        let plan = try XCTUnwrap(fixture).plan
        fixture = nil
        let coordinator = MediaExportCoordinator()
        let output = directory.appendingPathComponent("outliving-editor.gif")
        var result: Result<Void, Error>?
        coordinator.start(title: "paper", status: "Exporting", operation: { cancellation, report in
            try await StitchAnimationExporter.export(plan, to: output, format: .gif,
                                                      cancellation: cancellation, progress: report)
        }, completion: { result = $0 })
        XCTAssertTrue(coordinator.hasActiveJobs)
        await coordinator.waitUntilIdle()
        try XCTUnwrap(result).get()
        XCTAssertFalse(coordinator.hasActiveJobs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    private struct Fixture {
        var document: StitchDocument
        let prepared: ScreenshotPresentation.Prepared
        let plan: StitchAnimationExporter.Plan
    }

    private func makeFixture(maxDimension: Int = 1600, sourceScale: CGFloat = 1) throws -> Fixture {
        // The editable document contains green pixels; the provided composite
        // contains white paper and black redaction. Export must use the latter.
        let raw = ImageProbe.solidImage(width: 128, height: 112,
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        var style = StitchStyle()
        style.transition = .accordion
        style.accordionWidth = 12
        let rawPixels = try XCTUnwrap(raw.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: rawPixels)], style: style)
        XCTAssertTrue(document.collapse(axis: StitchAxis.horizontal, from: 40, to: 56))
        let composite = ImageProbe.makeImage(width: 128, height: 96) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 49, y: 31, width: 30, height: 34))
            context.setFillColor(CGColor(srgbRed: 1, green: 0.05, blue: 0.05, alpha: 1))
            context.fill(CGRect(x: 10, y: 66, width: 24, height: 20))
        }
        composite.size = NSSize(width: 128 / sourceScale, height: 96 / sourceScale)
        let backdrop = ImageProbe.solidImage(width: 20, height: 20,
            color: CGColor(srgbRed: 0.04, green: 0.14, blue: 0.9, alpha: 1))
        let config = BeautifyConfig(mode: .window, padding: 150, cornerRadius: 70,
            shadowRadius: 100, bgRadius: 80, customBackgroundImage: backdrop)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let prepared = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection).prepare(composite))
        let plan = try StitchAnimationExporter.prepare(document: document, presentation: prepared,
                                                       maxDimension: maxDimension)
        return Fixture(document: document, prepared: prepared, plan: plan)
    }

    private func assertEndpoints(first: CGImage, last: CGImage, fixture: Fixture, tolerance: CGFloat) throws {
        XCTAssertEqual(first.width, last.width)
        XCTAssertEqual(first.height, last.height)
        for image in [first, last] {
            let backdrop = try color(image, x: 1, y: 1)
            XCTAssertEqual(backdrop.blueComponent, 0.9, accuracy: tolerance)
            XCTAssertEqual(backdrop.redComponent, 0.04, accuracy: tolerance)
            XCTAssertEqual(backdrop.alphaComponent, 1, accuracy: 0.001)
        }
        let projection = try XCTUnwrap(fixture.plan.source.projection())
        let folded = try XCTUnwrap(projection.project(CGPoint(x: 64, y: 48)))
        let background = try XCTUnwrap(fixture.prepared.paperBackground)
        let scaleX = CGFloat(first.width) / background.imageSize.width
        let scaleY = CGFloat(first.height) / background.imageSize.height
        let paperScaleX = fixture.prepared.sourceSize.width / projection.documentBounds.width
        let paperScaleY = fixture.prepared.sourceSize.height / projection.documentBounds.height
        let firstMark = try color(first, x: Int((64 * paperScaleX + background.padding) * scaleX),
                                  y: Int((48 * paperScaleY + background.padding) * scaleY))
        let lastMark = try color(last, x: Int((folded.x * paperScaleX + background.padding) * scaleX),
                                 y: Int((folded.y * paperScaleY + background.padding) * scaleY))
        for mark in [firstMark, lastMark] {
            XCTAssertLessThan(mark.redComponent, tolerance + 0.03)
            XCTAssertLessThan(mark.greenComponent, tolerance + 0.03,
                              "Raw green source pixels must never replace the composited redaction")
            XCTAssertLessThan(mark.blueComponent, tolerance + 0.03)
        }
        let blankPaper = try color(first, x: Int((110 * paperScaleX + background.padding) * scaleX),
                                   y: Int((24 * paperScaleY + background.padding) * scaleY))
        XCTAssertGreaterThan(blankPaper.redComponent, 1 - tolerance)
        // The unwarped lower-right content corner becomes background under a
        // tilted silhouette; independent decoding must show that actual warp.
        let clearCorner = try color(last, x: Int((127 * paperScaleX + background.padding) * scaleX),
                                   y: Int((95 * paperScaleY + background.padding) * scaleY))
        XCTAssertGreaterThan(clearCorner.blueComponent, clearCorner.redComponent + 0.4)
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.colorAt(x: min(image.width - 1, max(0, x)),
                                       y: min(image.height - 1, max(0, y))))
    }
}
