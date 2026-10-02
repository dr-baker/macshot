import AppKit

/// Coordinates use the first capture's pixel scale, including observed page scrolling.
struct StitchCaptureFrame {
    let image: CGImage
    var position: CGPoint = .zero
    /// Frames without a desktop source still participate in content matching.
    let source: StitchCaptureSource?

    init(image: CGImage, position: CGPoint = .zero, source: StitchCaptureSource? = nil) {
        self.image = image
        self.position = position
        self.source = source
    }
}

/// Owns the asynchronous capture lifecycle independently of windows and global input.
@MainActor
final class StitchCaptureCoordinator {
    typealias Capture = (@escaping (StitchCaptureFrame?) -> Void) -> Void
    typealias Analyze = (CGImage, CGImage, CGPoint, @escaping (Bool, StitchAlignment.Match?) -> Void) -> Void
    private let capture: Capture
    private let analyze: Analyze
    private var generation = UUID()
    private var pending = false
    private var previousFrame: StitchCaptureFrame
    private var acceptedFrames: [StitchCaptureFrame]
    private let automaticallyContinues: Bool
    var canUndo: Bool { active && !finishing && document.pieces.count > 1 }
    private var finishing = false
    private var sourcePixels: Int
    private(set) var active = true
    private(set) var busy = false
    private(set) var document: StitchDocument
    private(set) var lastCaptureOutcome: String?
    var selectionStatus: String { lastCaptureOutcome ?? L("Drag to capture · hold Space to navigate") }
    var onUpdate: ((String) -> Void)?
    var onFinish: ((StitchDocument) -> Void)?

    init(first: StitchCaptureFrame, automaticallyContinues: Bool = false, capture: @escaping Capture, analyze: @escaping Analyze) {
        document = StitchDocument(pieces: [StitchPiece(image: first.image, label: L("Capture"))])
        sourcePixels = first.image.width * first.image.height
        previousFrame = first
        acceptedFrames = [first]
        self.automaticallyContinues = automaticallyContinues
        self.capture = capture
        self.analyze = analyze
    }

    /// Registration may have corrected earlier screen estimates. Anchor the next
    /// estimate to the last accepted document piece, including after Undo.
    func selectionRecommendations(at position: CGPoint, maximumSize: CGSize? = nil) -> StitchSelectionRecommendations.Result {
        guard let previous = document.pieces.last else {
            return StitchSelectionRecommendations.recommendations(frames: [])
        }
        let origin = CGPoint(x: previous.origin.x + position.x - previousFrame.position.x,
                             y: previous.origin.y + position.y - previousFrame.position.y)
        return StitchSelectionRecommendations.recommendations(frames: document.pieces.map(\.frame),
                                                              proposedOrigin: origin, maximumSize: maximumSize)
    }

    func selectionStartingGuides(screenFrame: CGRect, scrollOffset: CGPoint,
                                 pointer: CGPoint? = nil) -> StitchSelectionGuideGeometry.Result {
        guard let source = previousFrame.source, let previous = document.pieces.last else { return .empty }
        return StitchSelectionGuideGeometry.guides(frames: document.pieces.map(\.frame), anchor: previous.frame,
            source: source, screenFrame: screenFrame, scrollOffset: scrollOffset, pointer: pointer)
    }

    func requestCapture() {
        guard active, !finishing else { return }
        if busy {
            // Keep one requested capture; repeated key presses cannot create an unbounded queue.
            pending = true
            return
        }
        begin()
    }

    private func begin() {
        guard active, !finishing else { completeIfNeeded(); return }
        generation = UUID()
        guard document.pieces.count < 24, sourcePixels < 120_000_000 else {
            onUpdate?(L("Capture limit reached · press Enter to edit")); completeIfNeeded(); return
        }
        busy = true
        onUpdate?(selectionStatus)
        let token = generation
        capture { [weak self] frame in
            guard let self, self.active, self.generation == token else { return }
            guard let frame else {
                self.completed(message: L("Capture failed · try another region")); return
            }
            let hint = CGPoint(x: frame.position.x - self.previousFrame.position.x,
                               y: frame.position.y - self.previousFrame.position.y)
            self.analyze(self.previousFrame.image, frame.image, hint) { [weak self] identical, match in
                guard let self, self.active, self.generation == token else { return }
                self.accept(frame, identical: identical, match: match, hint: hint)
            }
        }
    }

    private func accept(_ frame: StitchCaptureFrame, identical: Bool, match: StitchAlignment.Match?, hint: CGPoint) {
        let image = frame.image
        if identical, abs(hint.x) < 2, abs(hint.y) < 2 {
            completed(message: L("Same content · scroll before the next capture")); return
        }
        let previous = document.pieces.last!
        let origin: CGPoint
        let label: String
        if let match, match.offset != .zero || image.width != previous.image.width || image.height != previous.image.height {
            origin = CGPoint(x: previous.origin.x + match.offset.x, y: previous.origin.y + match.offset.y)
            label = L("Overlap matched")
        } else {
            // Registration ignores margins and can report zero for a changed image.
            // Retain that capture somewhere visible so the user can place it manually.
            origin = Self.adjacentOrigin(previous: previous.frame,
                                         size: CGSize(width: image.width, height: image.height), hint: hint,
                                         occupied: document.pieces.map(\.frame))
            label = L("Estimated · drag to adjust")
        }
        var next = document
        next.pieces.append(StitchPiece(image: image, origin: origin, label: label))
        guard next.canRender, sourcePixels + image.width * image.height <= 120_000_000 else {
            completed(message: L("Canvas limit reached · press Enter to edit")); return
        }
        document = next
        previousFrame = frame
        acceptedFrames.append(frame)
        sourcePixels += image.width * image.height
        completed(message: label)
    }

    /// Screen distance suggests direction, but omitted page space must not become canvas space.
    /// Align the perpendicular edge as well so a diagonal selection cannot leave a gap at the join.
    static func adjacentOrigin(previous: CGRect, size: CGSize, hint: CGPoint, occupied: [CGRect] = []) -> CGPoint {
        let hasDirection = hint.x.isFinite && hint.y.isFinite && (abs(hint.x) >= 2 || abs(hint.y) >= 2)
        let horizontal = hasDirection && abs(hint.x) / (previous.width + size.width)
            > abs(hint.y) / (previous.height + size.height)
        let reverse = hasDirection && (horizontal ? hint.x < 0 : hint.y < 0)
        var origin = horizontal
            ? CGPoint(x: reverse ? previous.minX - size.width : previous.maxX, y: previous.minY)
            : CGPoint(x: previous.minX, y: reverse ? previous.minY - size.height : previous.maxY)
        // Returning across earlier captures must not hide them. Walk only through occupied
        // intervals so we attach to a real edge rather than a distant document bounding edge.
        for _ in occupied.indices {
            let candidate = CGRect(origin: origin, size: size)
            let collisions = occupied.filter {
                let overlap = candidate.intersection($0)
                return !overlap.isNull && overlap.width > 0 && overlap.height > 0
            }
            guard !collisions.isEmpty else { break }
            if horizontal {
                origin.x = reverse ? collisions.map(\.minX).min()! - size.width : collisions.map(\.maxX).max()!
            } else {
                origin.y = reverse ? collisions.map(\.minY).min()! - size.height : collisions.map(\.maxY).max()!
            }
        }
        return origin
    }

    private func completed(message: String) {
        lastCaptureOutcome = message
        busy = false
        onUpdate?(message)
        if !finishing && (pending || automaticallyContinues) {
            pending = false
            begin()
        } else { completeIfNeeded() }
    }

    /// Invalidates capture/matching work before restoring the last accepted registration reference.
    func undo() {
        guard canUndo else { return }
        generation = UUID()
        pending = false; busy = false
        let removed = acceptedFrames.removeLast()
        document.pieces.removeLast()
        previousFrame = acceptedFrames.last!
        sourcePixels -= removed.image.width * removed.image.height
        completed(message: L("Capture removed"))
    }

    func finish() {
        guard active else { return }
        finishing = true
        pending = false
        if busy { onUpdate?(L("Finishing capture…")) }
        completeIfNeeded()
    }

    private func completeIfNeeded() {
        guard active, finishing, !busy else { return }
        active = false
        onFinish?(document)
    }

    func cancel() {
        active = false; busy = false; finishing = false
        pending = false; generation = UUID()
        onUpdate = nil; onFinish = nil
    }
}
