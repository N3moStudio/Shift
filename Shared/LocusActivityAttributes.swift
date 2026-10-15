import ActivityKit
import Foundation

struct LocusActivityAttributes: ActivityAttributes {
    typealias ContentState = SessionSnapshot
    var sessionID: UUID
}
