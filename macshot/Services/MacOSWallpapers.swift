import AVFoundation
import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// Uses wallpaper files installed by macOS. No artwork is bundled or downloaded.
nonisolated struct MacOSWallpaper: Identifiable, Sendable {
    let id: String
    let title: String
    let url: URL

    var isVideo: Bool { url.pathExtension.lowercased() == "mov" }
}

nonisolated enum MacOSWallpapers {
    static let installed = discover()
    private static let imageCache = NSCache<NSString, CGImage>()

    static func discover(root: URL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")) -> [MacOSWallpaper] {
        let fm = FileManager.default
        let stillExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        var files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let collections = root.appendingPathComponent(".wallpapers", isDirectory: true)
        for directory in (try? fm.contentsOfDirectory(at: collections, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            files += (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        let images = files.filter {
            stillExtensions.contains($0.pathExtension.lowercased()) &&
                !$0.lastPathComponent.localizedCaseInsensitiveContains("thumbnail")
        }
        let stillNames = Set(images.map { $0.deletingPathExtension().lastPathComponent })
        // Some current wallpapers ship as movies. Use a still frame from those
        // files, while preferring the OS's full-resolution HEIC when present.
        let movies = files.filter {
            $0.pathExtension.lowercased() == "mov" &&
                !$0.lastPathComponent.contains("Portrait") &&
                !stillNames.contains($0.deletingLastPathComponent().lastPathComponent)
        }
        return (images + movies).map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return MacOSWallpaper(id: url.path, title: name, url: url)
        }.sorted {
            func priority(_ name: String) -> Int {
                if name.hasPrefix("Tahoe") { return 0 }
                if name == "Sonoma" { return 1 }
                if name == "Sonoma Horizon" { return 2 }
                return 3
            }
            let left = priority($0.title), right = priority($1.title)
            return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left < right
        }
    }

    /// Bounded decoding happens off the main thread; drawing uses cached pixels.
    static func image(for wallpaper: MacOSWallpaper, maxDimension: Int) -> CGImage? {
        let limit = min(4096, max(1, maxDimension))
        let key = "\(wallpaper.id):\(limit)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let image: CGImage?
        if wallpaper.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: wallpaper.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: limit, height: limit)
            image = try? generator.copyCGImage(at: .zero, actualTime: nil)
        } else if let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            image = nil
        }
        if let image {
            imageCache.totalCostLimit = 48 * 1024 * 1024
            imageCache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        }
        return image
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

enum BeautifyFramePreset: Int {
    case compact, roomy

    var padding: CGFloat { self == .compact ? 12 : 48 }
    var radius: CGFloat { self == .compact ? 12 : 10 }
    var shadow: CGFloat { self == .compact ? 12 : 20 }

    func matches(padding: CGFloat, radius: CGFloat, shadow: CGFloat) -> Bool {
        self.padding == padding && self.radius == radius && self.shadow == shadow
    }
}
