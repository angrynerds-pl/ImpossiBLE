import Foundation
import ImpossiBLEPassthroughCore
import SimBridgeServer

private let kSocketPath = "/tmp/impossible.sock"

/// A configuration handed over by the connected app, shown in place of the
/// user's selection while it is active.
struct ClientSuppliedConfiguration: Equatable {
    let name: String
    let devices: [MockDevice]
    let client: SocketClientInfo?

    var sourceDescription: String { client?.displayText ?? "connected app" }
}

/// The domain layer behind `/tmp/impossible.sock`, serving the ImpossiBLE wire
/// protocol in one of two modes: answering from mock data, or forwarding to
/// real Mac Bluetooth hardware through the in-process `CBSPassthroughBridge`.
///
/// The transport itself — socket lifecycle, NDJSON framing, hello handshake,
/// last-connection-wins takeover, client-socket hardening, and the
/// socket-ownership guard — lives in SimBridgeKit's `ProtocolServer`. Every
/// handler here runs on the transport's I/O queue, which also guards all
/// mutable state; UI-facing state is published on the main thread.
public final class MockServer: ObservableObject {
    public enum ServeMode: Sendable {
        case mock
        case passthrough
    }

    /// Socket lifecycle, connection status, client identity, and the activity
    /// line are published by the transport; observe it directly.
    public let transport: ProtocolServer

    @Published var connectedDeviceIDs: Set<String> = []
    /// Set while the connected client supplies its own devices. Published in
    /// full — not just the name — because the device list would otherwise show
    /// the user's configuration while a different one is being served.
    @Published private(set) var clientSuppliedConfiguration: ClientSuppliedConfiguration?
    @Published var pairedDeviceIDs: Set<String> = []

    public weak var store: MockStore?
    public let passthroughActivity = PassthroughActivityMonitor()
    /// Button presses and CSAFE commands into a PM5 the app is connected to
    /// through Passthrough.
    public let pm5Remote = PM5Remote()

    // Guarded by the transport's I/O queue
    private var serveMode: ServeMode = .mock
    private var currentClient: SocketClientInfo?
    /// Separate from `currentClient`, which is nil when the peer pid lookup fails.
    private var isClientConnected = false
    private var connectedPeripherals = Set<String>()
    private var pairedPeripherals = Set<String>()
    private var scanActive = false
    private var scanTimer: DispatchSourceTimer?
    private var writtenCharValues: [String: Data] = [:]
    private var writtenDescValues: [String: Data] = [:]
    private var notifyingCharacteristics = Set<String>()
    /// A configuration uploaded by the connected client. Deliberately kept in
    /// memory only: it must never overwrite the user's saved configurations,
    /// and it dies with the connection that supplied it.
    private var clientSuppliedDevices: [MockDevice]?
    /// What the app did in mock mode, for agents. Survives client changes so
    /// a reconnect is visible in the log rather than wiping it.
    private var activityLog = MockActivityLog()
    /// Failures armed by agents, consumed by matching requests.
    private var failureRules: [MockFailureRule] = []
    private var nextFailureRuleID = 1
    /// Sits in the passthrough path between the app and the bridge.
    private var pm5Engine: PM5RemoteEngine!
    /// Created on first Passthrough start and kept for the process lifetime;
    /// instantiating it triggers the one-time macOS Bluetooth consent prompt.
    private var passthroughBridge: CBSPassthroughBridge?

    private static let serverEnabledKey = "ServerEnabled"

    public init(autoStart: Bool = true) {
        transport = ProtocolServer(
            socketPath: kSocketPath,
            name: "ImpossiBLE-Mock",
            appVersion: AppVersion.current
        )
        transport.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        configurePM5Remote()
        transport.onClientConnected = { [weak self] client in
            self?.handleClientConnected(client)
        }
        transport.onClientTeardown = { [weak self] reason in
            guard let self else { return }
            if self.serveMode == .mock {
                self.activityLog.append("appDisconnected", detail: "\(reason)")
            }
            self.currentClient = nil
            self.isClientConnected = false
            self.tearDownClientState()
        }

        if autoStart, UserDefaults.standard.bool(forKey: Self.serverEnabledKey) {
            start(mode: .mock)
        }
    }

    public func start(mode: ServeMode, completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        transport.performOnIOQueue { [self] in
            serveMode = mode
            if mode == .passthrough {
                preparePassthroughBridge()
            }
        }
        transport.start(completion: completion)
    }

    public func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        transport.stop(completion: completion)
    }

    func terminateConnectedClient() {
        transport.terminateConnectedClient()
    }

    // MARK: - Connection lifecycle (called on the transport's I/O queue)

    private func handleClientConnected(_ client: SocketClientInfo?) {
        currentClient = client
        isClientConnected = true
        tearDownClientState()
        if serveMode == .mock {
            activityLog.append("appConnected", detail: client?.displayText)
        }
    }

    /// Everything the previous client owned, in both modes. Runs on connect,
    /// disconnect, takeover, and stop alike.
    private func tearDownClientState() {
        connectedPeripherals.removeAll()
        pairedPeripherals.removeAll()
        writtenCharValues.removeAll()
        writtenDescValues.removeAll()
        notifyingCharacteristics.removeAll()
        scanTimer?.cancel()
        scanTimer = nil
        scanActive = false
        clearClientSuppliedConfiguration()
        passthroughBridge?.reset()
        pm5Engine.reset()
        clearPassthroughActivity()
        publishDeviceState()
    }

    private func preparePassthroughBridge() {
        guard passthroughBridge == nil else { return }
        let bridge = CBSPassthroughBridge()
        bridge.messageHandler = { [weak self] message in
            guard let self else { return }
            self.transport.performOnIOQueue {
                guard self.serveMode == .passthrough else { return }
                if self.pm5Engine.bridgeMessage(message) { return }
                self.transport.send(message)
            }
        }
        bridge.activityHandler = { [weak self] peripheralId, name, operation, detail in
            guard let self else { return }
            DispatchQueue.main.async {
                self.passthroughActivity.record(id: peripheralId, name: name, operation: operation, detail: detail)
            }
            self.transport.note("\(name.isEmpty ? peripheralId.prefix(8) : Substring(name)): \(operation)")
        }
        passthroughBridge = bridge
    }

    private func configurePM5Remote() {
        let transport = transport
        let remote = pm5Remote
        let engine = PM5RemoteEngine(
            sendToBridge: { [weak self] message in self?.passthroughBridge?.handleMessage(message) },
            sendToApp: { transport.send($0) },
            schedule: { delay, work in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    transport.performOnIOQueue(work)
                }
            },
            publish: { connections in DispatchQueue.main.async { remote.publish(connections) } },
            note: { transport.note($0) }
        )
        engine.isEnabled = remote.isEnabled
        pm5Engine = engine
        remote.submitToEngine = { injection in transport.performOnIOQueue { engine.submit(injection) } }
        remote.setEngineEnabled = { enabled in transport.performOnIOQueue { engine.setEnabled(enabled) } }
        remote.fetchTrace = { since, completion in
            transport.performOnIOQueue {
                let entries = engine.trace(after: since)
                DispatchQueue.main.async { completion(entries) }
            }
        }
    }

    private func clearPassthroughActivity() {
        DispatchQueue.main.async { [passthroughActivity] in
            passthroughActivity.clear()
        }
    }

    // MARK: - Protocol Handler (called on the transport's I/O queue)

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        if serveMode == .passthrough {
            if pm5Engine.appMessage(msg) { return }
            passthroughBridge?.handleMessage(msg)
            return
        }

        switch type {
        case "scan":            handleScan(msg)
        case "stopScan":        handleStopScan()
        case "connect":         handleConnect(msg)
        case "cancel":          handleCancel(msg)
        case "discoverServices":           handleDiscoverServices(msg)
        case "discoverIncludedServices":   handleDiscoverIncludedServices(msg)
        case "discoverCharacteristics":    handleDiscoverCharacteristics(msg)
        case "discoverDescriptors":        handleDiscoverDescriptors(msg)
        case "read":            handleRead(msg)
        case "readDescriptor":  handleReadDescriptor(msg)
        case "write":           handleWrite(msg)
        case "writeDescriptor": handleWriteDescriptor(msg)
        case "setNotify":       handleSetNotify(msg)
        case "readRSSI":        handleReadRSSI(msg)
        case "registerForConnectionEvents": break
        case "setMockConfiguration":   handleSetMockConfiguration(msg)
        case "clearMockConfiguration": clearClientSuppliedConfiguration()
        case "openL2CAP":       handleOpenL2CAP(msg)
        case "l2capWrite", "l2capClose": break
        default:
            NSLog("ImpossiBLE-Mock: unknown message type: %@", type)
        }
    }

    // MARK: - Helpers for main-thread store access

    private func fetchEnabledDevices() -> [MockDevice] {
        if let clientSuppliedDevices {
            return clientSuppliedDevices.filter(\.isEnabled)
        }
        return DispatchQueue.main.sync { store?.enabledDevices ?? [] }
    }

    private func fetchDevice(uuid: String) -> MockDevice? {
        if let clientSuppliedDevices {
            return clientSuppliedDevices.first { $0.id.uuidString == uuid }
        }
        return DispatchQueue.main.sync { store?.devices.first { $0.id.uuidString == uuid } }
    }

    // MARK: - Client-supplied configuration

    private func handleSetMockConfiguration(_ msg: [String: Any]) {
        guard let raw = msg["configuration"] else {
            sendMockConfigurationResult(ok: false, error: "missing configuration")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            let configuration = try JSONDecoder().decode(MockConfiguration.self, from: data)
            clientSuppliedDevices = configuration.devices

            let published = ClientSuppliedConfiguration(
                name: configuration.name,
                devices: configuration.devices,
                client: currentClient
            )
            DispatchQueue.main.async { self.clientSuppliedConfiguration = published }
            let name = configuration.name
            transport.note("Client supplied configuration '\(name)' with \(configuration.devices.count) device(s)")
            sendMockConfigurationResult(ok: true, error: nil)
        } catch {
            // Report back rather than failing silently: a test that uploads a
            // malformed fixture would otherwise just see an empty scan.
            transport.note("Rejected client configuration: \(error.localizedDescription)")
            sendMockConfigurationResult(ok: false, error: error.localizedDescription)
        }
    }

    private func clearClientSuppliedConfiguration() {
        guard clientSuppliedDevices != nil else { return }
        clientSuppliedDevices = nil
        DispatchQueue.main.async { self.clientSuppliedConfiguration = nil }
        transport.note("Client configuration cleared; serving the selected configuration again")
    }

    private func sendMockConfigurationResult(ok: Bool, error: String?) {
        var msg: [String: Any] = ["type": "didSetMockConfiguration", "ok": ok]
        if let error { msg["error"] = error }
        transport.send(msg)
    }

    // MARK: - Scan

    private func handleScan(_ msg: [String: Any]) {
        scanActive = true
        let serviceFilter: [String]? = (msg["services"] as? [String])?.isEmpty == false
            ? msg["services"] as? [String]
            : nil
        activityLog.append("scan", detail: serviceFilter.map { "services: \($0.joined(separator: ", "))" })

        sendDiscoveries(serviceFilter: serviceFilter)

        scanTimer?.cancel()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.transport.performOnIOQueue {
                guard self.scanActive else { return }
                self.sendDiscoveries(serviceFilter: serviceFilter)
            }
        }
        timer.resume()
        scanTimer = timer
    }

    private func handleStopScan() {
        if scanActive {
            activityLog.append("stopScan")
        }
        scanActive = false
        scanTimer?.cancel()
        scanTimer = nil
    }

    private func sendDiscoveries(serviceFilter: [String]?) {
        let devices = fetchEnabledDevices()

        for device in devices {
            let matchesFilter: Bool
            if let filter = serviceFilter {
                let deviceServiceUUIDs = Set(
                    device.advertisedServiceUUIDs.map { $0.uppercased() } +
                    device.services.map { $0.uuid.uppercased() }
                )
                matchesFilter = filter.contains { deviceServiceUUIDs.contains($0.uppercased()) }
            } else {
                matchesFilter = true
            }
            guard matchesFilter else { continue }

            var adv: [String: Any] = [:]
            adv["kCBAdvDataLocalName"] = device.name
            adv["kCBAdvDataIsConnectable"] = device.isConnectable

            let svcUUIDs = device.advertisedServiceUUIDs.isEmpty
                ? device.services.map(\.uuid)
                : device.advertisedServiceUUIDs
            if !svcUUIDs.isEmpty {
                adv["kCBAdvDataServiceUUIDs"] = svcUUIDs
            }
            if let mfg = device.manufacturerData, !mfg.isEmpty {
                adv["kCBAdvDataManufacturerData"] = mfg.base64EncodedString()
            }

            transport.send([
                "type": "didDiscover",
                "id": device.id.uuidString,
                "name": device.name,
                "rssi": device.rssi,
                "adv": adv,
            ])
        }
    }

    // MARK: - Connect / Disconnect

    private func handleConnect(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        let connectFailure = consumeFailure(.connect, deviceID: uuidStr)
        activityLog.append("connect", deviceID: uuidStr, detail: connectFailure?.summary)
        if let rule = connectFailure {
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send(["type": "didFailConnect", "id": uuidStr, "error": message])
            return
        }
        guard let device = fetchDevice(uuid: uuidStr), device.isConnectable else {
            transport.send(["type": "didFailConnect", "id": uuidStr, "error": "Device not connectable"])
            return
        }
        connectedPeripherals.insert(uuidStr)
        publishDeviceState()
        transport.send(["type": "didConnect", "id": uuidStr])
    }

    private func handleCancel(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        activityLog.append("cancelConnection", deviceID: uuidStr)
        sendDisconnect(uuidStr, error: "")
    }

    /// Drops the peripheral's connection state and tells the app. An empty
    /// error is a disconnect the app asked for; anything else is unexpected.
    private func sendDisconnect(_ uuidStr: String, error: String) {
        connectedPeripherals.remove(uuidStr)
        pairedPeripherals.remove(uuidStr)
        notifyingCharacteristics = notifyingCharacteristics.filter { !$0.hasPrefix(uuidStr) }
        publishDeviceState()
        transport.send([
            "type": "didDisconnect",
            "id": uuidStr,
            "error": error,
            "timestamp": CFAbsoluteTimeGetCurrent(),
            "isReconnecting": false,
        ])
    }

    // MARK: - Service Discovery

    private func handleDiscoverServices(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        let rawFilter = msg["services"] as? [String]
        let filterUUIDs: [String]? = (rawFilter?.isEmpty == false) ? rawFilter!.map { $0.uppercased() } : nil

        let discoveryFailure = consumeFailure(.discoverServices, deviceID: uuidStr)
        activityLog.append("discoverServices", deviceID: uuidStr, detail: discoveryFailure?.summary)
        if let rule = discoveryFailure {
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send(["type": "didDiscoverServices", "id": uuidStr, "services": [] as [[String: Any]], "error": message])
            return
        }

        guard let device = fetchDevice(uuid: uuidStr) else {
            transport.note("discoverServices: device not found for \(uuidStr)")
            transport.send(["type": "didDiscoverServices", "id": uuidStr, "services": [] as [[String: Any]], "error": "Device not found"])
            return
        }

        var servicesPayload: [[String: Any]] = []
        for (idx, svc) in device.services.enumerated() {
            if let filter = filterUUIDs, !filter.contains(svc.uuid.uppercased()) {
                continue
            }
            let shimId = "\(uuidStr):\(svc.uuid):\(idx)"
            servicesPayload.append([
                "id": shimId,
                "uuid": svc.uuid,
                "primary": svc.isPrimary,
            ])
        }

        transport.send([
            "type": "didDiscoverServices",
            "id": uuidStr,
            "services": servicesPayload,
            "error": "",
        ])
    }

    private func handleDiscoverIncludedServices(_ msg: [String: Any]) {
        guard let serviceId = msg["serviceId"] as? String else { return }
        let parts = serviceId.split(separator: ":")
        guard parts.count >= 1 else { return }
        let peripheralUUID = String(parts[0])
        transport.send([
            "type": "didDiscoverIncludedServices",
            "id": peripheralUUID,
            "serviceId": serviceId,
            "includedServices": [] as [[String: Any]],
            "error": "",
        ])
    }

    // MARK: - Characteristic Discovery

    private func handleDiscoverCharacteristics(_ msg: [String: Any]) {
        guard let serviceId = msg["serviceId"] as? String else { return }
        let rawFilter = msg["characteristics"] as? [String]
        let filterUUIDs: [String]? = (rawFilter?.isEmpty == false) ? rawFilter!.map { $0.uppercased() } : nil

        let parts = serviceId.split(separator: ":")
        guard parts.count >= 3 else { return }
        let peripheralUUID = String(parts[0])
        let serviceUUID = String(parts[1])
        let serviceIdx = Int(parts[2]) ?? 0

        let discoveryFailure = consumeFailure(.discoverCharacteristics, deviceID: peripheralUUID)
        activityLog.append("discoverCharacteristics", deviceID: peripheralUUID, serviceUUID: serviceUUID,
                           detail: discoveryFailure?.summary)
        if let rule = discoveryFailure {
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send([
                "type": "didDiscoverCharacteristics",
                "id": peripheralUUID,
                "serviceId": serviceId,
                "characteristics": [] as [[String: Any]],
                "error": message,
            ])
            return
        }

        guard let device = fetchDevice(uuid: peripheralUUID),
              serviceIdx < device.services.count,
              device.services[serviceIdx].uuid.uppercased() == serviceUUID.uppercased()
        else { return }

        let svc = device.services[serviceIdx]
        var charsPayload: [[String: Any]] = []
        for (idx, ch) in svc.characteristics.enumerated() {
            if let filter = filterUUIDs, !filter.contains(ch.uuid.uppercased()) {
                continue
            }
            let shimId = "\(serviceId):\(ch.uuid):\(idx)"
            charsPayload.append([
                "id": shimId,
                "uuid": ch.uuid,
                "properties": ch.properties,
            ])
        }

        transport.send([
            "type": "didDiscoverCharacteristics",
            "id": peripheralUUID,
            "serviceId": serviceId,
            "characteristics": charsPayload,
            "error": "",
        ])
    }

    // MARK: - Descriptor Discovery

    private func handleDiscoverDescriptors(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let parts = charId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0

        guard let device = fetchDevice(uuid: peripheralUUID),
              serviceIdx < device.services.count,
              charIdx < device.services[serviceIdx].characteristics.count
        else { return }

        let ch = device.services[serviceIdx].characteristics[charIdx]
        var descriptorsPayload: [[String: Any]] = []
        for (idx, desc) in ch.descriptors.enumerated() {
            let shimId = "\(charId):\(desc.uuid):\(idx)"
            descriptorsPayload.append([
                "id": shimId,
                "uuid": desc.uuid,
            ])
        }

        transport.send([
            "type": "didDiscoverDescriptors",
            "id": peripheralUUID,
            "characteristicId": charId,
            "descriptors": descriptorsPayload,
            "error": "",
        ])
    }

    // MARK: - Read / Write

    private func handleRead(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let parts = charId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0

        if let rule = consumeFailure(.read, deviceID: peripheralUUID, characteristicUUID: String(parts[3])) {
            activityLog.append("read", deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                               characteristicUUID: String(parts[3]), detail: rule.summary)
            sendInjectedATTError(rule, type: "didUpdateValue", peripheralUUID: peripheralUUID, idKey: "characteristicId", idValue: charId)
            return
        }

        guard checkSecurity(peripheralUUID: peripheralUUID, serviceIdx: serviceIdx, charIdx: charIdx) else {
            activityLog.append("read", deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                               characteristicUUID: String(parts[3]), detail: "insufficient authentication")
            sendAuthError(type: "didUpdateValue", peripheralUUID: peripheralUUID, idKey: "characteristicId", idValue: charId)
            return
        }

        let value: Data?
        if let written = writtenCharValues[charId] {
            value = written
        } else if let device = fetchDevice(uuid: peripheralUUID),
                  serviceIdx < device.services.count,
                  charIdx < device.services[serviceIdx].characteristics.count {
            value = device.services[serviceIdx].characteristics[charIdx].value
        } else {
            value = nil
        }

        activityLog.append("read", deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                           characteristicUUID: String(parts[3]), value: value)
        transport.send([
            "type": "didUpdateValue",
            "id": peripheralUUID,
            "characteristicId": charId,
            "value": value?.base64EncodedString() ?? "",
            "error": "",
        ])
    }

    private func handleWrite(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let parts = charId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0

        let writeType = (msg["writeType"] as? Int) ?? 0
        let written = (msg["value"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let kind = writeType == 0 ? "write" : "writeWithoutResponse"

        if let rule = consumeFailure(.write, deviceID: peripheralUUID, characteristicUUID: String(parts[3])) {
            activityLog.append(kind, deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                               characteristicUUID: String(parts[3]), value: written, detail: rule.summary)
            if writeType == 0 {
                sendInjectedATTError(rule, type: "didWriteValue", peripheralUUID: peripheralUUID, idKey: "characteristicId", idValue: charId)
            }
            return
        }

        guard checkSecurity(peripheralUUID: peripheralUUID, serviceIdx: serviceIdx, charIdx: charIdx) else {
            activityLog.append(kind, deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                               characteristicUUID: String(parts[3]), value: written, detail: "insufficient authentication")
            sendAuthError(type: "didWriteValue", peripheralUUID: peripheralUUID, idKey: "characteristicId", idValue: charId)
            return
        }

        writtenCharValues[charId] = written
        activityLog.append(kind, deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                           characteristicUUID: String(parts[3]), value: written)

        if writeType == 0 {
            transport.send([
                "type": "didWriteValue",
                "id": peripheralUUID,
                "characteristicId": charId,
                "error": "",
            ])
        }
    }

    private func handleReadDescriptor(_ msg: [String: Any]) {
        guard let descId = msg["descriptorId"] as? String else { return }
        let parts = descId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0
        let descIdx: Int
        if parts.count >= 7 {
            descIdx = Int(parts[6]) ?? 0
        } else {
            descIdx = 0
        }
        let descriptorUUID = parts.count >= 6 ? String(parts[5]) : nil

        if let rule = consumeFailure(.readDescriptor, deviceID: peripheralUUID, characteristicUUID: String(parts[3])) {
            activityLog.append("readDescriptor", deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                               characteristicUUID: String(parts[3]), descriptorUUID: descriptorUUID, detail: rule.summary)
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send([
                "type": "didUpdateDescriptorValue",
                "id": peripheralUUID,
                "descriptorId": descId,
                "value": NSNull(),
                "valueB64": "",
                "error": message,
            ])
            return
        }

        let value: Data?
        if let written = writtenDescValues[descId] {
            value = written
        } else if let device = fetchDevice(uuid: peripheralUUID),
                  serviceIdx < device.services.count,
                  charIdx < device.services[serviceIdx].characteristics.count,
                  descIdx < device.services[serviceIdx].characteristics[charIdx].descriptors.count {
            value = device.services[serviceIdx].characteristics[charIdx].descriptors[descIdx].value
        } else {
            value = nil
        }

        activityLog.append("readDescriptor", deviceID: peripheralUUID, serviceUUID: String(parts[1]),
                           characteristicUUID: String(parts[3]), descriptorUUID: descriptorUUID, value: value)
        transport.send([
            "type": "didUpdateDescriptorValue",
            "id": peripheralUUID,
            "descriptorId": descId,
            "value": NSNull(),
            "valueB64": value?.base64EncodedString() ?? "",
            "error": "",
        ])
    }

    private func handleWriteDescriptor(_ msg: [String: Any]) {
        guard let descId = msg["descriptorId"] as? String else { return }
        let parts = descId.split(separator: ":")
        guard parts.count >= 1 else { return }
        let peripheralUUID = String(parts[0])
        let serviceUUID = parts.count >= 2 ? String(parts[1]) : nil
        let characteristicUUID = parts.count >= 4 ? String(parts[3]) : nil
        let descriptorUUID = parts.count >= 6 ? String(parts[5]) : nil
        let written = (msg["value"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }

        if let rule = consumeFailure(.writeDescriptor, deviceID: peripheralUUID, characteristicUUID: characteristicUUID) {
            activityLog.append("writeDescriptor", deviceID: peripheralUUID, serviceUUID: serviceUUID,
                               characteristicUUID: characteristicUUID, descriptorUUID: descriptorUUID,
                               value: written, detail: rule.summary)
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send([
                "type": "didWriteDescriptorValue",
                "id": peripheralUUID,
                "descriptorId": descId,
                "error": message,
            ])
            return
        }

        if let written {
            writtenDescValues[descId] = written
        }
        activityLog.append("writeDescriptor", deviceID: peripheralUUID, serviceUUID: serviceUUID,
                           characteristicUUID: characteristicUUID, descriptorUUID: descriptorUUID, value: written)

        transport.send([
            "type": "didWriteDescriptorValue",
            "id": peripheralUUID,
            "descriptorId": descId,
            "error": "",
        ])
    }

    // MARK: - Notify

    private func handleSetNotify(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let enabled: Bool
        if let b = msg["enabled"] as? Bool {
            enabled = b
        } else if let n = msg["enabled"] as? Int {
            enabled = n != 0
        } else {
            return
        }

        let parts = charId.split(separator: ":")
        guard parts.count >= 1 else { return }
        let peripheralUUID = String(parts[0])
        let serviceUUID = parts.count >= 2 ? String(parts[1]) : nil
        let characteristicUUID = parts.count >= 4 ? String(parts[3]) : nil
        let kind = enabled ? "subscribe" : "unsubscribe"

        if let rule = consumeFailure(.setNotify, deviceID: peripheralUUID, characteristicUUID: characteristicUUID) {
            activityLog.append(kind, deviceID: peripheralUUID, serviceUUID: serviceUUID,
                               characteristicUUID: characteristicUUID, detail: rule.summary)
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send([
                "type": "didUpdateNotification",
                "id": peripheralUUID,
                "characteristicId": charId,
                "enabled": !enabled,
                "error": message,
            ])
            return
        }

        activityLog.append(kind, deviceID: peripheralUUID, serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)
        if enabled {
            notifyingCharacteristics.insert(charId)
        } else {
            notifyingCharacteristics.remove(charId)
        }

        transport.send([
            "type": "didUpdateNotification",
            "id": peripheralUUID,
            "characteristicId": charId,
            "enabled": enabled,
            "error": "",
        ])
    }

    // MARK: - RSSI

    private func handleReadRSSI(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        let rssiFailure = consumeFailure(.readRSSI, deviceID: uuidStr)
        activityLog.append("readRSSI", deviceID: uuidStr, detail: rssiFailure?.summary)
        if let rule = rssiFailure {
            guard case .error(let message, _) = rule.behavior else { return }
            transport.send(["type": "didReadRSSI", "id": uuidStr, "rssi": 0, "error": message])
            return
        }
        let device = fetchDevice(uuid: uuidStr)

        transport.send([
            "type": "didReadRSSI",
            "id": uuidStr,
            "rssi": device?.rssi ?? -50,
            "error": "",
        ])
    }

    // MARK: - L2CAP (not supported in mock mode)

    private func handleOpenL2CAP(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        transport.send([
            "type": "didOpenL2CAP",
            "id": uuidStr,
            "channelId": "",
            "psm": 0,
            "error": "L2CAP is not supported in mock mode",
        ])
    }

    // MARK: - Security

    private func checkSecurity(peripheralUUID: String, serviceIdx: Int, charIdx: Int) -> Bool {
        guard let device = fetchDevice(uuid: peripheralUUID),
              serviceIdx < device.services.count,
              charIdx < device.services[serviceIdx].characteristics.count
        else { return true }

        let characteristic = device.services[serviceIdx].characteristics[charIdx]
        guard characteristic.securityLevel == .encryptionRequired else { return true }
        guard !pairedPeripherals.contains(peripheralUUID) else { return true }

        switch device.pairingMode {
            case .none:
                return true
            case .justWorks:
                pairedPeripherals.insert(peripheralUUID)
                publishDeviceState()
                transport.note("Auto-paired (Just Works): \(device.name)")
                return true
            case .passkey:
                return false
        }
    }

    private func sendAuthError(type: String, peripheralUUID: String, idKey: String, idValue: String) {
        transport.send([
            "type": type,
            "id": peripheralUUID,
            idKey: idValue,
            "value": "",
            "error": "Insufficient authentication",
            "errorDomain": "CBATTErrorDomain",
            "errorCode": 5,
        ])
    }

    // MARK: - Injected failures (I/O queue)

    /// The first armed rule matching the request, with its count consumed.
    private func consumeFailure(_ operation: MockOperation, deviceID: String, characteristicUUID: String? = nil) -> MockFailureRule? {
        guard let index = failureRules.firstIndex(where: {
            $0.matches(operation, deviceID: deviceID, characteristicUUID: characteristicUUID)
        }) else { return nil }
        let rule = failureRules[index]
        if let remaining = rule.remaining {
            if remaining <= 1 {
                failureRules.remove(at: index)
            } else {
                failureRules[index].remaining = remaining - 1
            }
        }
        transport.note("Injected failure: \(operation.rawValue)")
        return rule
    }

    private func sendInjectedATTError(_ rule: MockFailureRule, type: String, peripheralUUID: String, idKey: String, idValue: String) {
        guard case .error(let message, let attError) = rule.behavior else { return }
        transport.send([
            "type": type,
            "id": peripheralUUID,
            idKey: idValue,
            "value": "",
            "error": message,
            "errorDomain": "CBATTErrorDomain",
            "errorCode": attError,
        ])
    }

    // MARK: - Utilities

    private func publishDeviceState() {
        let connected = connectedPeripherals
        let paired = pairedPeripherals
        DispatchQueue.main.async { [weak self] in
            self?.connectedDeviceIDs = connected
            self?.pairedDeviceIDs = paired
        }
    }
}

// MARK: - Agent control

/// The live levers agents pull in mock mode. Each call hops to the transport's
/// I/O queue, where the session state lives, and completes on the main thread.
extension MockServer {
    struct LiveState {
        let isMockServing: Bool
        let connectedDeviceIDs: [String]
        /// (deviceID, serviceUUID, characteristicUUID) the app subscribed to.
        let subscriptions: [(String, String, String)]
    }

    struct ValuePush {
        let isConnected: Bool
        let isSubscribed: Bool
        let notified: Bool
    }

    /// Replaces the value the app reads for one characteristic for the rest of
    /// the session — the stored configuration is untouched — and, when the app
    /// is subscribed and `notify` is set, delivers it as a notification.
    func pushValue(_ value: Data, to address: MockCharacteristicAddress, notify: Bool,
                   completion: @escaping (Result<ValuePush, ToolError>) -> Void) {
        transport.performOnIOQueue { [self] in
            guard serveMode == .mock, isClientConnected else {
                let error = ToolError(serveMode == .mock
                    ? "No simulator app is connected"
                    : "Values can only be pushed in mock mode")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            writtenCharValues[address.wireID] = value
            let connected = connectedPeripherals.contains(address.deviceID)
            let subscribed = notifyingCharacteristics.contains(address.wireID)
            let notified = notify && connected && subscribed
            if notified {
                transport.send([
                    "type": "didUpdateValue",
                    "id": address.deviceID,
                    "characteristicId": address.wireID,
                    "value": value.base64EncodedString(),
                    "error": "",
                ])
            }
            activityLog.append(notified ? "notify" : "setValue", deviceID: address.deviceID,
                               serviceUUID: address.serviceUUID, characteristicUUID: address.characteristicUUID,
                               value: value, detail: "by agent")
            let push = ValuePush(isConnected: connected, isSubscribed: subscribed, notified: notified)
            DispatchQueue.main.async { completion(.success(push)) }
        }
    }

    /// Drops a connected peripheral as if the link was lost.
    func disconnectPeripheral(_ deviceID: String, error: String,
                              completion: @escaping (Result<Void, ToolError>) -> Void) {
        transport.performOnIOQueue { [self] in
            guard serveMode == .mock, connectedPeripherals.contains(deviceID) else {
                let failure = ToolError(serveMode == .mock
                    ? "The app is not connected to that device"
                    : "Devices can only be disconnected in mock mode")
                DispatchQueue.main.async { completion(.failure(failure)) }
                return
            }
            activityLog.append("disconnect", deviceID: deviceID, detail: "by agent: \(error)")
            sendDisconnect(deviceID, error: error)
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func addFailure(operation: MockOperation, deviceID: String, characteristicUUID: String?,
                    behavior: MockFailureRule.Behavior, count: Int?,
                    completion: @escaping (MockFailureRule) -> Void) {
        transport.performOnIOQueue { [self] in
            let rule = MockFailureRule(
                id: nextFailureRuleID,
                operation: operation,
                deviceID: deviceID,
                characteristicUUID: characteristicUUID?.uppercased(),
                behavior: behavior,
                remaining: count
            )
            nextFailureRuleID += 1
            failureRules.append(rule)
            DispatchQueue.main.async { completion(rule) }
        }
    }

    /// Removes one rule, or all of them when `id` is nil. Reports how many went.
    func clearFailures(id: Int?, completion: @escaping (Int) -> Void) {
        transport.performOnIOQueue { [self] in
            let before = failureRules.count
            failureRules.removeAll { id == nil || $0.id == id }
            let removed = before - failureRules.count
            DispatchQueue.main.async { completion(removed) }
        }
    }

    func failures(completion: @escaping ([MockFailureRule]) -> Void) {
        transport.performOnIOQueue { [self] in
            let rules = failureRules
            DispatchQueue.main.async { completion(rules) }
        }
    }

    func activity(after sequence: Int, limit: Int,
                  completion: @escaping (_ events: [MockActivityEvent], _ last: Int, _ state: LiveState) -> Void) {
        transport.performOnIOQueue { [self] in
            let events = activityLog.events(after: sequence, limit: limit)
            let last = activityLog.lastSequence
            let subscriptions = notifyingCharacteristics.sorted().compactMap { wireID -> (String, String, String)? in
                let parts = wireID.split(separator: ":").map(String.init)
                guard parts.count >= 5 else { return nil }
                return (parts[0], parts[1], parts[3])
            }
            let state = LiveState(
                isMockServing: serveMode == .mock && transport.isRunning,
                connectedDeviceIDs: connectedPeripherals.sorted(),
                subscriptions: subscriptions
            )
            DispatchQueue.main.async { completion(events, last, state) }
        }
    }

    func clearActivity(completion: @escaping () -> Void) {
        transport.performOnIOQueue { [self] in
            activityLog.clear()
            DispatchQueue.main.async(execute: completion)
        }
    }
}
