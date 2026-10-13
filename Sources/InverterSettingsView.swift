import SwiftUI

struct InverterSettingsView: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SettingDefinition?
    @State private var section = SettingSection.output
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isConnected {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi")
                            Text(model.isSettingsPreview ? "Preview · sample values" : "Connected locally")
                            Spacer()
                            if model.settingsBusy { ProgressView().controlSize(.small) }
                        }.font(.caption.weight(.medium)).foregroundStyle(accent)
                    }
                    if model.inverterSettings != nil {
                        if typeSize.isAccessibilitySize {
                            Picker("Category", selection: $section) { categories }.pickerStyle(.menu)
                        } else {
                            Picker("Category", selection: $section) { categories }.pickerStyle(.segmented)
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
                List {
                    if let message = model.settingsMessage {
                        Section {
                            SettingsNotice(message: message, symbol: model.settingsMessageIsError ? "exclamationmark.circle" : "checkmark.circle.fill",
                                           color: model.settingsMessageIsError ? .orange : accent)
                        }
                    }
                    if model.settingsBusy {
                        Section { Text(model.settingsActivity).font(.subheadline).foregroundStyle(Palette.secondary) }
                    }
                    if let settings = model.inverterSettings {
                        Section {
                            ForEach(definitions) { setting in settingRow(setting, settings: settings) }
                        }
                    } else if !model.settingsBusy {
                        ContentUnavailableView(model.isConnected ? "Settings not loaded" : "Inverter offline",
                                               systemImage: model.isConnected ? "slider.horizontal.3" : "wifi.slash")
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped).contentMargins(.top, 8, for: .scrollContent).contentMargins(.horizontal, 16, for: .scrollContent).scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)

            }
            .background(Palette.background)
            .navigationTitle("Inverter settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.loadSettings() }
                        .disabled(!model.isConnected || model.settingsBusy || model.commandBusy || model.isSettingsPreview)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
            .navigationDestination(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let setting = editing, let settings = model.inverterSettings, let current = settings.rawValue(for: setting.source) {
                    SettingEditor(model: model, setting: setting, settings: settings, current: current)
                }
            }
            .task { if model.isConnected && model.inverterSettings == nil { model.loadSettings() } }
            .onChange(of: model.isConnected) { _, connected in
                if connected && model.inverterSettings == nil { model.loadSettings() }
                if !connected { editing = nil }
            }
        }.tint(accent).preferredColorScheme(.dark)
    }

    private var definitions: [SettingDefinition] { SettingDefinition.all.filter { $0.section == section } }
    private var categories: some View {
        ForEach(SettingSection.allCases, id: \.self) { category in
            Text(category == .standard ? "General" : category.rawValue).tag(category)
        }
    }
    private func settingRow(_ setting: SettingDefinition, settings: InverterSettings) -> some View {
        let raw = settings.rawValue(for: setting.source)
        return Button { editing = setting } label: {
            HStack(spacing: 12) {
                Text(setting.title).font(.body).foregroundStyle(raw == nil ? Palette.secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if case .color = setting.input, let raw, let color = SettingsColor.color(raw) {
                    Circle().fill(color).frame(width: 16, height: 16).overlay(Circle().stroke(.white.opacity(0.3)))
                }
                Text(setting.displayValue(raw, in: settings)).font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                Image(systemName: raw == nil ? "minus.circle" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
            }.frame(minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).listRowBackground(Palette.card)
        .disabled(!model.isConnected || model.settingsBusy || model.commandBusy || raw == nil)
        .accessibilityIdentifier("setting_\(setting.id)")
        .accessibilityLabel(setting.title)
        .accessibilityValue(setting.displayValue(raw, in: settings))
    }
}

private struct SettingEditor: View {
    @Environment(\.inverterAccent) private var accent
    @Bindable var model: AppModel
    let setting: SettingDefinition
    let settings: InverterSettings
    let current: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var confirm = false

    init(model: AppModel, setting: SettingDefinition, settings: InverterSettings, current: String) {
        self.model = model; self.setting = setting; self.settings = settings; self.current = current
        let selected = setting.choices(in: settings)?.first { Double($0.value) == Double(current) }
        _draft = State(initialValue: selected?.value ?? current)
    }

    private var validationError: String? {
        do { _ = try setting.command(for: draft, in: settings); return nil }
        catch { return error.localizedDescription }
    }
    private var unchanged: Bool { setting.verifies(draft, before: settings, after: settings) }
    private var canReview: Bool { model.isConnected && !model.settingsBusy && !model.commandBusy && !unchanged && validationError == nil }

    var body: some View {
            Form {
                if case .color = setting.input { colorControls }
                else if let choices = setting.choices(in: settings) { choiceControls(choices) }
                else { numberControls }
                if setting.isBatteryCritical {
                    Section {
                        SettingsNotice(message: "Use your battery manufacturer’s values.",
                                       symbol: "battery.100percent", color: .orange)
                    }
                }
                if let validationError {
                    Section { SettingsNotice(message: validationError, symbol: "exclamationmark.circle", color: .orange) }
                }

            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .navigationTitle(setting.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { confirm = true }.disabled(!canReview)
                        .accessibilityIdentifier("reviewSettingChange")
                }
            }
            .sheet(isPresented: $confirm) {
                SettingReview(setting: setting, settings: settings, current: current, draft: draft,
                              canApply: canReview) {
                    guard canReview else { return }
                    confirm = false
                    model.writeSetting(setting, value: draft)
                    dismiss()
                }
            }
            .onChange(of: draft) { _, _ in confirm = false }
        .tint(accent).preferredColorScheme(.dark)
    }

    private func choiceControls(_ choices: [SettingChoice]) -> some View {
        Section {
            Picker("New value", selection: $draft) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value).accessibilityIdentifier("choice_\(choice.value)")
                }
            }.pickerStyle(.inline)
        }
    }

    private var numberControls: some View {
        Section {
            HStack {
                TextField("New value", text: $draft)
                    .keyboardType(.decimalPad).font(.title2.monospacedDigit())
                    .accessibilityIdentifier("settingValueInput")
                if let unit = setting.unit { Text(unit).foregroundStyle(Palette.secondary) }
            }
            if case .integer(_, _, let min, let max, let step) = setting.input {
                Stepper("Adjust value", value: Binding(get: { Int(draft) ?? min }, set: { draft = String($0) }), in: min...max, step: step)
                    .accessibilityIdentifier("settingValueStepper")
            }
        } header: { Text("New value") } footer: {
            if let hint = setting.inputHint { Text(hint) }
        }
    }

    private var colorControls: some View {
        Section {
            RoundedRectangle(cornerRadius: 18).fill(SettingsColor.color(draft) ?? Palette.card)
                .frame(height: 60).overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.border))
                .accessibilityLabel("New color preview").accessibilityValue(draft)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                ForEach(SettingsColor.presets, id: \.hex) { preset in
                    Button { draft = preset.hex } label: {
                        Circle().fill(SettingsColor.color(preset.hex) ?? .clear)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(.white.opacity(0.3)))
                            .padding(5)
                            .overlay(Circle().stroke(SettingsColor.normalized(draft) == preset.hex ? accent : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).frame(minWidth: 48, minHeight: 48)
                        .accessibilityLabel(preset.name).accessibilityIdentifier("color_\(preset.hex)")
                        .accessibilityAddTraits(SettingsColor.normalized(draft) == preset.hex ? .isSelected : [])
                }
            }
            HStack {
                Text("Hex color").foregroundStyle(Palette.secondary)
                Text("#").foregroundStyle(Palette.secondary)
                TextField("0000FF", text: $draft)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .font(.title3.monospaced()).accessibilityLabel("Hex color").accessibilityIdentifier("settingValueInput")
            }
        }
    }

}

private struct SettingReview: View {
    @Environment(\.inverterAccent) private var accent
    let setting: SettingDefinition
    let settings: InverterSettings
    let current: String
    let draft: String
    let canApply: Bool
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(setting.title) {
                    LabeledContent("Current") { value(current) }
                    LabeledContent("New") { value(draft) }
                }
                Section {
                    Text(setting.isBatteryCritical ? "Use your battery manufacturer’s values. This takes effect immediately." : "This takes effect immediately.")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }.listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Review change").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button("Apply change", action: apply).font(.headline).buttonStyle(.borderedProminent)
                        .controlSize(.large).disabled(!canApply).accessibilityIdentifier("applySettingChange")
                        .frame(maxWidth: .infinity).padding(16).background(Palette.background)
                }
        }.tint(accent).preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }
    private func value(_ raw: String) -> some View {
        HStack(spacing: 8) {
            if case .color = setting.input, let color = SettingsColor.color(raw) {
                Circle().fill(color).frame(width: 18, height: 18).overlay(Circle().stroke(.white.opacity(0.3)))
            }
            Text(setting.displayValue(raw, in: settings)).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

private struct SettingsNotice: View {
    let message: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

private enum SettingsColor {
    struct Preset { let name: String; let hex: String }
    static let presets = [Preset(name: "Blue", hex: "0000FF"), Preset(name: "Cyan", hex: "00FFFF"),
                          Preset(name: "Green", hex: "00FF00"), Preset(name: "Yellow", hex: "FFFF00"),
                          Preset(name: "Orange", hex: "FF8000"), Preset(name: "Red", hex: "FF0000"),
                          Preset(name: "Purple", hex: "9400FF"), Preset(name: "White", hex: "FFFFFF")]
    static func normalized(_ hex: String) -> String { hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased() }
    static func color(_ hex: String) -> Color? {
        let hex = normalized(hex)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

