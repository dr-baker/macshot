import AppKit
import XCTest

@MainActor
final class StitchInlineCanvasTests: XCTestCase {
    private final class KeyEditor: EditorView {
        var keys: [UInt16] = []
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }

    func testInlineRefreshAndParentResizePreservePixelProjection() {
        let (editor, canvas) = fixture()
        XCTAssertEqual(canvas.frame, editor.selectionRect)
        XCTAssertEqual(canvas.bounds, CGRect(x: 0, y: 0, width: 400, height: 200))
        editor.applySelection(CGRect(x: 15, y: 25, width: 100, height: 50))
        canvas.syncInlineGeometry()
        XCTAssertEqual(canvas.frame, editor.selectionRect)
        XCTAssertEqual(canvas.bounds.size, CGSize(width: 400, height: 200))
        canvas.refresh(canvas.document, preview: nil)
        XCTAssertEqual(canvas.frame, editor.selectionRect)
    }

    func testAutomaticRowsAndColumnsUseTopDownPixelsIncludingNegativeDocumentOrigin() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        var cuts: [(StitchAxis, CGFloat, CGFloat)] = []
        canvas.onCut = { cuts.append(($0, $1, $2)) }
        XCTAssertEqual(canvas.mode, .removeSpace)
        drag(canvas, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 43, y: 80))
        XCTAssertEqual(cuts[0].1, -20)
        XCTAssertEqual(cuts[0].2, 30)
        drag(canvas, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 150, y: 33))
        XCTAssertEqual(cuts[1].1, -60)
        XCTAssertEqual(cuts[1].2, 50)
        if case .horizontal = cuts[0].0 {} else { XCTFail("Rows axis") }
        if case .vertical = cuts[1].0 {} else { XCTFail("Columns axis") }
    }

    func testDirectionWaitsForDeliberateScreenMovementAndLocksAtEveryProjection() {
        for projection: CGFloat in [0.25, 0.5, 2] {
            let (editor, canvas) = fixture()
            editor.applySelection(CGRect(x: 10, y: 20, width: 400 * projection, height: 200 * projection))
            canvas.syncInlineGeometry()
            let window = host(editor)
            defer { window.orderOut(nil) }
            var cuts: [(StitchAxis, CGFloat, CGFloat)] = []
            canvas.onCut = { cuts.append(($0, $1, $2)) }
            let start = CGPoint(x: 40, y: 30)
            func point(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
                CGPoint(x: start.x + dx / projection, y: start.y + dy / projection)
            }
            canvas.mouseDown(with: mouse(.leftMouseDown, canvas, start))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(2, 2)))
            XCTAssertNil(canvas.bandAxis, "Jitter must not choose a cut axis")
            XCTAssertNil(canvas.removalBand)
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(8, 7.5)))
            XCTAssertNil(canvas.bandAxis, "Near-diagonal movement must remain undecided")
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(3, 10)))
            XCTAssertEqual(canvas.bandAxis, .horizontal)
            XCTAssertEqual(canvas.removalBand, CGRect(x: -100, y: -20, width: 400, height: 10 / projection))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(40, 11)))
            XCTAssertEqual(canvas.bandAxis, .horizontal, "A later sideways turn must not change the resolved axis")
            canvas.mouseUp(with: mouse(.leftMouseUp, canvas, point(40, 11)))
            XCTAssertEqual(cuts.count, 1)
            if let cut = cuts.first {
                XCTAssertEqual(cut.0, .horizontal)
                XCTAssertEqual(cut.1, -20)
                XCTAssertEqual(cut.2, -20 + 11 / projection, accuracy: 0.001)
            }
            XCTAssertNil(canvas.bandAxis)
        }
    }

    func testFractionalBandsMatchRoundedPreviewAndCommittedDimensionsForBothAxes() throws {
        for origin in [CGPoint.zero, CGPoint(x: -100.4, y: -50.4)] {
            for axis in [StitchAxis.horizontal, .vertical] {
                for option in [false, true] {
                    for reverse in [false, true] {
                        let (editor, canvas) = fractionalFixture(origin: origin)
                        let window = host(editor)
                        defer { window.orderOut(nil) }
                        let original = canvas.document
                        let before = try XCTUnwrap(StitchRenderer.render(original))
                        XCTAssertEqual(canvas.bounds.width, CGFloat(before.width))
                        XCTAssertEqual(canvas.bounds.height, CGFloat(before.height))
                        if option { canvas.bandGuideRows = [12, 20]; canvas.bandGuideColumns = [12, 20] }
                        let from: CGFloat = reverse ? 20.6 : 11.4, to: CGFloat = reverse ? 11.4 : 20.6
                        let flags: NSEvent.ModifierFlags = option ? [.option] : []
                        func point(_ coordinate: CGFloat) -> CGPoint {
                            axis == .horizontal
                                ? CGPoint(x: CGFloat(before.width) / 2, y: coordinate - original.bounds.integral.minY)
                                : CGPoint(x: coordinate - original.bounds.integral.minX, y: CGFloat(before.height) / 2)
                        }
                        var after = original, cuts = 0
                        canvas.onCut = { resolvedAxis, proposedStart, proposedEnd in
                            cuts += 1
                            XCTAssertEqual(resolvedAxis, axis)
                            XCTAssertEqual(proposedStart, from, accuracy: 0.000001)
                            XCTAssertEqual(proposedEnd, to, accuracy: 0.000001)
                            XCTAssertTrue(after.collapse(axis: resolvedAxis, from: proposedStart, to: proposedEnd))
                        }
                        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, point(from), modifiers: flags))
                        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(to), modifiers: flags))
                        let preview = try XCTUnwrap(canvas.removalBand)
                        XCTAssertEqual(canvas.bandAxis, axis)
                        XCTAssertEqual(axis == .horizontal ? preview.minY : preview.minX, 11)
                        XCTAssertEqual(axis == .horizontal ? preview.maxY : preview.maxX, 21)
                        XCTAssertEqual(canvas.removalAmountText, "10", "11.4 to 20.6 must preview the ten pixels that will be removed")
                        XCTAssertEqual(canvas.document.pieces[0].source, original.pieces[0].source)
                        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, point(to), modifiers: flags))
                        XCTAssertEqual(cuts, 1)
                        let removed = axis == .horizontal ? original.bounds.height - after.bounds.height : original.bounds.width - after.bounds.width
                        XCTAssertEqual(removed, 10, accuracy: 0.000001)
                        let output = try XCTUnwrap(StitchRenderer.render(after))
                        XCTAssertEqual(axis == .horizontal ? before.height - output.height : before.width - output.width, 10)
                        XCTAssertTrue(after.pieces.allSatisfy { $0.image === original.pieces[0].image })
                    }
                }
            }
        }
    }

    func testFractionalBoundaryClipsCommitProposedEndpointsWithoutRerounding() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for clipsLower in [false, true] {
                let (editor, canvas) = fractionalFixture(origin: CGPoint(x: -100.4, y: -50.4))
                let window = host(editor)
                defer { window.orderOut(nil) }
                let original = canvas.document
                let lower = axis == .horizontal ? original.bounds.minY : original.bounds.minX
                let upper = axis == .horizontal ? original.bounds.maxY : original.bounds.maxX
                let from = clipsLower ? lower + 12.6 : upper - 12.6
                let to = clipsLower ? lower - 8.6 : upper + 8.6
                let expectedLower = clipsLower ? lower : from.rounded()
                let expectedUpper = clipsLower ? from.rounded() : upper
                func point(_ coordinate: CGFloat) -> CGPoint {
                    axis == .horizontal
                        ? CGPoint(x: original.bounds.integral.width / 2, y: coordinate - original.bounds.integral.minY)
                        : CGPoint(x: coordinate - original.bounds.integral.minX, y: original.bounds.integral.height / 2)
                }
                var after = original, cuts = 0
                canvas.onCut = { resolvedAxis, proposedStart, proposedEnd in
                    cuts += 1
                    XCTAssertEqual(proposedStart, from, accuracy: 0.000001)
                    XCTAssertEqual(proposedEnd, to, accuracy: 0.000001)
                    XCTAssertTrue(after.collapse(axis: resolvedAxis, from: proposedStart, to: proposedEnd))
                }
                canvas.mouseDown(with: mouse(.leftMouseDown, canvas, point(from), modifiers: .option))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(to), modifiers: .option))
                let preview = try XCTUnwrap(canvas.removalBand)
                XCTAssertEqual(axis == .horizontal ? preview.minY : preview.minX, expectedLower, accuracy: 0.000001)
                XCTAssertEqual(axis == .horizontal ? preview.maxY : preview.maxX, expectedUpper, accuracy: 0.000001)
                XCTAssertEqual(canvas.removalAmountText, clipsLower ? "12.4" : "12.2", "Fractional boundary clips must retain their displayed amount")
                canvas.mouseUp(with: mouse(.leftMouseUp, canvas, point(to), modifiers: .option))
                XCTAssertEqual(cuts, 1)
                let removed = axis == .horizontal ? original.bounds.height - after.bounds.height : original.bounds.width - after.bounds.width
                XCTAssertEqual(removed, expectedUpper - expectedLower, accuracy: 0.000001)
                XCTAssertTrue(after.pieces.allSatisfy { $0.image === original.pieces[0].image })
            }
        }
    }

    func testHighProjectionRejectsBandsBelowMinimumPixelOrRetainedRange() {
        for axis in [StitchAxis.horizontal, .vertical] {
            let (editor, canvas) = fractionalFixture(origin: CGPoint(x: -100.4, y: -50.4))
            let window = host(editor)
            defer { window.orderOut(nil) }
            let original = canvas.document
            let lower = axis == .horizontal ? original.bounds.minY : original.bounds.minX
            let upper = axis == .horizontal ? original.bounds.maxY : original.bounds.maxX
            func point(_ coordinate: CGFloat) -> CGPoint {
                axis == .horizontal
                    ? CGPoint(x: original.bounds.integral.width / 2, y: coordinate - original.bounds.integral.minY)
                    : CGPoint(x: coordinate - original.bounds.integral.minX, y: original.bounds.integral.height / 2)
            }
            canvas.onCut = { _, _, _ in XCTFail("An invalid pixel range must not commit") }
            for (from, to) in [(CGFloat(11.4), CGFloat(12.4)), (lower + 0.1, upper + 0.6)] {
                canvas.mouseDown(with: mouse(.leftMouseDown, canvas, point(from), modifiers: .option))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, point(to), modifiers: .option))
                XCTAssertEqual(canvas.bandAxis, axis, "The eight-times projection has enough screen movement to resolve direction")
                XCTAssertNil(canvas.removalBand)
                XCTAssertNil(canvas.removalAmountText)
                canvas.mouseUp(with: mouse(.leftMouseUp, canvas, point(to), modifiers: .option))
                var candidate = original
                XCTAssertFalse(candidate.collapse(axis: axis, from: from, to: to))
                XCTAssertEqual(candidate.pieces[0].source, original.pieces[0].source)
            }
        }
    }

    func testClicksJitterAmbiguousDragsAndReleaseWithoutPreviewDoNotCut() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-22, -14]
        canvas.bandGuideColumns = [-62, -54]
        canvas.onCut = { _, _, _ in XCTFail("A band must resolve after deliberate movement before it can cut") }
        for end in [CGPoint(x: 40, y: 30), CGPoint(x: 46, y: 30),
                    CGPoint(x: 40, y: 36), CGPoint(x: 60, y: 50)] {
            drag(canvas, from: CGPoint(x: 40, y: 30), to: end)
            XCTAssertNil(canvas.bandAxis)
            XCTAssertTrue(canvas.bandGuideMatches.isEmpty)
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 40, y: 80)))
        canvas.bandGuideRows = [-20]
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 40, y: 40)))
        XCTAssertEqual(canvas.bandAxis, .horizontal)
        XCTAssertNil(canvas.removalBand, "Both endpoints snapped to one guide produce no removal preview")
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 40, y: 70)))
    }

    func testBandThresholdAndSnapRadiusFollowScrollMagnificationInScreenPoints() {
        for magnification: CGFloat in [0.5, 1, 4] {
            let (editor, canvas) = fixture()
            let scroll = NSScrollView(frame: editor.frame)
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.1
            scroll.maxMagnification = 8
            scroll.documentView = editor
            let window = host(scroll)
            defer { window.orderOut(nil) }
            scroll.magnification = magnification
            scroll.tile()
            let zoom = magnification / 2
            let start = CGPoint(x: 40, y: 30)
            let end = CGPoint(x: 40, y: 30 + 24 / zoom)
            let pointerRegion = CGRect(x: start.x, y: start.y, width: 1, height: 29 / zoom + 1)
                .insetBy(dx: -8 / zoom, dy: -8 / zoom)
            canvas.scrollToVisible(pointerRegion)
            XCTAssertTrue(canvas.visibleRect.contains(start), "The hover target must be visible at \(magnification)×")
            XCTAssertTrue(recipient(for: mouse(.mouseMoved, canvas, start), in: scroll) === canvas,
                          "The visible hover target must reach the canvas at \(magnification)×")
            canvas.bandGuideRows = [-20 + 7 / zoom]
            canvas.mouseMoved(with: mouse(.mouseMoved, canvas, start))
            XCTAssertNil(canvas.bandHoverRow, "Seven screen points must remain outside the six-point snap radius")
            let guides: [CGFloat] = [-20 + 5 / zoom, -20 + 29 / zoom]
            canvas.bandGuideRows = guides
            canvas.mouseMoved(with: mouse(.mouseMoved, canvas, start))
            XCTAssertEqual(canvas.bandHoverRow, guides[0])
            var cuts: [(CGFloat, CGFloat)] = []
            canvas.onCut = { _, from, to in cuts.append((from, to)) }
            canvas.mouseDown(with: mouse(.leftMouseDown, canvas, start))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 40, y: 30 + 3 / zoom)))
            XCTAssertNil(canvas.bandAxis, "Three screen points must remain below the drag threshold")
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, end))
            XCTAssertEqual(canvas.bandAxis, .horizontal)
            XCTAssertEqual(canvas.bandGuideMatches, guides)
            canvas.mouseUp(with: mouse(.leftMouseUp, canvas, end))
            XCTAssertEqual(cuts.count, 1)
            XCTAssertEqual(cuts.first?.0, guides[0])
            XCTAssertEqual(cuts.first?.1, guides[1])
        }
    }

    func testReturningInsideThresholdCancelsEvenWhenGuidesWidenTheBand() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-22, -14]
        canvas.onCut = { _, _, _ in XCTFail("Returning near the start must cancel the cut") }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 40, y: 48)))
        XCTAssertEqual(canvas.bandAxis, .horizontal)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 40, y: 33)))
        XCTAssertEqual(canvas.bandGuideMatches, [-22, -14], "Snapping may widen a raw three-pixel movement")
        XCTAssertNil(canvas.removalBand, "The cut preview must disappear inside the movement threshold")
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 40, y: 33)))
    }

    func testEscapeCancelsInlineBandThenReturnsToNativeEditor() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.onCut = { _, _, _ in XCTFail("Cancelled band applied") }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 43, y: 80)))
        XCTAssertEqual(canvas.bandAxis, .horizontal)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 43, y: 80)))
        XCTAssertNil(canvas.bandAxis)
        XCTAssertNil(canvas.removalBand)
        XCTAssertTrue(editor.keys.isEmpty)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        XCTAssertEqual(editor.keys, [53], "Idle Escape uses the native editor's close behavior")
    }

    func testInlineMoveUsesProjectedSnapRadiusAndDragThreshold() {
        let (editor, canvas) = fixture(twoPieces: true)
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.mode = .move
        var moves: [CGPoint] = []
        canvas.onMove = { _, point, _ in moves.append(point) }
        // 2 source pixels per point: four pixels are only two screen points.
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 260, y: 20)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 256, y: 20)))
        XCTAssertTrue(moves.isEmpty)
        // Proposed x=120 is 20 pixels (10 points) from the first piece's right edge 100.
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 230, y: 20)))
        XCTAssertEqual(moves.last, CGPoint(x: 100, y: -50))
        XCTAssertTrue(canvas.alignmentGuides.contains { $0.start.x == 100 && $0.start.y == -66 })
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertEqual(moves.last, CGPoint(x: 120, y: -50))
        XCTAssertTrue(canvas.alignmentGuides.isEmpty)
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(moves.last, CGPoint(x: 100, y: -50))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 230, y: 20), modifiers: .option))
        XCTAssertEqual(moves.last, CGPoint(x: 120, y: -50), "Release modifiers must apply without another drag event")
    }

    func testMoveClickOnUncoveredCanvasClearsSelectionAndHoverWithoutStartingDrag() {
        let (editor, canvas) = fixture(twoPieces: true)
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.mode = .move
        let original = canvas.document
        var selections: [UUID?] = []
        canvas.onSelect = { selections.append($0) }
        canvas.onMove = { _, _, _ in XCTFail("A blank click and drag must not move a piece") }
        canvas.onCut = { _, _, _ in XCTFail("A blank click must not cut") }
        canvas.onCancelMove = { XCTFail("A blank click must not create a move transaction") }

        let first = CGPoint(x: 40, y: 30), second = CGPoint(x: 280, y: 30)
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, first))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, first))
        XCTAssertEqual(canvas.selectedID, original.pieces[0].id)
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, second))
        XCTAssertEqual(canvas.hoveredID, original.pieces[1].id)

        // The gap is inside document bounds, between the two source pieces.
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 225, y: 30)))
        XCTAssertNil(canvas.selectedID)
        XCTAssertNil(canvas.hoveredID)
        XCTAssertTrue(canvas.needsDisplay, "The selected border and hover outline must be redrawn immediately")
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, second))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, second))
        XCTAssertNil(canvas.selectedID)
        XCTAssertTrue(canvas.alignmentGuides.isEmpty)
        XCTAssertTrue(canvas.document.isIdentical(to: original))
        XCTAssertTrue(editor.undoStack.isEmpty)
        XCTAssertEqual(selections, [original.pieces[0].id, nil])

        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, second))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, second))
        XCTAssertEqual(canvas.selectedID, original.pieces[1].id, "Clicking content must select it again")
        XCTAssertTrue(canvas.document.isIdentical(to: original))
    }

    func testMoveBackgroundClicksRouteThroughEditorAndCenteredViewportAtDifferentZooms() throws {
        for zoom: CGFloat in [0.5, 2] {
            let (editor, canvas) = fixture(twoPieces: true)
            editor.currentTool = .stitch
            canvas.mode = .move
            let (container, clip, window) = scrollHost(editor, magnification: zoom)
            defer { window.orderOut(nil) }
            let original = canvas.document
            canvas.onMove = { _, _, _ in XCTFail("Background clicks must not change geometry") }
            canvas.onCut = { _, _, _ in XCTFail("Background clicks must not cut") }
            canvas.onCancelMove = { XCTFail("Background clicks must not create a move transaction") }

            let editorBlank = mouse(.leftMouseDown, editor, CGPoint(x: 250, y: 150))
            let viewportPoint = CGPoint(x: clip.bounds.minX + 5, y: clip.bounds.minY + 5)
            XCTAssertFalse(editor.bounds.contains(editor.convert(viewportPoint, from: clip)))
            let viewportBlank = mouse(.leftMouseDown, clip, viewportPoint)
            for (event, expectedTarget) in [(editorBlank, editor as NSView), (viewportBlank, clip as NSView)] {
                canvas.selectedID = original.pieces[0].id
                canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 280, y: 30)))
                XCTAssertNotNil(canvas.hoveredID)
                let target = try XCTUnwrap(recipient(for: event, in: container))
                XCTAssertTrue(target === expectedTarget, "Background at zoom \(zoom) reached \(type(of: target)), expected \(type(of: expectedTarget))")
                target.mouseDown(with: event)
                XCTAssertNil(canvas.selectedID)
                XCTAssertNil(canvas.hoveredID)
                XCTAssertTrue(window.firstResponder === canvas)
                // Follow-up events on the background view must not start an annotation or move.
                target.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 280, y: 30)))
                target.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 280, y: 30)))
                XCTAssertTrue(canvas.document.isIdentical(to: original))
                XCTAssertTrue(editor.undoStack.isEmpty)
                XCTAssertEqual(editor.selectionRect, canvas.frame)
            }

            let reselect = mouse(.leftMouseDown, canvas, CGPoint(x: 280, y: 30))
            let target = try XCTUnwrap(recipient(for: reselect, in: container))
            XCTAssertTrue(target === canvas)
            target.mouseDown(with: reselect)
            target.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 280, y: 30)))
            XCTAssertEqual(canvas.selectedID, original.pieces[1].id)
            editor.currentTool = .arrow
            XCTAssertFalse(editor.handleStitchMoveMouseDown(with: viewportBlank), "Other tools must retain their event path")
            XCTAssertEqual(canvas.selectedID, original.pieces[1].id)
        }
    }

    func testNativeToolbarAndSeparateOptionsWindowClicksPreserveMoveSelection() throws {
        let (editor, canvas) = fixture()
        editor.currentTool = .stitch
        editor.stitchMode = .move
        canvas.mode = .move
        let (container, clip, window) = scrollHost(editor)
        defer { window.orderOut(nil) }
        let original = canvas.document
        canvas.selectedID = original.pieces[0].id
        canvas.onSelect = { _ in XCTFail("Native control clicks must not deselect the canvas") }
        var actions = 0
        let strips = container.subviews.compactMap { $0 as? ToolbarStripView }.filter { !$0.isHidden }
        let toolbarButton = try XCTUnwrap(strips.flatMap(\.buttonViews).first { $0.onMouseDown == nil })
        toolbarButton.onClick = { _ in actions += 1 }
        let options = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let optionsButton = ToolbarButtonView(action: .copy, sfSymbol: "doc.on.doc", tooltip: "Copy")
        optionsButton.frame.origin = CGPoint(x: 20, y: 20)
        optionsButton.onClick = { _ in actions += 1 }
        options.addSubview(optionsButton)
        let optionsWindow = NSPanel(contentRect: options.frame, styleMask: .borderless, backing: .buffered, defer: false)
        optionsWindow.contentView = options
        defer { optionsWindow.orderOut(nil) }

        for (root, button) in [(container, toolbarButton), (options, optionsButton)] {
            let event = mouse(.leftMouseDown, button, CGPoint(x: 10, y: 10))
            let target = try XCTUnwrap(recipient(for: event, in: root))
            XCTAssertTrue(target === button, "The control must receive its click directly")
            target.mouseDown(with: event)
            target.mouseUp(with: mouse(.leftMouseUp, button, CGPoint(x: 10, y: 10)))
            XCTAssertEqual(canvas.selectedID, original.pieces[0].id)
        }
        XCTAssertFalse(strips.isEmpty)
        for strip in strips {
            // The one-point inset is in the native strip's padding, outside every button.
            let padding = CGPoint(x: strip.bounds.minX + 1, y: strip.bounds.midY)
            XCTAssertFalse(strip.buttonViews.contains { $0.frame.contains(padding) })
            let event = mouse(.leftMouseDown, strip, padding)
            let target = try XCTUnwrap(recipient(for: event, in: container))
            XCTAssertTrue(target === strip, "Stitch toolbar padding must consume the click")
            target.mouseDown(with: event)
            target.mouseUp(with: mouse(.leftMouseUp, strip, padding))
            XCTAssertEqual(canvas.selectedID, original.pieces[0].id)
        }
        let scroll = try XCTUnwrap(clip.enclosingScrollView)
        for tool in [AnnotationTool.arrow, .rectangle] {
            editor.handleToolbarAction(.tool(tool))
            for strip in strips where !strip.isHidden {
                let padding = CGPoint(x: strip.bounds.minX + 1, y: strip.bounds.midY)
                let event = mouse(.leftMouseDown, strip, padding)
                let target = try XCTUnwrap(recipient(for: event, in: container))
                let unobstructed = try XCTUnwrap(recipient(for: event, in: scroll))
                XCTAssertFalse(target === strip, "Drawing tools must let padding clicks through")
                XCTAssertTrue(target === unobstructed, "Padding clicks must follow the native path beneath the toolbar")
            }
        }
        XCTAssertEqual(actions, 2)
        XCTAssertTrue(canvas.document.isIdentical(to: original))
        XCTAssertTrue(editor.undoStack.isEmpty)
    }

    func testMoveEscapeDeselectsAndClearsHoverBeforeForwardingUnusedEscape() {
        let (editor, canvas) = fixture(twoPieces: true)
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.mode = .move
        let original = canvas.document
        let hover = mouse(.mouseMoved, canvas, CGPoint(x: 280, y: 30))
        let escape = TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53)
        canvas.selectedID = original.pieces[0].id
        canvas.mouseMoved(with: hover)
        canvas.keyDown(with: escape)
        XCTAssertNil(canvas.selectedID)
        XCTAssertNil(canvas.hoveredID)
        XCTAssertTrue(editor.keys.isEmpty)
        canvas.mouseMoved(with: hover)
        canvas.keyDown(with: escape)
        XCTAssertNil(canvas.hoveredID, "Escape must also clear a hover-only border")
        XCTAssertTrue(editor.keys.isEmpty)
        canvas.keyDown(with: escape)
        XCTAssertEqual(editor.keys, [53])
        XCTAssertTrue(canvas.document.isIdentical(to: original))
        XCTAssertTrue(editor.undoStack.isEmpty)
    }

    func testNativeToolAndCommandKeysForwardButMoveKeysStayLocal() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.mode = .move
        var deleted = 0, moved = 0
        canvas.onDelete = { deleted += 1 }
        canvas.onMove = { _, _, _ in moved += 1 }
        canvas.selectedID = canvas.document.pieces[0].id
        for (characters, code) in [("r", UInt16(15)), ("c", UInt16(8)), ("v", UInt16(9))] {
            canvas.keyDown(with: TestKeyEvent.keyDown(characters: characters, keyCode: code))
        }
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "s", keyCode: 1, modifiers: .command))
        XCTAssertEqual(editor.keys, [15, 8, 9, 1])
        XCTAssertEqual(canvas.mode, .move)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 124))
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 51))
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(deleted, 1)
        canvas.mode = .removeSpace
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 51))
        XCTAssertEqual(editor.keys.last, 51)
        XCTAssertEqual(deleted, 1)
    }

    func testBandGuidesSnapBothEndsInDocumentPixelsAndReverseDrags() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        var cuts: [(StitchAxis, CGFloat, CGFloat)] = []
        canvas.onCut = { cuts.append(($0, $1, $2)) }
        canvas.bandGuideRows = [-20, 30]
        drag(canvas, from: CGPoint(x: 40, y: 27), to: CGPoint(x: 43, y: 76))
        XCTAssertEqual(cuts[0].1, -20)
        XCTAssertEqual(cuts[0].2, 30)
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 76)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 40, y: 100)))
        XCTAssertEqual(canvas.bandAxis, .horizontal)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 150, y: 27)))
        XCTAssertEqual(canvas.bandAxis, .horizontal, "Reversing past the start and turning sideways must keep the same cut axis")
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 150, y: 27)))
        XCTAssertEqual(cuts[1].1, 30)
        XCTAssertEqual(cuts[1].2, -20)
        canvas.bandGuideColumns = [-60, 50]
        drag(canvas, from: CGPoint(x: 38, y: 30), to: CGPoint(x: 147, y: 33))
        XCTAssertEqual(cuts[2].1, -60)
        XCTAssertEqual(cuts[2].2, 50)
    }

    func testOptionImmediatelyReleasesBandSnappingAndFinalCutUsesRawEndpoints() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-18, 30]
        var cut: (CGFloat, CGFloat)?
        canvas.onCut = { _, a, b in cut = (a, b) }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 43, y: 79)))
        XCTAssertEqual(canvas.bandGuideMatches, [-18, 30])
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertTrue(canvas.bandGuideMatches.isEmpty)
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(canvas.bandGuideMatches, [-18, 30])
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 43, y: 79), modifiers: .option))
        XCTAssertEqual(cut?.0, -20)
        XCTAssertEqual(cut?.1, 29)
        XCTAssertTrue(canvas.bandGuideMatches.isEmpty)
    }

    func testNewAnalysisDoesNotMoveAnActiveBand() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-18, 30]
        var cuts: [(CGFloat, CGFloat)] = []
        canvas.onCut = { _, a, b in cuts.append((a, b)) }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.bandGuideRows = [-20, 29]
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 43, y: 79)))
        XCTAssertEqual(canvas.bandGuideMatches, [-18, 30])
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 43, y: 79)))
        XCTAssertEqual(cuts[0].0, -18)
        XCTAssertEqual(cuts[0].1, 30)
        drag(canvas, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 43, y: 79))
        XCTAssertEqual(cuts[1].0, -20)
        XCTAssertEqual(cuts[1].1, 29)
    }

    func testBandHoverHighlightsBothPossibleAxesAndOptionDisablesThem() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-18, 30]
        canvas.bandGuideColumns = [-60, 50]
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 40, y: 30)))
        XCTAssertEqual(canvas.bandHoverRow, -18)
        XCTAssertEqual(canvas.bandHoverColumn, -60)
        XCTAssertNil(canvas.bandAxis)
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertNil(canvas.bandHoverRow)
        XCTAssertNil(canvas.bandHoverColumn)
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(canvas.bandHoverRow, -18)
        XCTAssertEqual(canvas.bandHoverColumn, -60)
        canvas.mouseExited(with: mouse(.mouseMoved, canvas, CGPoint(x: 40, y: 30)))
        XCTAssertNil(canvas.bandHoverRow)
        XCTAssertNil(canvas.bandHoverColumn)
    }

    func testRemovalGuidesOnlyDrawWhileHoveringCapturedContent() throws {
        let (editor, canvas) = fixture(twoPieces: true)
        let window = host(editor)
        defer { window.orderOut(nil) }
        func raster() throws -> Data {
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let bytes = try XCTUnwrap(bitmap.bitmapData)
            var pixels = Data()
            let rowLength = bitmap.pixelsWide * bitmap.bitsPerPixel / 8
            for row in 0..<bitmap.pixelsHigh {
                pixels.append(bytes.advanced(by: row * bitmap.bytesPerRow), count: rowLength)
            }
            return pixels
        }
        let unobstructed = try raster()
        canvas.bandGuideRows = [-18, 30]
        canvas.bandGuideColumns = [-60, 50]
        XCTAssertFalse(canvas.showsBandGuides)
        XCTAssertEqual(try raster(), unobstructed, "Idle Remove must leave the image clean")

        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 40, y: 30)))
        XCTAssertTrue(canvas.showsBandGuides)
        XCTAssertNotEqual(try raster(), unobstructed)
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 225, y: 30)))
        XCTAssertFalse(canvas.showsBandGuides, "A gap between captured pieces is canvas, not an image")
        XCTAssertNil(canvas.bandHoverRow)
        XCTAssertNil(canvas.bandHoverColumn)
        XCTAssertEqual(try raster(), unobstructed)

        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 280, y: 30)))
        XCTAssertTrue(canvas.showsBandGuides, "Every captured piece can show removal guides")
        canvas.mouseExited(with: mouse(.mouseMoved, canvas, CGPoint(x: 280, y: 30)))
        XCTAssertFalse(canvas.showsBandGuides)
        XCTAssertEqual(try raster(), unobstructed)
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertFalse(canvas.showsBandGuides, "Modifier changes must not revive an exited hover")
    }

    func testUnmatchedRemovalHoverStillRedrawsWhenEnteringAndLeavingImage() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-18]
        canvas.bandGuideColumns = [-60]
        canvas.needsDisplay = false
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 200, y: 150)))
        XCTAssertTrue(canvas.showsBandGuides)
        XCTAssertNil(canvas.bandHoverRow)
        XCTAssertNil(canvas.bandHoverColumn)
        XCTAssertTrue(canvas.needsDisplay, "Faint guides need a redraw even without a nearby snap")
        canvas.needsDisplay = false
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: -10, y: 150)))
        XCTAssertFalse(canvas.showsBandGuides)
        XCTAssertTrue(canvas.needsDisplay)
    }

    func testRemovalGuidesRemainDuringActiveDragOutsideImageAndOptionStillBypassesSnapping() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.bandGuideRows = [-18, 30]
        var cut: (CGFloat, CGFloat)?
        canvas.onCut = { _, from, to in cut = (from, to) }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 43, y: 79)))
        XCTAssertTrue(canvas.showsBandGuides)
        XCTAssertEqual(canvas.bandGuideMatches, [-18, 30])
        canvas.mouseExited(with: mouse(.mouseMoved, canvas, CGPoint(x: 450, y: 79)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 450, y: 79)))
        XCTAssertTrue(canvas.showsBandGuides, "Leaving the image must not interrupt an active cut")
        XCTAssertEqual(canvas.bandGuideMatches, [-18, 30])
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertTrue(canvas.showsBandGuides)
        XCTAssertTrue(canvas.bandGuideMatches.isEmpty)
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 450, y: 79), modifiers: .option))
        XCTAssertEqual(cut?.0, -20)
        XCTAssertEqual(cut?.1, 29)
        XCTAssertFalse(canvas.showsBandGuides)
    }

    func testRemovalHoverRefreshUsesCurrentPieceCoverageAndPixelProjection() {
        let (editor, canvas) = fixture(twoPieces: true)
        let window = host(editor)
        defer { window.orderOut(nil) }
        let original = canvas.document
        let hover = mouse(.mouseMoved, canvas, CGPoint(x: 180, y: 30))
        canvas.mouseMoved(with: hover)
        XCTAssertTrue(canvas.showsBandGuides)
        var narrowed = original
        narrowed.pieces[0].source.size.width = 40
        canvas.refresh(narrowed, preview: nil)
        XCTAssertFalse(canvas.showsBandGuides, "Changing source coverage must clear a hover over a new gap")
        canvas.refresh(original, preview: nil)
        XCTAssertFalse(canvas.showsBandGuides, "Refresh must not revive cleared hover feedback")
        canvas.mouseMoved(with: hover)
        var wider = original
        wider.pieces[1].origin.x = 300
        canvas.refresh(wider, preview: nil)
        XCTAssertFalse(canvas.showsBandGuides, "The stationary pointer now projects into a gap at the new canvas width")
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, CGPoint(x: 40, y: 30)))
        XCTAssertTrue(canvas.showsBandGuides)
        canvas.refresh(StitchDocument(), preview: nil)
        XCTAssertFalse(canvas.showsBandGuides)
    }

    func testRemovalHoverIgnoresNativeChromeAndClearsWhenOptionsTakeWindowFocus() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        let hover = mouse(.mouseMoved, canvas, CGPoint(x: 40, y: 30))
        canvas.mouseMoved(with: hover)
        XCTAssertTrue(canvas.showsBandGuides)
        let chrome = NSView(frame: canvas.frame)
        editor.addSubview(chrome)
        canvas.mouseMoved(with: hover)
        XCTAssertFalse(canvas.showsBandGuides, "Native controls in front of the image own the hover")
        chrome.removeFromSuperview()
        canvas.mouseMoved(with: hover)
        XCTAssertTrue(canvas.showsBandGuides)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(canvas.showsBandGuides, "Seams and other key panels must leave no passive guide feedback")
        canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertFalse(canvas.showsBandGuides)
    }

    func testRemovalHoverRejectsClippedContentUntilItIsScrolledIntoView() {
        let (editor, canvas) = fixture()
        let scroll = NSScrollView(frame: editor.frame)
        scroll.allowsMagnification = true
        scroll.maxMagnification = 8
        scroll.documentView = editor
        let window = host(scroll)
        defer { window.orderOut(nil) }
        scroll.magnification = 4
        scroll.tile()
        canvas.scrollToVisible(CGRect(x: 240, y: 20, width: 60, height: 20))
        let visible = CGPoint(x: 270, y: 30)
        let clipped = CGPoint(x: 40, y: 30)
        XCTAssertTrue(canvas.visibleRect.contains(visible))
        XCTAssertFalse(canvas.visibleRect.contains(clipped))
        canvas.bandGuideRows = [-20]
        canvas.bandGuideColumns = [-60, 170]
        canvas.mouseMoved(with: mouse(.mouseMoved, canvas, visible))
        XCTAssertTrue(canvas.showsBandGuides)
        XCTAssertEqual(canvas.bandHoverRow, -20)
        let clippedHover = mouse(.mouseMoved, canvas, clipped)
        XCTAssertFalse(recipient(for: clippedHover, in: scroll) === canvas,
                       "A real image point clipped by the viewport cannot receive native hover")
        canvas.mouseMoved(with: clippedHover)
        XCTAssertFalse(canvas.showsBandGuides)
        XCTAssertNil(canvas.bandHoverRow)
        XCTAssertNil(canvas.bandHoverColumn)

        canvas.scrollToVisible(CGRect(origin: clipped, size: CGSize(width: 1, height: 1)).insetBy(dx: -4, dy: -4))
        XCTAssertTrue(canvas.visibleRect.contains(clipped))
        let revealedHover = mouse(.mouseMoved, canvas, clipped)
        XCTAssertTrue(recipient(for: revealedHover, in: scroll) === canvas)
        canvas.mouseMoved(with: revealedHover)
        XCTAssertTrue(canvas.showsBandGuides)
        XCTAssertEqual(canvas.bandHoverRow, -20)
        XCTAssertEqual(canvas.bandHoverColumn, -60)
    }

    func testRemovalGuideStateClearsOnCancelModeChangeAndWindowDetach() {
        for exit in 0..<3 {
            let (editor, canvas) = fixture()
            let window = host(editor)
            defer { window.orderOut(nil) }
            canvas.bandGuideRows = [-18, 30]
            canvas.onCut = { _, _, _ in XCTFail("An exited gesture must not cut") }
            canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 43, y: 79)))
            XCTAssertTrue(canvas.showsBandGuides)
            switch exit {
            case 0: canvas.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
            case 1: canvas.mode = .move
            default: canvas.removeFromSuperview()
            }
            XCTAssertFalse(canvas.showsBandGuides)
            XCTAssertNil(canvas.bandAxis)
            XCTAssertTrue(canvas.bandGuideMatches.isEmpty)
            canvas.mode = .removeSpace
            canvas.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
            canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 43, y: 79)))
            XCTAssertFalse(canvas.showsBandGuides)
        }
    }

    private func fixture(twoPieces: Bool = false) -> (KeyEditor, StitchCanvasView) {
        let editor = KeyEditor(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        editor.applySelection(CGRect(x: 10, y: 20, width: 200, height: 100))
        let image = ImageProbe.quadrantImage(width: 400, height: 200).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var first = StitchPiece(image: image, origin: CGPoint(x: -100, y: -50))
        var pieces = [first]
        if twoPieces {
            first.source.size.width = 200
            var second = first
            second.id = UUID(); second.origin.x = 150; second.source.size.width = 150
            pieces = [first, second]
        }
        let canvas = StitchCanvasView(frame: .zero)
        editor.addSubview(canvas)
        canvas.inlineEditor = editor
        canvas.refresh(StitchDocument(pieces: pieces), preview: nil)
        return (editor, canvas)
    }
    private func fractionalFixture(origin: CGPoint) -> (KeyEditor, StitchCanvasView) {
        let (editor, canvas) = fixture()
        var document = canvas.document
        document.pieces[0].origin = origin
        document.pieces[0].source.size = CGSize(width: 399.6, height: 199.6)
        document.style.visible = false
        editor.applySelection(CGRect(x: 10, y: 20, width: document.bounds.integral.width * 8, height: document.bounds.integral.height * 8))
        canvas.refresh(document, preview: nil)
        return (editor, canvas)
    }
    private func host(_ editor: NSView) -> NSWindow {
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        return window
    }
    private func scrollHost(_ editor: NSView, magnification: CGFloat = 1) -> (NSView, CenteringClipView, NSWindow) {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scroll = NSScrollView(frame: container.bounds)
        let clip = CenteringClipView(frame: scroll.contentView.frame)
        scroll.contentView = clip
        scroll.documentView = editor
        scroll.allowsMagnification = true
        container.addSubview(scroll)
        if let overlay = editor as? EditorView {
            overlay.chromeParentView = container
            // Detached editor chrome is a sibling of the scroll view, outside magnification.
            for chrome in overlay.subviews where chrome is ToolbarStripView || chrome is ToolOptionsRowView {
                container.addSubview(chrome)
            }
            overlay.rebuildToolbarLayout()
        }
        let window = host(container)
        scroll.magnification = magnification
        scroll.tile()
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        return (container, clip, window)
    }
    private func recipient(for event: NSEvent, in root: NSView) -> NSView? {
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return root.hitTest(point)
    }
    private func mouse(_ type: NSEvent.EventType, _ canvas: NSView, _ point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func drag(_ canvas: StitchCanvasView, from: CGPoint, to: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, from))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, to))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, to))
    }
}
