import XCTest
@testable import SessionPresentation

final class SpeedUnitTests: XCTestCase {
    func testEveryWholeSecondThrough24HoursHasLosslessComponents() {
        for total in 0...86_400 {
            let seconds = Double(total)
            let hours = StopDuration.value(.hours, in: seconds)
            let minutes = StopDuration.value(.minutes, in: seconds)
            let remainder = StopDuration.value(.seconds, in: seconds)
            XCTAssertEqual(hours * 3600 + minutes * 60 + remainder, total)
            XCTAssertTrue(StopDuration.isValid(seconds))
        }
    }
    func testEditingDurationComponentsPreservesOtherUnitsAndCaps24Hours() {
        XCTAssertEqual(StopDuration.replacing(.minutes, in: 3661, with: 30), 5401)
        XCTAssertEqual(StopDuration.replacing(.seconds, in: 3661, with: 59), 3719)
        XCTAssertEqual(StopDuration.replacing(.hours, in: 3661, with: 24), 86_400)
        XCTAssertEqual(StopDuration.replacing(.hours, in: 86_400, with: 23), 82_800)
        XCTAssertEqual(StopDuration.replacing(.minutes, in: 86_400, with: 1), 86_400)
        XCTAssertEqual(StopDuration.replacing(.seconds, in: 0, with: Int.max), 59)
        XCTAssertEqual(StopDuration.replacing(.hours, in: 3661, with: Int.min), 61)
    }
    func testLongDurationLabelsAndUnclampedRouteTotals() {
        XCTAssertEqual(StopDuration.label(3600), "1 hr")
        XCTAssertEqual(StopDuration.label(3601), "1 hr 1 sec")
        XCTAssertEqual(StopDuration.label(86_399), "23 hr 59 min 59 sec")
        XCTAssertEqual(StopDuration.label(86_400), "24 hr")
        XCTAssertEqual(StopDuration.formatted(172_815), "48 hr 15 sec")
        XCTAssertEqual(StopDuration.formatted(0), "0 sec")
        XCTAssertFalse(StopDuration.isValid(86_401))
        XCTAssertFalse(StopDuration.isValid(.nan))
        XCTAssertFalse(StopDuration.isValid(-1))
    }
    func testExactConversionsAndPhysicalLimits() {
        XCTAssertEqual(SpeedUnit.kilometersPerHour.value(fromMPH: 60), 96.56064, accuracy: 1e-10)
        XCTAssertEqual(SpeedConversion.metresPerSecond(mph: 1), 0.44704, accuracy: 1e-10)
        let mph = SpeedUnit.kilometersPerHour.mph(from: 36)
        XCTAssertEqual(SpeedConversion.metresPerSecond(mph: mph), 10, accuracy: 1e-10)
        for mode in TravelMode.allCases {
            let range = SpeedUnit.kilometersPerHour.range(for: mode)
            XCTAssertEqual(SpeedUnit.kilometersPerHour.mph(from: range.lowerBound), mode.speedRangeMPH.lowerBound, accuracy: 1e-10)
            XCTAssertEqual(SpeedUnit.kilometersPerHour.mph(from: range.upperBound), mode.speedRangeMPH.upperBound, accuracy: 1e-10)
        }
    }

    func testMetricSelectionUsesMetricGridAndRejectsInvalidSpeed() {
        let unit = SpeedUnit.kilometersPerHour
        XCTAssertEqual(unit.value(fromMPH: unit.selectedMPH(36.1, mode: .drive)), 36, accuracy: 1e-10)
        XCTAssertEqual(unit.value(fromMPH: unit.selectedMPH(4.24, mode: .walk)), 4.2, accuracy: 1e-10)
        XCTAssertEqual(unit.selectedMPH(-10, mode: .drive), 1)
        XCTAssertEqual(unit.selectedMPH(1000, mode: .drive), 85)
        XCTAssertEqual(unit.selectedMPH(.nan, mode: .drive), TravelMode.drive.defaultSpeedMPH)
    }

    func testRepeatedConversionsDoNotRoundSavedSpeeds() {
        for initial in [1.0, 3.14159, 15.0, 22.369362920544, 85.0] {
            var speed = initial
            for _ in 0..<1000 {
                speed = SpeedUnit.kilometersPerHour.mph(from: SpeedUnit.kilometersPerHour.value(fromMPH: speed))
            }
            XCTAssertEqual(speed, initial, accuracy: 1e-10)
        }
    }

    func testMetricSpeedDrivesRealPlaybackDistanceAndSectionETA() {
        let mph = SpeedUnit.kilometersPerHour.mph(from: 36)
        let target = SpeedConversion.metresPerSecond(mph: mph)
        var distance = 0.0
        for _ in 0..<120 {
            distance += RouteMotion.step(speed: target, target: target, remaining: 1000, mode: .drive, smooth: false).metres
        }
        XCTAssertEqual(distance, 600, accuracy: 1e-8)
        let section = RouteTravelSection(id: UUID(), startMetres: 0, endMetres: 600, mode: .drive, speedMPH: mph)
        XCTAssertEqual(section.metresPerSecond, 10, accuracy: 1e-10)
        XCTAssertEqual(RouteTravelSection.remainingSeconds([section], from: 0), 60, accuracy: 1e-10)
        XCTAssertEqual(RouteTravelSection.remainingSeconds([section], from: 300), 30, accuracy: 1e-10)
    }
}
