import Cocoa
import XCTest

@MainActor
final class SelectionOnlyOverlayTests: XCTestCase {
    func testStitchSelectorsReleaseTheirWindowBetweenCaptures() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let image = ImageProbe.quadrantImage(width: 100, height: 80)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let selector = StitchRegionSelection(capture: ScreenCapture(screen: screen, image: pixels))
        let number = selector.windowNumber
        let window = try XCTUnwrap(NSApp.windows.first { $0.windowNumber == Int(number) })
        XCTAssertNotNil(window.contentView)
        selector.dismiss()
        XCTAssertNil(window.contentView)
        XCTAssertEqual(selector.windowNumber, CGWindowID.max)
        selector.dismiss() // Selection completion and session cleanup can both dismiss.
        let next = StitchRegionSelection(capture: ScreenCapture(screen: screen, image: pixels))
        defer { next.dismiss() }
        XCTAssertNotEqual(next.windowNumber, number)
    }

    func testSelectionKeyboardCannotRunCaptureOrEditorActions() {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = SelectionOnlyDelegate()
        view.overlayDelegate = delegate
        view.selectionOnlyMode = true
        view.applySelection(NSRect(x: 30, y: 40, width: 200, height: 100))
        delegate.selections.removeAll()
        let originalTool = view.currentTool
        let originalEffects = view.effectsActive
        for event in [TestKeyEvent.keyDown(characters: "s", keyCode: 1, modifiers: .command),
                      TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command),
                      TestKeyEvent.keyDown(characters: "v", keyCode: 9, modifiers: .command),
                      TestKeyEvent.keyDown(characters: "r", keyCode: 15),
                      TestKeyEvent.keyDown(characters: " ", keyCode: 49)] {
            _ = view.performKeyEquivalent(with: event)
            view.keyDown(with: event)
        }
        view.handleToolbarAction(.detach)
        view.handleToolbarAction(.scrollCapture)
        XCTAssertEqual(delegate.outputRequests, 0)
        XCTAssertEqual(delegate.selections, [])
        XCTAssertEqual(view.currentTool, originalTool)
        XCTAssertEqual(view.effectsActive, originalEffects)
        XCTAssertTrue(view.annotations.isEmpty)

        view.keyDown(with: TestKeyEvent.keyDown(characters: "\r", keyCode: 36))
        XCTAssertEqual(delegate.selections, [view.selectionRect])
        view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        XCTAssertEqual(delegate.cancellations, 1)
        XCTAssertEqual(delegate.outputRequests, 0)
    }

    func testFullScreenSelectionKeepsToolbarsHidden() {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = SelectionOnlyDelegate()
        view.overlayDelegate = delegate
        view.selectionOnlyMode = true
        view.keyDown(with: TestKeyEvent.keyDown(characters: "f", keyCode: 3))
        XCTAssertEqual(delegate.selections, [view.bounds])
        XCTAssertFalse(view.showToolbars)
    }

    func testRawCallbackClipsWithoutTouchingClipboard() async throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let controller = OverlayWindowController(screen: screen)
        defer { controller.tearDown() }
        let clipboardChange = NSPasteboard.general.changeCount
        let picked = expectation(description: "raw rectangle")
        controller.setSelectionOnlyMode(onSelect: { rect in
            XCTAssertEqual(rect, NSRect(x: 0, y: 20, width: 90, height: 50))
            picked.fulfill()
        }, onCancel: { XCTFail("unexpected cancellation") })
        controller.overlayViewDidFinishSelection(NSRect(x: -10, y: 20, width: 100, height: 50))
        await fulfillment(of: [picked], timeout: 1)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChange)
        controller.dismiss()
    }

    func testFinishFlushDeliversCompletedSelectionExactlyOnceBeforeQueuedCallback() async throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let controller = OverlayWindowController(screen: screen)
        defer { controller.tearDown() }
        let rect = NSRect(x: 10, y: 20, width: 100, height: 50)
        var selections: [NSRect] = []
        controller.setSelectionOnlyMode(onSelect: { selections.append($0) }, onCancel: {})
        controller.overlayViewDidFinishSelection(rect)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(controller.flushPendingRawSelection())
        XCTAssertEqual(selections, [rect])
        XCTAssertFalse(controller.flushPendingRawSelection())
        let drained = expectation(description: "queued selection drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(selections, [rect])
    }

    func testDismissAndTearDownSuppressPendingSelectionEvenWhenFlushed() async throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        for tearDown in [false, true] {
            let controller = OverlayWindowController(screen: screen)
            defer { controller.tearDown() }
            controller.setSelectionOnlyMode(onSelect: { _ in XCTFail("dismissed selection delivered") }, onCancel: {})
            controller.overlayViewDidFinishSelection(NSRect(x: 10, y: 20, width: 100, height: 50))
            if tearDown { controller.tearDown() } else { controller.dismiss() }
            XCTAssertFalse(controller.flushPendingRawSelection())
        }
        let drained = expectation(description: "invalidated selections drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }

    func testCancelInvalidatesQueuedSelection() async throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let controller = OverlayWindowController(screen: screen)
        defer { controller.tearDown() }
        var cancelled = false
        controller.setSelectionOnlyMode(onSelect: { _ in XCTFail("selection fired after cancellation") },
                                        onCancel: { cancelled = true })
        controller.overlayViewDidFinishSelection(NSRect(x: 10, y: 20, width: 100, height: 50))
        controller.overlayViewDidCancel()
        XCTAssertFalse(controller.flushPendingRawSelection())
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertTrue(cancelled)
    }
}

@MainActor
private final class SelectionOnlyDelegate: OverlayViewDelegate {
    var selections: [NSRect] = []
    var inputPermissionRequests = 0
    var cancellations = 0
    var outputRequests = 0
    func overlayViewDidRequestInputMonitoringPermission() { inputPermissionRequests += 1 }
    func overlayViewDidCancel() { cancellations += 1 }
    func overlayViewDidConfirm() { outputRequests += 1 }
    func overlayViewDidRequestSave() { outputRequests += 1 }
    func overlayViewDidRequestQuickSave() { outputRequests += 1 }
    func overlayViewDidFinishSelection(_ rect: NSRect) { selections.append(rect) }
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidRequestSaveAs() { outputRequests += 1 }
    func overlayViewDidRequestPin() { outputRequests += 1 }
    func overlayViewDidRequestOCR() { outputRequests += 1 }
    func overlayViewDidRequestFileSave() { outputRequests += 1 }
    func overlayViewDidRequestUpload() { outputRequests += 1 }
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() { outputRequests += 1 }
    func overlayViewDidRequestScrollCapture(rect: NSRect) { outputRequests += 1 }
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
