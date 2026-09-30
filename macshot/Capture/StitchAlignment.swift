import CoreGraphics
import Foundation
import Vision

/// Conservative translation matching. Ambiguous/blank images return nil and remain manually placeable.
enum StitchAlignment {
    struct Match { let offset: CGPoint; let error: Double }
    private struct Gray { let pixels: [UInt8]; let width: Int; let height: Int; let scale: CGFloat }
    private static func gray(_ image: CGImage) -> Gray? {
        let scale = min(1, 240 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return Gray(pixels: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height)), width: width, height: height, scale: scale)
    }
    private static func packedFrame(_ image: CGImage) -> ScrollFrameAnalyzer.Frame? {
        if let frame = ScrollFrameAnalyzer.frame(for: image) { return frame }
        // Cropped CGImages can omit trailing row padding. Repack before using a stride-based reader.
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage().flatMap { ScrollFrameAnalyzer.frame(for: $0) }
    }
    /// Compare every pixel, including margins; registration is not a duplicate detector.
    static func identical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        func bytes(_ image: CGImage) -> Data? {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: data, count: image.width * image.height * 4)
        }
        guard let first = bytes(a), let second = bytes(b) else { return false }
        return first == second
    }
    private static func registeredMatch(previous: CGImage, current: CGImage) -> Match? {
        guard let a = packedFrame(previous), let b = packedFrame(current) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        guard (try? VNImageRequestHandler(cgImage: current, options: [:]).perform([request])) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let transform = observation.alignmentTransform
        guard transform.tx.isFinite, transform.ty.isFinite,
              abs(transform.tx) < CGFloat(a.width) * 0.75, abs(transform.ty) < CGFloat(a.height) * 0.75 else { return nil }
        // Validate in top-left pixel coordinates, independently of Vision's transform convention.
        var best: Match?
        for signX: CGFloat in [-1, 1] {
            for signY: CGFloat in [-1, 1] {
                let cx = Int((transform.tx * signX).rounded()), cy = Int((transform.ty * signY).rounded())
                for dx in (cx - 1)...(cx + 1) {
                    for dy in (cy - 1)...(cy + 1) {
                        let mx = max(2, a.width / 12), my = max(2, a.height / 12)
                        let x0 = max(mx, dx + mx), x1 = min(a.width - mx, a.width + dx - mx)
                        let y0 = max(my, dy + my), y1 = min(a.height - my, a.height + dy - my)
                        guard x1 - x0 > a.width / 5, y1 - y0 > a.height / 5 else { continue }
                        var total = 0.0, squared = 0.0, difference = 0.0, count = 0.0
                        for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 32)) {
                            for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 32)) {
                                guard let ai = a.offset(x: x, y: y), let bi = b.offset(x: x - dx, y: y - dy) else { continue }
                                for (ac, bc) in [(a.redOffset, b.redOffset), (a.greenOffset, b.greenOffset), (a.blueOffset, b.blueOffset)] {
                                    let p = Double(a.bytes[ai + ac]), q = Double(b.bytes[bi + bc])
                                    total += p; squared += p * p; difference += abs(p - q); count += 1
                                }
                            }
                        }
                        guard count > 0, squared / count - pow(total / count, 2) > 100 else { continue }
                        let error = difference / count
                        if error < 4 && error < (best?.error ?? 255) { best = Match(offset: CGPoint(x: dx, y: dy), error: error) }
                    }
                }
            }
        }
        return best
    }
    /// Region captures may differ in size. Screen/scroll position supplies a candidate,
    /// and shared pixels verify it before we label the placement as matched.
    static func matchRegions(previous: CGImage, current: CGImage, expectedOffset: CGPoint) -> Match? {
        guard let a = packedFrame(previous), let b = packedFrame(current) else { return nil }
        func validate(_ offset: CGPoint) -> Match? {
            let dx = Int(offset.x.rounded()), dy = Int(offset.y.rounded())
            let x0 = max(0, dx), x1 = min(a.width, dx + b.width)
            let y0 = max(0, dy), y1 = min(a.height, dy + b.height)
            guard x1 - x0 >= 24, y1 - y0 >= 24,
                  (x1 - x0) * (y1 - y0) >= min(a.width * a.height, b.width * b.height) / 12 else { return nil }
            var error = 0.0, sum = 0.0, squared = 0.0, count = 0.0
            for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 64)) {
                for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 64)) {
                    guard let ai = a.offset(x: x, y: y), let bi = b.offset(x: x - dx, y: y - dy) else { continue }
                    for (ac, bc) in [(a.redOffset, b.redOffset), (a.greenOffset, b.greenOffset), (a.blueOffset, b.blueOffset)] {
                        let p = Double(a.bytes[ai + ac]), q = Double(b.bytes[bi + bc])
                        error += abs(p - q); sum += p; squared += p * p; count += 1
                    }
                }
            }
            guard count > 0, error / count < 4, squared / count - pow(sum / count, 2) > 100 else { return nil }
            return Match(offset: CGPoint(x: dx, y: dy), error: error / count)
        }
        if expectedOffset.x.isFinite, expectedOffset.y.isFinite,
           abs(expectedOffset.x) <= CGFloat(a.width + b.width), abs(expectedOffset.y) <= CGFloat(a.height + b.height),
           let expected = validate(expectedOffset) { return expected }
        // Start the registration samples near the predicted overlap. Cropping both
        // images at (0,0) loses shared content when a small selection comes from
        // the bottom or right of a much larger previous capture.
        let size = CGSize(width: min(previous.width, current.width), height: min(previous.height, current.height))
        func sampleOrigin(_ image: CGImage, toward offset: CGPoint) -> CGPoint {
            CGPoint(x: min(CGFloat(image.width) - size.width, max(0, offset.x)).rounded(),
                    y: min(CGFloat(image.height) - size.height, max(0, offset.y)).rounded())
        }
        let predictedA = sampleOrigin(previous, toward: expectedOffset)
        let predictedB = sampleOrigin(current, toward: CGPoint(x: -expectedOffset.x, y: -expectedOffset.y))
        var samples = [(predictedA, predictedB)]
        if predictedA != .zero || predictedB != .zero { samples.append((.zero, .zero)) }
        for (aOrigin, bOrigin) in samples {
            guard let first = previous.cropping(to: CGRect(origin: aOrigin, size: size)),
                  let second = current.cropping(to: CGRect(origin: bOrigin, size: size)) else { continue }
            let hint = CGPoint(x: expectedOffset.x - aOrigin.x + bOrigin.x,
                               y: expectedOffset.y - aOrigin.y + bOrigin.y)
            guard let registration = match(previous: first, current: second, scrollHint: hint) else { continue }
            let offset = CGPoint(x: registration.offset.x + aOrigin.x - bOrigin.x,
                                 y: registration.offset.y + aOrigin.y - bOrigin.y)
            if let match = validate(offset) { return match }
        }
        return nil
    }

    static func match(previous: CGImage, current: CGImage, scrollHint: CGPoint = .zero) -> Match? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        if max(previous.width, previous.height) > 240, let registration = registeredMatch(previous: previous, current: current) { return registration }
        guard let a = gray(previous), let b = gray(current), a.width >= 24, a.height >= 24 else { return nil }
        let horizontal = abs(scrollHint.x) > abs(scrollHint.y) * 1.5 && abs(scrollHint.x) > 1
        let axes: [Bool] = abs(scrollHint.x) + abs(scrollHint.y) > 1 ? [horizontal] : [false, true]
        var candidates: [(error: Double, dx: Int, dy: Int, variance: Double)] = []
        for xAxis in axes {
            let limit = Int(Double(xAxis ? a.width : a.height) * 0.72)
            for delta in -limit...limit {
                let dx = xAxis ? delta : 0, dy = xAxis ? 0 : delta
                let marginX = max(2, a.width / 12), marginY = max(2, a.height / 12)
                let x0 = max(marginX, dx + marginX), x1 = min(a.width - marginX, a.width + dx - marginX)
                let y0 = max(marginY, dy + marginY), y1 = min(a.height - marginY, a.height + dy - marginY)
                guard x1 - x0 > a.width / 5, y1 - y0 > a.height / 5 else { continue }
                var difference = 0.0, total = 0.0, squared = 0.0, count = 0.0
                for y in stride(from: y0, to: y1, by: 2) {
                    for x in stride(from: x0, to: x1, by: 2) {
                        let p = Double(a.pixels[y * a.width + x]), q = Double(b.pixels[(y - dy) * b.width + x - dx])
                        difference += abs(p - q); total += p; squared += p * p; count += 1
                    }
                }
                guard count > 0 else { continue }
                candidates.append((difference / count, dx, dy, squared / count - pow(total / count, 2)))
            }
        }
        guard let best = candidates.min(by: { $0.error < $1.error }), best.error < 7, best.variance > 100 else { return nil }
        let competitor = candidates.filter { abs($0.dx - best.dx) + abs($0.dy - best.dy) >= 5 }.map(\.error).min() ?? 255
        guard competitor > best.error + 1.5 else { return nil }
        return Match(offset: CGPoint(x: (CGFloat(best.dx) / a.scale).rounded(), y: (CGFloat(best.dy) / a.scale).rounded()), error: best.error)
    }
}
