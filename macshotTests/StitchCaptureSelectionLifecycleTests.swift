import AppKit
import XCTest

@MainActor
final class StitchCaptureSelectionLifecycleTests: XCTestCase {
    func testSpaceChangeRejectsInFlightDesktopAndKeepsPendingSelection() throws {
        let fixture = Fixture()
        fixture.request()
        let obsolete = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.dispatch(obsolete))
        fixture.lifecycle.workspaceDidChange()
        let current = try XCTUnwrap(fixture.requests.last)
        XCTAssertNotEqual(current, obsolete)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertFalse(fixture.dispatch(obsolete))
        XCTAssertFalse(fixture.receive(obsolete))
        XCTAssertTrue(fixture.visibleSelectors.isEmpty)
        XCTAssertTrue(fixture.completions.isEmpty)
        XCTAssertTrue(fixture.lifecycle.hasPendingSelection)
        XCTAssertTrue(fixture.dispatch(current))
        XCTAssertTrue(fixture.receive(current))
        XCTAssertFalse(fixture.receive(current))
        XCTAssertEqual(fixture.visibleSelectors, [current, current])
    }

    func testSpaceChangeDismissesEveryFrozenSelectorAndRejectsItsLatePick() throws {
        let fixture = Fixture()
        fixture.request()
        let obsolete = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(obsolete))
        fixture.lifecycle.workspaceDidChange()
        let current = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(fixture.dismissedSelectors, [obsolete, obsolete])
        XCTAssertTrue(fixture.visibleSelectors.isEmpty)
        XCTAssertFalse(fixture.lifecycle.complete(frame: frame(), for: obsolete))
        XCTAssertTrue(fixture.completions.isEmpty)
        XCTAssertTrue(fixture.receive(current))
        let accepted = frame()
        XCTAssertTrue(fixture.lifecycle.complete(frame: accepted, for: current))
        XCTAssertEqual(fixture.completions.count, 1)
        XCTAssertTrue(fixture.completions[0]?.image === accepted.image)
        XCTAssertFalse(fixture.lifecycle.hasPendingSelection)
        XCTAssertTrue(fixture.visibleSelectors.isEmpty)
    }

    func testSpaceChangeWhileNavigatingWaitsForReleaseAndPreservesPendingRequest() throws {
        let fixture = Fixture()
        fixture.request()
        let obsolete = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(obsolete))
        fixture.lifecycle.navigate(true)
        fixture.lifecycle.workspaceDidChange()
        fixture.lifecycle.workspaceDidChange()
        XCTAssertTrue(fixture.lifecycle.navigating)
        XCTAssertTrue(fixture.lifecycle.hasPendingSelection)
        XCTAssertFalse(fixture.lifecycle.capturing)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.dismissedSelectors, [obsolete, obsolete])
        XCTAssertFalse(fixture.lifecycle.complete(frame: frame(), for: obsolete))
        fixture.lifecycle.navigate(false)
        XCTAssertFalse(fixture.lifecycle.navigating)
        XCTAssertTrue(fixture.lifecycle.capturing)
        XCTAssertEqual(fixture.requests.count, 2)
        let current = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(current))
        XCTAssertTrue(fixture.lifecycle.complete(frame: frame(), for: current))
        XCTAssertEqual(fixture.completions.count, 1)
        XCTAssertEqual(fixture.navigationChanges, [true, false])
    }

    func testEveryDispatchUsesCurrentHUDAndThumbnailWindowNumbers() throws {
        let fixture = Fixture()
        fixture.hudNumbers = [10]
        fixture.thumbnailNumbers = [20, 21]
        fixture.request()
        let first = try XCTUnwrap(fixture.requests.last)
        // A thumbnail can disappear and another appear during the capture delay.
        fixture.thumbnailNumbers = [21, 22]
        XCTAssertTrue(fixture.dispatch(first))
        XCTAssertEqual(fixture.dispatchedNumbers, [[10, 21, 22]])
        fixture.hudNumbers = [11]
        fixture.thumbnailNumbers = [22]
        fixture.lifecycle.workspaceDidChange()
        let second = try XCTUnwrap(fixture.requests.last)
        XCTAssertFalse(fixture.dispatch(first))
        XCTAssertTrue(fixture.dispatch(second))
        XCTAssertEqual(fixture.dispatchedNumbers, [[10, 21, 22], [11, 22]])
    }

    func testSpaceRefreshPreservesAcceptedPiecesAndFinishDiscardsRefreshedSelector() throws {
        let fixture = Fixture()
        let first = frame()
        let coordinator = StitchCaptureCoordinator(first: first, automaticallyContinues: true,
            capture: { completion in fixture.request(completion: completion) },
            analyze: { _, _, _, complete in complete(false, nil) })
        var finished: [StitchDocument] = []
        coordinator.onFinish = { document in
            finished.append(document)
            fixture.lifecycle.tearDown()
        }
        let firstPiece = try XCTUnwrap(coordinator.document.pieces.first)
        coordinator.requestCapture()
        let obsolete = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(obsolete))
        fixture.lifecycle.workspaceDidChange()
        XCTAssertEqual(coordinator.document.pieces.count, 1)
        XCTAssertEqual(coordinator.document.pieces[0].id, firstPiece.id)
        XCTAssertTrue(coordinator.document.pieces[0].image === first.image)
        XCTAssertTrue(coordinator.busy)
        XCTAssertFalse(fixture.lifecycle.complete(frame: frame(), for: obsolete))
        let refreshed = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(refreshed))
        let second = frame(position: CGPoint(x: 0, y: 24))
        XCTAssertTrue(fixture.lifecycle.complete(frame: second, for: refreshed))
        XCTAssertEqual(coordinator.document.pieces.count, 2)
        XCTAssertEqual(coordinator.document.pieces[0].id, firstPiece.id)
        XCTAssertEqual(coordinator.document.pieces[0].origin, firstPiece.origin)
        XCTAssertTrue(coordinator.document.pieces[1].image === second.image)
        XCTAssertEqual(coordinator.document.pieces[1].origin, CGPoint(x: 0, y: 24))
        let next = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(next))
        coordinator.finish()
        fixture.lifecycle.completePendingSelection()
        XCTAssertEqual(finished.map { $0.pieces.count }, [2])
        XCTAssertFalse(coordinator.active)
        XCTAssertFalse(fixture.lifecycle.isPresenting)
        XCTAssertTrue(fixture.visibleSelectors.isEmpty)
        XCTAssertFalse(fixture.lifecycle.complete(frame: frame(), for: next))
        XCTAssertFalse(fixture.receive(next))
    }

    func testTeardownWhileNavigatingRejectsLateCaptureWithoutRetryAndCanRestart() throws {
        let fixture = Fixture()
        fixture.request()
        let obsolete = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(obsolete))
        fixture.lifecycle.navigate(true)
        fixture.lifecycle.tearDown()
        fixture.lifecycle.workspaceDidChange()
        fixture.lifecycle.navigate(false)
        XCTAssertFalse(fixture.lifecycle.isPresenting)
        XCTAssertFalse(fixture.lifecycle.navigating)
        XCTAssertFalse(fixture.lifecycle.hasPendingSelection)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.dismissedSelectors, [obsolete, obsolete])
        XCTAssertFalse(fixture.dispatch(obsolete))
        XCTAssertFalse(fixture.receive(obsolete))
        XCTAssertFalse(fixture.lifecycle.complete(frame: frame(), for: obsolete))
        XCTAssertTrue(fixture.completions.isEmpty)
        fixture.request()
        let restarted = try XCTUnwrap(fixture.requests.last)
        XCTAssertNotEqual(restarted, obsolete)
        XCTAssertTrue(fixture.receive(restarted))
        XCTAssertTrue(fixture.lifecycle.complete(frame: frame(), for: restarted))
        XCTAssertEqual(fixture.completions.count, 1)
    }

    func testTeardownClosesAllVisibleSelectorsAndInvalidatesDelayedDispatch() throws {
        let fixture = Fixture()
        fixture.request()
        let shown = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(fixture.receive(shown))
        fixture.lifecycle.tearDown()
        XCTAssertEqual(fixture.dismissedSelectors, [shown, shown])
        XCTAssertTrue(fixture.visibleSelectors.isEmpty)
        XCTAssertFalse(fixture.lifecycle.complete(frame: frame(), for: shown))
        fixture.request()
        let delayed = try XCTUnwrap(fixture.requests.last)
        fixture.lifecycle.tearDown()
        XCTAssertFalse(fixture.dispatch(delayed))
        XCTAssertFalse(fixture.receive(delayed))
        XCTAssertTrue(fixture.completions.isEmpty)
        XCTAssertFalse(fixture.lifecycle.isPresenting)
    }

    private func frame(position: CGPoint = .zero) -> StitchCaptureFrame {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return StitchCaptureFrame(image: context.makeImage()!, position: position)
    }

    @MainActor
    private final class Fixture {
        var requests: [StitchCaptureSelectionLifecycle.Token] = []
        var visibleSelectors: [StitchCaptureSelectionLifecycle.Token] = []
        var dismissedSelectors: [StitchCaptureSelectionLifecycle.Token] = []
        var dispatchedNumbers: [[CGWindowID]] = []
        var hudNumbers: [CGWindowID] = []
        var thumbnailNumbers: [CGWindowID] = []
        var navigationChanges: [Bool] = []
        var completions: [StitchCaptureFrame?] = []
        lazy var lifecycle = StitchCaptureSelectionLifecycle(requestCapture: { [weak self] token in
            self?.requests.append(token)
        }, dismissSelectors: { [weak self] in
            guard let self else { return }
            dismissedSelectors += visibleSelectors
            visibleSelectors = []
        }, excludedWindowNumbers: { [weak self] in
            guard let self else { return [] }
            return ScreenCaptureWindowExclusions.combining(hudNumbers, thumbnailNumbers)
        }, navigationChanged: { [weak self] held in
            self?.navigationChanges.append(held)
        })

        func request(completion: ((StitchCaptureFrame?) -> Void)? = nil) {
            lifecycle.request { [weak self] frame in
                self?.completions.append(frame)
                completion?(frame)
            }
        }

        func dispatch(_ token: StitchCaptureSelectionLifecycle.Token) -> Bool {
            lifecycle.dispatchCapture(for: token) { dispatchedNumbers.append($0) }
        }

        func receive(_ token: StitchCaptureSelectionLifecycle.Token) -> Bool {
            guard lifecycle.receivedCapture(for: token) else { return false }
            // Two displays exercise the same dismissal callback used by the session.
            visibleSelectors = [token, token]
            return true
        }
    }
}
