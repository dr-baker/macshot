import AppKit
import XCTest

@MainActor
final class MediaExportProgressControllerTests: XCTestCase {
    private final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() { isOpen = true; waiter?.resume(); waiter = nil }
    }

    func testProgressStaysAboveItsCaptureEditorAndCancellationWaitsForTheJob() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let origin = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 120, dy: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        origin.isReleasedWhenClosed = false
        origin.level = NSWindow.Level(257)
        origin.orderFront(nil)
        defer { origin.close() }
        let previousKeyWindow = NSApp.keyWindow
        let coordinator = MediaExportCoordinator()
        let gate = Gate()
        defer { gate.open() }
        var completed = false
        let job = coordinator.start(title: "Progress fixture.gif", status: "Saving", operation: { cancellation, _ in
            await gate.wait()
            try cancellation.check()
        }, completion: { result in
            completed = true
            guard case .failure(let error) = result else { return XCTFail("Cancelled export succeeded") }
            XCTAssertTrue(error is CancellationError)
        })
        MediaExportProgressController.show(for: job, above: origin)
        let panel = try await waitForProgress(job)
        XCTAssertGreaterThan(panel.level.rawValue, origin.level.rawValue)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, screen.visibleFrame.midY, accuracy: 1)
        origin.close()
        XCTAssertTrue(panel.isVisible, "Closing the screenshot must leave the app-owned export cancellable")
        let cancel = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSButton }.first)
        cancel.performClick(nil)
        XCTAssertTrue(job.isCancelling)
        XCTAssertFalse(completed, "Cancelling must wait until the worker releases its file inputs")
        gate.open()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(completed)
        XCTAssertFalse(panel.isVisible)
    }

    func testFastExportDoesNotShowAPanelAfterItHasAlreadyFinished() async throws {
        _ = NSApplication.shared
        let coordinator = MediaExportCoordinator()
        let job = coordinator.start(title: "Fast export.gif", status: "Saving", operation: { _, _ in }, completion: { _ in })
        MediaExportProgressController.show(for: job)
        await coordinator.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "macshot.exportProgress.\(job.id)" })
    }

    func testFocusReturnsOnlyWhenTheOriginAndAnyNewKeyWindowAreNoLongerVisible() {
        _ = NSApplication.shared
        let origin = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        origin.isReleasedWhenClosed = false
        origin.level = NSWindow.Level(257)
        origin.orderFront(nil)
        let newCapture = NSWindow(contentRect: origin.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        newCapture.isReleasedWhenClosed = false
        newCapture.level = origin.level
        defer {
            origin.close()
            newCapture.close()
        }
        XCTAssertFalse(MediaExportProgressController.shouldReturnFocus(originatingWindow: origin, keyWindow: nil),
            "The original borderless editor keeps keyboard input after its export finishes")
        origin.close()
        newCapture.orderFront(nil)
        XCTAssertFalse(MediaExportProgressController.shouldReturnFocus(originatingWindow: origin, keyWindow: newCapture),
            "An older export cannot yield focus away from a new borderless capture")
        newCapture.close()
        XCTAssertTrue(MediaExportProgressController.shouldReturnFocus(originatingWindow: origin, keyWindow: newCapture))
        XCTAssertTrue(MediaExportProgressController.shouldReturnFocus(originatingWindow: nil, keyWindow: nil),
            "Finishing an idle export keeps the existing focus-return behavior")
    }

    private func waitForProgress(_ job: MediaExportCoordinator.Job) async throws -> NSWindow {
        let identifier = "macshot.exportProgress.\(job.id)"
        let appeared = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated { NSApp.windows.contains { $0.identifier?.rawValue == identifier && $0.isVisible } }
        }, evaluatedWith: nil)
        await fulfillment(of: [appeared], timeout: 3)
        return try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == identifier })
    }
}
