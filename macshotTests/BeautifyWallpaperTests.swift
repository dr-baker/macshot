import Cocoa
import XCTest

@MainActor
final class BeautifyWallpaperTests: XCTestCase {
    private var savedPreferences: [String: Any] = [:]
    private let keys = ["beautifyPadding", "beautifyCornerRadius", "beautifyShadowRadius", "beautifyStyleIndex",
                        "beautifyCustomBgImageData", "beautifyWallpaperID"]

    override func setUp() {
        super.setUp()
        for key in keys { savedPreferences[key] = UserDefaults.standard.object(forKey: key) }
    }
    override func tearDown() {
        for key in keys {
            if let value = savedPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedPreferences.removeAll()
        super.tearDown()
    }

    func testCatalogUsesFullImagesAndOmitsThumbnailsAndDuplicateMovies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let collection = root.appendingPathComponent(".wallpapers/Sonoma")
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Sonoma.heic", "Mac Blue.heic", "Description.madesktop"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        for name in ["Sonoma Landscape.mov", "Sonoma Thumbnail.png"] {
            try Data().write(to: collection.appendingPathComponent(name))
        }
        let catalog = MacOSWallpapers.discover(root: root)
        XCTAssertEqual(catalog.map(\.title), ["Sonoma", "Mac Blue"])
        XCTAssertEqual(MacOSWallpapers.discover(root: root.appendingPathComponent("missing")).count, 0)
    }

    func testWallpaperDecodeIsBoundedAndPreservesPixelsInPNG() throws {
        let source = ImageProbe.solidImage(width: 1200, height: 800,
            color: CGColor(srgbRed: 0.15, green: 0.45, blue: 0.8, alpha: 1))
        let cg = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(MacOSWallpapers.pngData(cg))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let wallpaper = MacOSWallpaper(id: url.path, title: "Test", url: url)
        let thumbnail = try XCTUnwrap(MacOSWallpapers.image(for: wallpaper, maxDimension: 180))
        XCTAssertEqual(thumbnail.width, 180)
        XCTAssertEqual(thumbnail.height, 120)
        let decoded = try XCTUnwrap(NSImage(data: XCTUnwrap(MacOSWallpapers.pngData(thumbnail))))
        let color = try XCTUnwrap(ImageProbe.pixelColor(decoded, x: 5, y: 5))
        XCTAssertEqual(color.blueComponent, 0.8, accuracy: 0.02)
        XCTAssertEqual(color.redComponent, 0.15, accuracy: 0.02)
    }

    func testCompactWallpaperSurvivesHistoryAndDoesNotFollowLaterPreferences() throws {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.screenshotImage = ImageProbe.solidImage(width: 400, height: 300)
        view.applySelection(NSRect(x: 0, y: 0, width: 400, height: 300))
        view.beautifyEnabled = true
        view.beautifyMode = .rounded
        let wallpaper = ImageProbe.solidImage(width: 600, height: 400, color: CGColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        let data = try XCTUnwrap(MacOSWallpapers.pngData(XCTUnwrap(wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        view.setBeautifyBackground(wallpaper, pngData: data, wallpaperID: "saved-wallpaper")
        view.applyBeautifyFrame(.compact)
        let state = try JSONDecoder().decode(CaptureEditState.self, from: JSONEncoder().encode(view.captureEditState()))
        view.applyBeautifyFrame(.roomy)
        view.customBeautifyBackground = nil
        UserDefaults.standard.set("later-wallpaper", forKey: "beautifyWallpaperID")
        view.applyCaptureEditState(state)
        XCTAssertEqual(view.beautifyWallpaperID, "saved-wallpaper", "History must highlight its own wallpaper")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "beautifyWallpaperID"), "later-wallpaper")
        view.reset()
        XCTAssertEqual(view.beautifyWallpaperID, "later-wallpaper", "A reused capture overlay must reload the default wallpaper")
        let config = state.beautifyConfig()
        XCTAssertEqual(config.padding, 12)
        XCTAssertEqual(config.cornerRadius, 12)
        XCTAssertEqual(config.shadowRadius, 12)
        XCTAssertTrue(config.isCustomBackground)
        let output = BeautifyRenderer.render(image: ImageProbe.solidImage(width: 400, height: 300), config: config)
        XCTAssertEqual(output.size, NSSize(width: 424, height: 324))
        let rim = try XCTUnwrap(ImageProbe.pixelColor(output, x: 2, y: 162))
        XCTAssertGreaterThan(rim.blueComponent, rim.redComponent)
    }

    func testTightAndZeroPaddingWorkForEveryExistingFrameMode() {
        let image = ImageProbe.solidImage(width: 160, height: 120)
        for padding: CGFloat in [0, 4, 12] {
            for mode in [BeautifyMode.window, .rounded] {
                for snapped in [false, true] {
                    let config = BeautifyConfig(mode: mode, padding: padding, isWindowSnap: snapped)
                    let rendered = BeautifyRenderer.render(image: image, config: config)
                    XCTAssertEqual(rendered.size.width, 160 + padding * 2)
                    XCTAssertGreaterThanOrEqual(rendered.size.height, 120 + padding * 2)
                }
            }
        }
    }

    func testOptionalWallpaperVisualProof() throws {
        guard let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"]
            ?? ProcessInfo.processInfo.environment["MACSHOT_SEAM_PREVIEW_DIR"] else { return }
        guard let wallpaper = MacOSWallpapers.installed.first(where: { $0.title == "Tahoe Day" || $0.title == "Sonoma" }),
              let cg = MacOSWallpapers.image(for: wallpaper, maxDimension: 1600) else {
            throw XCTSkip("No installed macOS wallpaper available")
        }
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
            rect.fill()
            let title = "A little more room to think."
            title.draw(at: NSPoint(x: 34, y: 290), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
            "Macshot Pro".draw(at: NSPoint(x: 34, y: 246), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.lightGray])
            for row in 0..<4 {
                NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 34, y: 72 + row * 32, width: 380 - row * 35, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
        var config = BeautifyConfig(mode: .rounded, padding: 12, cornerRadius: 12, shadowRadius: 12,
                                    bgRadius: 0, customBackgroundImage: NSImage(cgImage: cg, size: .zero))
        config.prepareBackgroundCache()
        let output = BeautifyRenderer.render(image: image, config: config)
        let data = try XCTUnwrap(MacOSWallpapers.pngData(XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        let url = URL(fileURLWithPath: directory).appendingPathComponent("wallpaper-compact.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
