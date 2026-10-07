import AppKit
import ImageIO

/// Original captures are stored once, even when a cut creates several slices.
/// Keeping the source index also preserves image identity when restoring slices.
struct SavedStitchDocument: Codable, Equatable {
    struct Piece: Codable, Equatable {
        var id: UUID
        var lineageID: UUID
        var imageIndex: Int
        var source: [CGFloat]
        var origin: [CGFloat]
        var label: String
    }
    var images: [Data]
    var pieces: [Piece]
    var transition: String
    var lineColor: [CGFloat]
    var lineWidth: CGFloat
    var wave: CGFloat
    var blur: CGFloat
    var feather: CGFloat
    var tearWidth: CGFloat
    var tearRoughness: CGFloat
    var foldDepth: CGFloat
    var foldStrength: CGFloat
    var accordionWidth: CGFloat
    var accordionPleats: CGFloat
    var breakSize: CGFloat
    var visible: Bool
    var background: String
    var backgroundColor: [CGFloat]?
    var packed: Bool
    var packingHorizontal: Bool
    var packingLength: CGFloat

    private enum CodingKeys: String, CodingKey {
        case images, pieces, transition, lineColor, lineWidth, wave, blur, feather, visible
        case tearWidth, tearRoughness, foldDepth, foldStrength, breakSize
        case accordionWidth, accordionPleats
        case background, backgroundColor, packed, packingHorizontal, packingLength
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let style = StitchStyle()
        // Captured pixels and source geometry must restore together. Cosmetic
        // settings can use their defaults when a previous revision omitted them.
        images = try values.decode([Data].self, forKey: .images)
        pieces = try values.decode([Piece].self, forKey: .pieces)
        transition = values.decode(.transition, or: StitchTransition.wave.rawValue)
        lineColor = values.decode(.lineColor, or: Self.components(style.color))
        lineWidth = values.decode(.lineWidth, or: style.lineWidth)
        wave = values.decode(.wave, or: style.wave)
        blur = values.decode(.blur, or: style.blur)
        feather = values.decode(.feather, or: style.feather)
        tearWidth = values.decode(.tearWidth, or: style.tearWidth)
        tearRoughness = values.decode(.tearRoughness, or: wave)
        foldDepth = values.decode(.foldDepth, or: style.foldDepth)
        foldStrength = values.decode(.foldStrength, or: style.foldStrength)
        accordionWidth = values.decode(.accordionWidth, or: style.accordionWidth)
        accordionPleats = values.decode(.accordionPleats, or: style.accordionPleats)
        breakSize = values.decode(.breakSize, or: wave)
        visible = values.decode(.visible, or: style.visible)
        background = values.decode(.background, or: "automatic")
        backgroundColor = values.decodeOptional(.backgroundColor)
        packed = values.decode(.packed, or: false)
        packingHorizontal = values.decode(.packingHorizontal, or: true)
        packingLength = values.decode(.packingLength, or: 0)
    }

    init?(_ document: StitchDocument) {
        var cache: [(image: CGImage, data: Data)] = []
        self.init(document, imageData: &cache)
    }

    init?(_ document: StitchDocument, imageData: inout [(image: CGImage, data: Data)]) {
        guard document.canRender else { return nil }
        var sources: [CGImage] = []
        var images: [Data] = []
        var pieces: [Piece] = []
        for piece in document.pieces {
            let index: Int
            if let existing = sources.firstIndex(where: { $0 === piece.image }) { index = existing }
            else {
                let png: Data
                if let cached = imageData.first(where: { $0.image === piece.image }) { png = cached.data }
                else {
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
                    CGImageDestinationAddImage(destination, piece.image, nil)
                    guard CGImageDestinationFinalize(destination) else { return nil }
                    png = data as Data
                    imageData.append((piece.image, png))
                }
                index = sources.count
                sources.append(piece.image)
                images.append(png)
            }
            pieces.append(Piece(id: piece.id, lineageID: piece.lineageID, imageIndex: index,
                source: [piece.source.minX, piece.source.minY, piece.source.width, piece.source.height],
                origin: [piece.origin.x, piece.origin.y], label: piece.label))
        }
        imageData.removeAll { cached in !sources.contains(where: { $0 === cached.image }) }
        self.images = images
        self.pieces = pieces
        transition = document.style.transition.rawValue
        lineColor = Self.components(document.style.color)
        lineWidth = document.style.lineWidth
        wave = document.style.wave
        blur = document.style.blur
        feather = document.style.feather
        tearWidth = document.style.tearWidth
        tearRoughness = document.style.tearRoughness
        foldDepth = document.style.foldDepth
        foldStrength = document.style.foldStrength
        accordionWidth = document.style.accordionWidth
        accordionPleats = document.style.accordionPleats
        breakSize = document.style.breakSize
        visible = document.style.visible
        switch document.background {
        case .automatic: background = "automatic"; backgroundColor = nil
        case .transparent: background = "transparent"; backgroundColor = nil
        case .color(let color): background = "color"; backgroundColor = Self.components(color)
        }
        packed = document.placement == .packed
        packingHorizontal = document.savedPackingState.horizontal
        packingLength = document.savedPackingState.length
    }

    func restore() -> StitchDocument? {
        guard !pieces.isEmpty, pieces.count <= StitchDocument.maximumPieces,
              !images.isEmpty, images.count <= pieces.count,
              Set(pieces.map(\.id)).count == pieces.count,
              images.reduce(0, { $0 + min($1.count, SavedCaptureValidation.maximumImageBytes + 1) }) <= SavedCaptureValidation.maximumImageBytes,
              [lineWidth, wave, blur, feather, tearWidth, tearRoughness, foldDepth, foldStrength, breakSize, packingLength].allSatisfy({ $0.isFinite && $0 >= 0 }),
              lineWidth <= 100, wave <= 100, blur <= 100, feather <= 4096,
              tearWidth <= 100, tearRoughness <= 100, foldDepth <= 100,
              foldStrength <= StitchStyle.maximumFoldStrength, breakSize <= 100,
              accordionWidth.isFinite, (0...80).contains(accordionWidth),
              accordionPleats.isFinite, (2...6).contains(accordionPleats),
              accordionPleats.rounded() == accordionPleats,
              packingLength <= StitchDocument.maximumDimension,
              !packed || packingLength > 0, let color = Self.color(lineColor),
              let transition = StitchTransition(rawValue: transition) else { return nil }
        var pixels: [CGImage] = []
        var totalPixels = 0
        for data in images {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                w.isFinite, h.isFinite, w > 0, h > 0,
                w <= Double(StitchDocument.maximumDimension), h <= Double(StitchDocument.maximumDimension),
                w * h <= Double(SavedCaptureValidation.maximumImagePixels - totalPixels),
                let image = SavedCaptureValidation.image(data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            totalPixels += image.width * image.height
            pixels.append(image)
        }
        var restored: [StitchPiece] = []
        for piece in pieces {
            guard pixels.indices.contains(piece.imageIndex),
                  let source = SavedCaptureValidation.rect(piece.source),
                  let origin = SavedCaptureValidation.point(piece.origin),
                  source.width >= 1, source.height >= 1,
                  source == source.integral,
                  CGRect(x: 0, y: 0, width: pixels[piece.imageIndex].width, height: pixels[piece.imageIndex].height).contains(source) else { return nil }
            var next = StitchPiece(image: pixels[piece.imageIndex], origin: origin, label: piece.label)
            next.id = piece.id
            next.lineageID = piece.lineageID
            next.source = source
            restored.append(next)
        }
        let fill: StitchBackground
        switch background {
        case "automatic": fill = .automatic
        case "transparent": fill = .transparent
        case "color": guard let color = backgroundColor.flatMap(Self.color) else { return nil }; fill = .color(color)
        default: return nil
        }
        var style = StitchStyle()
        style.transition = transition
        style.color = color; style.lineWidth = lineWidth; style.wave = wave
        style.blur = blur; style.feather = feather; style.visible = visible
        style.tearWidth = tearWidth; style.tearRoughness = tearRoughness
        style.foldDepth = foldDepth; style.foldStrength = foldStrength
        style.accordionWidth = accordionWidth; style.accordionPleats = accordionPleats
        style.breakSize = breakSize
        var document = StitchDocument(pieces: restored, style: style, background: fill)
        document.restorePackingState(packed: packed, horizontal: packingHorizontal, length: packingLength)
        return document.canRender ? document : nil
    }

    private static func components(_ color: NSColor) -> [CGFloat] {
        let rgb = color.usingColorSpace(.sRGB) ?? .clear
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }
    private static func color(_ components: [CGFloat]) -> NSColor? {
        guard components.count == 4, components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
    }
}
