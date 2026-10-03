import AppKit
import XCTest

@MainActor
final class StitchSelectionSnappingTests: XCTestCase {
    private func view() -> OverlayView {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.stitchSizeRecommendations = { _, _ in
            .init(widths: [.init(value: 200, reason: .capture), .init(value: 300, reason: .row)],
                  heights: [.init(value: 100, reason: .capture), .init(value: 150, reason: .column)])
        }
        return view
    }

    func testBothDimensionsSnapWithoutMovingTheAnchor() {
        let view = view()
        let point = view.stitchSnappedSelectionPoint(raw: CGPoint(x: 247, y: 153),
            boundaryAdjusted: CGPoint(x: 249, y: 157), anchor: CGPoint(x: 50, y: 50), enabled: true)
        XCTAssertEqual(point, CGPoint(x: 250, y: 150))
        XCTAssertEqual(view.stitchDimensionGuides.filter(\.matched).count, 2)
    }

    func testReverseDragAndAlternateSize() {
        let view = view()
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: CGPoint(x: 198, y: 352),
            boundaryAdjusted: CGPoint(x: 198, y: 352), anchor: CGPoint(x: 500, y: 500), enabled: true),
            CGPoint(x: 200, y: 350))
        XCTAssertTrue(view.stitchDimensionGuides.contains { $0.isWidth && $0.dimension == 300 && $0.matched })
    }

    func testFarDimensionsKeepExistingBoundarySnap() {
        let view = view()
        let adjusted = CGPoint(x: 225, y: 177)
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: CGPoint(x: 222, y: 175),
            boundaryAdjusted: adjusted, anchor: CGPoint(x: 50, y: 50), enabled: true), adjusted)
        XCTAssertFalse(view.stitchDimensionGuides.contains(where: \.matched))
    }

    func testOutOfScreenTargetsNeverResizePastDisplay() {
        let view = view()
        let raw = CGPoint(x: 799, y: 599)
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
            anchor: CGPoint(x: 602, y: 502), enabled: true), raw)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
    }

    func testBypassClearsFeedbackAndOrdinaryCaptureHasNoTargets() {
        let view = view()
        let raw = CGPoint(x: 247, y: 153)
        _ = view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
                                           anchor: CGPoint(x: 50, y: 50), enabled: true)
        XCTAssertFalse(view.stitchDimensionGuides.isEmpty)
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
            anchor: CGPoint(x: 50, y: 50), enabled: false), raw)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.stitchSizeRecommendations = nil
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
            anchor: CGPoint(x: 50, y: 50), enabled: true), raw)
    }

    func testProviderReceivesSpaceAvailableInTheDragDirection() {
        let view = view()
        var sizes: [CGSize] = []
        view.stitchSizeRecommendations = { _, maximum in
            sizes.append(maximum)
            return .init(widths: [], heights: [])
        }
        _ = view.stitchSnappedSelectionPoint(raw: CGPoint(x: 300, y: 200),
            boundaryAdjusted: CGPoint(x: 300, y: 200), anchor: CGPoint(x: 250, y: 150), enabled: true)
        _ = view.stitchSnappedSelectionPoint(raw: CGPoint(x: 200, y: 100),
            boundaryAdjusted: CGPoint(x: 200, y: 100), anchor: CGPoint(x: 250, y: 150), enabled: true)
        XCTAssertEqual(sizes, [CGSize(width: 550, height: 450), CGSize(width: 250, height: 150)])
    }

    func testSelectionDragUsesTargetsAndOptionAndShiftReleaseThem() {
        let view = view()
        view.selectionOnlyMode = true
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153), .option))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 197, height: 103))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153), .shift))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 103, height: 103))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
    }

    func testResetDoesNotLeakTargetsIntoPooledCaptureOverlay() {
        let view = guidingView()
        view.stitchCaptureSelection = true
        view.reset()
        XCTAssertNil(view.stitchSizeRecommendations)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        XCTAssertNil(view.stitchStartingGuideProvider)
        XCTAssertTrue(view.stitchStartingGuides.isEmpty)
        XCTAssertNil(view.stitchStartingFeedback)
        XCTAssertFalse(view.stitchCaptureSelection)
    }

    func testSecondShotHasIdleReferencesBeforeAnyPointerOrSelectionEvent() throws {
        let image = try XCTUnwrap(ImageProbe.quadrantImage(width: 200, height: 100)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let source = StitchCaptureSource(screenRect: CGRect(x: 50, y: 50, width: 200, height: 100), scrollOffset: .zero)
        let coordinator = StitchCaptureCoordinator(first: .init(image: image, position: CGPoint(x: 50, y: -150), source: source),
            capture: { _ in }, analyze: { _, _, _, _ in })
        let view = view()
        view.selectionOnlyMode = true
        let bounds = view.bounds
        view.stitchStartingGuideProvider = { point in
            coordinator.selectionStartingGuides(screenFrame: bounds,
                                                scrollOffset: CGPoint(x: 0, y: 900), pointer: point)
        }
        XCTAssertEqual(view.state, .idle)
        XCTAssertEqual(view.selectionRect, .zero)
        XCTAssertEqual(view.stitchStartingGuides.vertical.map(\.position), [50, 250])
        XCTAssertEqual(view.stitchStartingGuides.horizontal.map(\.position), [50, 150])
        XCTAssertNil(view.stitchStartingFeedback)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
    }

    func testHoverShowsStartingCornerAndStationaryOptionReleasesItImmediately() {
        let view = guidingView()
        let raw = CGPoint(x: 53, y: 47)
        view.mouseMoved(with: mouse(.mouseMoved, view, raw))
        XCTAssertEqual(view.stitchStartingFeedback?.point, CGPoint(x: 50, y: 50))
        XCTAssertEqual(view.stitchStartingFeedback?.verticalEdge, 50)
        XCTAssertEqual(view.stitchStartingFeedback?.horizontalEdge, 50)
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertNil(view.stitchStartingFeedback)
        XCTAssertFalse(view.stitchStartingGuides.isEmpty)
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(view.stitchStartingFeedback?.point, CGPoint(x: 50, y: 50))
    }

    func testMouseDownModifierControlsStartEvenWithoutAnotherHoverEvent() {
        let view = guidingView()
        let raw = CGPoint(x: 53, y: 47)
        view.mouseMoved(with: mouse(.mouseMoved, view, raw))
        XCTAssertNotNil(view.stitchStartingFeedback)
        view.mouseDown(with: mouse(.leftMouseDown, view, raw, .option))
        XCTAssertEqual(view.selectionRect.origin, raw)
        XCTAssertNil(view.stitchStartingFeedback)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 248, y: 153), .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 53, y: 47, width: 195, height: 106))
        view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 248, y: 153), .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 53, y: 47, width: 195, height: 106))
    }

    func testNearGuideClickDoesNotBecomeATinyCaptureWithoutPointerMovement() {
        let view = guidingView()
        let raw = CGPoint(x: 56, y: 56)
        view.mouseDown(with: mouse(.leftMouseDown, view, raw))
        XCTAssertEqual(view.selectionRect.origin, CGPoint(x: 50, y: 50))
        view.mouseUp(with: mouse(.leftMouseUp, view, raw))
        XCTAssertEqual(view.selectionRect, view.bounds)
    }

    func testPointerJitterWithinFivePointsOfThePhysicalClickRemainsAClick() {
        let cases: [(start: CGPoint, end: CGPoint)] = [
            (CGPoint(x: 56, y: 56), CGPoint(x: 56.1, y: 56)),
            (CGPoint(x: 56, y: 56), CGPoint(x: 55.9, y: 56)),
            (CGPoint(x: 56, y: 56), CGPoint(x: 56, y: 55.9)),
            (CGPoint(x: 44, y: 44), CGPoint(x: 43.9, y: 44)),
            (CGPoint(x: 244, y: 144), CGPoint(x: 244.1, y: 143.9)),
            (CGPoint(x: 56, y: 56), CGPoint(x: 61, y: 61)),
            (CGPoint(x: 44, y: 44), CGPoint(x: 39, y: 39)),
        ]
        for (start, end) in cases {
            for modifiers in [NSEvent.ModifierFlags(), .option] {
                let view = guidingView()
                view.mouseDown(with: mouse(.leftMouseDown, view, start))
                view.mouseDragged(with: mouse(.leftMouseDragged, view, end))
                XCTAssertEqual(view.selectionRect.size, .zero, "Jitter from \(start) to \(end)")
                XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
                view.mouseUp(with: mouse(.leftMouseUp, view, end, modifiers))
                XCTAssertEqual(view.selectionRect, view.bounds, "Release from \(start) to \(end)")
                XCTAssertEqual(view.state, .selected)
            }
        }
    }

    func testReleaseCrossingTheRawThresholdOnEitherAxisCommitsTheMagneticAnchor() {
        let cases: [(start: CGPoint, end: CGPoint, expected: CGRect)] = [
            (CGPoint(x: 56, y: 56), CGPoint(x: 61.1, y: 56),
             CGRect(x: 50, y: 50, width: 11.1, height: 6)),
            (CGPoint(x: 56, y: 56), CGPoint(x: 56, y: 61.1),
             CGRect(x: 50, y: 50, width: 6, height: 11.1)),
            (CGPoint(x: 44, y: 44), CGPoint(x: 38.9, y: 44),
             CGRect(x: 38.9, y: 44, width: 11.1, height: 6)),
            // Crossing toward the magnetic anchor can leave a smaller rect.
            // The physical movement still crossed the drag threshold.
            (CGPoint(x: 53, y: 53), CGPoint(x: 47.9, y: 52),
             CGRect(x: 47.9, y: 50, width: 2.1, height: 2)),
        ]
        for (start, end, expected) in cases {
            for modifiers in [NSEvent.ModifierFlags(), .option] {
                let view = guidingView()
                view.mouseDown(with: mouse(.leftMouseDown, view, start))
                // Release must resolve its own location and modifier state.
                view.mouseUp(with: mouse(.leftMouseUp, view, end, modifiers))
                XCTAssertEqual(view.selectionRect.minX, expected.minX, accuracy: 0.001)
                XCTAssertEqual(view.selectionRect.minY, expected.minY, accuracy: 0.001)
                XCTAssertEqual(view.selectionRect.width, expected.width, accuracy: 0.001)
                XCTAssertEqual(view.selectionRect.height, expected.height, accuracy: 0.001)
                XCTAssertEqual(view.state, .selected)
            }
        }
    }

    func testReturningToThePhysicalClickOnReleaseKeepsClickBehaviorWithOption() {
        let view = guidingView()
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 56, y: 56)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 250, y: 150)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 60.9, y: 60.9), .option))
        XCTAssertEqual(view.selectionRect, view.bounds)
    }

    func testAnchoredSelectionUsesTheSameRawThresholdForJitterAndReverseMovement() {
        let jitter = guidingView()
        jitter.rightMouseDown(with: mouse(.rightMouseDown, jitter, CGPoint(x: 44, y: 44)))
        jitter.mouseMoved(with: mouse(.mouseMoved, jitter, CGPoint(x: 43.9, y: 43.9)))
        XCTAssertEqual(jitter.selectionRect.size, .zero)
        jitter.rightMouseDown(with: mouse(.rightMouseDown, jitter, CGPoint(x: 43.9, y: 43.9), .option))
        XCTAssertEqual(jitter.selectionRect, jitter.bounds)

        let reverse = guidingView()
        reverse.rightMouseDown(with: mouse(.rightMouseDown, reverse, CGPoint(x: 53, y: 53)))
        reverse.rightMouseDown(with: mouse(.rightMouseDown, reverse, CGPoint(x: 47.9, y: 52), .option))
        XCTAssertEqual(reverse.selectionRect.minX, 47.9, accuracy: 0.001)
        XCTAssertEqual(reverse.selectionRect.minY, 50, accuracy: 0.001)
        XCTAssertEqual(reverse.selectionRect.width, 2.1, accuracy: 0.001)
        XCTAssertEqual(reverse.selectionRect.height, 2, accuracy: 0.001)
        XCTAssertEqual(reverse.state, .selected)
    }

    func testGuideSelectionRepositionedBackToItsPhysicalClickRemainsARealSelection() {
        let view = guidingView()
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 247, y: 153)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 50, y: 50)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.keyDown(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153)))
        let moved = CGRect(x: 247, y: 153, width: 200, height: 100)
        XCTAssertEqual(view.selectionRect, moved)
        view.keyUp(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
        view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 247, y: 153), .option))
        XCTAssertEqual(view.selectionRect, moved)
    }

    func testOrdinarySelectorKeepsItsExistingDragThresholdWithoutGuideState() {
        for distance in [CGFloat(5), 5.1] {
            let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            view.selectionOnlyMode = true
            view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 56, y: 56)))
            view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 56 + distance, y: 56), .option))
            XCTAssertNil(view.stitchStartingGuideProvider)
            XCTAssertNil(view.stitchStartingFeedback)
            if distance == 5 {
                XCTAssertEqual(view.selectionRect, view.bounds)
            } else {
                XCTAssertEqual(view.selectionRect.minX, 56)
                XCTAssertEqual(view.selectionRect.width, distance, accuracy: 0.001)
                XCTAssertEqual(view.selectionRect.height, 1)
            }
        }
    }

    func testIdleHelperOnlyOffersGuideStartsWhenTheActivePresetAllowsThem() {
        let keys = ["preSelectionResolutionPresetKind", "preSelectionResolutionPresetWidth",
                    "preSelectionResolutionPresetHeight"]
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        UserDefaults.standard.set(1, forKey: keys[0]) // Freeform.
        let view = guidingView()
        let ordinary = OverlayView(frame: view.frame)
        let ordinaryHelp = ordinary.idleHelperText
        XCTAssertNotEqual(ordinaryHelp, L("Start near a guide · Option to ignore snapping"))
        XCTAssertTrue(view.stitchAllowsStartingCornerSnap)
        XCTAssertEqual(view.idleHelperText, L("Start near a guide · Option to ignore snapping"))

        UserDefaults.standard.set(3, forKey: keys[0]) // Persisted fixed resolution.
        UserDefaults.standard.set(200, forKey: keys[1])
        UserDefaults.standard.set(100, forKey: keys[2])
        XCTAssertFalse(view.stitchStartingGuides.isEmpty)
        XCTAssertFalse(view.stitchAllowsStartingCornerSnap)
        XCTAssertEqual(view.idleHelperText, ordinaryHelp)
        let point = CGPoint(x: 53, y: 47)
        view.mouseMoved(with: mouse(.mouseMoved, view, point))
        XCTAssertNil(view.stitchStartingFeedback)
        view.mouseDown(with: mouse(.leftMouseDown, view, point))
        XCTAssertEqual(view.selectionRect.origin, point)
        view.mouseUp(with: mouse(.leftMouseUp, view, point, .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 3, y: 22, width: 100, height: 50))
        XCTAssertEqual(view.selectionRect.midX, point.x)
        XCTAssertEqual(view.selectionRect.midY, point.y)
    }

    func testStartingCornerIsFixedWhileOptionUpdatesMovingDimensionsAndRelease() {
        let view = guidingView()
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 53, y: 47)))
        XCTAssertEqual(view.selectionRect.origin, CGPoint(x: 50, y: 50))
        let raw = CGPoint(x: 248, y: 153)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, raw))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 198, height: 103))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.mouseUp(with: mouse(.leftMouseUp, view, raw, .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 198, height: 103))
    }

    func testReverseDragSnapsTheStartingCornerAndBothDimensions() {
        let view = guidingView()
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 247, y: 153)))
        XCTAssertEqual(view.selectionRect.origin, CGPoint(x: 250, y: 150))
        let raw = CGPoint(x: 52, y: 47)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, raw))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 52, y: 47, width: 198, height: 103))
        XCTAssertEqual(view.selectionRect.maxX, 250)
        XCTAssertEqual(view.selectionRect.maxY, 150)
        view.mouseUp(with: mouse(.leftMouseUp, view, raw))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
    }

    func testTopLeftStartAndDownwardDragMatchThePriorCapture() {
        let view = guidingView()
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 53, y: 153)))
        XCTAssertEqual(view.selectionRect.origin, CGPoint(x: 50, y: 150))
        let raw = CGPoint(x: 248, y: 47)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, raw))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.mouseUp(with: mouse(.leftMouseUp, view, raw, .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 47, width: 198, height: 103))
        XCTAssertEqual(view.selectionRect.maxY, 150)
    }

    func testArbitrarySelectionOutsideSnapRadiusKeepsItsPositionAndDimensions() {
        let view = guidingView()
        let start = CGPoint(x: 131, y: 292), end = CGPoint(x: 510, y: 512)
        view.mouseMoved(with: mouse(.mouseMoved, view, start))
        XCTAssertNil(view.stitchStartingFeedback)
        view.mouseDown(with: mouse(.leftMouseDown, view, start))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, end))
        XCTAssertEqual(view.selectionRect, CGRect(x: 131, y: 292, width: 379, height: 220))
        XCTAssertFalse(view.stitchDimensionGuides.contains(where: \.matched))
        view.mouseUp(with: mouse(.leftMouseUp, view, end))
        XCTAssertEqual(view.selectionRect, CGRect(x: 131, y: 292, width: 379, height: 220))
    }

    func testRightClickAnchoredSelectionSharesTheStartingGuideAndModifierLifecycle() {
        let view = guidingView()
        view.rightMouseDown(with: mouse(.rightMouseDown, view, CGPoint(x: 53, y: 47)))
        view.mouseMoved(with: mouse(.mouseMoved, view, CGPoint(x: 248, y: 153)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.rightMouseDown(with: mouse(.rightMouseDown, view, CGPoint(x: 248, y: 153), .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 198, height: 103))
        XCTAssertEqual(view.state, .selected)
    }

    func testRecommendationsUseRegisteredLayoutRatherThanAbsoluteScreenCoordinates() throws {
        let first = try XCTUnwrap(ImageProbe.quadrantImage(width: 100, height: 80)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let second = try XCTUnwrap(ImageProbe.quadrantImage(width: 200, height: 80)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pending: ((StitchCaptureFrame?) -> Void)?
        let coordinator = StitchCaptureCoordinator(
            first: .init(image: first, position: CGPoint(x: 1000, y: 2000)),
            capture: { pending = $0 }, analyze: { _, _, _, complete in
                complete(false, StitchAlignment.Match(offset: CGPoint(x: 100, y: 0), error: 0))
            })
        coordinator.requestCapture()
        pending?(.init(image: second, position: CGPoint(x: 1500, y: 2000)))
        let result = coordinator.selectionRecommendations(at: CGPoint(x: 1400, y: 2080))
        XCTAssertEqual(result.widths.first?.value, 100)
        XCTAssertEqual(result.widths.first?.reason, .column)
    }

    func testGuideRenderingPreview() throws {
        let view = view()
        let page = NSImage(size: view.bounds.size)
        page.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        view.bounds.fill()
        for row in 0..<14 {
            let text = row == 0 ? "A page worth capturing" : "Content stays aligned as you add to your stitch."
            (text as NSString).draw(at: CGPoint(x: 80, y: 520 - row * 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: row == 0 ? 24 : 15), .foregroundColor: NSColor.darkGray
            ])
        }
        page.unlockFocus()
        view.screenshotImage = page
        view.selectionOnlyMode = true
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 80, y: 220)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 378, y: 366)))
        view.stitchReferencePixelsPerPoint = 2
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        let environment = ProcessInfo.processInfo.environment
        if let output = environment["MACSHOT_STITCH_GUIDE_PREVIEW"]
            ?? environment["TEST_RUNNER_MACSHOT_STITCH_GUIDE_PREVIEW"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }

    func testIdleSecondShotGuidesDrawOverTheActualOverlayPageAndShowHover() throws {
        let previous = UserDefaults.standard.object(forKey: "hideCaptureInstructions")
        UserDefaults.standard.set(true, forKey: "hideCaptureInstructions")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "hideCaptureInstructions") }
            else { UserDefaults.standard.removeObject(forKey: "hideCaptureInstructions") }
        }
        let view = view()
        let page = NSImage(size: view.bounds.size)
        page.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        view.bounds.fill()
        for row in 0..<14 {
            let text = row == 0 ? "Start the next capture along these edges" : "The page has scrolled. The previous crop still guides your next start."
            (text as NSString).draw(at: CGPoint(x: 80, y: 520 - row * 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: row == 0 ? 22 : 14), .foregroundColor: NSColor.darkGray
            ])
        }
        page.unlockFocus()
        view.screenshotImage = page
        view.selectionOnlyMode = true
        view.stitchCaptureSelection = true
        let baseline = try render(view)
        let source = StitchCaptureSource(screenRect: CGRect(x: 80, y: 220, width: 300, height: 150), scrollOffset: .zero)
        let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let bounds = view.bounds
        view.stitchStartingGuideProvider = { pointer in
            StitchSelectionGuideGeometry.guides(frames: [frame], anchor: frame, source: source,
                screenFrame: bounds, scrollOffset: CGPoint(x: 0, y: 80), pointer: pointer)
        }
        let idle = try render(view)
        XCTAssertEqual(view.state, .idle)
        XCTAssertEqual(view.selectionRect, .zero)
        let scaleX = CGFloat(idle.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(idle.pixelsHigh) / view.bounds.height
        let column = Int(80 * scaleX)
        var visibleGuidePixels = false
        for x in max(0, column - 2)...min(idle.pixelsWide - 1, column + 2) {
            for y in Int(40 * scaleY)..<Int(100 * scaleY) {
                if let before = baseline.colorAt(x: x, y: y), let after = idle.colorAt(x: x, y: y), !before.isEqual(after) {
                    visibleGuidePixels = true
                }
            }
        }
        XCTAssertTrue(visibleGuidePixels, "Idle guides must reach OverlayView.draw, not just the geometry provider")
        try writePreview(idle, suffix: "idle")
        view.mouseMoved(with: mouse(.mouseMoved, view, CGPoint(x: 83, y: 373)))
        XCTAssertEqual(view.stitchStartingFeedback?.point, CGPoint(x: 80, y: 370))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        try writePreview(render(view), suffix: "hover")
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertNil(view.stitchStartingFeedback)
        try writePreview(render(view), suffix: "option")
    }

    func testFirstStitchSelectionTeachesNavigationAndOrdinarySelectionKeepsMoveHint() {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.selectionOnlyMode = true
        XCTAssertEqual(view.selectingHelperText, L("Hold Space to move. Release to finish"))
        view.stitchCaptureSelection = true
        XCTAssertNil(view.stitchSizeRecommendations)
        XCTAssertEqual(view.selectingHelperText, L("Release to capture · hold Space to navigate"))
    }

    func testOptionUpdatesStationarySelectionAndReleaseUsesCurrentModifiers() {
        let view = view()
        view.selectionOnlyMode = true
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 50, y: 50)))
        let raw = CGPoint(x: 247, y: 153)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, raw))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 200, height: 100))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 197, height: 103))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 200, height: 100))
        // Even without a preceding flagsChanged delivery, mouseUp must honor Option.
        view.mouseUp(with: mouse(.leftMouseUp, view, raw, .option))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 197, height: 103))
    }

    func testShiftUpdatesStationarySelectionAndRemainsConstrainedOnRelease() {
        let view = view()
        view.selectionOnlyMode = true
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 50, y: 50)))
        let raw = CGPoint(x: 247, y: 153)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, raw))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 56, modifiers: .shift))
        XCTAssertEqual(view.selectionRect.width, view.selectionRect.height)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.mouseUp(with: mouse(.leftMouseUp, view, raw, [.shift, .option]))
        XCTAssertEqual(view.selectionRect.width, view.selectionRect.height)
    }

    func testOrdinarySelectionKeepsWholeRectSnapAfterStationarySpaceRelease() {
        let view = RepositionSnapOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        reposition(view)
        let displayed = view.selectionRect
        XCTAssertEqual(displayed, CGRect(x: 73, y: 62, width: 200, height: 100))
        view.keyUp(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
        view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 270, y: 160)))
        XCTAssertEqual(view.selectionRect, displayed)
    }

    func testStationarySpaceReleaseStillHonorsOptionAndShift() {
        let view = RepositionSnapOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        reposition(view)
        view.keyUp(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertEqual(view.selectionRect, CGRect(x: 70, y: 60, width: 200, height: 100))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(view.selectionRect, CGRect(x: 73, y: 62, width: 200, height: 100))
        view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 270, y: 160), [.option, .shift]))
        XCTAssertEqual(view.selectionRect, CGRect(x: 70, y: 60, width: 100, height: 100))
    }

    func testPointerMovementAfterSpaceReleaseResumesCornerResizing() {
        let view = RepositionSnapOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        reposition(view)
        view.keyUp(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 300, y: 180)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 70, y: 60, width: 230, height: 120))
        view.mouseUp(with: mouse(.leftMouseUp, view, CGPoint(x: 300, y: 180)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 70, y: 60, width: 230, height: 120))
    }

    private func reposition(_ view: OverlayView) {
        view.selectionOnlyMode = true // Ordinary raw selector; no Stitch context or targets.
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 250, y: 150)))
        view.keyDown(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 270, y: 160)))
    }

    private func guidingView() -> OverlayView {
        let view = view()
        view.selectionOnlyMode = true
        let source = StitchCaptureSource(screenRect: CGRect(x: 50, y: 50, width: 200, height: 100), scrollOffset: .zero)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let bounds = view.bounds
        view.stitchStartingGuideProvider = { pointer in
            StitchSelectionGuideGeometry.guides(frames: [frame], anchor: frame, source: source,
                screenFrame: bounds, scrollOffset: .zero, pointer: pointer)
        }
        return view
    }

    private func render(_ view: OverlayView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Reuses the existing drag-preview path for adjacent idle, hover, and Option receipts.
    private func writePreview(_ bitmap: NSBitmapImageRep, suffix: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MACSHOT_STITCH_GUIDE_PREVIEW"]
            ?? environment["TEST_RUNNER_MACSHOT_STITCH_GUIDE_PREVIEW"] else { return }
        let original = URL(fileURLWithPath: output)
        let receipt = original.deletingLastPathComponent()
            .appendingPathComponent(original.deletingPathExtension().lastPathComponent + "-" + suffix + ".png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: receipt)
    }

    private func mouse(_ type: NSEvent.EventType, _ view: OverlayView, _ point: CGPoint,
                       _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

/// Deterministic boundary hit: exercises the real drag/Space/modifier lifecycle
/// without waiting for asynchronous screenshot edge detection.
@MainActor
private final class RepositionSnapOverlay: OverlayView {
    override func boundarySnappedMovedRect(_ rect: NSRect, modifiers: NSEvent.ModifierFlags) -> NSRect {
        modifiers.contains(.option) ? rect : rect.offsetBy(dx: 3, dy: 2)
    }
}
