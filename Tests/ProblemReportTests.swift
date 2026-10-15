import XCTest
@testable import SessionPresentation

final class ProblemReportTests: XCTestCase {
    private var context: ProblemReportContext {
        ProblemReportContext(version: "1.6.0", build: "14", systemVersion: "27.0.1", isTablet: false,
                             phase: .unverified, routeState: .paused,
                             settings: [.lowPower: true, .hideLockName: true, .recording: true])
    }

    func testReportIncludesUsefulStateWithoutUnrequestedNotes() {
        var buffer = DiagnosticBuffer(uptime: 1_000)
        buffer.record(.phase(.disconnected), uptime: 1_002)
        let report = PrivateProblemReport.render(context: context, buffer: buffer,
            category: .connection, uptime: 1_005, notes: "Private Home 37.12,-122.5 pairing-secret")
        XCTAssertTrue(report.contains("App: 1.6.0 (14)"))
        XCTAssertTrue(report.contains("Route state: paused"))
        XCTAssertTrue(report.contains("+2s  Connection: disconnected"))
        XCTAssertTrue(report.contains("Disconnected status events observed: 1"))
        XCTAssertFalse(report.contains("Private Home"))
        XCTAssertFalse(report.contains("37.12"))
        XCTAssertFalse(report.contains("pairing-secret"))
    }

    func testUnexpectedVersionStringsCannotInjectPrivateData() {
        var modified = context
        modified.version = "1.6.0\nHome: 37.12,-122.5"
        modified.build = "/private/pairing/secret.plist"
        modified.systemVersion = "My personal iPhone"
        let report = PrivateProblemReport.render(context: modified, buffer: DiagnosticBuffer(uptime: 0),
                                                  category: .other, uptime: 1)
        XCTAssertTrue(report.contains("App: unknown (unknown)"))
        XCTAssertTrue(report.contains("iOS: unknown"))
        XCTAssertFalse(report.contains("37.12"))
        XCTAssertFalse(report.contains("secret.plist"))
        XCTAssertFalse(report.contains("My personal"))
        XCTAssertEqual(PrivateProblemReport.versionNumber("27.0.1"), "27.0.1")
        XCTAssertEqual(PrivateProblemReport.versionNumber("..."), "unknown")
    }

    func testNotesRequireExplicitOptInAndAreBounded() {
        let report = PrivateProblemReport.render(context: context, buffer: DiagnosticBuffer(uptime: 0),
            category: .button, uptime: 1, includeNotes: true, notes: String(repeating: "🧭", count: 2_500))
        XCTAssertEqual(report.filter { $0 == "🧭" }.count, 2_000)
        XCTAssertTrue(report.contains("NOTES ADDED BY YOU"))
    }

    func testEventBufferRemainsBoundedAndRetainsNewestEvents() {
        var buffer = DiagnosticBuffer(uptime: 100)
        for index in 0..<150 { buffer.record(.foreground, uptime: Double(100 + index)) }
        XCTAssertEqual(buffer.events.count, 100)
        XCTAssertEqual(buffer.events.first?.elapsedSeconds, 50)
        XCTAssertEqual(buffer.events.last?.elapsedSeconds, 149)
    }

    func testRapidSuccessesDoNotHideConnectionFailures() {
        var buffer = DiagnosticBuffer(uptime: 100)
        buffer.record(.phase(.disconnected), uptime: 100)
        for index in 0..<120 { buffer.commandSucceeded(uptime: 101 + Double(index) * 0.5) }
        XCTAssertEqual(buffer.successfulCommands, 120)
        XCTAssertEqual(buffer.events.count, 3)
        XCTAssertEqual(buffer.events.first?.kind, .phase(.disconnected))
        XCTAssertEqual(buffer.lastSuccessAge(uptime: 162), 1)
    }

    func testClearRemovesEventsCountsAndOldSuccessAge() {
        var buffer = DiagnosticBuffer(uptime: 0)
        buffer.commandSucceeded(uptime: 3)
        buffer.record(.phase(.disconnected), uptime: 5)
        buffer.clear(uptime: 10)
        XCTAssertTrue(buffer.events.isEmpty)
        XCTAssertEqual(buffer.successfulCommands, 0)
        XCTAssertEqual(buffer.updateFailures, 0)
        XCTAssertNil(buffer.lastSuccessAge(uptime: 15))
        buffer.record(.foreground, uptime: 12)
        XCTAssertEqual(buffer.events.first?.elapsedSeconds, 2)
    }

    func testInvalidClockValuesDoNotCrashOrReportNegativeAges() {
        var buffer = DiagnosticBuffer(uptime: 100)
        buffer.record(.foreground, uptime: .nan)
        buffer.commandSucceeded(uptime: .infinity)
        XCTAssertTrue(buffer.events.isEmpty)
        XCTAssertEqual(buffer.successfulCommands, 0)
        buffer.record(.background, uptime: 98)
        XCTAssertEqual(buffer.events.first?.elapsedSeconds, 0)
        buffer.commandSucceeded(uptime: 110)
        XCTAssertNil(buffer.lastSuccessAge(uptime: 108))
    }
}
