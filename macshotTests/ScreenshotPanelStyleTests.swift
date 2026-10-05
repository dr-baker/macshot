import AppKit
import XCTest

@MainActor
final class ScreenshotPanelStyleTests: XCTestCase {
    func testDefaultClearUsesThemeBackground() {
        let value = ScreenshotPanelStyle()
        XCTAssertEqual(value.material, .clear)
        XCTAssertEqual(value.tint, .init(red: 0, green: 0, blue: 0))
        XCTAssertEqual(value.tintOpacity, 0.70)
        XCTAssertTrue(value.tintUsesTheme)
        XCTAssertEqual(ScreenshotPanelStyle.Material.allCases, [.clear, .regular, .classic])
    }

    func testSwitchingFinishPreservesTintAndStrength() throws {
        var value = ScreenshotPanelStyle()
        let tint = ScreenshotPanelStyle.Tint(red: 0.2, green: 0.5, blue: 0.8)
        value.setTint(tint)
        value.tintOpacity = 0.6
        for material in ScreenshotPanelStyle.Material.allCases {
            value.material = material
            let reopened = try JSONDecoder().decode(ScreenshotPanelStyle.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(reopened, value)
        }
        value.tintOpacity = 0
        value.setTint(.init(red: 1, green: 0, blue: 0))
        XCTAssertEqual(value.tintOpacity, 0, "Choosing a color preserves an intentional strength setting")
    }

    func testThemeTintFollowsCurrentBackgroundWithoutReplacingCustomColor() throws {
        var value = ScreenshotPanelStyle(material: .classic)
        value.tintUsesTheme = true
        value.tintOpacity = 0.5
        XCTAssertEqual(value.resolvedTint(themeColor: .init(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                       .init(red: 1, green: 0, blue: 0))
        XCTAssertEqual(value.resolvedTint(themeColor: .init(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
                       .init(red: 0, green: 0, blue: 1))
        let reopened = try JSONDecoder().decode(ScreenshotPanelStyle.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(reopened.tintUsesTheme)
        XCTAssertEqual(reopened.tint, .init(red: 0, green: 0, blue: 0))
        value.setTint(.init(red: 1, green: 1, blue: 1))
        XCTAssertFalse(value.tintUsesTheme)
    }

    func testExistingMaterialPreferencesKeepColorButDropLabOnlyControls() throws {
        for oldMaterial in ["regular", "ribbon", "frosted", "lens", "future", "classic"] {
            let object: [String: Any] = ["material": oldMaterial, "activity": "alwaysInactive", "opacity": 0.1,
                                       "tint": ["red": 0.2, "green": 0.4, "blue": 0.6], "tintOpacity": 0.35]
            let value = try JSONDecoder().decode(ScreenshotPanelStyle.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(value.material, ScreenshotPanelStyle.Material(rawValue: oldMaterial) ?? .clear)
            XCTAssertEqual(value.tint, .init(red: 0.2, green: 0.4, blue: 0.6))
            XCTAssertEqual(value.tintOpacity, 0.35)
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            XCTAssertNil(stored["activity"])
            XCTAssertNil(stored["opacity"])
        }
    }

    func testSavingNotifiesControlsAndKeepsExistingStorageKey() throws {
        let name = "macshot.screenshot-appearance-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let changed = expectation(description: "Appearance change")
        let observer = NotificationCenter.default.addObserver(forName: ScreenshotPanelStyle.didChange,
            object: nil, queue: nil) { _ in changed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        ScreenshotPanelStyle(material: .classic).save(to: defaults)
        wait(for: [changed], timeout: 0.1)
        XCTAssertEqual(ScreenshotPanelStyle.load(from: defaults).material, .classic)
        XCTAssertNotNil(defaults.data(forKey: "stitchCaptureBarStyle"))
    }

    func testExplicitlyClearedTintRemainsCleared() throws {
        var value = ScreenshotPanelStyle()
        value.setTint(nil)
        let reopened = try JSONDecoder().decode(ScreenshotPanelStyle.self, from: JSONEncoder().encode(value))
        XCTAssertNil(reopened.tint)
        XCTAssertNil(reopened.resolvedTint(themeColor: .red))
    }

    func testInvalidNumbersAndCorruptPreferencesCannotReachRenderer() throws {
        let data = Data(#"{"tint":{"red":-10,"green":2,"blue":0.3},"tintOpacity":-4}"#.utf8)
        let value = try JSONDecoder().decode(ScreenshotPanelStyle.self, from: data)
        XCTAssertEqual(value.tint, .init(red: 0, green: 1, blue: 0.3))
        XCTAssertEqual(value.tintOpacity, 0)
        let name = "macshot.screenshot-appearance-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("bad data".utf8), forKey: ScreenshotPanelStyle.defaultsKey)
        XCTAssertEqual(ScreenshotPanelStyle.load(from: defaults), ScreenshotPanelStyle())
        var invalid = ScreenshotPanelStyle()
        invalid.tintOpacity = .infinity
        invalid.save(to: defaults)
        XCTAssertEqual(ScreenshotPanelStyle.load(from: defaults).tintOpacity, 0)
    }
}
