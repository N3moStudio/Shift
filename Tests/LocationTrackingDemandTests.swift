import XCTest
@testable import SessionPresentation

final class LocationTrackingDemandTests: XCTestCase {
    func testIdleTrackingRequiresBothVisibleMapAndActiveApp() {
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: true, mapVisible: true, sessionKeepsAlive: false), .map)
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: true, mapVisible: false, sessionKeepsAlive: false), .stopped)
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: false, mapVisible: true, sessionKeepsAlive: false), .stopped)
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: false, mapVisible: false, sessionKeepsAlive: false), .stopped)
    }

    func testSessionKeepAliveSurvivesTabChangesAndBackgrounding() {
        for appActive in [false, true] {
            for mapVisible in [false, true] {
                XCTAssertEqual(LocationTrackingDemand.resolve(appActive: appActive, mapVisible: mapVisible, sessionKeepsAlive: true), .session)
            }
        }
    }

    func testEndingSessionDoesNotRestartIdleTrackingOnSettingsOrLockedPhone() {
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: true, mapVisible: false, sessionKeepsAlive: false), .stopped)
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: false, mapVisible: true, sessionKeepsAlive: false), .stopped)
        XCTAssertEqual(LocationTrackingDemand.resolve(appActive: true, mapVisible: true, sessionKeepsAlive: false), .map)
    }
}
