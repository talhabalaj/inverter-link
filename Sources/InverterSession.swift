import Foundation

final class InverterSession {
    private let channel: TCPChannel
    private var transaction: UInt16 = 0
    private var code: UInt16 = 0
    private var lastHeartbeat: TimeInterval = 0
    private(set) var metadata: InverterMetadata?

    init(channel: TCPChannel) { self.channel = channel }
    static func connect(ip: String, local: String) async throws -> InverterSession {
        guard try IPv4(ip).isPrivate, try IPv4(local).isPrivate, ip != local else {
            throw InverterError.message("Choose a logger's private IPv4 address, not this phone's address.")
        }
        let server = try CallbackServer(local: local)
        defer { server.close() }
        try await server.start()
        server.expect(ip)
        let port = server.port
        let announcement = Task {
            for _ in 0..<4 {
                if Task.isCancelled { return }
                _ = await UDPProbe().run(host: ip, local: local, port: port)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        defer { announcement.cancel() }
        let connection = try await server.accept()
        let channel = TCPChannel(connection)
        do {
            try await channel.start()
            let session = InverterSession(channel: channel)
            try await session.identify()
            return session
        } catch { channel.close(); throw error }
    }
    private func send(code: UInt16, function: UInt8, payload: Data) async throws -> UInt16 {
        transaction = transaction == .max ? 1 : transaction + 1
        let id = transaction
        try await channel.send(TunnelFrame(transaction: id, code: code, address: 1, function: function, payload: payload))
        return id
    }
    private func heartbeat() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: .now)
        let year = (parts.year ?? 2000) - 2000
        guard (0...255).contains(year) else { throw InverterError.message("The phone's date is out of range.") }
        let bytes = [year, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0].map(UInt8.init)
        _ = try await send(code: 0, function: 1, payload: Data(bytes + [0, 60]))
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
    }
    func identify() async throws {
        try await heartbeat()
        let frame = try await channel.nextFrame(seconds: 5)
        var bytes = Array(frame.payload)
        while bytes.last == 0 || bytes.last == 32 { bytes.removeLast() }
        // The collector identity uses address 255; inverter query replies use address 1.
        guard frame.function == 1, frame.address == 255, frame.transaction == transaction, frame.code != 0,
              (1...64).contains(bytes.count), bytes.allSatisfy({ (32...126).contains($0) }),
              let identity = String(bytes: bytes, encoding: .ascii) else {
            throw InverterError.message("This device did not return a valid Eybond logger identity.")
        }
        code = frame.code
        guard try await query(.protocolID) == "PI30" else {
            throw InverterError.message("This inverter uses a different protocol. Only the verified PI30 model is supported.")
        }
        let firmware = try await query(.firmware)
        let ratings = try await query(.ratings)
        metadata = try InverterMetadata(identity: identity, firmware: firmware, ratings: ratings)
    }
    func query(_ command: ReadCommand) async throws -> String {
        try await exchange(PI30.request(command))
    }
    private func exchange(_ payload: Data) async throws -> String {
        if ProcessInfo.processInfo.systemUptime - lastHeartbeat >= 45 { try await heartbeat() }
        let id = try await send(code: code, function: 4, payload: payload)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw InverterError.message("The inverter response timed out.") }
            let frame = try await channel.nextFrame(seconds: remaining)
            if try frame.matches(transaction: id, code: code) { return try PI30.response(frame.payload) }
        }
    }
    func readLEDSettings() async throws -> LEDSettings {
        let response = try await query(.led)
        return try LEDSettings(response)
    }
    func setLEDColor(slot: Int, color: LEDColor) async throws -> LEDSettings {
        let before = try await readLEDSettings()
        _ = try before.color(at: slot)
        let reply = try await exchange(PI30.ledColorRequest(slot: slot, color: color))
        guard reply == "ACK" else { throw InverterError.message("The inverter did not acknowledge the LED color change.") }
        let after = try await readLEDSettings()
        guard try after.color(at: slot) == color else {
            throw InverterError.message("The inverter acknowledged the color change, but readback did not match.")
        }
        return after
    }
    func readSettings() async throws -> InverterSettings {
        let ratings = try await query(.ratings)
        let flags = try await query(.flags)
        let equalization = try await query(.equalization)
        let led = try await query(.led)
        let maxCharging = try await query(.maxChargingChoices)
        let utilityCharging = try await query(.utilityChargingChoices)
        return try InverterSettings(ratings: ratings, flags: flags, equalization: equalization,
                                    led: led, maxCharging: maxCharging, utilityCharging: utilityCharging)
    }
    func applySetting(_ setting: SettingDefinition, value: String) async throws -> InverterSettings {
        let before = try await readSettings()
        let command = try setting.command(for: value, in: before)
        let reply = try await exchange(PI30.settingRequest(command))
        guard reply == "ACK" else { throw InverterError.message("The inverter did not acknowledge \(setting.title).") }
        let after = try await readSettings()
        guard setting.verifies(value, before: before, after: after) else {
            throw InverterError.message("The inverter acknowledged \(setting.title), but readback did not match. Check its display before retrying.")
        }
        return after
    }
    func read() async throws -> ReadingSnapshot {
        let status = try await query(.status)
        let mode = try await query(.mode)
        let warnings = try await query(.warnings)
        return try ReadingSnapshot(status: status, mode: mode, warnings: warnings)
    }
    func waitForNextRead(seconds: Double, interrupted: () -> Bool = { false }) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline && !interrupted() {
            try channel.checkFailure()
            let untilHeartbeat = 45 - (ProcessInfo.processInfo.systemUptime - lastHeartbeat)
            if untilHeartbeat <= 0 { try await heartbeat() }
            else {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .seconds(min(0.25, min(remaining, untilHeartbeat))))
            }
        }
    }
    func close() { channel.close() }
}
