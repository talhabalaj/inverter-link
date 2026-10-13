import Foundation
import Network
import Testing
import RealityKit
@testable import InverterLink

private let observedStatus = "221.8 49.8 221.8 49.8 0798 0764 019 403 27.00 000 100 0036 02.0 287.7 00.00 00000 00010110 00 00 00471 111 0 01 0000"

struct ProtocolTests {
    @Test func verifiedCRCAndReadQueries() throws {
        #expect(PI30.request(.protocolID) == Data([0x51, 0x50, 0x49, 0xBE, 0xAC, 13]))
        #expect(try PI30.response(Data([40, 0x50, 0x49, 0x33, 0x30, 0x9A, 0x0B, 13])) == "PI30")
        #expect(throws: InverterError.self) { try PI30.response(Data([40, 0x50, 0x49, 0x33, 0x30, 0x9A, 0x0C, 13])) }
        let body = Data("(NAK".utf8)
        #expect(throws: InverterError.self) { try PI30.response(body + PI30.crc(body) + Data([13])) }
        #expect(ReadCommand.allCases.map(\.rawValue).sorted() == ["QBEQI", "QFLAG", "QLED", "QMCHGCR", "QMOD", "QMUCHGCR", "QPI", "QPIGS", "QPIRI", "QPIWS", "QVFW"])
    }
    @Test func liveSettingsAndValidatedWriteCommands() throws {
        let settings = try InverterSettings(
            ratings: "230.0 17.3 230.0 50.0 17.3 4000 4000 24.0 24.5 21.0 28.2 27.0 2 020 020 0 1 1 1 10 0 0 27.0 0 1",
            flags: "EabkxyzDdjlnuv", equalization: "0 060 030 020 030 27.00 000 120 0 0000",
            led: "1 0 3 0 2 000000255 000000255 148000255",
            maxCharging: "010 020 030 040 050 060 070 080 090 100 110 120",
            utilityCharging: "002 010 020 030 040 050 060 070 080 090 100")
        #expect(SettingDefinition.all.count == 37)
        func setting(_ id: String) throws -> SettingDefinition {
            try #require(SettingDefinition.all.first { $0.id == id })
        }
        #expect(try setting("output_voltage").command(for: "220", in: settings) == "V220")
        #expect(try setting("max_charge").command(for: "40", in: settings) == "MNCHGC040")
        #expect(try setting("max_ac_charge").command(for: "20", in: settings) == "MUCHGC020")
        #expect(try setting("bulk").command(for: "28.2", in: settings) == "PCVV28.2")
        #expect(try setting("equalization_voltage").command(for: "27.00", in: settings) == "PBEQV27.00")
        #expect(try setting("led_color_1").command(for: "#0000FF", in: settings) == "PLEDC1000000255")
        #expect(try setting("flag_a").command(for: "0", in: settings) == "PDa")
        #expect(settings.rawValue(for: .ledColor(3)) == nil)
        #expect(try setting("output_voltage").verifies("230", before: settings, after: settings))
        #expect(try setting("led_color_1").verifies("#0000FF", before: settings, after: settings))
        #expect(throws: InverterError.self) { try setting("led_color_3").command(for: "#0000FF", in: settings) }
        #expect(throws: InverterError.self) { try setting("max_charge").command(for: "25", in: settings) }
        #expect(throws: InverterError.self) { try setting("bulk").command(for: "40.0", in: settings) }
        #expect(throws: InverterError.self) { try setting("led_color_1").command(for: "FF0000;PF", in: settings) }
        let blueRequest = try PI30.ledColorRequest(slot: 1, color: LEDColor(red: 0, green: 0, blue: 255))
        #expect(PI30.settingRequest("PLEDC1000000255") == blueRequest)
    }
    @Test func fragmentedAndCoalescedFrames() throws {
        let frame = TunnelFrame(transaction: 7, code: 258, address: 1, function: 4, payload: PI30.request(.status))
        var decoder = FrameDecoder()
        for byte in frame.data.dropLast() { #expect(try decoder.append(Data([byte])).isEmpty) }
        #expect(try decoder.append(Data([try #require(frame.data.last)])) == [frame])
        #expect(try decoder.append(frame.data + frame.data) == [frame, frame])
        var bad = FrameDecoder()
        #expect(throws: InverterError.self) { try bad.append(Data([0, 1, 1, 2, 255, 255, 1, 4])) }
    }
    @Test func replyRouteIsPinned() throws {
        let right = TunnelFrame(transaction: 7, code: 258, address: 1, function: 4, payload: Data())
        #expect(try right.matches(transaction: 7, code: 258))
        #expect(try !right.matches(transaction: 8, code: 258))
        #expect(throws: InverterError.self) { try right.matches(transaction: 7, code: 259) }
        let heartbeat = TunnelFrame(transaction: 7, code: 258, address: 1, function: 1, payload: Data())
        #expect(try !heartbeat.matches(transaction: 7, code: 258))
    }
    @Test func observedReadingsAndHostileNumbers() throws {
        let reading = try ReadingSnapshot(status: observedStatus, mode: "L", warnings: "0000")
        #expect(reading.values["Load power"] == 764)
        #expect(reading.values["PV charging power"] == 471)
        #expect(reading.values["Battery voltage"] == 27)
        #expect(reading.mode == "Grid")
        #expect(!reading.hasWarning)
        #expect(throws: InverterError.self) { try ReadingSnapshot(status: observedStatus + " 0", mode: "L", warnings: "0") }
        #expect(throws: InverterError.self) { try ReadingSnapshot(status: observedStatus.replacingOccurrences(of: "27.00", with: "nan"), mode: "B", warnings: "0") }
        #expect(throws: InverterError.self) { try ReadingSnapshot(status: observedStatus.replacingOccurrences(of: "00010110", with: "0001011X"), mode: "B", warnings: "0") }
        #expect(throws: InverterError.self) { try ReadingSnapshot(status: observedStatus, mode: "B", warnings: "BAD") }
    }
    @Test func privateAddressAndScanBoundaries() throws {
        #expect(try IPv4("192.168.0.25").isPrivate)
        #expect(try IPv4("172.31.255.254").isPrivate)
        #expect(try !IPv4("172.32.0.1").isPrivate)
        #expect(try !IPv4("127.0.0.1").isPrivate)
        #expect(throws: InverterError.self) { try IPv4("192.168.0.025") }
        let scope = try ScanScope(local: "192.168.0.103", mask: "255.255.0.0")
        #expect(scope.label == "192.168.0.0/24")
        #expect(scope.hosts.count == 253)
        #expect(!scope.hosts.contains("192.168.0.103"))
        #expect(scope.isDiscoveryReply(Data("rsp>server=1;\r\n".utf8), from: "192.168.0.25"))
        #expect(!scope.isDiscoveryReply(Data("rsp>server=1;".utf8), from: "192.168.1.25"))
        #expect(!scope.isDiscoveryReply(Data("HTTP/1.1 200".utf8), from: "192.168.0.25"))
        #expect(throws: InverterError.self) { try ScanScope(local: "8.8.8.8", mask: "255.255.255.0") }
        #expect(throws: InverterError.self) { try ScanScope(local: "192.168.0.103", mask: "255.0.255.0") }
        #expect(try ScanScope(local: "192.168.0.1", mask: "255.255.255.252").hosts == ["192.168.0.2"])
    }
    @Test func invalidRatingsAreRejected() throws {
        let metadata = try InverterMetadata(identity: "logger", firmware: "VERFW:00080.01", ratings: "230 17 230 50 17 4000 4000 24")
        #expect(metadata.ratedOutput == 4000)
        #expect(metadata.ratedBattery == 24)
        #expect(throws: InverterError.self) { try InverterMetadata(identity: "logger", firmware: "fw", ratings: "230 17 230 50 17 4000 nan 24") }
    }
}

struct TransportTests {
    @Test(.timeLimit(.minutes(1))) func fixedCallbackPort() async throws {
        let server = try CallbackServer(local: "127.0.0.1")
        defer { server.close() }
        try await server.start()
        #expect(server.port == 8899)
    }
    @Test(.timeLimit(.minutes(1))) func realUDPAnnouncementAndReply() async throws {
        let listener = try NWListener(using: .udp, on: 58899)
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, _ in
                #expect(data == Data("set>server=127.0.0.1:8899;".utf8))
                connection.send(content: Data("rsp>server=1;".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        let reply = await UDPProbe().run(host: "127.0.0.1", local: "127.0.0.1", port: 8899)
        #expect(reply == Data("rsp>server=1;".utf8))
    }
    @Test(.timeLimit(.minutes(1))) func realTCPHandshakeAndReading() async throws {
        let server = try CallbackServer(local: "127.0.0.1", port: .any)
        defer { server.close() }
        try await server.start()
        server.expect("127.0.0.1")
        let mock = TCPChannel(NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: server.port)), using: .tcp))
        defer { mock.close() }
        let responder = Task {
            try await mock.start()
            let replies = ["QPI": "PI30", "QVFW": "VERFW:00080.01", "QPIRI": "230 17 230 50 17 4000 4000 24",
                           "QPIGS": observedStatus, "QMOD": "L", "QPIWS": "000000000000000000000000000000000000"]
            for index in 0..<8 {
                let request = try await mock.nextFrame(seconds: index == 7 ? 50 : 4)
                if request.function == 1 {
                    #expect(request.payload.count == 8)
                    try await mock.send(TunnelFrame(transaction: request.transaction, code: 258, address: 255, function: 1, payload: Data("TEST-LOGGER".utf8)))
                } else {
                    #expect(request.code == 258 && request.address == 1 && request.function == 4)
                    let command = try #require(String(data: Data(request.payload.dropLast(3)), encoding: .ascii))
                    let reply = try #require(replies[command])
                    let body = Data(("(" + reply).utf8)
                    try await mock.send(TunnelFrame(transaction: request.transaction, code: 258, address: 1, function: 4, payload: body + PI30.crc(body) + Data([13])))
                }
            }
        }
        defer { responder.cancel() }
        let accepted = try await server.accept()
        let channel = TCPChannel(accepted)
        defer { channel.close() }
        try await channel.start()
        let session = InverterSession(channel: channel)
        try await session.identify()
        let reading = try await session.read()
        #expect(session.metadata?.identity == "TEST-LOGGER")
        #expect(session.metadata?.ratedOutput == 4000)
        #expect(reading.values["Load power"] == 764)
        try await session.waitForNextRead(seconds: 46)
        try await responder.value
    }
    @Test(.timeLimit(.minutes(1))) func cancellationResumesPendingRead() async throws {
        let server = try CallbackServer(local: "127.0.0.1", port: .any)
        defer { server.close() }
        try await server.start()
        server.expect("127.0.0.1")
        let peer = TCPChannel(NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: server.port)), using: .tcp))
        defer { peer.close() }
        let started = Task { try await peer.start() }
        let channel = TCPChannel(try await server.accept())
        defer { channel.close() }
        try await channel.start()
        try await started.value
        let read = Task { try await channel.nextFrame(seconds: 10) }
        await Task.yield()
        read.cancel()
        do { _ = try await read.value; Issue.record("Cancelled read unexpectedly succeeded.") }
        catch { #expect(error is CancellationError) }
    }
}

struct ReconnectionAndSceneTests {
    @Test func hostnameValidationAndPriority() throws {
        #expect(try HostResolver.validate(" Inverter.LOCAL ") == "inverter.local")
        #expect(try HostResolver.validate("192.168.0.25") == "192.168.0.25")
        for bad in ["https://router.local", "8.8.8.8", "192.168.0.025", "-bad.local", "a..local", "a/b"] {
            #expect(throws: InverterError.self) { try HostResolver.validate(bad) }
        }
        let saved = SavedInverter(identity: "LOGGER-A", hostname: "inverter.local", lastIP: "192.168.0.25")
        #expect(saved.targets == ["inverter.local", "192.168.0.25"])
        #expect(try JSONDecoder().decode(SavedInverter.self, from: JSONEncoder().encode(saved)) == saved)
    }
    @Test func remembersAcrossLaunchAndForgetClearsIt() throws {
        let suite = "InverterLinkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = SavedInverter(identity: "LOGGER-A", hostname: "inverter.local", lastIP: "192.168.0.40")
        defaults.set(try JSONEncoder().encode(saved), forKey: "savedInverter")
        let model = AppModel(defaults: defaults)
        #expect(model.saved == saved)
        #expect(model.target == "inverter.local")
        model.refreshSeconds = 30
        model.liveActivityEnabled = true
        #expect(AppModel(defaults: defaults).refreshSeconds == 30)
        #expect(AppModel(defaults: defaults).liveActivityEnabled)
        model.forget()
        #expect(AppModel(defaults: defaults).saved == nil)
    }
    @Test func liveBehaviourAndOfflineState() throws {
        let offline = LiveEnergyState(nil)
        #expect(!offline.connected && !offline.solarActive && !offline.gridActive && !offline.loadActive)
        let real = LiveEnergyState(try ReadingSnapshot(status: observedStatus, mode: "L", warnings: "0"))
        #expect(real.solarActive && real.gridActive && real.loadActive)
        #expect(real.batteryFlow == .idle && real.batteryLevel == 1)
        var fields = observedStatus.split(separator: " ").map(String.init)
        fields[9] = "12"
        fields[15] = "2"
        fields[10] = "45"
        let charging = LiveEnergyState(try ReadingSnapshot(status: fields.joined(separator: " "), mode: "B", warnings: "0"))
        #expect(charging.batteryFlow == .charging && charging.batteryLevel == 0.45)
        #expect(!charging.gridActive)
        fields[9] = "0"
        fields[19] = "0"
        fields[5] = "0"
        let discharge = LiveEnergyState(try ReadingSnapshot(status: fields.joined(separator: " "), mode: "B", warnings: "0"))
        #expect(discharge.batteryFlow == .discharging)
        #expect(!discharge.solarActive && !discharge.loadActive)
    }
}

struct CommandSchedulingTests {
    @Test(.timeLimit(.minutes(1))) func disconnectInterruptsLongRefreshWait() async throws {
        let channel = TCPChannel(NWConnection(host: "127.0.0.1", port: 8899, using: .tcp))
        let session = InverterSession(channel: channel)
        let began = ProcessInfo.processInfo.systemUptime
        let wait = Task { try await session.waitForNextRead(seconds: 60) }
        await Task.yield()
        channel.close(error: InverterError.message("Test disconnect"))
        do { try await wait.value; Issue.record("Disconnected channel stayed live") }
        catch { #expect(error is InverterError) }
        #expect(ProcessInfo.processInfo.systemUptime - began < 2)
    }
    @Test func interruptedWaitReturnsWithoutSending() async throws {
        let channel = TCPChannel(NWConnection(host: "127.0.0.1", port: 8899, using: .tcp))
        defer { channel.close() }
        let session = InverterSession(channel: channel)
        let began = ProcessInfo.processInfo.systemUptime
        try await session.waitForNextRead(seconds: 60, interrupted: { true })
        #expect(ProcessInfo.processInfo.systemUptime - began < 0.5)
    }
}

struct MonitoringLifecycleTests {
    @Test func manualStopCancelsAutomaticRetry() async throws {
        let suite = "InverterLifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = SavedInverter(identity: "LOGGER-A", hostname: "inverter.local", lastIP: "192.168.0.40")
        defaults.set(try JSONEncoder().encode(saved), forKey: "savedInverter")
        let model = AppModel(defaults: defaults)
        // Invalid syntax fails before any network request, scheduling the same foreground retry path.
        model.connect(to: "https://bad.invalid")
        for _ in 0..<20 {
            if model.errorMessage != nil { break }
            await Task.yield()
        }
        #expect(model.errorMessage != nil)
        model.stop()
        try await Task.sleep(for: .seconds(5.2))
        #expect(model.phase == .idle)
        #expect(model.saved == saved)
    }
    @Test func shortBackgroundSwitchKeepsFreshConnection() throws {
        let suite = "InverterLifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        defer { model.stop() }
        model.liveActivityEnabled = true
        model.phase = .connected("192.168.0.25")
        model.snapshot = try ReadingSnapshot(status: observedStatus, mode: "L", warnings: "0")
        model.background()
        #expect(model.isConnected)
        #expect(model.snapshot != nil)
        model.resume()
        #expect(model.isConnected)
        #expect(model.snapshot != nil)
        model.pauseForBackground()
        #expect(!model.isConnected)
        #expect(model.snapshot == nil)
    }
    @Test func backgroundWithoutLiveActivityStopsMonitoring() throws {
        let suite = "InverterLifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.phase = .connected("192.168.0.25")
        model.snapshot = try ReadingSnapshot(status: observedStatus, mode: "L", warnings: "0")
        model.background()
        #expect(model.phase == .idle)
        #expect(model.snapshot == nil)
    }
    @Test func cancelledReconnectCannotOverwriteStoppedPhase() async throws {
        let suite = "InverterLifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = SavedInverter(identity: "LOGGER-A", hostname: "inverter.local", lastIP: "192.168.0.40")
        defaults.set(try JSONEncoder().encode(saved), forKey: "savedInverter")
        let model = AppModel(defaults: defaults)
        model.resume()
        model.stop()
        await Task.yield()
        #expect(model.phase == .idle)
        #expect(model.saved == saved)
    }
}

struct SceneLifecycleTests {
    @Test func sceneStopsOffscreenAndRestoresLiveFlow() throws {
        let view = SolarRenderView(frame: CGRect(x: 0, y: 0, width: 350, height: 290), cameraMode: .nonAR, automaticallyConfigureSession: false)
        let controller = SolarSceneController()
        defer { controller.stop() }
        view.sceneController = controller
        controller.install(in: view)
        let reading = try ReadingSnapshot(status: observedStatus, mode: "L", warnings: "0")
        controller.update(reading, reduceMotion: false)
        let anchor = try #require(view.scene.anchors.first)
        let entities = anchor.children.count
        #expect(controller.isAnimating)
        #expect(!view.isHidden && anchor.isEnabled)
        controller.update(reading, reduceMotion: false, isActive: false)
        #expect(!controller.isAnimating)
        #expect(!view.isHidden && anchor.isEnabled)
        controller.update(reading, reduceMotion: false, isActive: true)
        #expect(controller.isAnimating)
        #expect(!view.isHidden && anchor.isEnabled)
        #expect(anchor.children.count == entities)
        controller.update(reading, reduceMotion: true)
        #expect(!controller.isAnimating)
        #expect(!view.isHidden && anchor.isEnabled)
        controller.update(nil, reduceMotion: false)
        #expect(!controller.isAnimating)
    }
}

@MainActor struct DeviceLibraryTests {
    @Test func migratesLegacyDeviceAndKeepsItsNameAndAddress() throws {
        let suite = "DeviceLibrary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"identity":"LOGGER-A","hostname":"inverter.local","lastIP":"192.168.0.25"}"#.utf8), forKey: "savedInverter")
        let model = AppModel(defaults: defaults)
        #expect(model.remembered.count == 1)
        #expect(model.defaultInverter?.id == "LOGGER-A")
        model.startOnLaunch()
        #expect(!model.dashboardPresented && model.phase == .idle)
        let original = try #require(model.saved)
        try model.rename(original, to: " Roof solar ")
        let reloaded = AppModel(defaults: defaults)
        #expect(reloaded.remembered.first?.displayName == "Roof solar")
        #expect(reloaded.saved?.identity == original.identity)
        #expect(reloaded.saved?.targets == original.targets)
        #expect(throws: InverterError.self) { try model.rename(original, to: "\n") }
    }
    @Test func defaultPreferenceAndForgetAffectOnlySelectedDevice() throws {
        let suite = "DeviceLibrary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = SavedInverter(identity: "LOGGER-A", hostname: nil, lastIP: "192.168.0.25", name: "Roof")
        let b = SavedInverter(identity: "LOGGER-B", hostname: nil, lastIP: "192.168.0.26", name: "Garage")
        defaults.set(try JSONEncoder().encode([a, b]), forKey: "savedInverters")
        let model = AppModel(defaults: defaults)
        model.accentColor = .purple
        model.defaultInverterID = b.id
        model.openDefaultInverter = true
        let reloaded = AppModel(defaults: defaults)
        #expect(reloaded.defaultInverter?.displayName == "Garage")
        #expect(reloaded.openDefaultInverter)
        #expect(reloaded.accentColor == .purple)
        reloaded.forget(b)
        #expect(reloaded.remembered == [a])
        #expect(reloaded.defaultInverterID == a.id)
        #expect(AppModel(defaults: defaults).remembered == [a])
        reloaded.forget(a)
        #expect(!reloaded.openDefaultInverter && reloaded.defaultInverter == nil)
    }
    @Test func openingConnectedDeviceKeepsItsReadings() throws {
        let suite = "DeviceLibrary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = SavedInverter(identity: "LOGGER-A", hostname: nil, lastIP: "192.168.0.25", name: "Roof")
        defaults.set(try JSONEncoder().encode(device), forKey: "savedInverter")
        let model = AppModel(defaults: defaults)
        model.phase = .connected(device.lastIP)
        model.snapshot = try ReadingSnapshot(status: observedStatus, mode: "L", warnings: "0")
        model.open(device)
        #expect(model.dashboardPresented && model.isConnected)
        #expect(model.snapshot?.values["Load power"] == 764)
    }
}
