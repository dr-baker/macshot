import Cocoa
import XCTest

@MainActor
final class BeautifyWallpaperTests: XCTestCase {
    private var savedPreferences: [String: Any] = [:]
    private let keys = ["beautifyPadding", "beautifyCornerRadius", "beautifyShadowRadius", "beautifyStyleIndex",
                        "beautifyCustomBgImageData", "beautifyWallpaperID", "beautifyBgBlur"]

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

    func testWallpaperChoiceSurvivesDismissingItsPicker() throws {
        let deferred = DeferredWallpaperLoader()
        let view = backgroundEditor(loader: deferred)
        let wallpaper = testWallpaper("Tahoe Day")
        weak var releasedPicker: BeautifyBackgroundPickerView?
        try autoreleasepool {
            let picker = backgroundPicker(view: view, wallpapers: [wallpaper])
            releasedPicker = picker
            try clickWallpaper(wallpaper, in: picker)
        }
        XCTAssertEqual(deferred.requests.count, 1)
        XCTAssertNil(releasedPicker, "Pending wallpaper work must not retain the dismissed gallery")

        deferred.complete(0, with: try loadedWallpaper(color: .blue))
        XCTAssertEqual(view.beautifyWallpaperID, wallpaper.id)
        let background = try XCTUnwrap(view.customBeautifyBackground)
        XCTAssertGreaterThan(try XCTUnwrap(ImageProbe.pixelColor(background, x: 2, y: 2)).blueComponent, 0.9)
        XCTAssertFalse(view.beautifyEnabled, "Background selection must not enable frame decoration")
    }

    func testLaterPickerSelectionRejectsEarlierWallpaperCompletion() throws {
        let deferred = DeferredWallpaperLoader()
        let view = backgroundEditor(loader: deferred)
        let first = testWallpaper("Tahoe Day"), second = testWallpaper("Sonoma")
        var oldPicker: BeautifyBackgroundPickerView? = backgroundPicker(view: view, wallpapers: [first])
        try clickWallpaper(first, in: XCTUnwrap(oldPicker))
        oldPicker = nil
        let newPicker = backgroundPicker(view: view, wallpapers: [second])
        try clickWallpaper(second, in: newPicker)
        XCTAssertEqual(deferred.requests.map(\.id), [first.id, second.id])

        deferred.complete(0, with: try loadedWallpaper(color: .red))
        XCTAssertNil(view.beautifyWallpaperID, "An older completion cannot apply while a later choice is pending")
        deferred.complete(1, with: try loadedWallpaper(color: .blue))
        deferred.complete(0, with: try loadedWallpaper(color: .red))
        XCTAssertEqual(view.beautifyWallpaperID, second.id)
        let color = try XCTUnwrap(ImageProbe.pixelColor(XCTUnwrap(view.customBeautifyBackground), x: 2, y: 2))
        XCTAssertGreaterThan(color.blueComponent, 0.9)
        XCTAssertLessThan(color.redComponent, 0.1)
    }

    func testGradientAndCustomImageChoicesCancelAClosedPickersWallpaperLoad() throws {
        for customImage in [false, true] {
            let deferred = DeferredWallpaperLoader()
            let view = backgroundEditor(loader: deferred)
            let wallpaper = testWallpaper("Tahoe Day")
            var oldPicker: BeautifyBackgroundPickerView? = backgroundPicker(view: view, wallpapers: [wallpaper])
            try clickWallpaper(wallpaper, in: XCTUnwrap(oldPicker))
            oldPicker = nil
            let newPicker = backgroundPicker(view: view, wallpapers: [])
            let gradients = try XCTUnwrap(newPicker.subviews.compactMap { $0 as? GradientPickerView }.first)
            if customImage {
                newPicker.onCustomImage = { [weak view] in
                    view?.customBeautifyBackground = ImageProbe.solidImage(width: 12, height: 12, color: NSColor.green.cgColor)
                    view?.beautifyStyleIndex = -1
                }
                gradients.onCustomImage?()
            } else {
                gradients.onSelect?(3)
            }
            deferred.complete(0, with: try loadedWallpaper(color: .red))
            XCTAssertNil(view.beautifyWallpaperID)
            XCTAssertEqual(view.beautifyStyleIndex, customImage ? -1 : 3)
            if customImage {
                let color = try XCTUnwrap(ImageProbe.pixelColor(XCTUnwrap(view.customBeautifyBackground), x: 2, y: 2))
                XCTAssertGreaterThan(color.greenComponent, 0.9)
                XCTAssertLessThan(color.redComponent, 0.1)
            } else {
                XCTAssertNil(view.customBeautifyBackground)
            }
        }
    }

    func testWallpaperCompletionCannotChangeAResetOrRestoredCapture() throws {
        for restoreHistory in [false, true] {
            let deferred = DeferredWallpaperLoader()
            let view = backgroundEditor(loader: deferred)
            view.beautifyStyleIndex = 3
            let original = view.captureEditState()
            let wallpaper = testWallpaper("Tahoe Day")
            let picker = backgroundPicker(view: view, wallpapers: [wallpaper])
            try clickWallpaper(wallpaper, in: picker)
            if restoreHistory { view.applyCaptureEditState(original) }
            else { view.reset() }
            let expectedIndex = view.beautifyStyleIndex
            let expectedWallpaper = view.beautifyWallpaperID
            let expectedBackground = FieldDescriber.describe(view.customBeautifyBackground as Any)
            deferred.complete(0, with: try loadedWallpaper(color: .red))
            XCTAssertEqual(view.beautifyStyleIndex, expectedIndex)
            XCTAssertEqual(view.beautifyWallpaperID, expectedWallpaper)
            XCTAssertEqual(FieldDescriber.describe(view.customBeautifyBackground as Any), expectedBackground)
        }
    }

    func testWallpaperWorkDoesNotKeepAClosedEditorAlive() throws {
        let deferred = DeferredWallpaperLoader()
        let wallpaper = testWallpaper("Tahoe Day")
        weak var releasedEditor: OverlayView?
        weak var releasedPicker: BeautifyBackgroundPickerView?
        try autoreleasepool {
            let view = backgroundEditor(loader: deferred)
            let picker = backgroundPicker(view: view, wallpapers: [wallpaper])
            releasedEditor = view
            releasedPicker = picker
            try clickWallpaper(wallpaper, in: picker)
        }
        XCTAssertNil(releasedPicker)
        XCTAssertNil(releasedEditor)
        let savedID = UserDefaults.standard.string(forKey: "beautifyWallpaperID")
        deferred.complete(0, with: try loadedWallpaper(color: .red))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "beautifyWallpaperID"), savedID)
    }

    func testBackgroundPickerBlurPersistsForAFreshOverlay() throws {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        view.beautifyStyleIndex = -1
        view.customBeautifyBackground = ImageProbe.solidImage(width: 12, height: 12)
        let picker = view.makeBeautifyBackgroundPicker(backgroundOnly: true, wallpapers: [])
        let slider = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSSlider }.first)
        XCTAssertTrue(slider.isEnabled)
        slider.doubleValue = 23
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
        XCTAssertEqual(view.beautifyBackgroundBlur, 23)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "beautifyBgBlur"), 23)
        XCTAssertEqual(OverlayView().beautifyBackgroundBlur, 23,
            "The next capture must restore the blur selected through the actual background picker callback")
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

    private func backgroundEditor(loader: DeferredWallpaperLoader) -> OverlayView {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        view.beautifyBackgroundSelection = BeautifyBackgroundSelection(loader: loader.load)
        view.beautifyEnabled = false
        view.beautifyStyleIndex = 0
        view.beautifyWallpaperID = nil
        view.customBeautifyBackground = nil
        view.screenshotImage = ImageProbe.solidImage(width: 120, height: 80)
        view.applySelection(view.bounds)
        return view
    }

    private func backgroundPicker(view: OverlayView, wallpapers: [MacOSWallpaper]) -> BeautifyBackgroundPickerView {
        view.makeBeautifyBackgroundPicker(backgroundOnly: true, wallpapers: wallpapers)
    }

    private func clickWallpaper(_ wallpaper: MacOSWallpaper, in picker: BeautifyBackgroundPickerView) throws {
        let gallery = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSScrollView }.first?.documentView)
        let button = try XCTUnwrap(gallery.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == wallpaper.title })
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }

    private func testWallpaper(_ title: String) -> MacOSWallpaper {
        MacOSWallpaper(id: title, title: title, url: URL(fileURLWithPath: "/unused-test-wallpapers/\(title).heic"))
    }

    private func loadedWallpaper(color: NSColor) throws -> BeautifyBackgroundSelection.LoadedWallpaper {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 12, height: 12, color: color.cgColor)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        return BeautifyBackgroundSelection.LoadedWallpaper(image: image, pngData: try XCTUnwrap(MacOSWallpapers.pngData(image)))
    }

    @MainActor
    private final class DeferredWallpaperLoader {
        var requests: [MacOSWallpaper] = []
        private var completions: [@MainActor (BeautifyBackgroundSelection.LoadedWallpaper?) -> Void] = []

        func load(_ wallpaper: MacOSWallpaper,
                  completion: @escaping @MainActor (BeautifyBackgroundSelection.LoadedWallpaper?) -> Void) {
            requests.append(wallpaper)
            completions.append(completion)
        }

        func complete(_ index: Int, with result: BeautifyBackgroundSelection.LoadedWallpaper) {
            completions[index](result)
        }
    }
}
