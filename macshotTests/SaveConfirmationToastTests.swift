import AppKit
import XCTest

@MainActor
final class SaveConfirmationToastTests: XCTestCase {
    func testSavedToastShowsTheActualFilenameAboveTheCaptureEditorWithoutTakingFocus() throws {
        _ = NSApplication.shared
        let keyWindow = NSApp.keyWindow
        let url = URL(fileURLWithPath: "/tmp/Accordion example.gif")
        var revealed: [URL] = []
        var navigation: [String] = []
        var dismissals = 0
        let toast = UploadToastController(revealFile: { revealed.append($0); navigation.append("reveal") })
        toast.onDismiss = { dismissals += 1 }
        toast.showSavedFile(at: url, status: L("Animation saved."), above: NSWindow.Level(257),
            beforeReveal: { navigation.append("prepare") })
        defer { toast.dismiss() }
        let panel = try confirmationPanel()
        let content = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertGreaterThan(panel.level.rawValue, 257)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == L("Animation saved.") })
        XCTAssertTrue(labels.contains { $0.stringValue == url.lastPathComponent })
        XCTAssertFalse(content.subviews.contains { $0 is NSProgressIndicator })
        XCTAssertNotNil(content.subviews.compactMap { $0 as? NSImageView }.first?.image)
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(button.title, L("Show in Finder"))
        XCTAssertTrue(navigation.isEmpty, "Saving leaves the capture and its edits in place")
        button.performClick(nil)
        button.performClick(nil)
        XCTAssertEqual(revealed, [url])
        XCTAssertEqual(navigation, ["prepare", "reveal"])
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testAppOwnsTheConfirmationAndReplacesAPreviousSavedFile() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let firstURL = URL(fileURLWithPath: "/tmp/first.gif")
        app.showAnimationSavedToast(at: firstURL, above: .normal)
        let firstPanel = try confirmationPanel()
        app.showAnimationSavedToast(at: URL(fileURLWithPath: "/tmp/second.mp4"), above: .normal)
        XCTAssertFalse(firstPanel.isVisible)
        let secondPanel = try confirmationPanel()
        XCTAssertFalse(firstPanel === secondPanel)
        let content = try XCTUnwrap(secondPanel.contentView)
        XCTAssertTrue(content.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "second.mp4" })
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }.first)
        let toast = try XCTUnwrap(button.target as? UploadToastController)
        toast.dismiss()
        XCTAssertFalse(secondPanel.isVisible)
        withExtendedLifetime(app) {}
    }

    private func confirmationPanel() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "macshot.saveConfirmation" && $0.isVisible })
    }
}

