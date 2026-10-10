import Cocoa
import XCTest

/// Measures history-state preparation only, excluding controller work,
/// screenshot rendering, JSON sidecar encoding, and clipboard publication.
@MainActor
final class CaptureEditStateBackgroundLatencyTests: XCTestCase {
    func testWallpaperStatePreparationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MACSHOT_BACKGROUND_STATE_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in wallpaper edit-state benchmark")
        }
        let image = wallpaperFixture()
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sourcePNG = try XCTUnwrap(MacOSWallpapers.pngData(pixels))
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        view.showToolbars = false
        view.beautifyStyleIndex = -1
        view.beautifyBackgroundBlur = 0
        view.customBeautifyBackground = image
        var legacy: [Double] = []
        var cold: [Double] = []
        var repeated: [Double] = []
        var seeded: [Double] = []
        var sink: CaptureEditState?
        func measure(calls: Int = 1, work: () -> CaptureEditState) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<calls { sink = work() }
            return (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(calls)
        }
        // First round warms ImageIO and AppKit. Remaining rounds are retained.
        for round in 0..<6 {
            try autoreleasepool {
                // The legacy path copied the same fields but prepared PNG from
                // a TIFF representation on every call. The new PNG is already
                // warm here, so this adds only ordinary field-read overhead.
                _ = view.captureEditState()
                let legacyMS = measure {
                    var state = view.captureEditState()
                    state.customBeautifyBackgroundPNG = image.tiffRepresentation
                        .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                    return state
                }
                XCTAssertNotNil(sink?.customBeautifyBackgroundPNG)
                view.customBeautifyBackground = image
                let coldMS = measure { view.captureEditState() }
                XCTAssertNotNil(sink?.customBeautifyBackgroundPNG)
                let repeatedMS = measure(calls: 200) { view.captureEditState() }
                view.replaceCustomBeautifyBackground(image, originalPNG: sourcePNG)
                let seededMS = measure(calls: 200) { view.captureEditState() }
                XCTAssertEqual(sink?.customBeautifyBackgroundPNG, sourcePNG)
                if round > 0 {
                    legacy.append(legacyMS)
                    cold.append(coldMS)
                    repeated.append(repeatedMS)
                    seeded.append(seededMS)
                }
            }
        }
        let samples = ["legacy_tiff_png": legacy, "cold_native_png": cold,
                       "repeated_cached": repeated, "original_png_seeded": seeded]
        let report: [String: Any] = [
            "fixture": "synthetic_3840x2160_wallpaper",
            "unit": "milliseconds_per_capture_edit_state",
            "samples": samples,
            "medians": samples.mapValues { $0.sorted()[2] },
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("BACKGROUND_STATE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }

    private func wallpaperFixture() -> NSImage {
        ImageProbe.makeImage(width: 3840, height: 2160) { context in
            let colors = [
                CGColor(srgbRed: 0.08, green: 0.15, blue: 0.45, alpha: 1),
                CGColor(srgbRed: 0.45, green: 0.2, blue: 0.75, alpha: 1),
                CGColor(srgbRed: 0.9, green: 0.45, blue: 0.3, alpha: 1),
            ]
            let locations: [CGFloat] = [0, 0.5, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors as CFArray, locations: locations) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 3840, y: 2160), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            for index in 0..<16 {
                context.setFillColor(CGColor(srgbRed: CGFloat(index % 4) / 5,
                    green: CGFloat(index % 5) / 6, blue: 0.85, alpha: 0.15))
                context.fillEllipse(in: CGRect(x: index * 270 - 800, y: index * 125 - 700,
                    width: 2100, height: 1500))
            }
        }
    }
}
