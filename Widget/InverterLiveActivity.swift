import ActivityKit
import SwiftUI
import WidgetKit

@main struct InverterWidgets: WidgetBundle {
    var body: some Widget { InverterLiveActivity() }
}

struct InverterLiveActivity: Widget {
    private let mint = Color(red: 0.27, green: 0.89, blue: 0.66)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InverterActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(context.attributes.name, systemImage: "bolt.fill").font(.headline).foregroundStyle(mint)
                    Spacer()
                    Text(context.state.paused || context.isStale ? "Paused" : context.state.mode).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    stat("Solar", context.state.solarWatts, "W", "sun.max")
                    Spacer()
                    stat("Load", context.state.loadWatts, "W", "bolt")
                    Spacer()
                    stat("Battery", context.state.batteryPercent, "%", "battery.100percent")
                }
                Text(context.state.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }.padding(18)
                .activityBackgroundTint(Color(red: 0.055, green: 0.064, blue: 0.064))
                .activitySystemActionForegroundColor(.white)
                .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { stat("Solar", context.state.solarWatts, "W", "sun.max") }
                DynamicIslandExpandedRegion(.trailing) { stat("Load", context.state.loadWatts, "W", "bolt", alignment: .trailing) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("\(number(context.state.batteryPercent))%", systemImage: "battery.100percent").foregroundStyle(mint)
                        Spacer()
                        Text(context.state.paused || context.isStale ? "Paused" : context.state.mode).foregroundStyle(.secondary)
                    }.font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: context.state.paused || context.isStale ? "pause.fill" : "bolt.fill")
                    .foregroundStyle(context.state.paused || context.isStale ? .gray : mint)
                    .accessibilityLabel(context.state.paused || context.isStale ? "Monitoring paused" : "Monitoring live")
            } compactTrailing: {
                Text(context.state.paused || context.isStale ? "Paused" : "\(number(context.state.loadWatts))W")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel(context.state.paused || context.isStale ? "Monitoring paused" : "Load \(number(context.state.loadWatts)) watts")
            } minimal: {
                Image(systemName: context.state.paused || context.isStale ? "pause.fill" : "bolt.fill")
                    .foregroundStyle(context.state.paused || context.isStale ? .gray : mint)
            }.contentMargins(.horizontal, 20, for: .expanded)
                .contentMargins(.bottom, 14, for: .expanded)
                .keylineTint(mint)
        }
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
    private func stat(_ title: String, _ value: Double, _ unit: String, _ icon: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(mint)
            Text("\(number(value)) \(unit)").font(.headline.monospacedDigit())
        }.lineLimit(1).minimumScaleFactor(0.8)
    }
}
