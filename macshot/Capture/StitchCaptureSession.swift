import AppKit
import Carbon

/// Every capture opens the normal selector; Enter collects the session into one editable document.
@MainActor
final class StitchCaptureSession: NSObject {
    static let shared = StitchCaptureSession()
    private var coordinator: StitchCaptureCoordinator?
    private var pickers: [StitchRegionSelection] = []
    private var hud: StitchCaptureHUD?
    private var selectionCompletion: ((StitchCaptureFrame?) -> Void)?
    private var referenceScale: CGFloat?
    private var scrollOffset: CGPoint = .zero
    private var scrollMonitor: Any?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var capturing = false
    private var generation = UUID()
    var isPresenting: Bool { coordinator != nil || !pickers.isEmpty || capturing }
    private let matchingQueue = DispatchQueue(label: "macshot.stitch-alignment", qos: .userInitiated)

    func trigger() {
        guard pickers.isEmpty, !capturing else { return }
        if let coordinator { coordinator.requestCapture() }
        else { start() }
    }

    private func start() {
        guard CGPreflightScreenCaptureAccess() else {
            let alert = NSAlert(); alert.messageText = L("Screen Recording Access Required")
            alert.informativeText = L("Allow macshot in System Settings, then start Stitch Capture again.")
            alert.addButton(withTitle: L("Open Settings")); alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            return
        }
        referenceScale = nil; scrollOffset = .zero
        selectCapture { [weak self] frame in
            guard let self else { return }
            guard let frame else { self.cleanup(); self.showError(L("Unable to capture this display.")); return }
            let coordinator = StitchCaptureCoordinator(first: frame, capture: { [weak self] completion in
                self?.selectCapture(completion: completion)
            }, analyze: { [weak self] previous, current, expectedOffset, completion in
                self?.matchingQueue.async {
                    let identical = StitchAlignment.identical(previous, current)
                    let match = identical ? nil : StitchAlignment.matchRegions(previous: previous, current: current, expectedOffset: expectedOffset)
                    DispatchQueue.main.async { completion(identical, match) }
                }
            })
            self.coordinator = coordinator
            coordinator.onUpdate = { [weak self] message in self?.updateHUD(message) }
            coordinator.onFinish = { [weak self] document in
                self?.cleanup()
                StitchEditorWindowController.open(document: document)
            }
            self.updateHUD(L("Add Capture"))
            self.installSessionKeys(); self.startScrollTracking()
        }
    }

    private func selectCapture(completion: @escaping (StitchCaptureFrame?) -> Void) {
        capturing = true
        selectionCompletion = completion
        generation = UUID()
        let token = generation, offset = scrollOffset
        let excluded = hud?.windowNumbers ?? []
        hud?.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.generation == token else { return }
            ScreenCaptureManager.captureAllScreens(excludingWindowNumbers: excluded) { [weak self] captures in
                guard let self, self.generation == token else { return }
                self.capturing = false
                guard !captures.isEmpty else {
                    let callback = self.selectionCompletion; self.selectionCompletion = nil
                    callback?(nil); return
                }
                self.pickers = captures.map { capture in
                    let picker = StitchRegionSelection(capture: capture)
                    picker.onCancel = { [weak self] in self?.cancel() }
                    picker.onPick = { [weak self] rect in
                        guard let self, self.generation == token else { return }
                        let scale = CGFloat(capture.image.width) / capture.screen.frame.width
                        let baseScale = self.referenceScale ?? scale
                        self.referenceScale = baseScale
                        guard let image = Self.copyRegion(capture.image, rect: rect, scale: baseScale / scale) else {
                            self.endSelection(frame: nil); return
                        }
                        // AppKit global coordinates are bottom-up; document coordinates are top-down.
                        let position = StitchCaptureFrame.estimatedPosition(screenFrame: capture.screen.frame,
                            pixelRect: rect, pixelScale: scale, referenceScale: baseScale, scrollOffset: offset)
                        self.hud?.close()
                        let hud = StitchCaptureHUD(screen: capture.screen, pixelRect: rect,
                                                   imageSize: CGSize(width: capture.image.width, height: capture.image.height))
                        hud.onCapture = { [weak self] in self?.trigger() }
                        hud.onFinish = { [weak self] in self?.finish() }
                        hud.onCancel = { [weak self] in self?.cancel() }
                        self.hud = hud
                        self.endSelection(frame: StitchCaptureFrame(image: image, position: position))
                    }
                    return picker
                }
                for picker in self.pickers { picker.show() }
            }
        }
    }

    private func endSelection(frame: StitchCaptureFrame?) {
        for picker in pickers { picker.dismiss() }
        pickers = []; capturing = false
        let completion = selectionCompletion; selectionCompletion = nil
        completion?(frame)
    }

    // Own only selected pixels, normalized to the first display's pixel density.
    private static func copyRegion(_ image: CGImage, rect: CGRect, scale: CGFloat) -> CGImage? {
        guard let crop = image.cropping(to: rect) else { return nil }
        let width = max(1, Int((CGFloat(crop.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(crop.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func updateHUD(_ message: String) {
        guard let coordinator else { return }
        hud?.update(count: coordinator.document.pieces.count, status: message, busy: coordinator.busy)
        if pickers.isEmpty && !capturing { hud?.show() }
    }
    @objc private func finish() {
        guard let coordinator else { cancel(); return }
        // Enter while selecting finishes the captures already accepted, without saving an empty selection.
        if selectionCompletion != nil {
            generation = UUID()
            coordinator.finish()
            endSelection(frame: nil)
        } else { coordinator.finish() }
    }
    @objc private func cancel() { cleanup() }
    private func cleanup() {
        generation = UUID(); capturing = false
        coordinator?.cancel(); coordinator = nil
        selectionCompletion = nil
        for picker in pickers { picker.dismiss() }; pickers = []
        hud?.close(); hud = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil
        for key in hotKeys { UnregisterEventHotKey(key) }; hotKeys = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
        scrollOffset = .zero; referenceScale = nil
    }
    private func startScrollTracking() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.scrollOffset.x -= event.scrollingDeltaX
                self?.scrollOffset.y -= event.scrollingDeltaY
            }
        }
    }
    private func installSessionKeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == OSType(0x53544348), id.id == 1 || id.id == 2 else { return OSStatus(eventNotHandledErr) }
            let session = Unmanaged<StitchCaptureSession>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { if id.id == 1 { session.finish() } else { session.cancel() } }
            return noErr
        }, 1, &type, pointer, &handler)
        guard status == noErr else {
            updateHUD(L("Use Finish to open the stitch editor")); return
        }
        var failedRegistration = false
        for (code, id) in [(kVK_Return, 1), (kVK_Escape, 2), (kVK_ANSI_KeypadEnter, 1)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: OSType(0x53544348), id: UInt32(id)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { hotKeys.append(ref) } else { failedRegistration = true }
        }
        if failedRegistration { updateHUD(L("Use Finish to open the stitch editor")) }
    }
    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
}
