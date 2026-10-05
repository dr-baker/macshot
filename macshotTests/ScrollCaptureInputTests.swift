import Cocoa
import XCTest

@MainActor
final class ScrollCaptureInputTests: XCTestCase {
    func testEnterStopsScrollCaptureWithoutCopyingOrDismissingAfterCleanupClearsMode() {
        for code: UInt16 in [36, 76] {
            let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = ScrollCaptureInputDelegate()
            view.overlayDelegate = delegate
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            view.isScrollCapturing = true
            // The real stop callback tears down the HUD and clears this flag.
            // Key routing must still consume Enter after that synchronous cleanup.
            delegate.onStop = { [weak view] in view?.isScrollCapturing = false }

            view.keyDown(with: TestKeyEvent.keyDown(characters: "\r", keyCode: code))

            XCTAssertEqual(delegate.stopRequests, 1)
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.dismissRequests, 0)
            XCTAssertEqual(delegate.confirmRequests, 0)
            XCTAssertEqual(delegate.cancelScrollRequests, 0)
            XCTAssertFalse(view.isScrollCapturing)
        }
    }

    func testScrollKeyMonitorConsumesEnterAndEscapeWithoutScreenshotRequests() {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = ScrollCaptureInputDelegate()
        view.overlayDelegate = delegate
        view.isScrollCapturing = true
        for code: UInt16 in [36, 76, 53] {
            XCTAssertTrue(view.handleScrollCaptureKey(TestKeyEvent.keyDown(characters: "", keyCode: code)))
        }
        XCTAssertEqual(delegate.stopRequests, 2)
        XCTAssertEqual(delegate.cancelScrollRequests, 1)
        XCTAssertEqual(delegate.quickSaveRequests, 0)
        XCTAssertEqual(delegate.dismissRequests, 0)
        XCTAssertFalse(view.handleScrollCaptureKey(TestKeyEvent.keyDown(characters: "", keyCode: 124)))
    }

    func testOrdinaryCaptureAndEditorEnterStillRequestQuickSave() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let views: [OverlayView] = [OverlayView(frame: frame), EditorView(frame: frame)]
        for view in views {
            let delegate = ScrollCaptureInputDelegate()
            view.overlayDelegate = delegate
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            for code: UInt16 in [36, 76] {
                let event = TestKeyEvent.keyDown(characters: "\r", keyCode: code)
                XCTAssertFalse(view.handleScrollCaptureKey(event))
                view.keyDown(with: event)
            }
            XCTAssertEqual(delegate.quickSaveRequests, 2)
            XCTAssertEqual(delegate.stopRequests, 0)
            XCTAssertEqual(delegate.cancelScrollRequests, 0)
            XCTAssertEqual(delegate.dismissRequests, 0)
        }
    }
}

@MainActor
private final class ScrollCaptureInputDelegate: OverlayViewDelegate {
    var stopRequests = 0
    var cancelScrollRequests = 0
    var quickSaveRequests = 0
    var dismissRequests = 0
    var confirmRequests = 0
    var onStop: (() -> Void)?

    func overlayViewDidRequestStopScrollCapture() { stopRequests += 1; onStop?() }
    func overlayViewDidRequestCancelScrollCapture() { cancelScrollRequests += 1 }
    func overlayViewDidRequestQuickSave() { quickSaveRequests += 1 }
    func overlayViewDidCancel() { dismissRequests += 1 }
    func overlayViewDidConfirm() { confirmRequests += 1 }
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
