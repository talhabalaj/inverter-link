import SwiftUI

@main struct InverterLinkApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    private var testing: Bool { ProcessInfo.processInfo.environment["INVERTER_LINK_TESTING"] == "1" }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .task { if !testing { model.startOnLaunch() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.background() }
                    if phase == .active && !testing && (model.dashboardPresented || model.isConnected) { model.resume() }
                }
        }
    }
}

enum Palette {
    static let background = Color(red: 0.055, green: 0.064, blue: 0.064)
    static let card = Color(red: 0.12, green: 0.135, blue: 0.13)
    static let mint = Color(red: 0.27, green: 0.89, blue: 0.66)
    static let secondary = Color(red: 0.59, green: 0.64, blue: 0.62)
    static let border = Color.white.opacity(0.075)
}

struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack {
                DevicesView(model: model)
                    .navigationDestination(isPresented: $model.dashboardPresented) {
                        Dashboard(model: model).toolbar(.hidden, for: .tabBar)
                    }
            }.tabItem { Label("Devices", systemImage: "wifi") }.tag(0)
            NavigationStack { SettingsView(model: model) }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(1)
        }.tint(model.accentColor.color).environment(\.inverterAccent, model.accentColor.color)
            .toolbarBackground(Palette.background, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

struct Dashboard: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var settingsPresented = false
    @State private var diagnosticsPresented = false
    @State private var renamePresented = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill").font(.system(size: 16, weight: .medium)).foregroundStyle(accent)
                    Text(inverterTitle).font(.subheadline.weight(.medium))
                    Spacer()
                    if model.isConnected {
                        VStack(alignment: .trailing, spacing: 3) {
                            HStack(spacing: 5) {
                                Circle().fill(accent).frame(width: 5, height: 5)
                                Text(model.isSettingsPreview ? "Preview" : model.connectionLabel)
                            }.font(.caption).foregroundStyle(Palette.secondary)
                            if let reading = model.snapshot {
                                Text(reading.time.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(Palette.secondary)
                            }
                        }.accessibilityElement(children: .ignore)
                            .accessibilityLabel(model.isSettingsPreview ? "Preview data" : "Live, \(model.connectionLabel)")
                            .accessibilityValue(model.snapshot.map { "Updated " + $0.time.formatted(date: .omitted, time: .standard) } ?? "")
                    } else {
                        Button(model.busy ? "\(model.connectionLabel)…" : "Connect") {
                            if model.saved != nil { model.resume() } else { model.dashboardPresented = false }
                        }.font(.caption.weight(.semibold)).buttonStyle(.bordered)
                            .controlSize(.small).tint(accent)
                            .frame(minHeight: 44).disabled(model.busy)
                            .accessibilityIdentifier("dashboardConnect")
                    }
                }.padding(.horizontal, 16).padding(.vertical, model.isConnected ? 14 : 6)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.border))

                SolarSceneView(reading: model.snapshot, isActive: visible && scenePhase == .active).frame(height: 290)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityHint("Drag horizontally to rotate.")

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        MetricCard(title: "Solar", icon: "sun.max", value: value("PV charging power"), unit: "W")
                        MetricCard(title: "Load", icon: "bolt", value: value("Load power"), unit: "W", percentage: model.snapshot?.values["Load"])
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { smallMetrics }
                        VStack(spacing: 10) { smallMetrics }
                    }
                }
                if let reading = model.snapshot {
                    if reading.hasWarning {
                        Label("Inverter warning", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("Details") {
                    VStack(spacing: 14) {
                        Button { settingsPresented = true } label: {
                            HStack { Label("Inverter settings", systemImage: "slider.horizontal.3"); Spacer(); Image(systemName: "chevron.right") }
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("inverterSettingsButton")
                        Button { diagnosticsPresented = true } label: {
                            HStack { Label("Diagnostics", systemImage: "terminal"); Spacer(); Image(systemName: "chevron.right") }
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("diagnosticsButton")
                        if let reading = model.snapshot {
                            Divider()
                            ForEach(ReadingSnapshot.mapping, id: \.0) { name, _ in
                                HStack {
                                    Text(name).foregroundStyle(Palette.secondary)
                                    Spacer()
                                    Text("\(value(name)) \(ReadingSnapshot.units[name] ?? "")").monospacedDigit()
                                }.font(.subheadline)
                            }
                            if reading.hasWarning { Text(reading.warningBits).font(.caption.monospaced()).foregroundStyle(.orange) }
                        }
                    }.padding(.top, 14)
                }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))

                if let error = model.errorMessage { ErrorNotice(message: error) }
            }.padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Palette.background)
            .navigationTitle(model.saved?.displayName ?? "Inverter").navigationBarTitleDisplayMode(.inline)
            .onAppear { visible = true }.onDisappear { visible = false }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if model.saved != nil { Button("Rename", systemImage: "pencil") { renamePresented = true } }
                        Button("Disconnect", systemImage: "wifi.slash") { model.stop() }.disabled(!model.busy)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Device actions")
                }
            }
            .sheet(isPresented: $settingsPresented) { InverterSettingsView(model: model) }
            .sheet(isPresented: $diagnosticsPresented) { CommandsView(model: model) }
            .sheet(isPresented: $renamePresented) {
                if let saved = model.saved { RenameDeviceSheet(model: model, inverter: saved) }
            }
    }
    private var inverterTitle: String {
        guard let watts = model.metadata?.ratedOutput else { return "Inverter" }
        return "\((watts / 1000).formatted(.number.precision(.fractionLength(0...1)))) kW inverter"
    }
    @ViewBuilder private var smallMetrics: some View {
        MetricCard(title: "Battery", icon: "battery.100percent", value: value("Reported battery"), unit: "%", compact: true)
        MetricCard(title: "Grid", icon: "bolt.horizontal", value: value("Grid voltage"), unit: "V", compact: true)
        MetricCard(title: "Temp", icon: "thermometer.medium", value: value("Temperature"), unit: "°C", compact: true)
    }
    private func value(_ key: String) -> String {
        model.snapshot?.values[key]?.formatted(.number.precision(.fractionLength(0...1))) ?? "—"
    }
}

struct MetricCard: View {
    @Environment(\.inverterAccent) private var accent
    let title: String
    let icon: String
    let value: String
    let unit: String
    var compact = false
    var percentage: Double?
    @ScaledMetric(relativeTo: .title) private var largeSize = 30.0
    @ScaledMetric(relativeTo: .title2) private var smallSize = 21.0
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 14) {
            Label(title, systemImage: icon).font(compact ? .caption : .subheadline).foregroundStyle(accent)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: compact ? smallSize : largeSize, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.caption).foregroundStyle(Palette.secondary).fixedSize()
                if let percentage {
                    Spacer(minLength: 0)
                    Text("\(percentage.formatted(.number.precision(.fractionLength(0))))%")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(accent).fixedSize()
                }
            }
            if !compact {
                ZStack {
                    if let percentage {
                        GeometryReader { geometry in
                            Capsule().fill(accent.opacity(0.12))
                            Capsule().fill(LinearGradient(colors: [accent.opacity(0.45), accent], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geometry.size.width * min(100, max(0, percentage)) / 100)
                        }
                    }
                }.frame(height: 4).padding(.top, -4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 14 : 18)
            .background(Palette.card.opacity(compact ? 0.45 : 0.8), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value == "—" ? "offline" : value + " " + unit)\(percentage.map { ", " + $0.formatted(.number.precision(.fractionLength(0))) + " percent" } ?? "")")
    }
}

struct DevicesView: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    @State private var addressPresented = false
    @State private var renaming: SavedInverter?
    private var connected: SavedInverter? { model.isConnected ? model.saved : nil }
    private var savedDevices: [SavedInverter] { model.remembered.filter { $0.id != connected?.id } }
    private var discovered: [LoggerDevice] {
        model.devices.filter { device in !model.remembered.contains { $0.lastIP == device.ip } }
    }
    var body: some View {
        List {
            if model.isScanning {
                Section {
                    ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1)))
                    Text("\(model.scanned) / \(model.total)").font(.caption.monospaced()).foregroundStyle(Palette.secondary)
                }
            } else if case .connecting = model.phase {
                Section { HStack { ProgressView(); Text("Connecting…") } }
            }
            if let connected {
                Section("Connected") { deviceRow(connected, connected: true) }
            }
            if !savedDevices.isEmpty {
                Section("Saved") { ForEach(savedDevices) { device in deviceRow(device, connected: false) } }
            }
            Section {
                ForEach(discovered) { device in
                    Button { model.connect(to: device.ip) } label: {
                        HStack {
                            Image(systemName: "bolt").foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Inverter").foregroundStyle(.primary)
                                Text(device.ip).font(.caption.monospaced()).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
                        }.frame(minHeight: 40).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isScanning)
                }
                if discovered.isEmpty { Text(model.isScanning ? "Searching…" : "Scan to find devices").foregroundStyle(Palette.secondary) }
            } header: { Text("Discovered") } footer: { Text("Local mode may pause Energy Mate.") }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }.listStyle(.insetGrouped).contentMargins(.horizontal, 16, for: .scrollContent).listSectionSpacing(18).scrollContentBackground(.hidden).background(Palette.background)
            .safeAreaInset(edge: .bottom) {
                if model.isSettingsPreview { Text("Preview data").font(.caption2).foregroundStyle(Palette.secondary).padding(4) }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Scan", systemImage: model.isScanning ? "xmark" : "dot.radiowaves.left.and.right") {
                        if model.isScanning { model.cancelScan() } else { model.scan() }
                    }.accessibilityIdentifier("scanButton")
                    Button("Connect IP", systemImage: "plus") { addressPresented = true }
                        .accessibilityIdentifier("connectIPButton").disabled(model.isScanning)
                }
            }
            .sheet(isPresented: $addressPresented) { ConnectAddressSheet(model: model) }
            .sheet(item: $renaming) { inverter in RenameDeviceSheet(model: model, inverter: inverter) }
    }
    private func deviceRow(_ device: SavedInverter, connected: Bool) -> some View {
        Button { model.open(device) } label: {
            HStack(spacing: 12) {
                Image(systemName: connected ? "wifi" : "bolt").foregroundStyle(connected ? accent : Palette.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName).foregroundStyle(.primary)
                    Text(device.hostname ?? device.lastIP).font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if device.id == model.defaultInverterID { Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.secondary).accessibilityLabel("Default inverter") }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
            }.frame(minHeight: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .accessibilityIdentifier("savedDevice_\(device.lastIP)")
            .contextMenu {
                Button("Rename", systemImage: "pencil") { renaming = device }
                Button("Set as default", systemImage: "star") { model.defaultInverterID = device.id }
                Button("Forget", systemImage: "trash", role: .destructive) { model.forget(device) }
            }
    }
}

struct RenameDeviceSheet: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    let inverter: SavedInverter
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    init(model: AppModel, inverter: SavedInverter) {
        self.model = model; self.inverter = inverter; _name = State(initialValue: inverter.displayName)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Device name", text: $name).submitLabel(.done).onSubmit(save)
                if let error { Text(error).foregroundStyle(.orange) }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Device name").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", systemImage: "checkmark", action: save) }
                }
        }.tint(accent).presentationDetents([.medium])
    }
    private func save() {
        do { try model.rename(inverter, to: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct ConnectAddressSheet: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressFocused: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Hostname or IP", text: $model.target)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($addressFocused).padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Hostname or IP").accessibilityIdentifier("inverterAddress")
                    .submitLabel(.go).onSubmit { connect() }
                Button("Connect", action: connect)
                    .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderedProminent)
                    .foregroundStyle(Palette.background)
                    .disabled(model.isScanning || model.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }.padding(22).background(Palette.background)
                .navigationTitle("Connect IP").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
                .task { addressFocused = true }
        }.tint(accent).preferredColorScheme(.dark)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func connect() {
        guard !model.isScanning, !model.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addressFocused = false
        dismiss()
        model.connect(to: model.target)
    }
}

struct SettingsView: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    var body: some View {
        List {
            Section {
                HStack {
                    Label("Refresh interval", systemImage: "arrow.clockwise")
                    Spacer()
                    Picker("Refresh interval", selection: $model.refreshSeconds) {
                        ForEach(AppModel.refreshChoices, id: \.self) { seconds in Text("\(seconds)s").tag(seconds) }
                    }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("refreshInterval")
                }
                Toggle("Live Activity", isOn: $model.liveActivityEnabled).accessibilityIdentifier("liveActivityToggle")
            } footer: { Text("Pauses while iOS suspends the app.") }
            Section("Appearance") {
                Picker("Accent color", selection: $model.accentColor) {
                    ForEach(AppAccent.allCases, id: \.self) { choice in Text(choice.label).tag(choice) }
                }.id(model.accentColor).accessibilityIdentifier("accentColor")
            }
            Section("Launch") {
                Toggle("Open default inverter", isOn: $model.openDefaultInverter)
                    .disabled(model.remembered.isEmpty).accessibilityIdentifier("openDefaultInverter")
                if !model.remembered.isEmpty {
                    Picker("Default inverter", selection: $model.defaultInverterID) {
                        ForEach(model.remembered) { inverter in Text(inverter.displayName).tag(inverter.id) }
                    }.id(model.accentColor).accessibilityIdentifier("defaultInverter")
                }
            }
        }.listStyle(.insetGrouped).contentMargins(.horizontal, 16, for: .scrollContent).listSectionSpacing(18).scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Settings").tint(accent)
    }
}

struct CommandsView: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.isConnected ? "Local diagnostic queries" : "Connect your inverter first.")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ReadCommand.allCases, id: \.self) { command in
                            Button(command.label) { model.runCommand(command) }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .buttonStyle(.bordered).disabled(!model.isConnected || model.commandBusy)
                        }
                    }
                    if model.commandBusy { ProgressView("Reading…") }
                    if !model.commandResult.isEmpty {
                        Text(model.commandTitle).font(.headline)
                        Text(model.commandResult).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if let error = model.errorMessage { ErrorNotice(message: error) }
                }.padding(22)
            }.background(Palette.background)
                .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
        }.tint(accent).preferredColorScheme(.dark)
    }
}

struct ErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}
