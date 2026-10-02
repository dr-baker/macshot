import CoreGraphics
import Foundation

/// Keeps one pending region request alive while its desktop snapshot is refreshed.
/// Window creation and screen capture stay with the session; obsolete callbacks
/// cannot present or accept pixels after navigation, a Space change, or teardown.
@MainActor
final class StitchCaptureSelectionLifecycle {
    typealias Token = UUID
    private enum Phase { case idle, capturing, selecting }
    private var phase = Phase.idle
    private var generation = Token()
    private var completion: ((StitchCaptureFrame?) -> Void)?
    private let requestCapture: (Token) -> Void
    private let dismissSelectors: () -> Void
    private let excludedWindowNumbers: () -> [CGWindowID]
    private let navigationChanged: (Bool) -> Void
    private(set) var navigating = false
    var capturing: Bool { phase == .capturing }
    var hasPendingSelection: Bool { completion != nil }
    var isPresenting: Bool { hasPendingSelection || phase != .idle || navigating }

    init(requestCapture: @escaping (Token) -> Void, dismissSelectors: @escaping () -> Void,
         excludedWindowNumbers: @escaping () -> [CGWindowID], navigationChanged: @escaping (Bool) -> Void) {
        self.requestCapture = requestCapture
        self.dismissSelectors = dismissSelectors
        self.excludedWindowNumbers = excludedWindowNumbers
        self.navigationChanged = navigationChanged
    }

    func request(completion: @escaping (StitchCaptureFrame?) -> Void) {
        self.completion = completion
        if navigating { navigationChanged(true) }
        else { beginCapture() }
    }

    private func beginCapture() {
        invalidateSnapshot()
        phase = .capturing
        requestCapture(generation)
    }

    /// Called after the capture delay, so thumbnails created or dismissed during
    /// that delay contribute their current window IDs to both capture backends.
    @discardableResult
    func dispatchCapture(for token: Token, capture: ([CGWindowID]) -> Void) -> Bool {
        guard generation == token, capturing, hasPendingSelection else { return false }
        capture(excludedWindowNumbers())
        return true
    }

    /// Returns false for a screenshot captured on an obsolete desktop.
    @discardableResult
    func receivedCapture(for token: Token) -> Bool {
        guard generation == token, capturing, hasPendingSelection else { return false }
        phase = .selecting
        return true
    }

    func canSelect(for token: Token) -> Bool {
        generation == token && phase == .selecting && hasPendingSelection
    }

    @discardableResult
    func complete(frame: StitchCaptureFrame?, for token: Token) -> Bool {
        guard canSelect(for: token) else { return false }
        completePendingSelection(frame: frame)
        return true
    }

    /// Finishing drops the unfinished selection while allowing its coordinator
    /// to finish accepted pieces. Clear state before the callback can request again.
    func completePendingSelection(frame: StitchCaptureFrame? = nil) {
        let callback = completion
        completion = nil
        invalidateSnapshot()
        callback?(frame)
    }

    func discardPendingSelection() {
        completion = nil
        invalidateSnapshot()
    }

    func navigate(_ held: Bool) {
        guard held != navigating else { return }
        navigating = held
        navigationChanged(held)
        if held { invalidateSnapshot() }
        else if hasPendingSelection { beginCapture() }
    }

    func workspaceDidChange() {
        guard hasPendingSelection else { return }
        // Keep the completion and navigation state. Only the obsolete snapshot
        // is discarded; accepted document pieces belong to the coordinator.
        if navigating { invalidateSnapshot() }
        else { beginCapture() }
    }

    func tearDown() {
        completion = nil
        navigating = false
        invalidateSnapshot()
    }

    private func invalidateSnapshot() {
        generation = Token()
        phase = .idle
        dismissSelectors()
    }
}
