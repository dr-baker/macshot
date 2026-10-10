import AppKit
import ImageIO

/// Original captures are stored once, even when a cut creates several slices.
/// Keeping the source index also preserves image identity when restoring slices.
struct SavedStitchDocument: Codable, Equatable {
    struct FoldTexture: Codable, Equatable {
        let cutID: UUID
        let horizontal: Bool
        let start: CGFloat
        let end: CGFloat
        let removedLength: CGFloat
        let image: Data
    }
    struct Piece: Codable, Equatable {
        var id: UUID
        var lineageID: UUID
        var imageIndex: Int
        var source: [CGFloat]
        var origin: [CGFloat]
        var label: String
        var trimStamps: [StitchTrimStamp]

        private enum CodingKeys: String, CodingKey {
            case id, lineageID, imageIndex, source, origin, label, trimStamps
        }

        init(id: UUID, lineageID: UUID, imageIndex: Int, source: [CGFloat], origin: [CGFloat],
             label: String, trimStamps: [StitchTrimStamp] = []) {
            self.id = id
            self.lineageID = lineageID
            self.imageIndex = imageIndex
            self.source = source
            self.origin = origin
            self.label = label
            self.trimStamps = trimStamps
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            lineageID = try values.decode(UUID.self, forKey: .lineageID)
            imageIndex = try values.decode(Int.self, forKey: .imageIndex)
            source = try values.decode([CGFloat].self, forKey: .source)
            origin = try values.decode([CGFloat].self, forKey: .origin)
            label = try values.decode(String.self, forKey: .label)
            trimStamps = try values.decodeIfPresent([StitchTrimStamp].self, forKey: .trimStamps) ?? []
        }
    }
    var images: [Data]
    var pieces: [Piece]
    var foldTextures: [FoldTexture]
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
    var accordionPerspective: CGFloat
    var accordionYaw: CGFloat
    var breakSize: CGFloat
    var visible: Bool
    var background: String
    var backgroundColor: [CGFloat]?
    var packed: Bool
    var packingHorizontal: Bool
    var packingLength: CGFloat

    private enum CodingKeys: String, CodingKey {
        case images, pieces, foldTextures, transition, lineColor, lineWidth, wave, blur, feather, visible
        case tearWidth, tearRoughness, foldDepth, foldStrength, breakSize
        case accordionWidth, accordionPleats, accordionPerspective, accordionYaw
        case background, backgroundColor, packed, packingHorizontal, packingLength
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let style = StitchStyle()
        // Captured pixels and source geometry must restore together. Cosmetic
        // settings can use their defaults when a previous revision omitted them.
        images = try values.decode([Data].self, forKey: .images)
        pieces = try values.decode([Piece].self, forKey: .pieces)
        foldTextures = try values.decodeIfPresent([FoldTexture].self, forKey: .foldTextures) ?? []
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
        accordionPerspective = values.decode(.accordionPerspective, or: style.accordionPerspective)
        // Earlier documents used one angle and derived yaw from vertical tilt.
        accordionYaw = values.decode(.accordionYaw, or: accordionPerspective * 0.8)
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
                    guard let data = Self.png(piece.image) else { return nil }
                    png = data
                    imageData.append((piece.image, png))
                }
                index = sources.count
                sources.append(piece.image)
                images.append(png)
            }
            pieces.append(Piece(id: piece.id, lineageID: piece.lineageID, imageIndex: index,
                source: [piece.source.minX, piece.source.minY, piece.source.width, piece.source.height],
                origin: [piece.origin.x, piece.origin.y], label: piece.label, trimStamps: piece.trimStamps))
        }
        var textures: [FoldTexture] = []
        for (cutID, strips) in document.activeFoldTextures.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for strip in strips {
                let data: Data
                if let cached = imageData.first(where: { $0.image === strip.image }) { data = cached.data }
                else {
                    guard let encoded = Self.png(strip.image) else { return nil }
                    data = encoded
                    imageData.append((strip.image, encoded))
                }
                if !sources.contains(where: { $0 === strip.image }) { sources.append(strip.image) }
                textures.append(FoldTexture(cutID: cutID, horizontal: strip.axis == .horizontal,
                    start: strip.start, end: strip.end, removedLength: strip.removedLength, image: data))
            }
        }
        imageData.removeAll { cached in !sources.contains(where: { $0 === cached.image }) }
        self.images = images
        self.pieces = pieces
        foldTextures = textures
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
        accordionPerspective = document.style.accordionPerspective
        accordionYaw = document.style.accordionYaw
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
              pieces.reduce(0, { $0 + $1.trimStamps.count }) <= StitchDocument.maximumTrimStamps,
              pieces.allSatisfy({ $0.trimStamps.count <= StitchPiece.maximumTrimStamps }),
              foldTextures.count <= StitchDocument.maximumFoldTextures,
              (images + foldTextures.map(\.image)).reduce(0, {
                  $0 + min($1.count, SavedCaptureValidation.maximumImageBytes + 1)
              }) <= SavedCaptureValidation.maximumImageBytes,
              [lineWidth, wave, blur, feather, tearWidth, tearRoughness, foldDepth, foldStrength, breakSize, packingLength].allSatisfy({ $0.isFinite && $0 >= 0 }),
              lineWidth <= 100, wave <= 100, blur <= 100, feather <= 4096,
              tearWidth <= 100, tearRoughness <= 100, foldDepth <= 100,
              foldStrength <= StitchStyle.maximumFoldStrength, breakSize <= 100,
              accordionWidth.isFinite, (0...80).contains(accordionWidth),
              accordionPleats.isFinite, (2...6).contains(accordionPleats),
              accordionPleats.rounded() == accordionPleats,
              accordionPerspective.isFinite, (-30...30).contains(accordionPerspective),
              accordionYaw.isFinite, (-35...35).contains(accordionYaw),
              packingLength <= StitchDocument.maximumDimension,
              !packed || packingLength > 0, let color = Self.color(lineColor),
              let transition = StitchTransition(rawValue: transition) else { return nil }
        var pixels: [CGImage] = []
        var totalPixels = 0
        func decode(_ data: Data) -> CGImage? {
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
            return image
        }
        for data in images {
            guard let image = decode(data) else { return nil }
            pixels.append(image)
        }
        var restored: [StitchPiece] = []
        for piece in pieces {
            guard pixels.indices.contains(piece.imageIndex),
                  let source = SavedCaptureValidation.rect(piece.source),
                  let origin = SavedCaptureValidation.point(piece.origin),
                  source.width >= 1, source.height >= 1,
                  source == source.integral,
                  piece.trimStamps.allSatisfy({ $0.isValid(on: source) }),
                  CGRect(x: 0, y: 0, width: pixels[piece.imageIndex].width, height: pixels[piece.imageIndex].height).contains(source) else { return nil }
            var next = StitchPiece(image: pixels[piece.imageIndex], origin: origin, label: piece.label)
            next.id = piece.id
            next.lineageID = piece.lineageID
            next.source = source
            next.trimStamps = piece.trimStamps
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
        style.accordionPerspective = accordionPerspective
        style.accordionYaw = accordionYaw
        style.breakSize = breakSize
        var document = StitchDocument(pieces: restored, style: style, background: fill)
        document.restorePackingState(packed: packed, horizontal: packingHorizontal, length: packingLength)
        var textures: [UUID: [StitchFoldTexture]] = [:]
        var texturePixels = 0
        let activeCuts = Set(restored.flatMap(\.trimStamps).map(\.cutID))
        for saved in foldTextures {
            guard activeCuts.contains(saved.cutID), let image = decode(saved.image) else { return nil }
            let texture = StitchFoldTexture(image: image, axis: saved.horizontal ? .horizontal : .vertical,
                start: saved.start, end: saved.end, removedLength: saved.removedLength)
            guard texture.isValid else { return nil }
            texturePixels += image.width * image.height
            guard texturePixels <= StitchDocument.maximumFoldTexturePixels else { return nil }
            textures[saved.cutID, default: []].append(texture)
        }
        document.restoreFoldTextures(textures)
        return document.canRender ? document : nil
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
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
