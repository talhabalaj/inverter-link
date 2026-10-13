import Foundation
import Observation
import UIKit

@Observable final class AppModel {
    enum Phase: Equatable { case idle, scanning, connecting(String), connected(String) }
    var phase = Phase.idle
    var devices: [LoggerDevice] = []
    var snapshot: ReadingSnapshot?
    var metadata: InverterMetadata?
    var saved: SavedInverter?
    var remembered: [SavedInverter] = []
    var dashboardPresented = false
    var accentColor = AppAccent.mint { didSet { defaults.set(accentColor.rawValue, forKey: "accentColor") } }
    var openDefaultInverter = false { didSet { defaults.set(openDefaultInverter, forKey: "openDefaultInverter") } }
    var defaultInverterID = "" { didSet { defaults.set(defaultInverterID, forKey: "defaultInverterID") } }
    var defaultInverter: SavedInverter? { remembered.first { $0.id == defaultInverterID } }
    var isScanning = false
    private var scanOperation: Task<Void, Never>?
    private var scanGeneration = UUID()
    var scanned = 0
    var total = 0
    var errorMessage: String?
    var selectedTab = 0
    var target = ""
    static let refreshChoices = [5, 10, 15, 30, 60]
    var refreshSeconds = 5 {
        didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    var liveActivityEnabled = false {
        didSet {
            defaults.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if liveActivityEnabled { updateLiveActivity() } else { liveActivity.end() }
        }
    }
    var commandBusy = false
    var commandResult = ""
    var commandTitle = ""
    private var pendingCommand: ReadCommand?
    var inverterSettings: InverterSettings?
    var settingsBusy = false
    var settingsMessage: String?
    var settingsMessageIsError = false
    var settingsActivity = "Reading settings…"
    private enum SettingsAction { case load, write(SettingDefinition, String) }
    private var pendingSettingsAction: SettingsAction?
    var isSettingsPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["INVERTER_LINK_SETTINGS_PREVIEW"] == "1"
        #else
        false
        #endif
    }
    private let liveActivity = LiveActivityClient()
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var session: InverterSession?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var reconnectTask: Task<Void, Never>?
    private var isForeground = true
    private static let savedKey = "savedInverter"
    init(defaults suppliedDefaults: UserDefaults = .standard) {
        #if DEBUG
        let defaults = ProcessInfo.processInfo.environment["INVERTER_LINK_SETTINGS_PREVIEW"] == "1"
            ? UserDefaults(suiteName: "InverterLink.SettingsPreview")! : suppliedDefaults
        #else
        let defaults = suppliedDefaults
        #endif
        self.defaults = defaults
        accentColor = AppAccent(rawValue: defaults.string(forKey: "accentColor") ?? "") ?? .mint
        let interval = defaults.integer(forKey: "refreshSeconds")
        refreshSeconds = Self.refreshChoices.contains(interval) ? interval : 5
        liveActivityEnabled = defaults.bool(forKey: "liveActivityEnabled")
        if let data = defaults.data(forKey: Self.savedKey) {
            saved = try? JSONDecoder().decode(SavedInverter.self, from: data)
            target = saved?.hostname ?? saved?.lastIP ?? ""
        }
        if let data = defaults.data(forKey: "savedInverters") {
            remembered = (try? JSONDecoder().decode([SavedInverter].self, from: data)) ?? []
        }
        if let saved, !remembered.contains(where: { $0.id == saved.id }) { remembered.append(saved) }
        openDefaultInverter = defaults.bool(forKey: "openDefaultInverter")
        defaultInverterID = defaults.string(forKey: "defaultInverterID") ?? remembered.first?.id ?? ""
        if !remembered.contains(where: { $0.id == defaultInverterID }) { defaultInverterID = remembered.first?.id ?? "" }
        #if DEBUG
        if isSettingsPreview {
            phase = .connected("192.168.0.25")
            let preview = SavedInverter(identity: "PREVIEW", hostname: nil, lastIP: "192.168.0.25", name: "Home inverter")
            saved = preview
            remembered = [preview]
            defaultInverterID = "PREVIEW"
            snapshot = try? ReadingSnapshot(status: "221.8 49.8 221.8 49.8 0798 0764 019 403 27.00 000 100 0036 02.0 287.7 00.00 00000 00010110 00 00 00471 111 0 01 0000", mode: "L", warnings: "0")
            inverterSettings = try? InverterSettings(
                ratings: "230.0 17.3 230.0 50.0 17.3 4000 4000 24.0 24.5 21.0 28.2 27.0 2 020 020 0 1 1 1 10 0 0 27.0 0 1",
                flags: "EabkxyzDdjlnuv", equalization: "0 060 030 020 030 27.00 000 120 0 0000",
                led: "1 0 3 0 2 000000255 000000255 148000255",
                maxCharging: "010 020 030 040 050 060 070 080 090 100 110 120",
                utilityCharging: "002 010 020 030 040 050 060 070 080 090 100")
        }
        #endif

    }
    var busy: Bool { phase != .idle }
    var isConnected: Bool { if case .connected = phase { true } else { false } }
    var connectionLabel: String {
        switch phase {
        case .idle: "Offline"
        case .scanning: "Searching"
        case .connecting: "Connecting"
        case .connected: snapshot?.mode ?? "Connected"
        }
    }
    private func discover(run: UUID) async throws {
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
        if !isConnected { phase = .scanning }
        devices = []
        scanned = 0
        total = 0
        let scope = try WiFiNetwork.current()
        total = scope.hosts.count
        let excluded: Set<String>
        if case .connected(let ip) = phase { excluded = [ip] } else { excluded = [] }
        try await LoggerScanner.scan(scope: scope, excluding: excluded) { done, count, ip in
            guard self.generation == run else { return }
            self.scanned = done
            self.total = count
            if let ip, !self.devices.contains(where: { $0.ip == ip }) {
                self.devices.append(LoggerDevice(ip: ip))
                self.devices.sort { ((try? IPv4($0.ip).value) ?? 0) < ((try? IPv4($1.ip).value) ?? 0) }
            }
        }
    }
    func cancelScan() {
        scanGeneration = UUID()
        scanOperation?.cancel()
        scanOperation = nil
        isScanning = false
        if phase == .scanning { phase = .idle }
    }
    func scan() {
        if isSettingsPreview { devices = [LoggerDevice(ip: "192.168.0.26")]; return }
        if !isConnected { stop() }
        cancelScan()
        errorMessage = nil
        isScanning = true
        let scanID = scanGeneration
        let run = generation
        scanOperation = Task { [weak self] in
            guard let self else { return }
            do {
                try await discover(run: run)
                guard generation == run, scanGeneration == scanID else { return }
                if !isConnected { phase = .idle }
                if devices.isEmpty && !isConnected { errorMessage = "No inverter found. Check Wi-Fi and Local Network access." }
            } catch {
                guard generation == run, scanGeneration == scanID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                if !isConnected { phase = .idle }
            }
            if scanGeneration == scanID { isScanning = false; scanOperation = nil }
        }
    }
    private func establish(_ target: String, expected: String? = nil) async throws -> (InverterSession, String) {
        try Task.checkCancellation()
        phase = .connecting(target)
        let ip = try await HostResolver.resolve(target)
        try Task.checkCancellation()
        let scope = try WiFiNetwork.current()
        let connection = try await InverterSession.connect(ip: ip, local: scope.local.text)
        if let expected, connection.metadata?.identity != expected {
            connection.close()
            throw InverterError.message("This is a different inverter.")
        }
        return (connection, ip)
    }
    private func monitor(_ connection: InverterSession, ip: String, hostname: String?, run: UUID) async throws {
        defer { connection.close() }
        guard generation == run, !Task.isCancelled else { return }
        session = connection
        metadata = connection.metadata
        var first = true
        while !Task.isCancelled {
            let reading = try await connection.read()
            guard generation == run else { return }
            snapshot = reading
            updateLiveActivity()
            phase = .connected(ip)
            if first {
                first = false
                if let identity = metadata?.identity {
                    let existingName = remembered.first(where: { $0.id == identity })?.name
                    let watts = metadata?.ratedOutput ?? 0
                    let name = existingName ?? (watts > 0 ? "\((watts / 1000).formatted(.number.precision(.fractionLength(0...1)))) kW inverter" : "Inverter")
                    save(SavedInverter(identity: identity, hostname: hostname, lastIP: ip, name: name))
                    // Learn a router-provided name when available; this logger may have no PTR record.
                    if hostname == nil {
                        Task { [weak self] in
                            let name = await HostResolver.reverse(ip)
                            guard let self, self.generation == run, let name, var saved = self.saved else { return }
                            saved.hostname = name
                            self.save(saved)
                        }
                    }
                }
            }
            try await connection.waitForNextRead(seconds: Double(refreshSeconds)) {
                self.pendingCommand != nil || self.pendingSettingsAction != nil
            }
            while let command = pendingCommand {
                pendingCommand = nil
                do { commandResult = try await connection.query(command) }
                catch { commandResult = error.localizedDescription }
                commandBusy = false
            }
            while let action = pendingSettingsAction {
                pendingSettingsAction = nil
                do {
                    switch action {
                    case .load:
                        inverterSettings = try await connection.readSettings()
                        settingsMessage = nil
                    case .write(let setting, let value):
                        inverterSettings = try await connection.applySetting(setting, value: value)
                        settingsMessage = "\(setting.title) saved and verified."
                        settingsMessageIsError = false
                    }
                } catch { settingsMessage = error.localizedDescription; settingsMessageIsError = true }
                settingsBusy = false
            }
        }
    }
    func connect(to input: String) {
        if isSettingsPreview { dashboardPresented = true; return }
        stop()
        selectedTab = 0
        dashboardPresented = true
        errorMessage = nil
        let run = generation
        phase = .connecting(input)
        operation = Task { [weak self] in
            guard let self else { return }
            guard generation == run, !Task.isCancelled else { return }
            do {
                let host = try HostResolver.validate(input)
                saved = remembered.first { $0.targets.contains(host) }
                let (connection, ip) = try await establish(host)
                let name = (try? IPv4(host)) == nil ? host : nil
                try await monitor(connection, ip: ip, hostname: name, run: run)
            } catch { failed(error, run: run) }
            if generation == run { operation = nil }
        }
    }
    func resume() {
        guard !isSettingsPreview else { return }
        isForeground = true
        endBackgroundTime()
        if isConnected, let snapshot, Date.now.timeIntervalSince(snapshot.time) > Double(refreshSeconds + 20) {
            liveActivity.pause()
            stop(endingActivity: false)
        }
        if !isConnected { liveActivity.pause() }
        guard !busy, let remembered = saved else { return }
        stop(endingActivity: false)
        errorMessage = nil
        let run = generation
        phase = .connecting(remembered.hostname ?? remembered.lastIP)
        operation = Task { [weak self] in
            guard let self else { return }
            guard generation == run, !Task.isCancelled else { return }
            do {
                var established: (InverterSession, String)?
                for target in remembered.targets {
                    do { established = try await establish(target, expected: remembered.identity); break }
                    catch { try Task.checkCancellation() }
                }
                if established == nil {
                    try await discover(run: run)
                    for device in devices {
                        do { established = try await establish(device.ip, expected: remembered.identity); break }
                        catch { try Task.checkCancellation() }
                    }
                }
                guard let (connection, ip) = established else { throw InverterError.message("Couldn't find your saved inverter.") }
                try await monitor(connection, ip: ip, hostname: remembered.hostname, run: run)
            } catch { failed(error, run: run) }
            if generation == run { operation = nil }
        }
    }
    func startOnLaunch() {
        guard openDefaultInverter, let inverter = defaultInverter else { return }
        open(inverter)
    }
    func open(_ inverter: SavedInverter) {
        selectedTab = 0
        dashboardPresented = true
        cancelScan()
        if isConnected, saved?.id == inverter.id { return }
        stop()
        saved = inverter
        target = inverter.hostname ?? inverter.lastIP
        resume()
    }
    func rename(_ inverter: SavedInverter, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 48, !name.contains(where: { $0.isNewline }) else {
            throw InverterError.message("Use a name of 1–48 characters on one line.")
        }
        guard let index = remembered.firstIndex(where: { $0.id == inverter.id }) else { return }
        remembered[index].name = name
        if saved?.id == inverter.id { saved = remembered[index] }
        persistDevices()
    }
    private func persistDevices() {
        if let data = try? JSONEncoder().encode(remembered) { defaults.set(data, forKey: "savedInverters") }
        if let saved, let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.savedKey) }
        else { defaults.removeObject(forKey: Self.savedKey) }
    }
    private func save(_ inverter: SavedInverter) {
        saved = inverter
        target = inverter.hostname ?? inverter.lastIP
        if let index = remembered.firstIndex(where: { $0.id == inverter.id }) { remembered[index] = inverter }
        else { remembered.append(inverter) }
        if defaultInverterID.isEmpty { defaultInverterID = inverter.id }
        persistDevices()
    }
    func forget() {
        if let saved { forget(saved) }
    }
    func forget(_ inverter: SavedInverter) {
        if saved?.id == inverter.id {
            stop()
            saved = nil
            target = ""
        }
        remembered.removeAll { $0.id == inverter.id }
        if defaultInverterID == inverter.id { defaultInverterID = remembered.first?.id ?? "" }
        if remembered.isEmpty { openDefaultInverter = false }
        persistDevices()
        errorMessage = nil
    }
    private func failed(_ error: any Error, run: UUID) {
        guard generation == run else { return }
        cancelScan()
        phase = .idle
        snapshot = nil
        metadata = nil
        session?.close()
        session = nil
        commandBusy = false
        pendingCommand = nil
        settingsBusy = false
        pendingSettingsAction = nil
        inverterSettings = nil
        liveActivity.pause()
        endBackgroundTime()
        if !Task.isCancelled { errorMessage = error.localizedDescription }
        if isForeground, dashboardPresented, saved != nil, !Task.isCancelled {
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, isForeground, generation == run, !busy else { return }
                resume()
            }
        }
    }
    private func updateLiveActivity() {
        guard liveActivityEnabled, let snapshot,
              ProcessInfo.processInfo.environment["INVERTER_LINK_TESTING"] != "1", !isSettingsPreview else { return }
        if let error = liveActivity.update(snapshot, interval: refreshSeconds) { errorMessage = error }
    }
    func runCommand(_ command: ReadCommand) {
        if isSettingsPreview { commandTitle = command.rawValue; commandResult = "Preview: no query was sent."; return }
        guard isConnected, !commandBusy, !settingsBusy else { return }
        commandBusy = true
        commandTitle = command.rawValue
        commandResult = ""
        pendingCommand = command
    }
    func loadSettings() {
        guard !isSettingsPreview else { return }
        guard isConnected, !settingsBusy, !commandBusy else { return }
        settingsBusy = true
        settingsMessage = nil
        settingsMessageIsError = false
        settingsActivity = "Reading settings…"
        pendingSettingsAction = .load
    }
    func writeSetting(_ setting: SettingDefinition, value: String) {
        guard !isSettingsPreview else {
            settingsMessage = "Preview only — no command was sent."
            settingsMessageIsError = false
            return
        }
        guard isConnected, !settingsBusy, !commandBusy else { return }
        settingsBusy = true
        settingsMessage = nil
        settingsMessageIsError = false
        settingsActivity = "Saving and verifying…"
        pendingSettingsAction = .write(setting, value)
    }
    func stop(endingActivity: Bool = true) {
        cancelScan()
        endBackgroundTime()
        reconnectTask?.cancel()
        reconnectTask = nil
        generation = UUID()
        operation?.cancel()
        operation = nil
        session?.close()
        session = nil
        phase = .idle
        snapshot = nil
        metadata = nil
        commandBusy = false
        pendingCommand = nil
        commandResult = ""
        settingsBusy = false
        pendingSettingsAction = nil
        inverterSettings = nil
        settingsMessage = nil
        if endingActivity { liveActivity.end() }
    }
    func background() {
        guard !isSettingsPreview else { return }
        isForeground = false
        reconnectTask?.cancel()
        reconnectTask = nil
        guard liveActivityEnabled, isConnected else { pauseForBackground(); return }
        guard backgroundTask == .invalid else { return }
        // iOS grants only a short grace period; a Live Activity cannot keep the app running indefinitely.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Inverter monitoring") { [weak self] in
            self?.pauseForBackground()
        }
        if backgroundTask == .invalid { pauseForBackground() }
    }
    func pauseForBackground() {
        liveActivity.pause()
        stop(endingActivity: false)
    }
    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
