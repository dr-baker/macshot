import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class StitchAnimationExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testAnimationCadenceHasStableEndpointsAndSmoothExpansion() {
        XCTAssertEqual(StitchAnimationExporter.duration, 1.8)
        XCTAssertEqual(StitchAnimationExporter.expansionProgress(at: 0), 0)
        XCTAssertEqual(StitchAnimationExporter.expansionProgress(at: 0.25), 0)
        XCTAssertEqual(StitchAnimationExporter.expansionProgress(at: 0.7), 0.5, accuracy: 0.000001)
        XCTAssertEqual(StitchAnimationExporter.expansionProgress(at: 1.15), 1, accuracy: 0.000001)
        XCTAssertEqual(StitchAnimationExporter.expansionProgress(at: 1.8), 1)
        XCTAssertEqual(StitchAnimationExporter.Format.mp4.framesPerSecond, 30)
        XCTAssertEqual(StitchAnimationExporter.Format.gif.framesPerSecond, 20)
        let values = (0...180).map { StitchAnimationExporter.expansionProgress(at: Double($0) / 100) }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertLessThan(values[26] - values[25], values[71] - values[70])
        XCTAssertEqual(StitchAnimationExporter.expansionProgress(at: .nan), 0)
    }

    /// Opt-in visual audit artifacts. Normal tests do not write outside their
    /// temporary fixture directory or spend time encoding this larger sheet.
    func testDiagnosticExpansionExportsForVisualAudit() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MACSHOT_ANIMATION_PREVIEW_DIR"]
            ?? environment["TEST_RUNNER_MACSHOT_ANIMATION_PREVIEW_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MACSHOT_ANIMATION_PREVIEW_DIR to render the expansion audit fixture")
        }
        let target = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let plan = try diagnosticPlan()
        let movie = target.appendingPathComponent("accordion-expansion.mp4")
        try await StitchAnimationExporter.export(plan, to: movie, format: .mp4)
        try await StitchAnimationExporter.export(plan,
            to: target.appendingPathComponent("accordion-expansion.gif"), format: .gif)
        let asset = AVAsset(url: movie)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for index in [0, 8, 12, 16, 21, 26, 32, 35, 53] {
            let image = try generator.copyCGImage(at: CMTime(value: Int64(index), timescale: 30), actualTime: nil)
            XCTAssertEqual(image.width, plan.width)
            XCTAssertEqual(image.height, plan.height)
            let url = target.appendingPathComponent(String(format: "accordion-frame-%02d.png", index))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
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
        XCTAssertEqual(fixture.plan.source.unfoldedBounds.size, NSSize(width: 128, height: 112))
        let expected = NSSize(
            width: Int(fixture.plan.outputBounds.width + 48) / 2 * 2,
            height: Int(fixture.plan.outputBounds.height + 48) / 2 * 2)
        XCTAssertEqual(fixture.plan.size, expected)
        XCTAssertGreaterThan(fixture.plan.height, 144,
                             "The expanded paper keeps a physical footprint beyond the compact texture")
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
            XCTAssertEqual(first.width, fixture.plan.width)
            XCTAssertEqual(first.height, fixture.plan.height)
            try assertEndpoints(first: first, last: last, fixture: fixture, tolerance: 0.09)
        }
    }

    func testFixedEnvelopeContainsEveryExportedSilhouetteWithLargeRemovedBands() throws {
        let fixture = try makeFixture(removedLength: 220, perspective: 30, yaw: -35)
        let plan = fixture.plan
        XCTAssertEqual(plan.source.unfoldedBounds.height, 316)
        let first = try XCTUnwrap(plan.source.expandingProjection(progress: 0))
        XCTAssertTrue(first.hasProjectedOutput)
        XCTAssertEqual(first.outputBounds, plan.source.documentBounds)
        for format in StitchAnimationExporter.Format.allCases {
            let fps = format.framesPerSecond
            let count = Int((plan.duration * Double(fps)).rounded())
            for index in 0..<count {
                let progress = StitchAnimationExporter.expansionProgress(at: Double(index) / Double(fps))
                let projection = try XCTUnwrap(plan.source.expandingProjection(progress: progress))
                XCTAssertTrue(plan.outputBounds.contains(projection.outputBounds),
                              "Frame \(index) of \(format.rawValue) must retain its silhouette")
                XCTAssertNotNil(projection.withOutputBounds(plan.outputBounds))
            }
        }
        let final = try XCTUnwrap(plan.source.expandingProjection(progress: 1))
        XCTAssertGreaterThan(final.outputBounds.height, first.outputBounds.height,
                             "The sheet opens from its compact image into the physical pleats")
    }

    func testOpeningStartsCompactThenRevealsSafePrintedPaperAtItsPhysicalSize() async throws {
        let fixture = try makeFixture(perspective: 0, yaw: 0)
        let output = directory.appendingPathComponent("expansion.gif")
        try await StitchAnimationExporter.export(fixture.plan, to: output, format: .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let projection = try XCTUnwrap(fixture.plan.source.expandingProjection(progress: 0))
        let start = try XCTUnwrap(projection.project(CGPoint(x: 20, y: 15)))
        let end = try XCTUnwrap(projection.project(CGPoint(x: 40, y: 35)))
        let rasterStart = framePoint(start, image: frame, fixture: fixture)
        let rasterEnd = framePoint(end, image: frame, fixture: fixture)
        XCTAssertEqual(rasterEnd.x - rasterStart.x, 20, accuracy: 0.3)
        XCTAssertEqual(rasterEnd.y - rasterStart.y, 20, accuracy: 0.3)

        let before = try XCTUnwrap(projection.project(CGPoint(x: 110, y: 39.999)))
        let after = try XCTUnwrap(projection.project(CGPoint(x: 110, y: 40.001)))
        XCTAssertEqual(after.y - before.y, 0.002, accuracy: 0.001,
                       "The removed paper begins edge-on instead of showing a full unfolded sheet")
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetCount(source) - 1, nil))
        let final = try XCTUnwrap(fixture.plan.source.expandingProjection(progress: 1))
        let finalBefore = try XCTUnwrap(final.project(CGPoint(x: 110, y: 39.999)))
        let finalAfter = try XCTUnwrap(final.project(CGPoint(x: 110, y: 40.001)))
        XCTAssertEqual(finalAfter.y - finalBefore.y, 16 * 0.45 + 0.002, accuracy: 0.001)
        let visiblePaper = try XCTUnwrap(final.faces.first { face in
            guard face.paperSample != nil, face.isFrontFacing else { return false }
            let center = CGPoint(x: face.vertices.map(\.rest.x).reduce(0, +) / 3,
                y: face.vertices.map(\.rest.y).reduce(0, +) / 3)
            guard let projected = face.projectRest(center), let hit = final.unproject(projected) else { return false }
            return abs(hit.y - 40) < 0.001
        })
        let center = CGPoint(x: visiblePaper.vertices.map(\.rest.x).reduce(0, +) / 3,
            y: visiblePaper.vertices.map(\.rest.y).reduce(0, +) / 3)
        let paperPoint = framePoint(try XCTUnwrap(visiblePaper.projectRest(center)), image: last, fixture: fixture)
        let paper = try color(last, x: Int(paperPoint.x), y: Int(paperPoint.y))
        XCTAssertGreaterThan(paper.redComponent, 0.65)
        XCTAssertGreaterThan(paper.greenComponent, 0.65)
        XCTAssertGreaterThan(paper.blueComponent, 0.65,
                             "The pleats reveal the sanitized white cut texture, never the raw green source")
        try assertEndpoints(first: frame, last: last, fixture: fixture, tolerance: 0.07)
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

    private func diagnosticPlan() throws -> StitchAnimationExporter.Plan {
        let image = ImageProbe.makeImage(width: 720, height: 960) { context in
            context.translateBy(x: 0, y: 960)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 960))
            context.setFillColor(CGColor(srgbRed: 0.10, green: 0.13, blue: 0.22, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 80))
            context.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1))
            context.fill(CGRect(x: 50, y: 28, width: 270, height: 12))
            let palette = [CGColor(srgbRed: 0.34, green: 0.58, blue: 0.95, alpha: 1),
                           CGColor(srgbRed: 0.93, green: 0.42, blue: 0.55, alpha: 1),
                           CGColor(srgbRed: 0.35, green: 0.71, blue: 0.61, alpha: 1)]
            for row in 0..<12 {
                let y = CGFloat(100 + row * 64)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.addPath(CGPath(roundedRect: CGRect(x: 50, y: y, width: 620, height: 56),
                    cornerWidth: 7, cornerHeight: 7, transform: nil))
                context.fillPath()
                context.setFillColor(palette[row % palette.count])
                context.fill(CGRect(x: 50, y: y + 8, width: 4, height: 40))
                context.fillEllipse(in: CGRect(x: 616, y: y + 15, width: 24, height: 24))
                context.setFillColor(CGColor(srgbRed: 0.17, green: 0.20, blue: 0.28, alpha: 1))
                context.fill(CGRect(x: 72, y: y + 12, width: CGFloat(180 + row * 13), height: 6))
                context.setFillColor(CGColor(srgbRed: 0.58, green: 0.62, blue: 0.69, alpha: 1))
                context.fill(CGRect(x: 72, y: y + 28, width: 490, height: 4))
                context.fill(CGRect(x: 72, y: y + 38, width: CGFloat(370 + row * 5), height: 4))
            }
            // A sanitized redaction inside the omitted strip makes any unsafe
            // replacement of its preserved printed pixels visible in the audit.
            context.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1))
            context.fill(CGRect(x: 250, y: 390, width: 150, height: 45))
        }
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 220, to: 650, texture: pixels))
        document.style.transition = .accordion
        document.style.accordionPerspective = 18
        document.style.accordionYaw = -14
        let compact = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        let background = ImageProbe.solidImage(width: 24, height: 24,
            color: CGColor(srgbRed: 0.045, green: 0.06, blue: 0.10, alpha: 1))
        let config = BeautifyConfig(customBackgroundImage: background)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let prepared = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection).prepare(compact))
        return try StitchAnimationExporter.prepare(document: document, presentation: prepared)
    }

    private func makeFixture(maxDimension: Int = 1600, sourceScale: CGFloat = 1,
                             removedLength: Int = 16,
                             perspective: CGFloat = StitchPaperCamera.defaultPerspective,
                             yaw: CGFloat = StitchPaperCamera.defaultYaw) throws -> Fixture {
        // The editable document contains green pixels; the provided composite
        // contains white paper and black redaction. Export must use the latter.
        let raw = ImageProbe.solidImage(width: 128, height: 96 + removedLength,
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        var style = StitchStyle()
        style.transition = .accordion
        style.accordionWidth = 12
        style.accordionPerspective = perspective
        style.accordionYaw = yaw
        let rawPixels = try XCTUnwrap(raw.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: rawPixels)], style: style)
        let safeCut = ImageProbe.solidImage(width: 128, height: 96 + removedLength,
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertTrue(document.collapse(axis: StitchAxis.horizontal, from: 40, to: CGFloat(40 + removedLength),
            texture: try XCTUnwrap(safeCut.cgImage(forProposedRect: nil, context: nil, hints: nil))))
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
        let compactProjection = try XCTUnwrap(fixture.plan.source.expandingProjection(progress: 0))
        let foldedProjection = try XCTUnwrap(fixture.plan.source.expandingProjection(progress: 1))
        let unfolded = try XCTUnwrap(compactProjection.project(CGPoint(x: 64, y: 48)))
        let folded = try XCTUnwrap(foldedProjection.project(CGPoint(x: 64, y: 48)))
        let firstPoint = framePoint(unfolded, image: first, fixture: fixture)
        let lastPoint = framePoint(folded, image: last, fixture: fixture)
        let firstMark = try color(first, x: Int(firstPoint.x), y: Int(firstPoint.y))
        let lastMark = try color(last, x: Int(lastPoint.x), y: Int(lastPoint.y))
        for mark in [firstMark, lastMark] {
            XCTAssertLessThan(mark.redComponent, tolerance + 0.03)
            XCTAssertLessThan(mark.greenComponent, tolerance + 0.03,
                              "Raw green source pixels must never replace the composited redaction")
            XCTAssertLessThan(mark.blueComponent, tolerance + 0.03)
        }
        let blank = try XCTUnwrap(compactProjection.project(CGPoint(x: 110, y: 24)))
        let blankPoint = framePoint(blank, image: first, fixture: fixture)
        let blankPaper = try color(first, x: Int(blankPoint.x), y: Int(blankPoint.y))
        XCTAssertGreaterThan(blankPaper.redComponent, 1 - tolerance)
        if fixture.plan.source.camera.perspective != 0 || fixture.plan.source.camera.yaw != 0 {
            let bounds = foldedProjection.outputBounds.insetBy(dx: 0.5, dy: 0.5)
            let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                           CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            let corner = try XCTUnwrap(corners.first { foldedProjection.unproject($0) == nil })
            let cornerPoint = framePoint(corner, image: last, fixture: fixture)
            let clearCorner = try color(last, x: Int(cornerPoint.x), y: Int(cornerPoint.y))
            XCTAssertGreaterThan(clearCorner.blueComponent, clearCorner.redComponent + 0.4,
                                 "The rotated alpha silhouette must show the selected background")
        }
    }

    private func framePoint(_ point: CGPoint, image: CGImage, fixture: Fixture) -> CGPoint {
        let bounds = fixture.plan.outputBounds
        let compact = fixture.plan.source.documentBounds
        let pointScaleX = fixture.prepared.sourceSize.width / compact.width
        let pointScaleY = fixture.prepared.sourceSize.height / compact.height
        let padding = ScreenshotPresentation.paperPadding
        let canvasWidth = bounds.width * pointScaleX + padding * 2
        let canvasHeight = bounds.height * pointScaleY + padding * 2
        return CGPoint(
            x: ((point.x - bounds.minX) * pointScaleX + padding) * CGFloat(image.width) / canvasWidth,
            y: ((point.y - bounds.minY) * pointScaleY + padding) * CGFloat(image.height) / canvasHeight)
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.colorAt(x: min(image.width - 1, max(0, x)),
                                       y: min(image.height - 1, max(0, y))))
    }
}
