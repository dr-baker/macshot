import XCTest

final class StitchAccordionAnimationTests: XCTestCase {
    func testEditorSamplesAreDenseBoundedAndShareExportEasing() {
        let times = StitchAccordionAnimation.editorKeyTimes
        let progress = StitchAccordionAnimation.editorProgresses
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last, 1)
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(times.count, progress.count)
        XCTAssertGreaterThanOrEqual(times.count, 43)
        XCTAssertLessThanOrEqual(times.count, 45)
        XCTAssertEqual(StitchAccordionAnimation.editorFramesPerSecond, 60)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 })
        for (time, value) in zip(times, progress) {
            let seconds = StitchAccordionAnimation.exportLeadHold
                + Double(time) * StitchAccordionAnimation.exportMotionDuration
            XCTAssertEqual(StitchAccordionAnimation.exportProgress(at: seconds), value, accuracy: 0.000001)
        }
        XCTAssertLessThan(progress[1] - progress[0], progress[22] - progress[21])
    }

    func testInvalidTimesAndEndpointHoldsHaveDefinedProgress() {
        XCTAssertEqual(StitchAccordionAnimation.progress(.nan), 0)
        XCTAssertEqual(StitchAccordionAnimation.progress(.infinity), 0)
        XCTAssertEqual(StitchAccordionAnimation.progress(-1), 0)
        XCTAssertEqual(StitchAccordionAnimation.progress(2), 1)
        XCTAssertEqual(StitchAccordionAnimation.exportProgress(at: .nan), 0)
        XCTAssertEqual(StitchAccordionAnimation.exportProgress(at: 0.25), 0)
        XCTAssertEqual(StitchAccordionAnimation.exportProgress(at: 1.15), 1, accuracy: 0.000001)
        XCTAssertEqual(StitchAccordionAnimation.exportProgress(at: 1.8), 1)
    }
}
