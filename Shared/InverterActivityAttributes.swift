import ActivityKit
import Foundation

nonisolated struct InverterActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        let solarWatts: Double
        let loadWatts: Double
        let batteryPercent: Double
        let mode: String
        let updatedAt: Date
        var paused: Bool
    }
    let name: String
}
