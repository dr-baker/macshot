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
    private var keyMonitor: Any?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var navigating = false
    private var capturing = false
    private var generation = UUID()
    var isPresenting: Bool { coordinator != nil || selectionCompletion != nil || !pickers.isEmpty || capturing || navigating }
    private let matchingQueue = DispatchQueue(label: "macshot.stitch-alignment", qos: .userInitiated)

    func trigger() {
        guard pickers.isEmpty, !capturing, selectionCompletion == nil, !navigating else { return }
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
        if let screen = NSScreen.main {
            makeHUD(screen: screen, rect: .zero, imageSize: screen.frame.size)
        }
        installSessionKeys(); startScrollTracking()
        selectFirstCapture()
    }

    private func selectFirstCapture() {
        selectCapture { [weak self] frame in
            guard let self else { return }
            guard let frame else {
                self.updateHUD(L("Capture failed · try another region"))
                self.selectFirstCapture()
                return
            }
            let coordinator = StitchCaptureCoordinator(first: frame, automaticallyContinues: true, capture: { [weak self] completion in
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
                DetachedEditorWindowController.open(stitchDocument: document)
            }
            coordinator.requestCapture()
        }
    }

    private func selectCapture(completion: @escaping (StitchCaptureFrame?) -> Void) {
        selectionCompletion = completion
        guard !navigating else { updateHUD(L("Navigate the page · release Space to select")); return }
        capturing = true
        generation = UUID()
        let token = generation, offset = scrollOffset
        let excluded = hud?.windowNumbers ?? []
        hud?.show()
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
                        self.makeHUD(screen: capture.screen, rect: rect,
                                     imageSize: CGSize(width: capture.image.width, height: capture.image.height))
                        self.endSelection(frame: StitchCaptureFrame(image: image, position: position))
                    }
                    return picker
                }
                for picker in self.pickers { picker.show() }
                self.updateHUD(L("Drag to capture · hold Space to navigate"))
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

    private func makeHUD(screen: NSScreen, rect: CGRect, imageSize: CGSize) {
        hud?.close()
        let hud = StitchCaptureHUD(screen: screen, pixelRect: rect, imageSize: imageSize)
        hud.onUndo = { [weak self] in self?.undo() }
        hud.onFinish = { [weak self] in self?.finish() }
        self.hud = hud
        updateHUD(L("Drag to capture · hold Space to navigate"))
    }

    private func updateHUD(_ message: String) {
        hud?.update(count: coordinator?.document.pieces.count ?? 0, status: message,
                    canUndo: coordinator?.canUndo ?? false)
        hud?.show()
    }

    private func undo() {
        guard let coordinator, coordinator.canUndo else { return }
        generation = UUID(); capturing = false
        selectionCompletion = nil
        for picker in pickers { picker.dismiss() }; pickers = []
        coordinator.undo()
    }

    /// Space temporarily returns input to the page. Releasing it starts a fresh screenshot.
    private func navigate(_ held: Bool) {
        guard held != navigating else { return }
        navigating = held
        if held {
            generation = UUID(); capturing = false
            for picker in pickers { picker.dismiss() }; pickers = []
            updateHUD(L("Navigate the page · release Space to select"))
        } else if let completion = selectionCompletion {
            selectCapture(completion: completion)
        }
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
        generation = UUID(); capturing = false; navigating = false
        coordinator?.cancel(); coordinator = nil
        selectionCompletion = nil
        for picker in pickers { picker.dismiss() }; pickers = []
        hud?.close(); hud = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
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
        // The selector owns keyboard focus while Macshot is active. Handle its
        // keys directly as well as Carbon hotkeys used while navigating another app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPresenting,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                let pressed = event.type == .keyDown
                switch Int(event.keyCode) {
                case kVK_Space:
                    if !event.isARepeat { self.navigate(pressed) }
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    if pressed { self.finish() }
                case kVK_Escape:
                    if pressed { self.cancel() }
                default: return event
                }
                return nil
            }
        }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == OSType(0x53544348), id.id == 1 || id.id == 2 || id.id == 3 else { return OSStatus(eventNotHandledErr) }
            let session = Unmanaged<StitchCaptureSession>.fromOpaque(data).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated {
                if id.id == 3 { session.navigate(pressed) }
                else if pressed { if id.id == 1 { session.finish() } else { session.cancel() } }
            }
            return noErr
        }, types.count, &types, pointer, &handler)
        guard status == noErr else {
            updateHUD(L("Use Finish to open the stitch editor")); return
        }
        var failedRegistration = false
        for (code, id) in [(kVK_Return, 1), (kVK_Escape, 2), (kVK_ANSI_KeypadEnter, 1), (kVK_Space, 3)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: OSType(0x53544348), id: UInt32(id)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { hotKeys.append(ref) } else { failedRegistration = true }
        }
        if failedRegistration { updateHUD(L("Use Finish to open the stitch editor")) }
    }
}
