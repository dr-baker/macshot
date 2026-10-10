import Cocoa
import UniformTypeIdentifiers
import ImageIO
import WebP

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String, CaseIterable, Sendable {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case webp = "webp"
        case avif = "avif"

        nonisolated var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .webp: return "webp"
            case .avif: return "avif"
            }
        }

        nonisolated var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .webp: return .webP
            case .avif: return UTType("public.avif") ?? .image
            }
        }

        nonisolated var hasQuality: Bool {
            switch self {
            case .png: return false
            case .jpeg, .heic, .webp, .avif: return true
            }
        }

        nonisolated var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .webp: return "WebP"
            case .avif: return "AVIF"
            }
        }
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw),
           isFormatAvailable(fmt) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC, WebP, and AVIF)
    static var quality: CGFloat {
        if let q = UserDefaults.standard.object(forKey: "imageQuality") as? Double {
            return q.isFinite ? CGFloat(max(0.1, min(1.0, q))) : 0.85
        }
        return 0.85
    }

    /// Whether to downscale Retina (2x) screenshots to standard (1x) resolution.
    static var downscaleRetina: Bool {
        UserDefaults.standard.bool(forKey: "downscaleRetina")
    }

    static var fileExtension: String { format.fileExtension }
    static var utType: UTType { format.utType }

    nonisolated static var availableFormats: [Format] {
        Format.allCases.filter { isFormatAvailable($0) }
    }

    nonisolated static func isFormatAvailable(_ format: Format) -> Bool {
        switch format {
        case .png, .jpeg, .heic, .webp:
            return true
        case .avif:
            // Native ImageIO AVIF encode support is OS-provided. Keep the UI and
            // saved default gated so older supported macOS versions never expose
            // a format that cannot be written.
            guard #available(macOS 13.0, *) else { return false }
            let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
            return identifiers.contains("public.avif")
        }
    }

    /// Owns immutable pixels and settings from the instant the user requests
    /// output. AppKit stays on the main actor; encoding can run on a worker.
    struct PreparedImage: Sendable {
        let image: HistoryImageSnapshot.Image
        let format: Format
        let quality: CGFloat
        let downscaleRetina: Bool

        @MainActor init(_ source: NSImage) throws {
            image = try HistoryImageSnapshot.Image(source)
            format = ImageEncoder.format
            quality = ImageEncoder.quality
            downscaleRetina = ImageEncoder.downscaleRetina
        }

        nonisolated func pixelsForEncoding() throws -> CGImage {
            let pixels = image.pixels
            guard downscaleRetina, Double(pixels.width) > image.pointSize.width,
                  Double(pixels.height) > image.pointSize.height else { return pixels }
            // Clamp before converting to Int; malformed point sizes must not
            // trap, overflow a row stride or allocate an enormous bitmap.
            let width = max(1, Int(min(Double(pixels.width), image.pointSize.width)))
            let height = max(1, Int(min(Double(pixels.height), image.pointSize.height)))
            return try HistoryImageSnapshot.Image.render(pixels, width: width, height: height)
        }

        nonisolated func encode() -> Data? {
            guard let pixels = try? pixelsForEncoding() else { return nil }
            return encode(pixels: pixels)
        }

        nonisolated func encode(pixels: CGImage) -> Data? {
            switch format {
            case .png: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.png", lossyQuality: nil)
            case .jpeg: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.jpeg", lossyQuality: quality)
            case .heic: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.heic", lossyQuality: quality)
            case .avif: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.avif", lossyQuality: quality)
            case .webp: return ImageEncoder.encodeWebP(cgImage: pixels, quality: quality)
            }
        }
    }

    static func encode(_ image: NSImage) -> Data? {
        (try? PreparedImage(image))?.encode()
    }

    /// Encode WebP via Swift-WebP (libwebp).
    /// Uses a raw RGBA buffer: the library's NSImage path has a bug
    /// (assumes RGB stride and logical size instead of pixel size).
    nonisolated private static func encodeWebP(cgImage srcImage: CGImage, quality: CGFloat) -> Data? {
        let w = srcImage.width
        let h = srcImage.height
        // WebP cannot exceed 16383 px per side; refuse before allocating.
        guard w > 0, h > 0, w <= webPMaximumDimension, h <= webPMaximumDimension else { return nil }
        let stride = w * 4
        let (byteCount, overflow) = stride.multipliedReportingOverflow(by: h)
        // Fallible allocation: a huge capture must fail the save, not the app.
        guard !overflow, let memory = calloc(byteCount, 1) else { return nil }
        defer { free(memory) }
        // CGContext only draws premultiplied RGBA, but libwebp expects straight
        // alpha: without undoing it, semi-transparent edges encode darker.
        let cs = srcImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: memory, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: stride,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = memory.bindMemory(to: UInt8.self, capacity: byteCount)
        unpremultiplyRGBA(UnsafeMutableBufferPointer(start: pixels, count: byteCount))

        let config = WebPEncoderConfig.preset(.picture, quality: Float(quality * 100))
        return try? WebPEncoder().encode(RGBA: pixels, config: config, originWidth: w, originHeight: h, stride: stride)
    }

    nonisolated static let webPMaximumDimension = 16_383

    /// Converts premultiplied RGBA8 to straight alpha in place, rounding to nearest.
    nonisolated static func unpremultiplyRGBA(_ pixels: UnsafeMutableBufferPointer<UInt8>) {
        var index = 0
        while index + 3 < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 {
                    let value = (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha
                    pixels[index + channel] = UInt8(min(255, value))
                }
            }
            index += 4
        }
    }

    /// Generic CGImageDestination encoder — embeds the source color profile.
    /// The CGImage already carries its display's ICC profile (e.g. Display P3).
    /// CGImageDestination embeds it automatically — no pixel conversion needed.
    nonisolated static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?,
                                                         pngFilter: Int? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        if let pngFilter, type == "public.png" {
            properties[kCGImagePropertyPNGDictionary as String] = [
                kCGImagePropertyPNGCompressionFilter as String: pngFilter,
            ]
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    private nonisolated static let clipboardGeneration = ClipboardCopyGeneration()

    /// No file URL: it points into our sandbox, which Teams/RDP/web apps prefer but can't read (#309, #393).
    /// Opt-in: also offer the configured format (e.g. AVIF) to apps that read it (#373).
    static var clipboardIncludesImageFormat: Bool {
        UserDefaults.standard.bool(forKey: "clipboardIncludesImageFormat")
    }

    @MainActor static func copyToClipboard(_ image: NSImage,
                                          pasteboard: NSPasteboard = .general,
                                          completion: ((Bool) -> Void)? = nil) {
        let generation = clipboardGeneration.beginCopy()
        let changeCount = pasteboard.changeCount
        let includeFormat = clipboardIncludesImageFormat
        guard let prepared = try? PreparedImage(image) else { completion?(false); return }

        DispatchQueue.global(qos: .userInitiated).async {
            // Repeated copies supersede queued jobs before they allocate encoders.
            guard clipboardGeneration.isCurrent(generation) else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let representations = clipboardRepresentations(for: prepared, includeConfiguredFormat: includeFormat)
            DispatchQueue.main.async {
                guard !representations.isEmpty, clipboardGeneration.isCurrent(generation),
                      pasteboard.changeCount == changeCount else { completion?(false); return }
                writeImagePasteboard(pasteboard, representations: representations)
                completion?(true)
            }
        }
    }

    /// Pasteboard flavors in preference order. PNG and TIFF are always present
    /// so apps that only read those (Teams, browsers, RDP) keep working; the
    /// configured format goes first when opted in so apps that read it get the
    /// smaller file. Returns nothing only if PNG encoding fails.
    nonisolated static func clipboardRepresentations(for prepared: PreparedImage,
                                                     includeConfiguredFormat: Bool) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
        guard let pixels = try? prepared.pixelsForEncoding() else { return [] }
        let includesExtra = includeConfiguredFormat && prepared.format != .png
        let results = ClipboardEncodingResults()
        // The formats are independent and consume the same frozen pixels.
        // Publish once all encoders finish, retaining the established flavor order.
        DispatchQueue.concurrentPerform(iterations: includesExtra ? 3 : 2) { index in
            let data: Data?
            switch index {
            case 0: data = encodeClipboardPNG(pixels)
            case 1: data = encodeWithCGImageDestination(cgImage: pixels, type: "public.tiff", lossyQuality: nil)
            default: data = prepared.encode(pixels: pixels)
            }
            results.store(data, at: index)
        }
        guard let pngData = results.data(at: 0) else { return [] }
        var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        if includesExtra, let data = results.data(at: 2) {
            representations.append((NSPasteboard.PasteboardType(prepared.format.utType.identifier), data))
        }
        representations.append((.png, pngData))
        if let tiffData = results.data(at: 1) { representations.append((.tiff, tiffData)) }
        return representations
    }

    /// Limit filter search to vertical and horizontal prediction. UP alone
    /// compresses projected paper poorly; UP plus SUB keeps that case fast
    /// while preserving every pixel and the color profile.
    /// File saves retain their existing compression policy.
    nonisolated static func encodeClipboardPNG(_ pixels: CGImage) -> Data? {
        encodeWithCGImageDestination(cgImage: pixels, type: "public.png", lossyQuality: nil,
                                     pngFilter: Int(IMAGEIO_PNG_FILTER_UP | IMAGEIO_PNG_FILTER_SUB))
    }

    private nonisolated final class ClipboardEncodingResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Data] = [:]

        func store(_ data: Data?, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            values[index] = data
        }

        func data(at index: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[index]
        }
    }

    /// Queue and main-actor checks share only this locked counter.
    private nonisolated final class ClipboardCopyGeneration: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func beginCopy() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        func isCurrent(_ generation: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return generation == value
        }
    }

    static func writeImagePasteboard(
        _ pasteboard: NSPasteboard,
        representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    ) {
        pasteboard.clearContents()
        pasteboard.declareTypes(representations.map(\.type), owner: nil)
        for representation in representations {
            pasteboard.setData(representation.data, forType: representation.type)
        }
    }
}
