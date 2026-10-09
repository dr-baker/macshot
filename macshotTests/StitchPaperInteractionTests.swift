import AppKit
import XCTest

@MainActor
final class StitchPaperInteractionTests: XCTestCase {
    func testStationaryPaperAndBackgroundClicksKeepPreviewVisible() throws {
        let (preview, _, point) = try previewFixture()
        var edits = 0, begins = 0
        preview.onEdit = { edits += 1 }
        preview.onCameraBegin = { begins += 1 }
        preview.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2)))
        preview.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 2, y: 2)))
        XCTAssertEqual(edits, 0)
        preview.mouseDown(with: mouse(.leftMouseDown, at: point))
        preview.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 1, y: point.y + 1)))
        preview.mouseUp(with: mouse(.leftMouseUp, at: point))
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(begins, 0, "A stationary click must not create an angle edit")
        XCTAssertFalse(preview.acceptsFirstResponder)
    }

    func testPaperOrbitReportsOneGestureWithDownwardPositiveCameraMovement() throws {
        let (preview, _, point) = try previewFixture()
        let initial = preview.camera
        var begins = 0, edits = 0
        var values: [StitchPaperCamera] = [], ends: [Bool] = []
        preview.onCameraBegin = { begins += 1 }
        preview.onCameraChanged = { values.append($0) }
        preview.onCameraEnd = { ends.append($0) }
        preview.onEdit = { edits += 1 }
        preview.mouseDown(with: mouse(.leftMouseDown, at: point))
        preview.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 20, y: point.y - 10)))
        preview.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 30, y: point.y - 20)))
        preview.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: point.x + 30, y: point.y - 20)))
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(values.last, initial.dragged(by: CGPoint(x: 30, y: 20)))
        XCTAssertEqual(ends, [true])
        XCTAssertEqual(edits, 0)
    }

    func testPaperPrecisionAxisLockCancellationAndDoubleClickReset() throws {
        let (preview, _, point) = try previewFixture()
        let initial = preview.camera
        var ends: [Bool] = [], resets = 0
        preview.onCameraEnd = { ends.append($0) }
        preview.onReset = { resets += 1 }
        preview.mouseDown(with: mouse(.leftMouseDown, at: point))
        preview.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 24, y: point.y - 8), flags: [.option, .shift]))
        XCTAssertEqual(preview.camera.perspective, initial.perspective)
        XCTAssertEqual(preview.camera.yaw, initial.yaw + 0.9, accuracy: 0.0001)
        XCTAssertTrue(preview.cancelCameraGesture())
        XCTAssertEqual(preview.camera, initial)
        XCTAssertEqual(ends, [false])
        preview.mouseUp(with: mouse(.leftMouseUp, at: point))
        XCTAssertEqual(ends, [false], "Mouse-up after cancellation must not commit")
        preview.mouseDown(with: mouse(.leftMouseDown, at: point, clicks: 2))
        preview.mouseUp(with: mouse(.leftMouseUp, at: point, clicks: 2))
        XCTAssertEqual(resets, 1)
    }

    func testLivePaperSurvivesAnimationCancellationUntilFinalImageReplacement() throws {
        let (preview, document, _) = try previewFixture()
        let texture = try XCTUnwrap(StitchRenderer.render(document))
        let background = try XCTUnwrap(ImageProbe.solidImage(width: 100, height: 100)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(preview.showInteractivePaper(texture: texture, document: document,
            frame: try XCTUnwrap(preview.paperFrame), background: background))
        XCTAssertTrue(preview.isShowingInteractivePaper)
        preview.cancelAnimation()
        XCTAssertTrue(preview.isShowingInteractivePaper, "Final CPU rendering must not blink away the live paper")
        preview.image = NSImage(cgImage: texture, size: document.bounds.size)
        XCTAssertFalse(preview.isShowingInteractivePaper)
        XCTAssertTrue(preview.showInteractivePaper(texture: texture, document: document,
            frame: try XCTUnwrap(preview.paperFrame), background: background))
        preview.image = nil
        XCTAssertFalse(preview.isShowingInteractivePaper, "Content/redaction invalidation must wipe the cached live texture")
        XCTAssertFalse(preview.containsPaper(at: CGPoint(x: preview.bounds.midX, y: preview.bounds.midY)))
    }

    func testOrbitReusesTexturedFaceLayersAndMatchesProjectedVertices() throws {
        var document = try documentFixture()
        let texture = try XCTUnwrap(StitchRenderer.render(document))
        let initial = try XCTUnwrap(StitchAccordionProjection(document: document))
        let frame = CGRect(x: 18, y: 12, width: 420, height: 310)
        let effect = try XCTUnwrap(StitchAccordionCollapseView(interactiveTexture: texture, projection: initial, frame: frame))
        let original = Dictionary(uniqueKeysWithValues: try XCTUnwrap(effect.layer?.sublayers).map { (try XCTUnwrap($0.name), $0) })
        document.style.accordionPerspective = -12
        document.style.accordionYaw = 29
        let next = try XCTUnwrap(StitchAccordionProjection(document: document))
        XCTAssertTrue(effect.updateInteractive(projection: next, frame: frame))
        let layers = try XCTUnwrap(effect.layer?.sublayers)
        XCTAssertEqual(layers.count, original.count)
        for layer in layers {
            let name = try XCTUnwrap(layer.name)
            XCTAssertTrue(layer === original[name])
            XCTAssertNil(layer.animation(forKey: "transform"), "Direct manipulation must follow the pointer without an implicit animation")
            let index = try XCTUnwrap(Int(name.replacingOccurrences(of: "accordion.face.", with: "")))
            let face = next.faces[index]
            let sx = frame.width / next.documentBounds.width, sy = frame.height / next.documentBounds.height
            for vertex in face.vertices {
                let local = CGPoint(x: (vertex.source.x - next.documentBounds.minX) * sx - layer.contentsRect.minX * frame.width,
                                    y: (vertex.source.y - next.documentBounds.minY) * sy - layer.contentsRect.minY * frame.height)
                let transform = layer.transform
                let w = local.x * transform.m14 + local.y * transform.m24 + transform.m44
                XCTAssertEqual((local.x * transform.m11 + local.y * transform.m21 + transform.m41) / w,
                    (vertex.projected.x - next.documentBounds.minX) * sx, accuracy: 0.00001)
                XCTAssertEqual((local.x * transform.m12 + local.y * transform.m22 + transform.m42) / w,
                    (vertex.projected.y - next.documentBounds.minY) * sy, accuracy: 0.00001)
            }
        }
        XCTAssertFalse(effect.acceptsFirstResponder)
        XCTAssertNil(effect.hitTest(.zero))
        XCTAssertEqual(effect.layer?.shadowRadius, BeautifyRenderer.stitchPaperShadow.radius)
    }

    func testAnglePadSupportsPrecisionAxisLockAndCancellation() throws {
        let control = StitchPaperAngleControl(frame: CGRect(x: 0, y: 0, width: 176, height: 92))
        control.camera = StitchPaperCamera(perspective: 0, yaw: 0)
        let origin = CGPoint(x: control.padRect.midX, y: control.padRect.midY)
        var begins = 0, ends: [Bool] = []
        control.onCameraBegin = { begins += 1 }
        control.onCameraEnd = { ends.append($0) }
        control.mouseDown(with: mouse(.leftMouseDown, at: origin))
        control.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: origin.x + 20, y: origin.y + 3), flags: [.shift]))
        let normalYaw = control.camera.yaw
        XCTAssertGreaterThan(normalYaw, 0)
        XCTAssertEqual(control.camera.perspective, 0)
        XCTAssertTrue(control.cancelCameraGesture())
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 0, yaw: 0))
        control.mouseDown(with: mouse(.leftMouseDown, at: origin))
        control.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: origin.x + 20, y: origin.y + 3), flags: [.shift, .option]))
        XCTAssertEqual(control.camera.yaw, normalYaw / 4, accuracy: 0.0001)
        control.mouseUp(with: mouse(.leftMouseUp, at: origin))
        XCTAssertEqual(begins, 2)
        XCTAssertEqual(ends, [false, true])
    }

    func testAnglePadKeyboardAndAccessibilityKeepCommandKeysInResponderChain() throws {
        let control = StitchPaperAngleControl(frame: CGRect(x: 0, y: 0, width: 176, height: 92))
        let receiver = PaperCommandReceiver()
        control.nextResponder = receiver
        control.camera = StitchPaperCamera(perspective: 0, yaw: 0)
        var ends: [Bool] = []
        control.onCameraEnd = { ends.append($0) }
        control.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 124))
        control.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 125, modifiers: .option))
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 0.25, yaw: 1))
        XCTAssertEqual(ends, [true, true])
        control.keyDown(with: TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command))
        control.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        XCTAssertEqual(receiver.keys, [8, 53])
        let tilt = try XCTUnwrap(control.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first)
        XCTAssertTrue(tilt.accessibilityPerformIncrement())
        XCTAssertEqual(control.camera.perspective, 1.25)
        XCTAssertTrue((control.accessibilityValue() as? String)?.contains("1.25°") == true)
        control.isEnabled = false
        XCTAssertFalse(tilt.accessibilityPerformDecrement())
    }

    func testNativeAccessibilityHierarchyExposesTwoAngleAxesResetAndPaperPreview() throws {
        let (preview, _, _) = try previewFixture()
        let control = StitchPaperAngleControl(frame: CGRect(x: 20, y: 330, width: 176, height: 92))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.addSubview(preview)
        root.addSubview(control)
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()

        // Ask AppKit's published, unignored hierarchy rather than calling only
        // the adjustment methods. This catches cellless controls disappearing.
        let published = NSAccessibility.unignoredChildren(from: try XCTUnwrap(root.accessibilityChildren()))
        XCTAssertTrue(published.contains { ($0 as? NSView) === control })
        XCTAssertTrue(published.contains { ($0 as? NSView) === preview })
        XCTAssertTrue(control.isAccessibilityElement())
        XCTAssertEqual(control.accessibilityRole(), .group)
        let children = NSAccessibility.unignoredChildren(from: try XCTUnwrap(control.accessibilityChildren()))
        XCTAssertEqual(children.count, 3)
        let sliders = children.compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(sliders.count, 2)
        XCTAssertEqual(sliders.map { $0.accessibilityLabel() }, [L("Tilt"), L("Turn")])
        XCTAssertTrue(sliders.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .slider })
        XCTAssertTrue(sliders.allSatisfy { ($0.accessibilityParent() as? NSView) === control })
        XCTAssertTrue(sliders.allSatisfy { $0.accessibilityFrame().width > 0 && $0.accessibilityFrame().height > 0 })
        XCTAssertEqual((sliders[0].accessibilityMinValue() as? NSNumber)?.doubleValue, -30)
        XCTAssertEqual((sliders[0].accessibilityMaxValue() as? NSNumber)?.doubleValue, 30)
        XCTAssertEqual((sliders[1].accessibilityMinValue() as? NSNumber)?.doubleValue, -35)
        XCTAssertEqual((sliders[1].accessibilityMaxValue() as? NSNumber)?.doubleValue, 35)
        let nativeButton = try XCTUnwrap(control.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(nativeButton.cell is NSButtonCell, "Reset must use a native push-button cell")
        XCTAssertEqual(nativeButton.imagePosition, .imageOnly)
        let publishedClasses = children.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        let reset = try XCTUnwrap(children.first { !($0 is NSAccessibilityElement) } as? NSAccessibilityProtocol,
                                 "Expected the native Reset accessibility representative; got \(publishedClasses)")
        let nativeRepresentative = try XCTUnwrap(NSAccessibility.unignoredDescendant(of: nativeButton))
        XCTAssertTrue((reset as AnyObject) === (nativeRepresentative as AnyObject))
        XCTAssertTrue(reset.isAccessibilityElement())
        XCTAssertEqual(reset.accessibilityRole(), .button)
        XCTAssertEqual(reset.accessibilityLabel(), L("Reset view angle"))
        let resetParent = try XCTUnwrap(reset.accessibilityParent())
        XCTAssertTrue((NSAccessibility.unignoredAncestor(of: resetParent) as? NSView) === control)
        var resets = 0
        control.onReset = { resets += 1 }
        // AppKit can report false for an unordered headless window even after
        // delivering the native press. Verify the actual action reaches Reset.
        _ = reset.accessibilityPerformPress()
        XCTAssertEqual(resets, 1)

        XCTAssertEqual(preview.accessibilityRole(), .image)
        XCTAssertEqual(preview.accessibilityLabel(), L("Folded screenshot preview"))
        XCTAssertEqual(preview.accessibilityChildren()?.count, 0, "Rendering layers and the spinner are implementation details")
        preview.onReset = { resets += 1 }
        XCTAssertEqual(preview.accessibilityCustomActions()?.map(\.name), [L("Reset view angle")])
        control.isHidden = true
        XCTAssertFalse(control.isAccessibilityElement())
        XCTAssertTrue(control.accessibilityChildren()?.isEmpty == true)
    }

    func testAccessibilityAdjustsEachNumericAngleAndPreservesDisabledState() throws {
        let control = StitchPaperAngleControl(frame: CGRect(x: 0, y: 0, width: 176, height: 92))
        let sliders = try XCTUnwrap(control.accessibilityChildren()).compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(sliders.count, 2)
        let tilt = sliders[0], turn = sliders[1]
        control.camera = StitchPaperCamera(perspective: 0, yaw: 0)
        var ends: [Bool] = []
        control.onCameraEnd = { ends.append($0) }
        XCTAssertTrue(tilt.accessibilityPerformIncrement())
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 1, yaw: 0))
        XCTAssertTrue(turn.accessibilityPerformDecrement())
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 1, yaw: -1))
        tilt.setAccessibilityValue(NSNumber(value: 22.5))
        turn.setAccessibilityValue(NSNumber(value: -12.25))
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 22.5, yaw: -12.25))
        XCTAssertEqual((tilt.accessibilityValue() as? NSNumber)?.doubleValue, 22.5)
        XCTAssertEqual((turn.accessibilityValue() as? NSNumber)?.doubleValue, -12.25)
        XCTAssertEqual(ends, [true, true, true, true])
        control.isEnabled = false
        XCTAssertFalse(tilt.isAccessibilityEnabled())
        XCTAssertFalse(turn.isAccessibilityEnabled())
        XCTAssertFalse(tilt.accessibilityPerformIncrement())
        XCTAssertFalse(turn.accessibilityPerformDecrement())
        tilt.setAccessibilityValue(NSNumber(value: 0))
        turn.setAccessibilityValue(NSNumber(value: 0))
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 22.5, yaw: -12.25))
        XCTAssertEqual(ends.count, 4)
        control.isEnabled = true
        control.isHidden = true
        XCTAssertFalse(tilt.isAccessibilityEnabled())
        XCTAssertFalse(turn.accessibilityPerformIncrement())
        tilt.setAccessibilityValue(NSNumber(value: 0))
        XCTAssertEqual(control.camera, StitchPaperCamera(perspective: 22.5, yaw: -12.25))
    }

    private func documentFixture() throws -> StitchDocument {
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 256, height: 256)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 120, to: 136))
        document.style.transition = .accordion
        return document
    }

    private func previewFixture() throws -> (StitchPaperPreviewView, StitchDocument, CGPoint) {
        let document = try documentFixture()
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let preview = StitchPaperPreviewView(frame: CGRect(x: 0, y: 0, width: document.bounds.width + 48, height: document.bounds.height + 48))
        preview.projection = projection
        preview.paperFrame = CGRect(x: 24, y: 24, width: document.bounds.width, height: document.bounds.height)
        preview.image = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        let mapped = try XCTUnwrap(projection.project(CGPoint(x: 35, y: 35)))
        let point = CGPoint(x: 24 + mapped.x, y: 24 + document.bounds.height - mapped.y)
        XCTAssertTrue(preview.containsPaper(at: point))
        return (preview, document, point)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
}

private final class PaperCommandReceiver: NSResponder {
    var keys: [UInt16] = []
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}
