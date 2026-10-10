import Cocoa
import XCTest
import ImageIO

/// Opt-in stage and key-to-readable-pasteboard benchmark.
/// Run with TEST_RUNNER_MACSHOT_CLIPBOARD_BENCHMARK=1 in the same configuration for both revisions.
final class ClipboardLatencyTests: XCTestCase {
    @MainActor func testStageBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MACSHOT_CLIPBOARD_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in clipboard benchmark")
        }
        try withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for (name, width, height, annotated, beautify, effects) in [
                ("ordinary", 1920, 1080, false, false, false),
                ("retina", 6016, 3384, false, false, false),
                ("redacted", 3840, 2160, true, false, false),
                ("beautify", 3840, 2160, true, true, true),
                ("accordion", 3840, 2160, true, true, false),
            ] {
                let source = try fixture(width: width, height: height)
                let view = EditorView(frame: CGRect(origin: .zero, size: source.size))
                view.screenshotImage = source
                view.applySelection(view.bounds)
                view.showToolbars = false
                if annotated {
                    let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 40, y: 40),
                        endPoint: CGPoint(x: 400, y: 160), color: .black, strokeWidth: 2)
                    view.annotations = [redaction]
                }
                let board = NSPasteboard(name: .init("macshot.benchmark.\(UUID().uuidString)"))
                defer { board.releaseGlobally() }
                var projection: StitchAccordionProjection?
                if name == "accordion" {
                    let pixels = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
                    XCTAssertTrue(document.collapse(axis: .horizontal, from: 300, to: 500))
                    document.style.transition = .accordion
                    projection = try XCTUnwrap(StitchAccordionProjection(document: document))
                }
                var samples: [[Double]] = []
                for iteration in 0..<6 {
                    try autoreleasepool {
                        var times: [Double] = []
                        func stage<T>(_ work: () throws -> T) rethrows -> T {
                            let start = ProcessInfo.processInfo.systemUptime
                            let value = try work()
                            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                            return value
                        }
                        var output = try stage { try XCTUnwrap(view.captureSelectedRegion()) }
                        output = stage { effects ? ImageEffects.apply(to: output, config: ImageEffectsConfig(preset: .vivid)) : output }
                        output = try stage { try XCTUnwrap(ScreenshotPresentation(beautify: beautify ? BeautifyConfig() : nil, projection: projection).render(output)) }
                        let prepared = try stage { try ImageEncoder.PreparedImage(output) }
                        let pixels = try prepared.pixelsForEncoding()
                        _ = stage { ImageEncoder.encodeClipboardPNG(pixels) }
                        _ = stage { ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.tiff", lossyQuality: nil) }
                        let representations = ImageEncoder.clipboardRepresentations(for: prepared, includeConfiguredFormat: false)
                        stage { ImageEncoder.writeImagePasteboard(board, representations: representations) }
                        _ = try stage { try HistoryImageSnapshot(image: output, rawImage: annotated ? source : nil,
                            annotations: annotated ? view.annotations : nil, editState: nil) }
                        if iteration > 0 { samples.append(times) }
                    }
                }
                let medians = (0..<samples[0].count).map { column in samples.map { $0[column] }.sorted()[2] }
                print("CLIPBOARD_BENCH \(name) capture,effects,beautify,snapshot,png,tiff,write,history(ms)=\(medians.map { String(format: "%.2f", $0) }.joined(separator: ","))")
                view.reset()
            }
        }
    }

    @MainActor func testKeyToReadablePasteboardBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MACSHOT_CLIPBOARD_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in clipboard benchmark")
        }
        for (name, width, height, annotated, framed) in [
            ("ordinary", 1920, 1080, false, false),
            ("retina", 6016, 3384, false, false),
            ("redacted", 3840, 2160, true, false),
            ("beautify", 3840, 2160, true, true),
            ("accordion", 3840, 2160, true, true),
        ] {
            let source = try fixture(width: width, height: height)
            let view = EditorView(frame: CGRect(origin: .zero, size: source.size))
            view.screenshotImage = source
            view.applySelection(view.bounds)
            view.showToolbars = false
            view.effectsPreset = name == "beautify" ? .vivid : .none
            view.effectsBrightness = 0
            view.effectsContrast = 1
            view.effectsSaturation = 1
            view.effectsSharpness = 0
            view.beautifyEnabled = framed
            view.beautifyStyleIndex = 0
            if name == "accordion" {
                var document = StitchDocument(pieces: [StitchPiece(image: try XCTUnwrap(
                    source.cgImage(forProposedRect: nil, context: nil, hints: nil)))])
                XCTAssertTrue(document.collapse(axis: .horizontal, from: 600, to: 1000))
                document.style.transition = .accordion
                view.installStitchDocument(document)
            }
            if annotated {
                view.annotations = [Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 40, y: 40),
                    endPoint: CGPoint(x: 400, y: 160), color: .black, strokeWidth: 2)]
            }
            let board = NSPasteboard(name: .init("macshot.benchmark.\(UUID().uuidString)"))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let history = ScreenshotHistory(directory: directory)
            defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
            var samples: [Double] = []
            for iteration in 0..<6 {
                let copied = expectation(description: "Readable PNG and TIFF")
                let saved = expectation(description: "History saved")
                let delegate = ClipboardBenchmarkDelegate()
                view.overlayDelegate = delegate
                var elapsed: Double = 0
                let start = ProcessInfo.processInfo.systemUptime
                delegate.confirm = {
                    do {
                        let composite = try XCTUnwrap(view.captureSelectedRegion())
                        let output = try XCTUnwrap(ScreenshotPresentation(view: view).render(composite))
                        let raw = annotated ? view.captureSelectedRegionRaw() : nil
                        let annotations = annotated ? view.annotations.map { $0.clone() } : nil
                        ImageEncoder.copyToClipboard(output, pasteboard: board) { success in
                            XCTAssertTrue(success)
                            XCTAssertNotNil(board.data(forType: .png))
                            XCTAssertNotNil(board.data(forType: .tiff))
                            elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                            copied.fulfill()
                        }
                        history.add(image: output, rawImage: raw, annotations: annotations) { success in
                            XCTAssertTrue(success)
                            saved.fulfill()
                        }
                    } catch { XCTFail("\(error)"); copied.fulfill(); saved.fulfill() }
                }
                withDefaults(["imageFormat": "png", "downscaleRetina": false,
                              "clipboardIncludesImageFormat": false, "historySize": 10]) {
                    XCTAssertTrue(view.performKeyEquivalent(with: TestKeyEvent.keyDown(
                        characters: "c", keyCode: 8, modifiers: .command)))
                    wait(for: [copied, saved], timeout: 30)
                }
                if iteration > 0 { samples.append(elapsed) }
            }
            print("CLIPBOARD_READY \(name) median_ms=\(String(format: "%.2f", samples.sorted()[2])) samples=\(samples)")
            view.reset()
        }
    }

    @MainActor func testPNGCompressionBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MACSHOT_CLIPBOARD_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in clipboard benchmark")
        }
        let source = try fixture(width: 3840, height: 2160)
        let pixels = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 600, to: 1000))
        document.style.transition = .accordion
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let paper = try XCTUnwrap(StitchAccordionWarp.render(pixels, projection: projection))
        for filter: Int? in [nil, Int(IMAGEIO_PNG_FILTER_UP), Int(IMAGEIO_PNG_FILTER_UP | IMAGEIO_PNG_FILTER_SUB)] {
            var times: [Double] = [], size = 0
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                let data = try XCTUnwrap(ImageEncoder.encodeWithCGImageDestination(cgImage: paper,
                    type: "public.png", lossyQuality: nil, pngFilter: filter))
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                size = data.count
            }
            print("CLIPBOARD_FILTER filter=\(String(describing: filter)) bytes=\(size) ms=\(times)")
        }
    }

    @MainActor private func fixture(width: Int, height: Int) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Deterministic screenshot-like content: panels, text-like rows, colored tiles.
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 24) {
            for x in stride(from: 0, to: width, by: 120) {
                context.setFillColor(CGColor(srgbRed: CGFloat((x + y) % 251) / 255,
                    green: CGFloat((x * 3 + y) % 233) / 255, blue: CGFloat((x + y * 7) % 241) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 88, height: 8))
            }
        }
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width / 2, height: height / 2))
    }
}

@MainActor private final class ClipboardBenchmarkDelegate: OverlayViewDelegate {
    var confirm: (() -> Void)?
    func overlayViewDidConfirm() { confirm?() }
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidCancel() {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestQuickSave() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
