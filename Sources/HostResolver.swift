import Darwin
import Foundation

nonisolated enum HostResolver {
    static func validate(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let ip = try? IPv4(text) {
            guard ip.isPrivate else { throw InverterError.message("Use an address on your local network.") }
            return ip.text
        }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.count <= 253, !text.isEmpty,
              !text.allSatisfy({ $0.isNumber || $0 == "." }),
              labels.allSatisfy({ label in
                  (1...63).contains(label.count) && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
              }) else { throw InverterError.message("Enter a hostname or private IPv4 address.") }
        return text
    }
    @concurrent static func resolve(_ input: String) async throws -> String {
        let host = try validate(input)
        if let ip = try? IPv4(host) { return ip.text }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { throw InverterError.message("Couldn't find \(host).") }
        defer { freeaddrinfo(first) }
        try Task.checkCancellation()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr, address.pointee.sa_family == AF_INET else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
            let ip = IPv4(value: value)
            if ip.isPrivate { return ip.text }
        }
        throw InverterError.message("That hostname doesn't resolve to a local address.")
    }
    @concurrent static func reverse(_ ip: String) async -> String? {
        guard let value = try? IPv4(ip), value.isPrivate else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = value.value.bigEndian
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &name, socklen_t(name.count), nil, 0, NI_NAMEREQD)
            }
        }
        let text = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard status == 0, !Task.isCancelled,
              let host = try? validate(text), (try? IPv4(host)) == nil else { return nil }
        return host
    }
}

nonisolated struct SavedInverter: Codable, Equatable, Identifiable, Sendable {
    let identity: String
    var hostname: String?
    var lastIP: String
    var name: String? = nil
    var id: String { identity }
    var displayName: String { name ?? "Inverter" }
    var targets: [String] { hostname.map { [$0, lastIP] } ?? [lastIP] }
}

nonisolated struct LiveEnergyState: Equatable, Sendable {
    enum BatteryFlow { case idle, charging, discharging }
    let connected: Bool
    let solarActive: Bool
    let gridActive: Bool
    let loadActive: Bool
    let batteryFlow: BatteryFlow
    let batteryLevel: Float
    init(_ reading: ReadingSnapshot?) {
        connected = reading != nil
        let values = reading?.values ?? [:]
        solarActive = (values["PV charging power"] ?? 0) > 0
        gridActive = reading?.mode == "Grid" && (values["Grid voltage"] ?? 0) > 0
        loadActive = (values["Load power"] ?? 0) > 0
        let current = (values["Battery charge current"] ?? 0) - (values["Battery discharge current"] ?? 0)
        batteryFlow = current > 0 ? .charging : current < 0 ? .discharging : .idle
        batteryLevel = Float(min(100, max(0, values["Reported battery"] ?? 0)) / 100)
    }
}
