import Foundation

nonisolated enum InverterError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

nonisolated struct IPv4: Equatable, Sendable {
    let value: UInt32
    init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw InverterError.message("Enter a private IPv4 address, such as 192.168.0.25.") }
        var result: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part), String(byte) == part else {
                throw InverterError.message("Invalid IPv4 address.")
            }
            result = (result << 8) | UInt32(byte)
        }
        value = result
    }
    init(value: UInt32) { self.value = value }
    var text: String { [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".") }
    var isPrivate: Bool {
        value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8
    }
}

nonisolated struct ScanScope: Sendable {
    let local: IPv4
    let prefix: Int
    let network: UInt32
    let broadcast: UInt32
    init(local: String, mask: String) throws {
        let ip = try IPv4(local)
        let subnet = try IPv4(mask).value
        let inverse = ~subnet
        guard ip.isPrivate, inverse & (inverse &+ 1) == 0 else {
            throw InverterError.message("Join a Wi-Fi network with a private IPv4 address.")
        }
        let length = max(24, subnet.nonzeroBitCount)
        guard length <= 30 else { throw InverterError.message("This Wi-Fi subnet has no addresses to scan.") }
        let boundedMask = UInt32.max << (32 - length)
        self.local = ip
        prefix = length
        network = ip.value & boundedMask
        broadcast = network | ~boundedMask
    }
    var label: String { "\(IPv4(value: network).text)/\(prefix)" }
    var hosts: [String] {
        ((network + 1)..<broadcast).filter { $0 != local.value }.map { IPv4(value: $0).text }
    }
    func containsPeer(_ text: String) -> Bool {
        guard let ip = try? IPv4(text) else { return false }
        return ip.value > network && ip.value < broadcast && ip != local
    }
    func isDiscoveryReply(_ data: Data, from host: String) -> Bool {
        guard containsPeer(host), let text = String(data: data, encoding: .ascii) else { return false }
        return ["rsp>server=1;", "rsp>server=2;"].contains(text.trimmingCharacters(in: .newlines))
    }
}

nonisolated enum ReadCommand: String, Sendable, CaseIterable {
    case protocolID = "QPI", firmware = "QVFW", ratings = "QPIRI"
    case status = "QPIGS", mode = "QMOD", warnings = "QPIWS", led = "QLED"
    case flags = "QFLAG", equalization = "QBEQI"
    case maxChargingChoices = "QMCHGCR", utilityChargingChoices = "QMUCHGCR"
    var label: String {
        switch self {
        case .protocolID: "Protocol"
        case .firmware: "Firmware"
        case .ratings: "Ratings"
        case .status: "Status"
        case .mode: "Mode"
        case .warnings: "Warnings"
        case .led: "LED settings"
        case .flags: "Flags"
        case .equalization: "Equalization"
        case .maxChargingChoices: "Charge currents"
        case .utilityChargingChoices: "AC charge currents"
        }
    }
}

nonisolated struct LEDColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ text: Substring) throws {
        let bytes = Array(text.utf8)
        guard bytes.count == 9, bytes.allSatisfy({ (48...57).contains($0) }),
              let red = UInt8(String(decoding: bytes[0..<3], as: UTF8.self)),
              let green = UInt8(String(decoding: bytes[3..<6], as: UTF8.self)),
              let blue = UInt8(String(decoding: bytes[6..<9], as: UTF8.self)) else {
            throw InverterError.message("Invalid inverter LED color response.")
        }
        self.init(red: red, green: green, blue: blue)
    }

    var protocolValue: String {
        String(format: "%03d%03d%03d", Int(red), Int(green), Int(blue))
    }
}

nonisolated struct LEDSettings: Equatable, Sendable {
    let enabled: Bool
    let speed: Int
    let effect: Int
    let brightness: Int
    let totalColors: Int
    let colors: [LEDColor]

    init(_ response: String) throws {
        let fields = response.split(whereSeparator: \.isWhitespace)
        guard fields.count == 7 || fields.count == 8,
              let enabled = Int(fields[0]), (0...1).contains(enabled),
              let speed = Int(fields[1]), (0...2).contains(speed),
              let effect = Int(fields[2]), (0...3).contains(effect),
              let brightness = Int(fields[3]), (0...9).contains(brightness),
              let totalColors = Int(fields[4]), (2...3).contains(totalColors),
              fields.count >= 5 + totalColors else {
            throw InverterError.message("Unsupported inverter LED settings response.")
        }
        self.enabled = enabled == 1
        self.speed = speed
        self.effect = effect
        self.brightness = brightness
        self.totalColors = totalColors
        colors = try fields.dropFirst(5).map(LEDColor.init)
    }

    func color(at slot: Int) throws -> LEDColor {
        guard (1...totalColors).contains(slot), colors.indices.contains(slot - 1) else {
            throw InverterError.message("This inverter does not support LED color \(slot).")
        }
        return colors[slot - 1]
    }
}

nonisolated enum PI30 {
    static func crc(_ data: Data) -> Data {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000 != 0) ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return Data([UInt8(crc >> 8), UInt8(crc & 255)].map { [10, 13, 40].contains($0) ? $0 + 1 : $0 })
    }
    static func request(_ command: ReadCommand) -> Data {
        let body = Data(command.rawValue.utf8)
        return body + crc(body) + Data([13])
    }
    static func ledColorRequest(slot: Int, color: LEDColor) throws -> Data {
        guard (1...3).contains(slot) else {
            throw InverterError.message("Invalid LED color slot.")
        }
        let body = Data("PLEDC\(slot)\(color.protocolValue)".utf8)
        return body + crc(body) + Data([13])
    }
    static func settingRequest(_ command: String) -> Data {
        let body = Data(command.utf8)
        return body + crc(body) + Data([13])
    }
    static func response(_ data: Data) throws -> String {
        let bytes = Array(data)
        guard bytes.count >= 4, bytes.first == 40, bytes.last == 13 else {
            throw InverterError.message("Invalid inverter response framing.")
        }
        let body = Data(bytes.dropLast(3))
        guard Data(bytes.suffix(3).prefix(2)) == crc(body) else {
            throw InverterError.message("Inverter checksum failed. Reading discarded.")
        }
        guard bytes.dropFirst().dropLast(3).allSatisfy({ (32...126).contains($0) }),
              let text = String(data: Data(bytes.dropFirst().dropLast(3)), encoding: .ascii) else {
            throw InverterError.message("Invalid inverter response text.")
        }
        guard !["NAK", "NOA", "ERCRC"].contains(text) else {
            throw InverterError.message("Inverter rejected the command: \(text).")
        }
        return text
    }
}

nonisolated struct TunnelFrame: Equatable, Sendable {
    let transaction: UInt16
    let code: UInt16
    let address: UInt8
    let function: UInt8
    let payload: Data
    var data: Data {
        var result = Data()
        for word in [transaction, code, UInt16(payload.count + 2)] {
            result.append(contentsOf: [UInt8(word >> 8), UInt8(word & 255)])
        }
        result.append(contentsOf: [address, function])
        result.append(payload)
        return result
    }
    func matches(transaction: UInt16, code: UInt16) throws -> Bool {
        if function == 1 { return false }
        guard function == 4 else { throw InverterError.message("Unexpected logger response.") }
        if self.transaction != transaction { return false }
        guard self.code == code, address == 1 else {
            throw InverterError.message("Logger response route does not match the request.")
        }
        return true
    }
}

nonisolated struct FrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [TunnelFrame] {
        buffer.append(data)
        guard buffer.count <= 8192 else { throw InverterError.message("Logger sent too much data.") }
        var frames: [TunnelFrame] = []
        while buffer.count >= 8 {
            let bytes = Array(buffer.prefix(8))
            func word(_ index: Int) -> UInt16 { UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]) }
            let size = Int(word(4)) + 6
            guard (8...4096).contains(size) else { throw InverterError.message("Invalid logger frame length.") }
            guard buffer.count >= size else { break }
            frames.append(TunnelFrame(transaction: word(0), code: word(2), address: bytes[6],
                                      function: bytes[7], payload: Data(buffer.dropFirst(8).prefix(size - 8))))
            buffer = Data(buffer.dropFirst(size))
        }
        return frames
    }
}

nonisolated struct LoggerDevice: Identifiable, Equatable, Sendable {
    let ip: String
    var id: String { ip }
}

nonisolated struct InverterMetadata: Sendable {
    let identity: String
    let firmware: String
    let ratedOutput: Double
    let ratedBattery: Double
    init(identity: String, firmware: String, ratings: String) throws {
        let parts = ratings.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 8, let power = Double(parts[6]), let battery = Double(parts[7]),
              power.isFinite, battery.isFinite, power > 0, battery > 0 else {
            throw InverterError.message("Invalid inverter ratings.")
        }
        self.identity = identity
        self.firmware = firmware
        ratedOutput = power
        ratedBattery = battery
    }
}

nonisolated struct ReadingSnapshot: Sendable {
    let time: Date
    let values: [String: Double]
    let mode: String
    let warningBits: String
    var hasWarning: Bool { warningBits.contains("1") }
    static let mapping: [(String, Int)] = [
        ("Grid voltage", 0), ("Grid frequency", 1), ("Output voltage", 2), ("Output frequency", 3),
        ("Apparent power", 4), ("Load power", 5), ("Load", 6), ("DC bus voltage", 7),
        ("Battery voltage", 8), ("Battery charge current", 9), ("Reported battery", 10),
        ("Temperature", 11), ("Reported PV current", 12), ("PV voltage", 13),
        ("Battery SCC voltage", 14), ("Battery discharge current", 15), ("PV charging power", 19)
    ]
    static let units = [
        "Grid voltage": "V", "Grid frequency": "Hz", "Output voltage": "V", "Output frequency": "Hz",
        "Apparent power": "VA", "Load power": "W", "Load": "%", "DC bus voltage": "V",
        "Battery voltage": "V", "Battery charge current": "A", "Reported battery": "%",
        "Temperature": "°C", "Reported PV current": "A", "PV voltage": "V",
        "Battery SCC voltage": "V", "Battery discharge current": "A", "PV charging power": "W"
    ]
    init(status: String, mode: String, warnings: String, time: Date = .now) throws {
        let fields = status.split(whereSeparator: \.isWhitespace)
        // shortcut: only the 24-field layout verified on this inverter; reject other firmware layouts.
        guard fields.count == 24 else { throw InverterError.message("Unsupported inverter status layout (\(fields.count) fields).") }
        for (index, width) in [(16, 8), (20, 3)] {
            guard fields[index].count == width, fields[index].allSatisfy({ $0 == "0" || $0 == "1" }) else {
                throw InverterError.message("Invalid inverter status bits.")
            }
        }
        guard !warnings.isEmpty, warnings.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            throw InverterError.message("Invalid warning bits.")
        }
        var values: [String: Double] = [:]
        for (name, index) in Self.mapping {
            guard let value = Double(fields[index]), value.isFinite else {
                throw InverterError.message("Invalid reading: \(name).")
            }
            values[name] = value
        }
        self.values = values
        self.time = time
        self.mode = ["P": "Starting", "S": "Standby", "L": "Grid", "B": "Battery",
                     "F": "Fault", "H": "Power saving", "D": "Shutdown"][mode] ?? "Unknown (\(mode))"
        warningBits = warnings
    }
}
