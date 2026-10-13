import ActivityKit
import Foundation

final class LiveActivityClient {
    private var activityID: String?
    private var lastState: InverterActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    func update(_ reading: ReadingSnapshot, interval: Int) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return "Allow Live Activities in iOS Settings." }
        let state = InverterActivityAttributes.ContentState(
            solarWatts: reading.values["PV charging power"] ?? 0,
            loadWatts: reading.values["Load power"] ?? 0,
            batteryPercent: reading.values["Reported battery"] ?? 0,
            mode: reading.mode, updatedAt: reading.time, paused: false)
        let content = ActivityContent(state: state, staleDate: reading.time.addingTimeInterval(Double(interval + 20)))
        lastState = state
        let existing = Activity<InverterActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
        activityID = existing?.id
        do {
            if let activityID {
                updateTask?.cancel()
                let timestamp = Date.now
                updateTask = Task { await Self.send(id: activityID, content: content, timestamp: timestamp) }
            } else {
                activityID = try Activity.request(attributes: InverterActivityAttributes(name: "Home"), content: content, pushType: nil).id
            }
            return nil
        } catch { return "Couldn't start Live Activity." }
    }
    func pause() {
        guard ProcessInfo.processInfo.environment["INVERTER_LINK_TESTING"] != "1" else { return }
        let existing = Activity<InverterActivityAttributes>.activities.first { $0.id == activityID }
            ?? Activity<InverterActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
        guard let existing else { return }
        let activityID = existing.id
        self.activityID = activityID
        var state = lastState ?? existing.content.state
        state.paused = true
        lastState = state
        updateTask?.cancel()
        let timestamp = Date.now
        let content = ActivityContent(state: state, staleDate: timestamp)
        updateTask = Task { await Self.send(id: activityID, content: content, timestamp: timestamp) }
    }
    func end() {
        guard ProcessInfo.processInfo.environment["INVERTER_LINK_TESTING"] != "1" else { return }
        updateTask?.cancel()
        updateTask = nil
        let ids = Activity<InverterActivityAttributes>.activities.map(\.id)
        activityID = nil
        lastState = nil
        Task { await Self.end(ids: ids) }
    }
    // Keep the SDK's non-Sendable Activity handles local to the executor that performs async updates.
    @concurrent private static func send(id: String, content: ActivityContent<InverterActivityAttributes.ContentState>, timestamp: Date) async {
        guard !Task.isCancelled, let activity = Activity<InverterActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content, timestamp: timestamp)
    }
    @concurrent private static func end(ids: [String]) async {
        for activity in Activity<InverterActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
