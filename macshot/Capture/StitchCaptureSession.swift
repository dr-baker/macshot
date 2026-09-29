import AppKit
import Carbon

/// The shortcut captures the same display region repeatedly without taking focus from the page.
@MainActor
final class StitchCaptureSession: NSObject {
    static let shared = StitchCaptureSession()
    private var document = StitchDocument()
    private var pickerWindow: NSWindow?
    private var hud: NSPanel?
    private var hudLabel: NSTextField?
    private var sourceApp: NSRunningApplication?
    private var displayID: NSNumber?
    private var displayFrame: CGRect = .zero
    private var displayPixels: CGSize = .zero
    private var pixelRect: CGRect = .zero
    private var lastImage: CGImage?
    private var lastOrigin: CGPoint = .zero
    private var scrollHint: CGPoint = .zero
    private var scrollMonitor: Any?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var busy = false
    private var finishPending = false
    private var generation = UUID()
    private var sourcePixelCount = 0
    private var isActive = false
    var isPresenting: Bool { isActive || pickerWindow != nil || busy }
    private let matchingQueue = DispatchQueue(label: "macshot.stitch-alignment", qos: .userInitiated)

    func trigger() {
        guard !busy else { return }
        if isActive { captureNext(); return }
        start()
    }
    private func start() {
        guard pickerWindow == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert(); alert.messageText = L("Screen Recording Access Required")
            alert.informativeText = L("Allow macshot in System Settings, then start Stitch Capture again.")
            alert.addButton(withTitle: L("Open Settings")); alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            return
        }
        busy = true; generation = UUID()
        let token = generation
        sourceApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        ScreenCaptureManager.captureAllScreens { [weak self] captures in
            guard let self, self.generation == token else { return }
            self.busy = false
            guard let capture = captures.first(where: { $0.screen.frame.contains(mouse) }) ?? captures.first else { self.showError(L("Unable to capture this display.")); return }
            self.displayID = capture.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            self.displayFrame = capture.screen.frame
            self.displayPixels = CGSize(width: capture.image.width, height: capture.image.height)
            let window = StitchPickerWindow(contentRect: capture.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let picker = StitchRegionPicker(image: capture.image, frame: CGRect(origin: .zero, size: capture.screen.frame.size))
            picker.onCancel = { [weak self] in self?.cancel() }
            picker.onPick = { [weak self] rect in
                guard let self, let image = Self.copyRegion(capture.image, rect: rect) else { return }
                self.pixelRect = rect
                self.pickerWindow?.orderOut(nil); self.pickerWindow = nil
                self.document = StitchDocument(pieces: [StitchPiece(image: image, label: L("Capture"))])
                self.lastImage = image; self.lastOrigin = .zero
                self.sourcePixelCount = image.width * image.height
                self.isActive = true
                self.sourceApp?.activate(options: .activateIgnoringOtherApps)
                self.showHUD(); self.installSessionKeys(); self.startScrollTracking()
            }
            window.contentView = picker
            self.pickerWindow = window
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(picker)
        }
    }
    private func captureNext() {
        guard isActive, !busy else { return }
        guard document.pieces.count < 24, sourcePixelCount < 120_000_000 else { updateHUD(L("Capture limit reached · press Enter to edit")); return }
        busy = true
        hud?.orderOut(nil)
        let token = generation, hint = scrollHint
        scrollHint = .zero
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.isActive, self.generation == token else { return }
            ScreenCaptureManager.captureAllScreens { [weak self] captures in
                guard let self, self.isActive, self.generation == token else { return }
                guard let capture = captures.first(where: { ($0.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == self.displayID }), capture.screen.frame == self.displayFrame,
                      CGSize(width: capture.image.width, height: capture.image.height) == self.displayPixels,
                      let image = Self.copyRegion(capture.image, rect: self.pixelRect), let previous = self.lastImage else {
                    self.busy = false; self.hud?.orderFrontRegardless(); self.updateHUD(L("Display changed or capture failed · finish and start a new session")); if self.finishPending { self.finishPending = false; self.finish() }; return
                }
                self.matchingQueue.async { [weak self] in
                    let match = StitchAlignment.match(previous: previous, current: image, scrollHint: hint)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isActive, self.generation == token else { return }
                        self.accept(image, match: match, hint: hint)
                    }
                }
            }
        }
    }
    // Cropping alone retains the entire display buffer. Own only the selected pixels.
    private static func copyRegion(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height,
                                      bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }
    private func accept(_ image: CGImage, match: StitchAlignment.Match?, hint: CGPoint) {
        busy = false
        defer {
            hud?.orderFrontRegardless()
            if finishPending { finishPending = false; finish() }
        }
        if let match, abs(match.offset.x) < 2 && abs(match.offset.y) < 2 {
            updateHUD(L("Same content · scroll before the next capture")); return
        }
        var origin: CGPoint
        let label: String
        if let match {
            origin = CGPoint(x: lastOrigin.x + match.offset.x, y: lastOrigin.y + match.offset.y)
            label = L("Overlap matched")
        } else {
            if abs(hint.x) > abs(hint.y) && abs(hint.x) > 1 {
                origin = CGPoint(x: hint.x < 0 ? document.bounds.minX - CGFloat(image.width) : document.bounds.maxX, y: lastOrigin.y)
            } else {
                origin = CGPoint(x: lastOrigin.x, y: hint.y < -1 ? document.bounds.minY - CGFloat(image.height) : document.bounds.maxY)
            }
            label = L("Estimated · drag to adjust")
        }
        var next = document
        next.pieces.append(StitchPiece(image: image, origin: origin, label: label))
        guard next.canRender, sourcePixelCount + image.width * image.height <= 120_000_000 else { updateHUD(L("Canvas limit reached · press Enter to edit")); return }
        document = next; lastImage = image; lastOrigin = origin; sourcePixelCount += image.width * image.height
        updateHUD(label)
    }
    private func showHUD() {
        let panel = NSPanel(contentRect: CGRect(x: displayFrame.midX - 245, y: displayFrame.minY + 28, width: 490, height: 70), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("Stitch Capture")
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 12
        let label = NSTextField(wrappingLabelWithString: ""); label.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(NSButton(title: L("Capture"), target: self, action: #selector(captureClicked)))
        stack.addArrangedSubview(NSButton(title: L("Finish ↵"), target: self, action: #selector(finish)))
        stack.addArrangedSubview(NSButton(title: L("Cancel"), target: self, action: #selector(cancel)))
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let view = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
        hud = panel; hudLabel = label
        updateHUD(L("Scroll the page, then capture again")); panel.orderFrontRegardless()
    }
    private func updateHUD(_ message: String) { hudLabel?.stringValue = "\(document.pieces.count) \(L("captures")) · \(message)" }
    @objc private func captureClicked() { captureNext() }
    @objc private func finish() {
        guard isActive else { return }
        if busy { finishPending = true; updateHUD(L("Finishing capture…")); return }
        let result = document
        cleanup()
        StitchEditorWindowController.open(document: result)
    }
    @objc private func cancel() { cleanup(); sourceApp?.activate(options: .activateIgnoringOtherApps) }
    private func cleanup() {
        generation = UUID(); busy = false; isActive = false; finishPending = false
        pickerWindow?.orderOut(nil); pickerWindow = nil; hud?.orderOut(nil); hud = nil; hudLabel = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil
        for key in hotKeys { UnregisterEventHotKey(key) }; hotKeys = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
        document = StitchDocument(); lastImage = nil; scrollHint = .zero; sourcePixelCount = 0
    }
    private func startScrollTracking() {
        scrollHint = .zero
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.displayFrame.contains(NSEvent.mouseLocation) else { return }
                self.scrollHint.x -= event.scrollingDeltaX; self.scrollHint.y -= event.scrollingDeltaY
            }
        }
    }
    private func installSessionKeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == OSType(0x53544348) else { return OSStatus(eventNotHandledErr) }
            let session = Unmanaged<StitchCaptureSession>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { if id.id == 1 { session.finish() } else { session.cancel() } }
            return noErr
        }, 1, &type, pointer, &handler)
        for (code, id) in [(kVK_Return, 1), (kVK_Escape, 2), (kVK_ANSI_KeypadEnter, 1)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: OSType(0x53544348), id: UInt32(id)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { hotKeys.append(ref) }
        }
        if hotKeys.isEmpty { updateHUD(L("Use Finish to open the stitch editor")) }
    }
    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
}
