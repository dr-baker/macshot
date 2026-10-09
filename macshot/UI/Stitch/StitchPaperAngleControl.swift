import AppKit

/// A native two-axis control mirrors dragging the screenshot paper itself.
@MainActor
final class StitchPaperAngleControl: NSControl {
    var onCameraBegin: (() -> Void)?
    var onCameraChanged: ((StitchPaperCamera) -> Void)?
    var onCameraEnd: ((Bool) -> Void)?
    var onReset: (() -> Void)?
    var foregroundColor: NSColor = .labelColor {
        didSet { needsDisplay = true; resetButton.contentTintColor = foregroundColor }
    }
    var camera = StitchPaperCamera() {
        didSet {
            guard camera != oldValue else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
            if camera.perspective != oldValue.perspective { NSAccessibility.post(element: tiltAccessibility, notification: .valueChanged) }
            if camera.yaw != oldValue.yaw { NSAccessibility.post(element: turnAccessibility, notification: .valueChanged) }
        }
    }
    private let resetButton = NSButton(title: "", target: nil, action: nil)
    private lazy var tiltAccessibility = AngleAxisAccessibilityElement(owner: self, axis: .tilt)
    private lazy var turnAccessibility = AngleAxisAccessibilityElement(owner: self, axis: .turn)
    private var mouseOrigin: CGPoint?
    private var gestureCamera: StitchPaperCamera?
    private var hasCameraChanges = false
    override var isEnabled: Bool {
        didSet { resetButton.isEnabled = isEnabled; needsDisplay = true }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 176, height: 92) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("stitch.paper.angle")
        toolTip = L("Drag to tilt and turn. Hold Option for precision or Shift to lock an axis.")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("View angle"))
        setAccessibilityHelp(toolTip)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: L("Reset view angle"))
        resetButton.setButtonType(.momentaryPushIn)
        resetButton.imagePosition = .imageOnly
        resetButton.isBordered = false
        resetButton.bezelStyle = .inline
        resetButton.target = self
        resetButton.action = #selector(resetCamera)
        resetButton.toolTip = L("Reset view angle")
        resetButton.contentTintColor = foregroundColor
        resetButton.setAccessibilityLabel(L("Reset view angle"))
        addSubview(resetButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    var padRect: CGRect { CGRect(x: 0, y: 4, width: min(104, bounds.width), height: max(0, bounds.height - 8)) }
    private var dotRect: CGRect {
        let pad = padRect.insetBy(dx: 10, dy: 10)
        let x = pad.minX + (camera.yaw - StitchPaperCamera.yawRange.lowerBound) / rangeWidth(StitchPaperCamera.yawRange) * pad.width
        let y = pad.minY + (camera.perspective - StitchPaperCamera.perspectiveRange.lowerBound) / rangeWidth(StitchPaperCamera.perspectiveRange) * pad.height
        return CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
    }

    override func layout() {
        super.layout()
        resetButton.frame = CGRect(x: bounds.width - 24, y: 2, width: 22, height: 22)
        resetButton.isEnabled = isEnabled
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad = padRect
        let background = NSBezierPath(roundedRect: pad, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        background.fill()
        (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : foregroundColor.withAlphaComponent(0.16)).setStroke()
        background.lineWidth = window?.firstResponder === self ? 2 : 1
        background.stroke()
        let grid = NSBezierPath()
        grid.move(to: CGPoint(x: pad.minX + 9, y: pad.midY)); grid.line(to: CGPoint(x: pad.maxX - 9, y: pad.midY))
        grid.move(to: CGPoint(x: pad.midX, y: pad.minY + 9)); grid.line(to: CGPoint(x: pad.midX, y: pad.maxY - 9))
        foregroundColor.withAlphaComponent(0.16).setStroke()
        grid.lineWidth = 1
        grid.stroke()
        let dot = dotRect
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.16 : 0.08).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4)).fill()
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let x = pad.maxX + 10
        drawText(L("Tilt"), at: CGPoint(x: x, y: 10), color: foregroundColor.withAlphaComponent(0.82), font: .systemFont(ofSize: 10))
        drawText(degrees(camera.perspective), at: CGPoint(x: x, y: 24), color: foregroundColor, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        drawText(L("Turn"), at: CGPoint(x: x, y: 44), color: foregroundColor.withAlphaComponent(0.82), font: .systemFont(ofSize: 10))
        drawText(degrees(camera.yaw), at: CGPoint(x: x, y: 58), color: foregroundColor, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
    }

    private func drawText(_ text: String, at point: CGPoint, color: NSColor, font: NSFont) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.5)])
    }
    private func degrees(_ value: CGFloat) -> String {
        let digits = abs(value - value.rounded()) < 0.001 ? 0 : (abs(value * 10 - (value * 10).rounded()) < 0.001 ? 1 : 2)
        return String(format: "%+.*f°", digits, Double(value))
    }
    private func rangeWidth(_ range: ClosedRange<CGFloat>) -> CGFloat { range.upperBound - range.lowerBound }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, padRect.contains(point) else { return }
        window?.makeFirstResponder(self)
        if event.clickCount > 1 { resetCamera(); return }
        gestureCamera = camera
        hasCameraChanges = false
        // Dragging the handle is relative; clicking elsewhere places it there.
        mouseOrigin = dotRect.insetBy(dx: -5, dy: -5).contains(point) ? point : CGPoint(x: dotRect.midX, y: dotRect.midY)
        onCameraBegin?()
        changeCamera(with: event)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) { changeCamera(with: event) }

    private func changeCamera(with event: NSEvent) {
        guard let origin = mouseOrigin, let initial = gestureCamera else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pad = padRect.insetBy(dx: 10, dy: 10)
        guard pad.width > 0, pad.height > 0 else { return }
        let delta = CGPoint(x: (point.x - origin.x) * rangeWidth(StitchPaperCamera.yawRange) / pad.width / 0.15,
                            y: (point.y - origin.y) * rangeWidth(StitchPaperCamera.perspectiveRange) / pad.height / 0.15)
        let next = initial.dragged(by: delta, precision: event.modifierFlags.contains(.option),
                                   axisLock: event.modifierFlags.contains(.shift))
        guard next != camera else { return }
        camera = next
        hasCameraChanges = next != initial
        onCameraChanged?(next)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseOrigin != nil else { return }
        let changed = hasCameraChanges
        clearGesture()
        onCameraEnd?(changed)
        window?.invalidateCursorRects(for: self)
    }

    @discardableResult
    func cancelCameraGesture() -> Bool {
        guard let initial = gestureCamera else { return false }
        clearGesture()
        if camera != initial { camera = initial; onCameraChanged?(initial) }
        onCameraEnd?(false)
        window?.invalidateCursorRects(for: self)
        return true
    }

    private func clearGesture() {
        mouseOrigin = nil
        gestureCamera = nil
        hasCameraChanges = false
    }

    @objc private func resetCamera() {
        _ = cancelCameraGesture()
        onReset?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { _ = cancelCameraGesture() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(padRect, cursor: mouseOrigin == nil ? .openHand : .closedHand) } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, cancelCameraGesture() { return }
        guard isEnabled, event.modifierFlags.intersection([.command, .control]).isEmpty else {
            nextResponder?.keyDown(with: event); return
        }
        let step: CGFloat = event.modifierFlags.contains(.option) ? 0.25 : 1
        switch event.keyCode {
        case 123: adjust(perspective: 0, yaw: -step)
        case 124: adjust(perspective: 0, yaw: step)
        case 125: adjust(perspective: step, yaw: 0)
        case 126: adjust(perspective: -step, yaw: 0)
        default: nextResponder?.keyDown(with: event)
        }
    }

    private func adjust(perspective: CGFloat, yaw: CGFloat) {
        let next = StitchPaperCamera(perspective: camera.perspective + perspective, yaw: camera.yaw + yaw)
        commitCamera(next)
    }

    private func commitCamera(_ next: StitchPaperCamera) {
        guard next != camera else { return }
        onCameraBegin?()
        camera = next
        onCameraChanged?(next)
        onCameraEnd?(true)
    }

    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("View angle") }
    override func accessibilityChildren() -> [Any]? {
        guard !isHiddenOrHasHiddenAncestor else { return [] }
        return [tiltAccessibility, turnAccessibility, resetButton]
    }
    override func accessibilityVisibleChildren() -> [Any]? { accessibilityChildren() }
    override func accessibilityValue() -> Any? { "\(L("Tilt")) \(degrees(camera.perspective)), \(L("Turn")) \(degrees(camera.yaw))" }

    /// The pad draws both axes in one view. Stable accessibility children make
    /// each numeric axis adjustable without adding visible slider controls.
    @MainActor
    private final class AngleAxisAccessibilityElement: NSAccessibilityElement {
        enum Axis: Equatable { case tilt, turn }
        private weak var owner: StitchPaperAngleControl?
        private let axis: Axis

        init(owner: StitchPaperAngleControl, axis: Axis) {
            self.owner = owner
            self.axis = axis
            super.init()
            setAccessibilityElement(true)
            setAccessibilityRole(.slider)
            setAccessibilityLabel(axis == .tilt ? L("Tilt") : L("Turn"))
            setAccessibilityIdentifier(axis == .tilt ? "stitch.paper.angle.tilt" : "stitch.paper.angle.turn")
            setAccessibilityParent(owner)
            setAccessibilityOrientation(axis == .tilt ? .vertical : .horizontal)
        }

        private var range: ClosedRange<CGFloat> { axis == .tilt ? StitchPaperCamera.perspectiveRange : StitchPaperCamera.yawRange }
        private var value: CGFloat? { axis == .tilt ? owner?.camera.perspective : owner?.camera.yaw }

        override func isAccessibilityElement() -> Bool { owner?.isAccessibilityElement() == true }
        override func isAccessibilityEnabled() -> Bool { owner?.isEnabled == true && isAccessibilityElement() }
        override func accessibilityValue() -> Any? { value.map { NSNumber(value: Double($0)) } }
        override func accessibilityValueDescription() -> String? { value.flatMap { owner?.degrees($0) } }
        override func accessibilityMinValue() -> Any? { NSNumber(value: Double(range.lowerBound)) }
        override func accessibilityMaxValue() -> Any? { NSNumber(value: Double(range.upperBound)) }
        override func accessibilityFrame() -> NSRect {
            guard let owner else { return .zero }
            let x = owner.padRect.maxX + 10
            let rect = CGRect(x: x, y: axis == .tilt ? 10 : 44,
                              width: max(0, owner.bounds.maxX - x), height: 30)
            return NSAccessibility.screenRect(fromView: owner, rect: rect)
        }
        override func setAccessibilityValue(_ value: Any?) {
            guard let numeric = value as? NSNumber else { return }
            _ = setValue(CGFloat(numeric.doubleValue))
        }
        override func accessibilityPerformIncrement() -> Bool {
            guard let value else { return false }
            return setValue(value + 1)
        }
        override func accessibilityPerformDecrement() -> Bool {
            guard let value else { return false }
            return setValue(value - 1)
        }
        private func setValue(_ value: CGFloat) -> Bool {
            guard let owner, owner.isEnabled, owner.isAccessibilityElement(), value.isFinite else { return false }
            let next = StitchPaperCamera(perspective: axis == .tilt ? value : owner.camera.perspective,
                                        yaw: axis == .turn ? value : owner.camera.yaw)
            owner.commitCamera(next)
            return true
        }
    }
}
