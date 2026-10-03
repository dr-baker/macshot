import AppKit
import Carbon

/// Every capture opens the normal selector; Enter collects the session into one editable document.
@MainActor
final class StitchCaptureSession: NSObject {
    static let shared = StitchCaptureSession()
    private var coordinator: StitchCaptureCoordinator?
    private var pickers: [StitchRegionSelection] = []
    private var hud: StitchCaptureHUD?
    var thumbnailWindowNumbers: () -> [CGWindowID] = { [] }
    private var referenceScale: CGFloat?
    private var firstCaptureFailure: String?
    private var scrollOffset: CGPoint = .zero
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private lazy var selection = StitchCaptureSelectionLifecycle(requestCapture: { [weak self] token in
        self?.captureScreens(for: token)
    }, dismissSelectors: { [weak self] in
        self?.dismissPickers()
    }, excludedWindowNumbers: { [weak self] in
        guard let self else { return [] }
        return ScreenCaptureWindowExclusions.combining(self.hud?.windowNumbers ?? [], self.thumbnailWindowNumbers())
    }, navigationChanged: { [weak self] held in
        if held { self?.updateHUD(L("Navigate the page · release Space to select")) }
    })
    var isPresenting: Bool { coordinator != nil || selection.isPresenting || !pickers.isEmpty }
    private let matchingQueue = DispatchQueue(label: "macshot.stitch-alignment", qos: .userInitiated)

    func trigger() {
        guard pickers.isEmpty, !selection.isPresenting else { return }
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
                let message = L("Capture failed · try another region")
                self.firstCaptureFailure = message
                self.updateHUD(message)
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
        selection.request(completion: completion)
    }

    private func captureScreens(for token: StitchCaptureSelectionLifecycle.Token) {
        hud?.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.selection.dispatchCapture(for: token) { excluded in
                let offset = self.scrollOffset
                ScreenCaptureManager.captureAllScreens(excludingWindowNumbers: excluded) { [weak self] captures in
                    self?.presentCaptures(captures, for: token, scrollOffset: offset)
                }
            }
        }
    }

    private func presentCaptures(_ captures: [ScreenCapture], for token: StitchCaptureSelectionLifecycle.Token,
                                 scrollOffset offset: CGPoint) {
        guard selection.receivedCapture(for: token) else { return }
        guard !captures.isEmpty else {
            selection.complete(frame: nil, for: token)
            return
        }
        pickers = captures.map { capture in
            let picker = StitchRegionSelection(capture: capture)
            if let coordinator = coordinator, let referenceScale = referenceScale {
                picker.setStartingGuides { [weak coordinator] pointer in
                    coordinator?.selectionStartingGuides(screenFrame: capture.screen.frame,
                        scrollOffset: offset, pointer: pointer) ?? .empty
                }
                picker.setSizeRecommendations(referenceScale: referenceScale) { [weak coordinator] rect, available in
                    let topLeft = CGPoint(x: capture.screen.frame.minX + rect.minX,
                                          y: capture.screen.frame.minY + rect.maxY)
                    guard let position = StitchCaptureSource.estimatedPosition(screenTopLeft: topLeft,
                        scrollOffset: offset, referenceScale: referenceScale) else {
                        return .init(widths: [], heights: [])
                    }
                    return (coordinator?.selectionRecommendations(at: position, maximumSize:
                        CGSize(width: available.width * referenceScale, height: available.height * referenceScale))
                        ?? StitchSelectionRecommendations.recommendations(frames: []))
                        .scaled(by: 1 / referenceScale)
                }
            }
            picker.onCancel = { [weak self] in
                guard let self, self.selection.canSelect(for: token) else { return }
                self.cancel()
            }
            picker.onPick = { [weak self] rect in
                guard let self, self.selection.canSelect(for: token) else { return }
                let scale = CGFloat(capture.image.width) / capture.screen.frame.width
                let baseScale = self.referenceScale ?? scale
                self.referenceScale = baseScale
                let pixelsPerPoint = CGSize(width: scale,
                    height: CGFloat(capture.image.height) / capture.screen.frame.height)
                guard let source = StitchCaptureSource.fromPixels(screenFrame: capture.screen.frame,
                    pixelRect: rect, pixelsPerPoint: pixelsPerPoint, scrollOffset: offset),
                    let position = source.estimatedPosition(referenceScale: baseScale),
                    let image = StitchCaptureImageCrop.copy(image: capture.image, rect: rect, scale: baseScale / scale) else {
                    self.selection.complete(frame: nil, for: token); return
                }
                self.makeHUD(screen: capture.screen, rect: rect,
                             imageSize: CGSize(width: capture.image.width, height: capture.image.height))
                self.selection.complete(frame: StitchCaptureFrame(image: image, position: position, source: source), for: token)
            }
            return picker
        }
        for picker in pickers { picker.show() }
        updateHUD(coordinator?.selectionStatus ?? firstCaptureFailure
            ?? L("Drag to capture · hold Space to navigate"))
    }

    private func dismissPickers() {
        for picker in pickers { picker.dismiss() }
        pickers = []
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
        selection.discardPendingSelection()
        coordinator.undo()
    }

    /// Space temporarily returns input to the page. Releasing it starts a fresh screenshot.
    private func navigate(_ held: Bool) {
        selection.navigate(held)
    }

    func workspaceDidChange() {
        guard isPresenting else { return }
        selection.workspaceDidChange()
    }

    @objc private func finish() {
        // Flushing may accept the first image, start analysis, or replace the pickers.
        // Iterate the original selectors before deciding which unfinished work to drop.
        let completedPickers = pickers
        for picker in completedPickers { picker.flushPendingSelection() }
        guard let coordinator else { return }
        // Enter while selecting finishes the captures already accepted, without saving an empty selection.
        if selection.hasPendingSelection {
            coordinator.finish()
            selection.completePendingSelection()
        } else { coordinator.finish() }
    }
    @objc private func cancel() { cleanup() }
    private func cleanup() {
        coordinator?.cancel(); coordinator = nil
        selection.tearDown()
        hud?.close(); hud = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        for key in hotKeys { UnregisterEventHotKey(key) }; hotKeys = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
        scrollOffset = .zero; referenceScale = nil; firstCaptureFailure = nil
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPresenting else { return event }
                if event.type == .flagsChanged {
                    // Only one display's selector is key. Refresh hover guides
                    // on every display when Option changes at a stationary pointer.
                    for picker in self.pickers { picker.refreshStartingModifiers(event.modifierFlags) }
                    return event
                }
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
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
