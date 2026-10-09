import AppKit
import XCTest

@MainActor
final class ScreenshotCommandScopeTests: XCTestCase {
    func testEscapeCancelsGestureThenMountedTrayThenEditor() {
        let (window, root, editor, commands) = fixture()
        defer { window.close() }
        let tray = mountedOwner(in: root)
        let gesture = mountedOwner(in: tray)
        var cancelled: [String] = []
        commands.setTransientScope(owner: tray) { [weak commands, weak tray] in
            cancelled.append("tray")
            if let tray { commands?.removeTransientScope(owner: tray) }
        }
        commands.setTransientScope(owner: gesture) { [weak commands, weak gesture] in
            cancelled.append("gesture")
            if let gesture { commands?.removeTransientScope(owner: gesture) }
        }

        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["gesture"])
        XCTAssertTrue(commands.hasTransientScope)
        XCTAssertEqual(editor.escapeRequests, 0)
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["gesture", "tray"])
        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(editor.escapeRequests, 1)
    }

    func testRemovingLowerScopeLeavesUpperHandlerAndEditorAttached() {
        let (window, root, editor, commands) = fixture()
        defer { window.close() }
        let tray = mountedOwner(in: root)
        let gesture = mountedOwner(in: root)
        var cancelled: [String] = []
        commands.setTransientScope(owner: tray) { cancelled.append("tray") }
        commands.setTransientScope(owner: gesture) { [weak commands, weak gesture] in
            cancelled.append("gesture")
            if let gesture { commands?.removeTransientScope(owner: gesture) }
        }

        commands.removeTransientScope(owner: tray)
        XCTAssertTrue(commands.hasTransientScope)
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["gesture"])
        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertTrue(commands.performEditorKeyEquivalent(copy))
        XCTAssertEqual(editor.copyRequests, 1)
        XCTAssertNotNil(commands.nextResponder, "The local editor still owns screenshot commands")
    }

    func testDepartedAndReleasedOwnersArePrunedWithoutCancellingThem() {
        let (window, root, _, commands) = fixture()
        defer { window.close() }
        let tray = mountedOwner(in: root)
        var cancellations = 0
        commands.setTransientScope(owner: tray) { cancellations += 1 }
        let departed = mountedOwner(in: root)
        commands.setTransientScope(owner: departed) { XCTFail("A departed owner cannot consume Escape") }
        departed.removeFromSuperview()
        weak var weakOwner: NSView?
        autoreleasepool {
            let released = mountedOwner(in: root)
            weakOwner = released
            commands.setTransientScope(owner: released) { XCTFail("A released owner cannot consume Escape") }
            released.removeFromSuperview()
        }

        XCTAssertNil(weakOwner, "The command stack must not retain its view owners")
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancellations, 1)
        commands.removeTransientScope(owner: tray)
        XCTAssertFalse(commands.hasTransientScope)
    }

    func testOwnerMovingToAnotherWindowCannotKeepItsOldScope() {
        let (window, root, _, commands) = fixture()
        let otherWindow = makeWindow()
        let otherRoot = NSView(frame: root.frame)
        otherWindow.contentView = otherRoot
        defer { otherWindow.close(); window.close() }
        let tray = mountedOwner(in: root)
        let moved = mountedOwner(in: root)
        var cancellations = 0
        commands.setTransientScope(owner: tray) { cancellations += 1 }
        commands.setTransientScope(owner: moved) { XCTFail("A moved owner belongs to another window") }
        otherRoot.addSubview(moved)

        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancellations, 1)
        commands.removeTransientScope(owner: tray)
        XCTAssertFalse(commands.hasTransientScope)
    }

    func testRefreshingSameOwnerReplacesCallbackAndMovesScopeToTopWithoutDuplicates() {
        let (window, root, editor, commands) = fixture()
        defer { window.close() }
        let tray = mountedOwner(in: root)
        let gesture = mountedOwner(in: root)
        var cancelled: [String] = []
        commands.setTransientScope(owner: tray) { XCTFail("The old callback must be replaced") }
        commands.setTransientScope(owner: gesture) { [weak commands, weak gesture] in
            cancelled.append("gesture")
            if let gesture { commands?.removeTransientScope(owner: gesture) }
        }
        commands.setTransientScope(owner: tray) { [weak commands, weak tray] in
            cancelled.append("refreshed tray")
            if let tray { commands?.removeTransientScope(owner: tray) }
        }

        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["refreshed tray"])
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["refreshed tray", "gesture"])
        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(editor.escapeRequests, 1)
    }

    func testNativePopoverRoutingSurvivesRemovingUpperScopeAndPreservesFieldEditing() throws {
        let (parent, _, editor, _) = fixture()
        let popup = makeWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        popup.contentView = root
        defer { popup.close(); parent.close() }
        let commands = ScreenshotCommandResponder.install(in: popup, editor: nil)
        commands.linkEditor(from: parent)
        let menu = mountedOwner(in: root)
        let gesture = mountedOwner(in: root)
        commands.setTransientScope(owner: menu) {}
        commands.setTransientScope(owner: gesture) {}

        XCTAssertTrue(commands.performEditorKeyEquivalent(copy))
        commands.removeTransientScope(owner: gesture)
        XCTAssertTrue(commands.hasTransientScope)
        XCTAssertTrue(commands.performEditorKeyEquivalent(copy))
        XCTAssertEqual(editor.copyRequests, 2)

        let field = NSTextField(string: "14")
        root.addSubview(field)
        field.selectText(nil)
        let fieldEditor = try XCTUnwrap(popup.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        XCTAssertFalse(commands.performEditorKeyEquivalent(copy))
        XCTAssertEqual(editor.copyRequests, 2)
        XCTAssertTrue(popup.firstResponder === fieldEditor)

        commands.removeTransientScope(owner: menu)
        popup.makeFirstResponder(nil)
        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertNil(commands.editor, "An unmounted native popover must release its linked editor")
        XCTAssertNil(commands.nextResponder)
        XCTAssertFalse(root.nextResponder === commands)
        XCTAssertFalse(commands.performEditorKeyEquivalent(copy))
        XCTAssertEqual(editor.copyRequests, 2)
    }

    func testPruningLastNativePopoverOwnerReleasesLinkedRouting() {
        let (parent, _, editor, _) = fixture()
        let popup = makeWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        popup.contentView = root
        defer { popup.close(); parent.close() }
        let commands = ScreenshotCommandResponder.install(in: popup, editor: nil)
        commands.linkEditor(from: parent)
        let menu = mountedOwner(in: root)
        commands.setTransientScope(owner: menu) {}
        XCTAssertTrue(commands.performEditorKeyEquivalent(copy))
        menu.removeFromSuperview()

        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertNil(commands.editor)
        XCTAssertNil(commands.nextResponder)
        XCTAssertFalse(commands.performEditorKeyEquivalent(copy))
        XCTAssertEqual(editor.copyRequests, 1)
    }

    func testForeignPopoverOwnerCanNestAboveCaptureTray() {
        let (parent, root, editor, commands) = fixture()
        let popup = makeWindow()
        let popupRoot = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        popup.contentView = popupRoot
        defer { popup.close(); parent.close() }
        let tray = mountedOwner(in: root)
        let menu = mountedOwner(in: popupRoot)
        var cancelled: [String] = []
        commands.setTransientScope(owner: tray) { cancelled.append("tray") }
        commands.setTransientScope(owner: menu) { [weak commands, weak menu] in
            cancelled.append("popover")
            if let menu { commands?.removeTransientScope(owner: menu) }
        }

        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["popover"])
        XCTAssertTrue(commands.dispatchKeyEvent(escape))
        XCTAssertEqual(cancelled, ["popover", "tray"])
        XCTAssertEqual(editor.escapeRequests, 0)
    }

    func testWindowCloseDropsEveryScopeAndDetachesResponder() {
        let (window, root, _, commands) = fixture()
        let tray = mountedOwner(in: root)
        let gesture = mountedOwner(in: root)
        var marker: NSObject? = NSObject()
        weak var weakMarker = marker
        commands.setTransientScope(owner: tray) { XCTFail("Closing the window must not invoke cancellation callbacks") }
        commands.setTransientScope(owner: gesture) { [retained = marker!] in
            XCTFail("Closing the window must not invoke cancellation callbacks: \(retained)")
        }
        marker = nil
        XCTAssertNotNil(weakMarker)
        window.close()

        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertNil(commands.editor)
        XCTAssertNil(commands.nextResponder)
        XCTAssertFalse(root.nextResponder === commands)
        XCTAssertNil(weakMarker, "Closing the window must release every cancellation callback")
        XCTAssertFalse(commands.dispatchKeyEvent(escape))
    }

    private var escape: NSEvent { TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53) }
    private var copy: NSEvent { TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command) }

    private func fixture() -> (NSWindow, NSView, ScreenshotScopeEditor, ScreenshotCommandResponder) {
        _ = NSApplication.shared
        let window = makeWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let editor = ScreenshotScopeEditor(frame: root.bounds)
        root.addSubview(editor)
        window.contentView = root
        let commands = ScreenshotCommandResponder.install(in: window, editor: editor)
        return (window, root, editor, commands)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func mountedOwner(in root: NSView) -> NSView {
        let owner = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        root.addSubview(owner)
        return owner
    }
}

@MainActor
private final class ScreenshotScopeEditor: OverlayView {
    var escapeRequests = 0
    var copyRequests = 0
    override var acceptsFirstResponder: Bool { true }

    override func handleEditorKeyEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        escapeRequests += 1
        return true
    }

    override func handleEditorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) else { return false }
        copyRequests += 1
        return true
    }
}
