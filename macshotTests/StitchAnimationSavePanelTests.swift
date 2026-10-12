import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class StitchAnimationSavePanelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testGIFIsVisibleByDefaultAndChangingFormatKeepsTheFilenameAndAllowedTypeTogether() throws {
        let panel = NSSavePanel()
        let controller = StitchAnimationSavePanel(panel: panel)
        let formats = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(formats.itemTitles, [L("Animated GIF"), L("MP4 video")])
        XCTAssertEqual(formats.titleOfSelectedItem, L("Animated GIF"))
        XCTAssertEqual(panel.allowedContentTypes, [.gif])
        XCTAssertEqual(panel.nameFieldStringValue, "Macshot Accordion.gif")
        XCTAssertFalse(panel.allowsOtherFileTypes)
        XCTAssertFalse(panel.isExtensionHidden)

        panel.nameFieldStringValue = "Project.v2.gif"
        formats.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(formats.action), to: formats.target, from: formats))
        XCTAssertEqual(panel.allowedContentTypes, [.mpeg4Movie])
        XCTAssertEqual(panel.nameFieldStringValue, "Project.v2.mp4")
        formats.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(formats.action), to: formats.target, from: formats))
        XCTAssertEqual(panel.allowedContentTypes, [.gif])
        XCTAssertEqual(panel.nameFieldStringValue, "Project.v2.gif")
        withExtendedLifetime(controller) {}
    }

    func testFormatChangePreservesADottedFilenameWithoutAnAnimationExtension() throws {
        let panel = NSSavePanel()
        let controller = StitchAnimationSavePanel(panel: panel)
        let formats = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        panel.nameFieldStringValue = "Project.v2"
        formats.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(formats.action), to: formats.target, from: formats))
        XCTAssertEqual(panel.nameFieldStringValue, "Project.v2.mp4")
        withExtendedLifetime(controller) {}
    }

    func testAcceptedExtensionChoosesItsEncoderAndCancellationReturnsNoChoice() {
        let panel = AnimationSavePanelProbe()
        let controller = StitchAnimationSavePanel(panel: panel)
        let window = NSWindow()
        var choice: StitchAnimationSavePanel.Choice?
        var completions = 0
        controller.present(in: window) { choice = $0; completions += 1 }
        let url = URL(fileURLWithPath: "/tmp/Edited filename.mp4")
        panel.finish(.OK, url: url)
        XCTAssertEqual(choice?.url, url)
        XCTAssertEqual(choice?.format, .mp4)
        XCTAssertEqual(completions, 1)

        controller.present(in: window) { choice = $0; completions += 1 }
        panel.finish(.cancel, url: url)
        XCTAssertNil(choice)
        XCTAssertEqual(completions, 2)
    }
}

@MainActor
private final class AnimationSavePanelProbe: NSSavePanel {
    private var acceptedURL: URL?
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    override var url: URL? { acceptedURL }
    override func beginSheetModal(for window: NSWindow,
                                 completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        completion = handler
    }
    func finish(_ response: NSApplication.ModalResponse, url: URL?) {
        acceptedURL = url
        let callback = completion
        completion = nil
        callback?(response)
    }
}
