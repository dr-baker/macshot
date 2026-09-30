import Carbon
import Cocoa
import XCTest

/// Sends Carbon events inside the test process. No physical keys or app UI are driven.
@MainActor
final class HotkeyDispatchTests: XCTestCase {
    private let appSignature = OSType(0x4D53_4854)
    private let sessionSignature = OSType(0x5354_4348)

    func testRepeatedStitchShortcutSurvivesSessionHandlerInstallationAndRemoval() throws {
        try withRegisteredStitch { captureCount in
            XCTAssertEqual(try send(signature: appSignature, id: 13), noErr)
            XCTAssertEqual(captureCount.value, 1)

            let session = SessionHandlerProbe()
            try session.install()
            defer { session.remove() }
            for _ in 0..<3 {
                XCTAssertEqual(try send(signature: appSignature, id: 13), noErr)
            }
            XCTAssertEqual(captureCount.value, 4)
            XCTAssertTrue(session.actions.isEmpty)

            // The session handler cleans itself up on Finish, as the live session does.
            XCTAssertEqual(try send(signature: sessionSignature, id: 1), noErr)
            XCTAssertEqual(session.actions, [1])
            XCTAssertFalse(session.isInstalled)
            XCTAssertEqual(try send(signature: appSignature, id: 13), noErr)
            XCTAssertEqual(captureCount.value, 5)

            try session.install()
            XCTAssertEqual(try send(signature: sessionSignature, id: 2), noErr)
            XCTAssertEqual(session.actions, [1, 2])
            XCTAssertFalse(session.isInstalled)
            XCTAssertEqual(try send(signature: appSignature, id: 13), noErr)
            XCTAssertEqual(captureCount.value, 6)
        }
    }

    func testManagerForwardsForeignSignatureWhenItIsFirstInTheHandlerChain() throws {
        let session = SessionHandlerProbe()
        try session.install()
        defer { session.remove() }
        try withRegisteredStitch { captureCount in
            // Same numeric ID as Stitch, but a foreign signature must never call capture.
            XCTAssertEqual(try send(signature: sessionSignature, id: 13), noErr)
            XCTAssertEqual(session.actions, [13])
            XCTAssertEqual(captureCount.value, 0)
            XCTAssertEqual(try send(signature: appSignature, id: 13), noErr)
            XCTAssertEqual(captureCount.value, 1)
            XCTAssertEqual(try send(signature: sessionSignature, id: 2), noErr)
            XCTAssertEqual(session.actions, [13, 2])
            XCTAssertEqual(captureCount.value, 1)
        }
    }

    func testUnregisterAllRemovesTheActualCarbonCallback() throws {
        try withRegisteredStitch { captureCount in
            XCTAssertEqual(try send(signature: appSignature, id: 13), noErr)
            XCTAssertEqual(captureCount.value, 1)
            HotkeyManager.shared.unregisterAll()
            _ = try send(signature: appSignature, id: 13)
            XCTAssertEqual(captureCount.value, 1)
        }
    }

    private func send(signature: OSType, id: UInt32) throws -> OSStatus {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   0, EventAttributes(kEventAttributeNone), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var hotkeyID = EventHotKeyID(signature: signature, id: id)
        XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &hotkeyID), noErr)
        return SendEventToEventTarget(created, GetEventDispatcherTarget())
    }

    private func withRegisteredStitch(_ body: (Counter) throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let slots = HotkeyManager.HotkeySlot.allCases
        let keys = slots.flatMap { [$0.keyCodeKey, $0.modifiersKey, $0.disabledKey] }
        // This target is a standalone xctest process with its own preferences domain.
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            HotkeyManager.shared.unregisterAll()
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for slot in slots { defaults.set(true, forKey: slot.disabledKey) }
        HotkeyManager.saveHotkey(for: .stitchCapture, keyCode: UInt32(kVK_F20),
                                modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        let count = Counter()
        HotkeyManager.shared.registerAll(
            captureArea: {}, captureFullScreen: {}, recordArea: {}, recordScreen: {},
            historyOverlay: {}, captureOCR: {}, quickCapture: {}, scrollCapture: {},
            openFromClipboard: {}, captureLastArea: {}, pinFromClipboard: {},
            clearHistory: {}, stitchCapture: { count.value += 1 })
        try body(count)
    }

    private final class Counter { var value = 0 }
}

/// A foreign handler models the session's signature and handler cleanup only.
/// Actual Stitch session state and physical hotkey registration need separate coverage.
private final class SessionHandlerProbe {
    private var handler: EventHandlerRef?
    var actions: [UInt32] = []
    var isInstalled: Bool { handler != nil }

    func install() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == OSType(0x5354_4348) else {
                return OSStatus(eventNotHandledErr)
            }
            let probe = Unmanaged<SessionHandlerProbe>.fromOpaque(data).takeUnretainedValue()
            probe.actions.append(id.id)
            if id.id == 1 || id.id == 2 { probe.remove() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        XCTAssertEqual(status, noErr)
        _ = try XCTUnwrap(handler)
    }

    func remove() {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
