import Foundation

/// One expansion path drives the disposable editor reveal and saved animation.
/// Timing stays separate from mesh geometry, so both renderers use the same
/// connected sheet at a given eased progress.
nonisolated enum StitchAccordionAnimation {
    static let editorDuration: TimeInterval = 0.7
    static let editorFramesPerSecond = 60
    static let exportDuration: TimeInterval = 1.8
    static let exportLeadHold: TimeInterval = 0.25
    static let exportMotionDuration: TimeInterval = 0.9

    static let editorKeyTimes: [CGFloat] = {
        let intervals = Int((editorDuration * Double(editorFramesPerSecond)).rounded(.up))
        return (0...intervals).map { CGFloat($0) / CGFloat(intervals) }
    }()

    static var editorProgresses: [CGFloat] { editorKeyTimes.map(progress) }

    /// Ease into opening the pleats, then settle at the selected camera angle.
    static func progress(_ fraction: CGFloat) -> CGFloat {
        guard fraction.isFinite else { return 0 }
        let value = max(0, min(1, fraction))
        return value * value * (3 - 2 * value)
    }

    static func exportProgress(at seconds: TimeInterval) -> CGFloat {
        guard seconds.isFinite else { return 0 }
        return progress(CGFloat((seconds - exportLeadHold) / exportMotionDuration))
    }
}
