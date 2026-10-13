import Foundation

nonisolated enum SettingSection: String, CaseIterable, Sendable {
    case output = "Output"
    case battery = "Battery"
    case standard = "Standard"
    case lighting = "LED"
}

nonisolated struct SettingChoice: Sendable {
    let value: String
    let label: String
    init(_ value: String, _ label: String) { self.value = value; self.label = label }
}

nonisolated enum SettingSource: Sendable {
    case rating(Int), equalization(Int), flag(Character)
    case ledEnabled, ledSpeed, ledEffect, ledBrightness, ledCount, ledColor(Int)
}

nonisolated enum SettingInput: Sendable {
    case choices(prefix: String, width: Int, [SettingChoice])
    case currentChoices(prefix: String, utility: Bool)
    case integer(prefix: String, width: Int, min: Int, max: Int, step: Int)
    case decimal(prefix: String, min: Double, max: Double, places: Int)
    case flag(Character)
    case color(Int)
}

nonisolated struct InverterSettings: Sendable {
    let ratings: [String]
    let enabledFlags: Set<Character>
    let disabledFlags: Set<Character>
    let equalization: [String]
    let led: LEDSettings
    let maxChargingChoices: [Int]
    let utilityChargingChoices: [Int]

    init(ratings: String, flags: String, equalization: String, led: String,
         maxCharging: String, utilityCharging: String) throws {
        let ratingFields = ratings.split(whereSeparator: \.isWhitespace).map(String.init)
        let equalizationFields = equalization.split(whereSeparator: \.isWhitespace).map(String.init)
        guard ratingFields.count >= 25, equalizationFields.count == 10,
              flags.first == "E", let divider = flags.dropFirst().firstIndex(of: "D"),
              flags.filter({ $0 == "E" || $0 == "D" }).count == 2 else {
            throw InverterError.message("Unsupported inverter settings layout.")
        }
        let enabled = Set(flags[flags.index(after: flags.startIndex)..<divider])
        let disabled = Set(flags[flags.index(after: divider)...])
        guard enabled.isDisjoint(with: disabled),
              enabled.union(disabled).allSatisfy({ $0.isLetter && $0.isLowercase }) else {
            throw InverterError.message("Invalid inverter flag settings.")
        }
        func currentChoices(_ response: String) throws -> [Int] {
            let choices = response.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard !choices.isEmpty, choices.count == response.split(whereSeparator: \.isWhitespace).count,
                  choices.allSatisfy({ (0...999).contains($0) }) else {
                throw InverterError.message("Invalid inverter charging choices.")
            }
            return choices
        }
        self.ratings = ratingFields
        enabledFlags = enabled
        disabledFlags = disabled
        self.equalization = equalizationFields
        self.led = try LEDSettings(led)
        maxChargingChoices = try currentChoices(maxCharging)
        utilityChargingChoices = try currentChoices(utilityCharging)
    }

    func rawValue(for source: SettingSource) -> String? {
        switch source {
        case .rating(let index): return ratings.indices.contains(index) ? ratings[index] : nil
        case .equalization(let index): return equalization.indices.contains(index) ? equalization[index] : nil
        case .flag(let flag): return enabledFlags.contains(flag) ? "1" : (disabledFlags.contains(flag) ? "0" : nil)
        case .ledEnabled: return led.enabled ? "1" : "0"
        case .ledSpeed: return String(led.speed)
        case .ledEffect: return String(led.effect)
        case .ledBrightness: return String(led.brightness)
        case .ledCount: return String(led.totalColors)
        case .ledColor(let slot):
            guard let color = try? led.color(at: slot) else { return nil }
            return String(format: "%02X%02X%02X", color.red, color.green, color.blue)
        }
    }
}

nonisolated struct SettingDefinition: Identifiable, Sendable {
    let id: String
    let title: String
    let section: SettingSection
    let source: SettingSource
    let input: SettingInput

    var isBatteryCritical: Bool { section == .battery }

    func choices(in settings: InverterSettings) -> [SettingChoice]? {
        switch input {
        case .choices(_, _, let values): values
        case .currentChoices(_, let utility):
            (utility ? settings.utilityChargingChoices : settings.maxChargingChoices)
                .map { SettingChoice(String($0), "\($0) A") }
        case .flag: [SettingChoice("0", "Off"), SettingChoice("1", "On")]
        default: nil
        }
    }

    func command(for value: String, in settings: InverterSettings) throws -> String {
        guard settings.rawValue(for: source) != nil else {
            throw InverterError.message("This setting is not available on this inverter.")
        }
        switch input {
        case .choices(let prefix, let width, let options):
            guard options.contains(where: { $0.value == value }), let number = Int(value) else {
                throw InverterError.message("Choose a listed value for \(title).")
            }
            return prefix + String(format: "%0*d", width, number)
        case .currentChoices(let prefix, let utility):
            guard let number = Int(value),
                  (utility ? settings.utilityChargingChoices : settings.maxChargingChoices).contains(number) else {
                throw InverterError.message("Choose a current offered by the inverter.")
            }
            return prefix + String(format: "%03d", number)
        case .integer(let prefix, let width, let min, let max, let step):
            guard let number = Int(value), (min...max).contains(number), (number - min) % step == 0 else {
                throw InverterError.message("Enter \(min)–\(max) in steps of \(step) for \(title).")
            }
            return prefix + String(format: "%0*d", width, number)
        case .decimal(let prefix, let min, let max, let places):
            guard let number = Double(value), number.isFinite, number >= min, number <= max,
                  abs((number * pow(10, Double(places))).rounded() - number * pow(10, Double(places))) < 0.00001 else {
                throw InverterError.message("Enter \(min)–\(max) with up to \(places) decimal place(s) for \(title).")
            }
            return prefix + String(format: "%0*.*f", places == 1 ? 4 : 5, places, number)
        case .flag(let flag):
            guard value == "0" || value == "1" else { throw InverterError.message("Choose On or Off.") }
            return "P\(value == "1" ? "E" : "D")\(flag)"
        case .color(let slot):
            let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
            guard hex.count == 6, let number = UInt32(hex, radix: 16) else {
                throw InverterError.message("Enter a six-digit RGB color, such as #0000FF.")
            }
            let color = LEDColor(red: UInt8((number >> 16) & 255),
                                 green: UInt8((number >> 8) & 255), blue: UInt8(number & 255))
            return "PLEDC\(slot)\(color.protocolValue)"
        }
    }

    func verifies(_ requested: String, before: InverterSettings, after: InverterSettings) -> Bool {
        guard let actual = after.rawValue(for: source) else { return false }
        switch input {
        case .decimal:
            guard let a = Double(actual), let b = Double(requested) else { return false }
            return abs(a - b) < 0.001
        case .color:
            return actual.caseInsensitiveCompare(requested.replacingOccurrences(of: "#", with: "")) == .orderedSame
        default:
            return Double(actual) == Double(requested)
        }
    }

    static let all: [SettingDefinition] = {
        func choices(_ id: String, _ title: String, _ section: SettingSection, _ source: SettingSource,
                     _ prefix: String, _ width: Int, _ options: [SettingChoice]) -> SettingDefinition {
            .init(id: id, title: title, section: section, source: source,
                  input: .choices(prefix: prefix, width: width, options))
        }
        func decimal(_ id: String, _ title: String, _ source: SettingSource,
                     _ prefix: String, _ min: Double, _ max: Double, _ places: Int = 1) -> SettingDefinition {
            .init(id: id, title: title, section: .battery, source: source,
                  input: .decimal(prefix: prefix, min: min, max: max, places: places))
        }
        func integer(_ id: String, _ title: String, _ source: SettingSource,
                     _ prefix: String, _ width: Int, _ min: Int, _ max: Int, _ step: Int = 1) -> SettingDefinition {
            .init(id: id, title: title, section: .battery, source: source,
                  input: .integer(prefix: prefix, width: width, min: min, max: max, step: step))
        }
        func flag(_ letter: Character, _ title: String) -> SettingDefinition {
            .init(id: "flag_\(letter)", title: title, section: .standard,
                  source: .flag(letter), input: .flag(letter))
        }
        let offOn = [SettingChoice("0", "Off"), SettingChoice("1", "On")]
        return [
            choices("output_source", "Output source priority", .output, .rating(16), "POP", 2,
                    [.init("0", "Utility first"), .init("1", "Solar first"), .init("2", "Solar → battery → utility")]),
            choices("input_range", "AC input range", .output, .rating(15), "PGR", 2,
                    [.init("0", "Appliance"), .init("1", "UPS")]),
            choices("output_voltage", "Output voltage", .output, .rating(2), "V", 3,
                    [.init("220", "220 V"), .init("230", "230 V"), .init("240", "240 V")]),
            choices("output_frequency", "Output frequency", .output, .rating(3), "F", 2,
                    [.init("50", "50 Hz"), .init("60", "60 Hz")]),
            choices("battery_type", "Battery type", .battery, .rating(12), "PBT", 2,
                    [.init("0", "AGM"), .init("1", "Flooded"), .init("2", "User defined"),
                     .init("3", "Pylontech"), .init("4", "Shinheung"), .init("5", "Weco"),
                     .init("6", "Soltaro"), .init("7", "BAK"), .init("8", "Lib"), .init("9", "Lic")]),
            decimal("cutoff", "Battery cut-off voltage", .rating(9), "PSDV", 21, 24),
            decimal("bulk", "Bulk charging voltage", .rating(10), "PCVV", 25, 31.5),
            decimal("float", "Float charging voltage", .rating(11), "PBFT", 25, 31.5),
            .init(id: "max_charge", title: "Max charging current", section: .battery,
                  source: .rating(14), input: .currentChoices(prefix: "MNCHGC", utility: false)),
            .init(id: "max_ac_charge", title: "Max AC charging current", section: .battery,
                  source: .rating(13), input: .currentChoices(prefix: "MUCHGC", utility: true)),
            choices("charge_source", "Charging source priority", .battery, .rating(17), "PCP", 2,
                    [.init("1", "Solar first"), .init("2", "Solar + utility"), .init("3", "Solar only")]),
            decimal("back_to_grid", "Back to grid voltage", .rating(8), "PBCV", 21, 25.5),
            decimal("back_to_battery", "Back to battery voltage", .rating(22), "PBDV", 24, 29),
            choices("equalization", "Battery equalization", .battery, .equalization(0), "PBEQE", 1, offOn),
            choices("equalization_now", "Equalize now", .battery, .equalization(8), "PBEQA", 1, offOn),
            integer("equalization_time", "Equalization time (min)", .equalization(1), "PBEQT", 3, 5, 900, 5),
            integer("equalization_timeout", "Equalization timeout (min)", .equalization(7), "PBEQOT", 3, 5, 900, 5),
            integer("equalization_period", "Equalization period (days)", .equalization(2), "PBEQP", 3, 0, 90),
            decimal("equalization_voltage", "Equalization voltage", .equalization(5), "PBEQV", 25, 31.5, 2),
            flag("a", "Buzzer"), flag("b", "Overload bypass"), flag("d", "Solar feed to grid"),
            flag("j", "Power saving"), flag("k", "LCD auto-return"), flag("u", "Overload auto-restart"),
            flag("v", "Temperature auto-restart"), flag("x", "Backlight"),
            flag("y", "Primary-source alarm"), flag("z", "Fault code record"),
            choices("led_status", "LED status", .lighting, .ledEnabled, "PLEDE", 1, offOn),
            choices("led_speed", "LED speed", .lighting, .ledSpeed, "PLEDS", 1,
                    [.init("0", "Slow"), .init("1", "Medium"), .init("2", "Fast")]),
            choices("led_effect", "LED effect", .lighting, .ledEffect, "PLEDM", 1,
                    [.init("0", "Breathing"), .init("2", "Solid"), .init("3", "Scrolling")]),
            .init(id: "led_brightness", title: "LED brightness", section: .lighting,
                  source: .ledBrightness, input: .integer(prefix: "PLEDB", width: 1, min: 1, max: 9, step: 1)),
            choices("led_count", "LED color count", .lighting, .ledCount, "PLEDT", 1,
                    [.init("2", "Two"), .init("3", "Three")]),
            .init(id: "led_color_1", title: "LED color 1 · line", section: .lighting,
                  source: .ledColor(1), input: .color(1)),
            .init(id: "led_color_2", title: "LED color 2 · AVR", section: .lighting,
                  source: .ledColor(2), input: .color(2)),
            .init(id: "led_color_3", title: "LED color 3 · battery", section: .lighting,
                  source: .ledColor(3), input: .color(3))
        ]
    }()
}

nonisolated extension SettingDefinition {
    var unit: String? {
        switch input {
        case .decimal: "V"
        case .currentChoices: "A"
        case .integer:
            switch id {
            case "equalization_time", "equalization_timeout": "min"
            case "equalization_period": "days"
            default: nil
            }
        default: nil
        }
    }

    var inputHint: String? {
        switch input {
        case .integer(_, _, let min, let max, let step):
            "Range: \(min)–\(max)\(unit.map { " \($0)" } ?? ""). Step: \(step)."
        case .decimal(_, let min, let max, let places):
            "Range: \(String(format: "%g", min))–\(String(format: "%g", max)) V. Up to \(places) decimal place\(places == 1 ? "" : "s")."
        default: nil
        }
    }

    func displayValue(_ raw: String?, in settings: InverterSettings) -> String {
        guard let raw else {
            if case .ledColor(3) = source, settings.led.totalColors == 2 { return "Two-color mode" }
            return "Unavailable"
        }
        if case .color = input { return "#" + raw.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        if let selected = choices(in: settings)?.first(where: { Double($0.value) == Double(raw) }) { return selected.label }
        if case .decimal(_, _, _, let places) = input, let number = Double(raw), number.isFinite {
            return String(format: "%.*f V", places, number)
        }
        if case .integer = input, let number = Int(raw) {
            if id == "led_brightness" { return (1...9).contains(number) ? "\(number) / 9" : "Reported: \(number)" }
            return String(number) + (unit.map { " \($0)" } ?? "")
        }
        return raw
    }
}
