import AppKit
import XCTest

@MainActor
final class StitchCaptureHUDTests: XCTestCase {
    func testOnlyUndoAndFinishRemainUsableAboveSelectionAndWindowIsExcluded() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let hud = StitchCaptureHUD(screen: screen, pixelRect: .zero, imageSize: screen.frame.size)
        defer { hud.close() }
        let number = try XCTUnwrap(hud.windowNumbers.first)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.windowNumber == Int(number) })
        let buttons = try XCTUnwrap(panel.contentView).subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(Set(buttons.map(\.title)), Set([L("Undo"), L("Finish ↵")]))
        XCTAssertGreaterThan(panel.level.rawValue, 257)
        var undos = 0, finishes = 0
        hud.onUndo = { undos += 1 }
        hud.onFinish = { finishes += 1 }
        let undo = try XCTUnwrap(buttons.first { $0.title == L("Undo") })
        let finish = try XCTUnwrap(buttons.first { $0.title == L("Finish ↵") })
        hud.update(count: 2, status: "Selecting", canUndo: true)
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(finish.isEnabled)
        undo.performClick(nil)
        finish.performClick(nil)
        XCTAssertEqual(undos, 1)
        XCTAssertEqual(finishes, 1)
        hud.update(count: 1, status: "Selecting", canUndo: false)
        XCTAssertFalse(undo.isEnabled)
        XCTAssertTrue(finish.isEnabled)
        hud.update(count: 0, status: "Selecting first capture", canUndo: false)
        XCTAssertFalse(undo.isEnabled)
        XCTAssertFalse(finish.isEnabled, "Finish requires a capture to hand off to the editor")
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(hud.windowNumbers, [number])
    }
}
