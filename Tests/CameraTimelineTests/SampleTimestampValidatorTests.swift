import CoreMedia
import XCTest
@testable import CameraTimeline

final class SampleTimestampValidatorTests: XCTestCase {
    func testAcceptsFirstSyntheticSample() {
        XCTAssertTrue(SampleTimestampValidator.strictlyAdvances(time(0), after: nil))
    }

    func testAcceptsStrictlyIncreasingSyntheticSample() {
        XCTAssertTrue(SampleTimestampValidator.strictlyAdvances(time(2), after: time(1)))
    }

    func testRejectsDuplicateSyntheticSampleTimestamp() {
        XCTAssertFalse(SampleTimestampValidator.strictlyAdvances(time(1), after: time(1)))
    }

    func testRejectsRegressingSyntheticSampleTimestamp() {
        XCTAssertFalse(SampleTimestampValidator.strictlyAdvances(time(1), after: time(2)))
    }

    func testRejectsNonNumericSyntheticSampleTimestamp() {
        XCTAssertFalse(SampleTimestampValidator.strictlyAdvances(.indefinite, after: time(1)))
        XCTAssertFalse(SampleTimestampValidator.strictlyAdvances(time(2), after: .positiveInfinity))
    }

    private func time(_ value: CMTimeValue) -> CMTime {
        CMTime(value: value, timescale: 24)
    }
}
