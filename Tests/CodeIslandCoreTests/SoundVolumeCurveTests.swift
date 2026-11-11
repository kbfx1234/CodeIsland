import XCTest
@testable import CodeIslandCore

final class SoundVolumeCurveTests: XCTestCase {
    func testEndpointsAreSilentAndFull() {
        XCTAssertEqual(SoundVolumeCurve.amplitude(forPercent: 0), 0)
        XCTAssertEqual(SoundVolumeCurve.amplitude(forPercent: -5), 0)
        XCTAssertEqual(SoundVolumeCurve.amplitude(forPercent: 100), 1)
        XCTAssertEqual(SoundVolumeCurve.amplitude(forPercent: 140), 1)
    }

    /// Settings at or above the knee — the 50 % default included — must play
    /// exactly as loud as they did under the old linear map.
    func testSettingsFromTheKneeUpKeepTheirOldLoudness() {
        for percent in SoundVolumeCurve.knee...99 {
            XCTAssertEqual(
                SoundVolumeCurve.amplitude(forPercent: percent),
                Float(percent) / 100,
                accuracy: 0.000_001,
                "\(percent)%"
            )
        }
    }

    /// The point of the change: the quiet end reaches far below the old
    /// 5 % floor (−26 dB) instead of stopping there.
    func testLowEndGoesMuchQuieterThanTheOldLinearFloor() {
        let oldFloor: Float = 0.05
        XCTAssertLessThan(SoundVolumeCurve.amplitude(forPercent: 5), oldFloor / 4)
        XCTAssertLessThan(SoundVolumeCurve.amplitude(forPercent: 1), 0.001)
        XCTAssertGreaterThan(SoundVolumeCurve.amplitude(forPercent: 1), 0, "1 % is soft, not muted")
    }

    func testCurveIsMonotonicAndContinuousAtTheKnee() {
        var previous: Float = 0
        for percent in 0...100 {
            let value = SoundVolumeCurve.amplitude(forPercent: percent)
            XCTAssertGreaterThanOrEqual(value, previous, "\(percent)%")
            previous = value
        }
        let justBelow = SoundVolumeCurve.amplitude(forPercent: SoundVolumeCurve.knee - 1)
        let atKnee = SoundVolumeCurve.amplitude(forPercent: SoundVolumeCurve.knee)
        XCTAssertLessThan(atKnee - justBelow, 0.03, "no audible jump where the taper hands over")
    }
}
