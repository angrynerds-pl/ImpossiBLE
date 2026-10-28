import Combine
import Foundation
import SimBridgeServer
import SimBridgeShell

/// Reports progress of a long-running tool call: (progress, total, message).
typealias ToolProgress = (Double, Double?, String) -> Void

/// The JSON payload of a successful call, or the reason it failed.
typealias ToolCompletion = (Result<Any, ToolError>) -> Void

struct ToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let readOnly: Bool
    let destructive: Bool
    let run: (ProviderTools, [String: Any], ToolProgress?, @escaping ToolCompletion) -> Void

    var listing: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "openWorldHint": false,
            ],
        ]
    }
}

/// The MCP tools: mode switching, mock configurations, the working device set,
/// capture, and passthrough activity. Every handler runs on the main thread,
/// because that is where `MockStore`, the mode controller, and the activity
/// monitor live — the same objects the panel binds to, so whatever an agent
/// changes shows up there immediately.
///
/// Configurations a connected app uploads (`setMockConfiguration`) are only
/// ever reported here, never edited: they must not reach `MockStore`.
final class ProviderTools {
    private let store: MockStore
    private let server: MockServer
    private let modeController: ModeTransitionController<ProviderMode>
    /// Separate from the capture window's session, like that one is separate
    /// from the serving bridge: an agent recording never disturbs either.
    private lazy var capture = CaptureSession()
    private var isSavingCapture = false

    private static let modeSwitchTimeout: TimeInterval = 15

    init(store: MockStore, server: MockServer, modeController: ModeTransitionController<ProviderMode>) {
        self.store = store
        self.server = server
        self.modeController = modeController
    }

    func stop() {
        capture.stop()
    }

    // MARK: - Dispatch

    var listing: [[String: Any]] {
        Self.definitions.map(\.listing)
    }

    /// Must be called on the main thread; `completion` is called on it, too.
    func call(name: String, arguments: [String: Any], progress: ToolProgress?, completion: @escaping ToolCompletion) {
        guard let tool = Self.definitions.first(where: { $0.name == name }) else {
            completion(.failure(ToolError("Unknown tool \"\(name)\"")))
            return
        }
        tool.run(self, arguments, progress, completion)
    }

    // MARK: - Tool table

    private static func sync(_ body: @escaping (ProviderTools, [String: Any]) throws -> Any)
        -> (ProviderTools, [String: Any], ToolProgress?, @escaping ToolCompletion) -> Void {
        { tools, args, _, completion in
            do {
                completion(.success(try body(tools, args)))
            } catch let error as ToolError {
                completion(.failure(error))
            } catch {
                completion(.failure(ToolError(error.localizedDescription)))
            }
        }
    }

    private static let configurationRef: [String: Any] = [
        "type": "string",
        "description": "Configuration id or name (as returned by list_configurations)",
    ]
    private static let deviceRef: [String: Any] = [
        "type": "string",
        "description": "Device id or name in the working set (as returned by list_devices)",
    ]
    private static let captureFilterProperties: [String: Any] = [
        "onlyConnectable": ["type": "boolean", "description": "Only connectable devices (default false)"],
        "includeUnnamed": ["type": "boolean", "description": "Include devices without a name (default false)"],
        "nameContains": ["type": "string", "description": "Case-insensitive name substring"],
        "advertisingService": ["type": "string", "description": "Only devices advertising this service UUID"],
    ]
    private static let deviceSchema: [String: Any] = [
        "type": "object",
        "description": """
            Mock device fields. Values are hex strings (e.g. "0A1B"); characteristic and descriptor values \
            may instead be given as UTF-8 text via valueText. properties is a list of: \
            \(ControlDTO.propertyNames.map(\.name).joined(separator: ", ")). pairingMode: none, justWorks, \
            passkey (needs a six-digit passkey). securityLevel: none, encryptionRequired. \
            Example: {"name":"Thermo","advertisedServiceUUIDs":["181A"],"services":[{"uuid":"181A",\
            "characteristics":[{"uuid":"2A6E","properties":["read","notify"],"value":"E803",\
            "descriptors":[{"uuid":"2902","value":"0000"}]}]}]}
            """,
        "properties": [
            "name": ["type": "string"],
            "rssi": ["type": "integer"],
            "isConnectable": ["type": "boolean"],
            "isEnabled": ["type": "boolean"],
            "advertisedServiceUUIDs": ["type": "array", "items": ["type": "string"]],
            "manufacturerData": ["type": "string", "description": "Hex, including the company identifier"],
            "pairingMode": ["type": "string", "enum": ControlDTO.pairingModeNames.map(\.name)],
            "passkey": ["type": "string"],
            "services": ["type": "array", "items": ["type": "object"]],
        ],
    ]

    private static func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    static let definitions: [ToolDefinition] = [
        // MARK: Status & mode
        ToolDefinition(
            name: "get_status",
            description: """
                Current ImpossiBLE provider state: mode (off/mock/passthrough), socket status, the connected \
                simulator app, the active mock configuration, any configuration the app uploaded itself, and \
                capture state. Call this first.
                """,
            inputSchema: schema(),
            readOnly: true,
            destructive: false,
            run: sync { tools, _ in tools.status() }
        ),
        ToolDefinition(
            name: "set_mode",
            description: """
                Switch the provider mode. off: CoreBluetooth in the simulator reports poweredOff. mock: serves \
                the virtual devices of the working set. passthrough: forwards to the Mac's real Bluetooth \
                hardware. Switching disconnects the simulator app briefly (it reconnects automatically). \
                Waits until the switch completes and returns the new status.
                """,
            inputSchema: schema([
                "mode": ["type": "string", "enum": ProviderMode.allCases.map(\.rawValue)],
            ], required: ["mode"]),
            readOnly: false,
            destructive: false,
            run: { tools, args, _, completion in tools.setMode(args, completion: completion) }
        ),

        // MARK: Configurations
        ToolDefinition(
            name: "list_configurations",
            description: """
                List mock configurations (named device sets): built-in ones and the user's. \
                active marks the one currently loaded into the working set.
                """,
            inputSchema: schema(),
            readOnly: true,
            destructive: false,
            run: sync { tools, _ in
                ["configurations": tools.store.allConfigurations.map {
                    ControlDTO.configurationSummary($0, isActive: $0.name == tools.store.activeConfigurationName)
                }]
            }
        ),
        ToolDefinition(
            name: "get_configuration",
            description: "Full contents of a configuration: devices, services, characteristics, descriptors.",
            inputSchema: schema(["configuration": configurationRef], required: ["configuration"]),
            readOnly: true,
            destructive: false,
            run: sync { tools, args in
                let config = try tools.configuration(args)
                return ControlDTO.configuration(config, isActive: config.name == tools.store.activeConfigurationName)
            }
        ),
        ToolDefinition(
            name: "select_configuration",
            description: """
                Load a configuration into the working set; in mock mode its enabled devices are what the \
                simulator sees. Replaces the current working set (save it first with save_working_set_as if \
                it has unsaved edits).
                """,
            inputSchema: schema(["configuration": configurationRef], required: ["configuration"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let config = try tools.configuration(args)
                tools.store.loadConfiguration(config)
                return tools.workingSetResult()
            }
        ),
        ToolDefinition(
            name: "create_configuration",
            description: """
                Create (or with replace, overwrite) a user configuration from device definitions — also the \
                way to import a fixture. Loads it into the working set unless select is false.
                """,
            inputSchema: schema([
                "name": ["type": "string"],
                "devices": ["type": "array", "items": deviceSchema],
                "select": ["type": "boolean", "description": "Load into the working set (default true)"],
                "replace": ["type": "boolean", "description": "Overwrite an existing user configuration with this name (default false)"],
            ], required: ["name", "devices"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let name = try tools.newConfigurationName(args["name"], replace: args["replace"] as? Bool ?? false)
                guard let list = args["devices"] as? [[String: Any]] else {
                    throw ToolError("devices must be an array of objects")
                }
                let devices = try list.enumerated().map { index, json in
                    var base = MockDevice()
                    base.name = "Mock Device \(index + 1)"
                    return try ControlDTO.applyDevice(json, to: base)
                }
                return tools.storeConfiguration(name: name, devices: devices, select: args["select"] as? Bool ?? true)
            }
        ),
        ToolDefinition(
            name: "save_working_set_as",
            description: """
                Save the current working set (including edits made with the device tools) as a user \
                configuration, and mark it active.
                """,
            inputSchema: schema([
                "name": ["type": "string"],
                "replace": ["type": "boolean", "description": "Overwrite an existing user configuration with this name (default false)"],
            ], required: ["name"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let name = try tools.newConfigurationName(args["name"], replace: args["replace"] as? Bool ?? false)
                tools.store.saveCurrentAsConfiguration(name: name)
                tools.store.activeConfigurationName = name
                return tools.workingSetResult()
            }
        ),
        ToolDefinition(
            name: "rename_configuration",
            description: "Rename a user configuration. Built-in configurations cannot be renamed.",
            inputSchema: schema([
                "configuration": configurationRef,
                "newName": ["type": "string"],
            ], required: ["configuration", "newName"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let config = try tools.userConfiguration(args, action: "renamed")
                let name = try tools.newConfigurationName(args["newName"], replace: false)
                tools.store.renameConfiguration(id: config.id, to: name)
                return ["renamed": config.name, "to": name]
            }
        ),
        ToolDefinition(
            name: "duplicate_configuration",
            description: "Copy any configuration (built-ins included) to a new user configuration.",
            inputSchema: schema([
                "configuration": configurationRef,
                "newName": ["type": "string", "description": "Defaults to \"<name> Copy\""],
            ], required: ["configuration"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let config = try tools.configuration(args)
                let name = try tools.newConfigurationName(args["newName"] ?? tools.uniqueName(config.name + " Copy"), replace: false)
                let copy = tools.store.duplicateConfiguration(config, name: name)
                return ControlDTO.configurationSummary(copy, isActive: false)
            }
        ),
        ToolDefinition(
            name: "delete_configuration",
            description: """
                Delete a user configuration. Built-ins cannot be deleted. The working set is left as it is, \
                even when the deleted configuration was the active one.
                """,
            inputSchema: schema(["configuration": configurationRef], required: ["configuration"]),
            readOnly: false,
            destructive: true,
            run: sync { tools, args in
                let config = try tools.userConfiguration(args, action: "deleted")
                tools.store.deleteConfiguration(id: config.id)
                return ["deleted": config.name]
            }
        ),

        // MARK: Working set
        ToolDefinition(
            name: "list_devices",
            description: """
                The working set: the devices served in mock mode (only enabled ones are visible to the app). \
                Edits to it are saved immediately but do not change any stored configuration until \
                save_working_set_as.
                """,
            inputSchema: schema(),
            readOnly: true,
            destructive: false,
            run: sync { tools, _ in tools.workingSetResult() }
        ),
        ToolDefinition(
            name: "get_device",
            description: "Full GATT definition of one working-set device.",
            inputSchema: schema(["device": deviceRef], required: ["device"]),
            readOnly: true,
            destructive: false,
            run: sync { tools, args in ControlDTO.device(try tools.device(args)) }
        ),
        ToolDefinition(
            name: "add_device",
            description: "Add a device to the working set. Omitted fields take defaults (connectable, enabled, RSSI -50).",
            inputSchema: schema(["device": deviceSchema], required: ["device"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                guard let json = args["device"] as? [String: Any] else {
                    throw ToolError("device must be an object")
                }
                var base = MockDevice()
                base.name = "Mock Device \(tools.store.devices.count + 1)"
                let device = try ControlDTO.applyDevice(json, to: base)
                tools.store.addDevice(device)
                return tools.annotated(ControlDTO.device(device))
            }
        ),
        ToolDefinition(
            name: "update_device",
            description: """
                Change fields of a working-set device. Only the given fields change; services, when given, \
                replaces the device's whole GATT tree.
                """,
            inputSchema: schema(["device": deviceRef, "changes": deviceSchema], required: ["device", "changes"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                guard let changes = args["changes"] as? [String: Any] else {
                    throw ToolError("changes must be an object")
                }
                let updated = try ControlDTO.applyDevice(changes, to: try tools.device(args))
                tools.store.updateDevice(updated)
                return tools.annotated(ControlDTO.device(updated))
            }
        ),
        ToolDefinition(
            name: "set_device_enabled",
            description: "Show or hide a working-set device from the simulator without deleting it.",
            inputSchema: schema(["device": deviceRef, "enabled": ["type": "boolean"]], required: ["device", "enabled"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let device = try tools.device(args)
                let enabled = try ControlDTO.bool(args["enabled"] as Any, field: "enabled")
                tools.store.setDeviceEnabled(id: device.id, enabled)
                return tools.annotated(["device": device.name, "isEnabled": enabled])
            }
        ),
        ToolDefinition(
            name: "duplicate_device",
            description: "Copy a working-set device (with a new id and \" Copy\" appended to its name).",
            inputSchema: schema(["device": deviceRef], required: ["device"]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in
                let device = try tools.device(args)
                tools.store.duplicateDevice(id: device.id)
                guard let copy = tools.store.devices.last else {
                    throw ToolError("Duplicating \(device.name) failed")
                }
                return tools.annotated(ControlDTO.device(copy))
            }
        ),
        ToolDefinition(
            name: "delete_device",
            description: "Remove a device from the working set.",
            inputSchema: schema(["device": deviceRef], required: ["device"]),
            readOnly: false,
            destructive: true,
            run: sync { tools, args in
                let device = try tools.device(args)
                tools.store.deleteDevice(id: device.id)
                return tools.annotated(["deleted": device.name])
            }
        ),

        // MARK: Capture
        ToolDefinition(
            name: "capture_start",
            description: """
                Start recording nearby real BLE devices with the Mac's Bluetooth (independent of the current \
                mode). Restarts and clears results if already recording. Let it run a few seconds, then use \
                capture_results and capture_save.
                """,
            inputSchema: schema([
                "advertisingService": ["type": "string", "description": "Only scan for devices advertising this service UUID"],
            ]),
            readOnly: false,
            destructive: false,
            run: sync { tools, args in try tools.startCapture(args) }
        ),
        ToolDefinition(
            name: "capture_results",
            description: "Devices seen by the current capture, most interesting first, after filtering.",
            inputSchema: schema(captureFilterProperties.merging([
                "limit": ["type": "integer", "description": "Maximum devices to return (default 50)"],
            ]) { $1 }),
            readOnly: true,
            destructive: false,
            run: sync { tools, args in try tools.captureResults(args) }
        ),
        ToolDefinition(
            name: "capture_save",
            description: """
                Save captured devices as a new configuration. Picks deviceIds when given, otherwise every \
                device matching the filters. With inspect (default), connectable devices are connected to \
                and their full GATT database — services, characteristics, descriptors, readable values — is \
                read; this takes several seconds per device. Stops the capture and loads the configuration \
                into the working set unless select is false.
                """,
            inputSchema: schema(captureFilterProperties.merging([
                "name": ["type": "string", "description": "Defaults to \"Capture <date time>\""],
                "deviceIds": ["type": "array", "items": ["type": "string"], "description": "ids from capture_results"],
                "inspect": ["type": "boolean", "description": "Deep GATT inspection (default true)"],
                "select": ["type": "boolean", "description": "Load into the working set (default true)"],
                "replace": ["type": "boolean", "description": "Overwrite an existing user configuration with this name (default false)"],
            ]) { $1 }),
            readOnly: false,
            destructive: false,
            run: { tools, args, progress, completion in
                tools.saveCapture(args, progress: progress, completion: completion)
            }
        ),
        ToolDefinition(
            name: "capture_stop",
            description: "Stop recording. Results stay available to capture_results and capture_save (advertisement data only, no inspection).",
            inputSchema: schema(),
            readOnly: false,
            destructive: false,
            run: sync { tools, _ in
                guard !tools.isSavingCapture else {
                    throw ToolError("A capture is being saved; wait for capture_save to finish")
                }
                tools.capture.stop()
                return ["stopped": true, "deviceCount": tools.capture.devices.count]
            }
        ),

        // MARK: Passthrough
        ToolDefinition(
            name: "passthrough_activity",
            description: """
                In passthrough mode: the real devices the simulator app is talking to and its latest GATT/L2CAP \
                operation on each (reads, writes, subscriptions, L2CAP traffic), most recent first.
                """,
            inputSchema: schema(),
            readOnly: true,
            destructive: false,
            run: sync { tools, _ in tools.passthroughActivity() }
        ),
        ToolDefinition(
            name: "terminate_simulator_app",
            description: """
                Send SIGTERM to the simulator app currently connected to ImpossiBLE, e.g. to restart it with a \
                fresh Bluetooth state. The app must be relaunched afterwards.
                """,
            inputSchema: schema(),
            readOnly: false,
            destructive: true,
            run: sync { tools, _ in
                guard let client = tools.server.transport.connectedClient else {
                    throw ToolError("No simulator app is connected")
                }
                tools.server.terminateConnectedClient()
                return ["terminated": ProviderTools.client(client)]
            }
        ),
    ]

    // MARK: - Status & mode

    private func status() -> [String: Any] {
        let transport = server.transport
        var json: [String: Any] = [
            "mode": modeController.mode.rawValue,
            "isSwitching": modeController.isSwitching,
            "provider": Self.describe(transport.status),
            "simulatorApp": transport.connectedClient.map(Self.client) ?? NSNull(),
            "activeConfiguration": store.activeConfigurationName.isEmpty ? NSNull() : store.activeConfigurationName,
            "workingSet": [
                "deviceCount": store.devices.count,
                "enabledDeviceCount": store.enabledDevices.count,
            ],
            "capture": [
                "recording": capture.isRunning,
                "inspecting": capture.isInspecting,
                "deviceCount": capture.devices.count,
            ],
            "lastActivity": transport.lastActivity,
        ]
        if let supplied = server.clientSuppliedConfiguration {
            json["appSuppliedConfiguration"] = [
                "name": supplied.name,
                "deviceCount": supplied.devices.count,
                "source": supplied.sourceDescription,
                "note": Self.clientSuppliedNote,
            ]
        }
        return json
    }

    private func setMode(_ args: [String: Any], completion: @escaping ToolCompletion) {
        guard let raw = args["mode"] as? String, let target = ProviderMode(rawValue: raw.lowercased()) else {
            completion(.failure(ToolError("mode must be one of: off, mock, passthrough")))
            return
        }
        // Re-selecting the current mode would bounce the server and drop the
        // connected app for nothing.
        if modeController.mode == target && !modeController.isSwitching {
            completion(.success(status()))
            return
        }
        modeController.select(target)

        let deadline = Date().addingTimeInterval(Self.modeSwitchTimeout)
        func poll() {
            if !modeController.isSwitching {
                completion(.success(status()))
            } else if Date() > deadline {
                completion(.failure(ToolError("Switching to \(target.title) did not finish within \(Int(Self.modeSwitchTimeout)) s")))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
    }

    private static func describe(_ status: ProtocolServer.Status) -> String {
        switch status {
            case .stopped: "stopped"
            case .listening: "listening"
            case .clientConnected: "clientConnected"
            case .blocked(let reason): "blocked: \(reason)"
        }
    }

    private static func client(_ client: SocketClientInfo) -> [String: Any] {
        [
            "pid": Int(client.pid),
            "processName": client.processName,
            "bundleId": client.bundleId ?? NSNull(),
            "libraryVersion": client.libraryVersion ?? NSNull(),
        ]
    }

    // MARK: - Configurations

    private func configuration(_ args: [String: Any]) throws -> MockConfiguration {
        guard let ref = args["configuration"] as? String else {
            throw ToolError("configuration (id or name) is required")
        }
        let all = store.allConfigurations
        if let match = all.first(where: { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame })
            ?? all.first(where: { $0.name == ref }) {
            return match
        }
        let loose = all.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        guard loose.count == 1 else {
            throw ToolError("No configuration \"\(ref)\". Available: \(all.map(\.name).joined(separator: ", "))")
        }
        return loose[0]
    }

    private func userConfiguration(_ args: [String: Any], action: String) throws -> MockConfiguration {
        let config = try configuration(args)
        guard !config.isBuiltIn else {
            throw ToolError("\"\(config.name)\" is built in and cannot be \(action); duplicate it first")
        }
        return config
    }

    /// Validates a name for a new or overwritten user configuration. Built-in
    /// names are always refused, so selecting by name stays unambiguous.
    private func newConfigurationName(_ value: Any?, replace: Bool) throws -> String {
        guard let raw = value as? String else {
            throw ToolError("name must be a string")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ToolError("name must not be empty")
        }
        if StockConfigurations.all.contains(where: { $0.name == name }) {
            throw ToolError("\"\(name)\" is the name of a built-in configuration")
        }
        if !replace, store.configurations.contains(where: { $0.name == name }) {
            throw ToolError("A configuration named \"\(name)\" already exists; pass replace: true to overwrite it")
        }
        return name
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(store.allConfigurations.map(\.name))
        var name = base
        var counter = 2
        while taken.contains(name) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    private func storeConfiguration(name: String, devices: [MockDevice], select: Bool) -> [String: Any] {
        let config = MockConfiguration(name: name, devices: devices)
        store.upsertConfiguration(config)
        if select {
            store.loadConfiguration(config)
        }
        return annotated(ControlDTO.configuration(config, isActive: select))
    }

    // MARK: - Working set

    private func device(_ args: [String: Any]) throws -> MockDevice {
        guard let ref = args["device"] as? String else {
            throw ToolError("device (id or name) is required")
        }
        let devices = store.devices
        if let match = devices.first(where: { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame }) {
            return match
        }
        var named = devices.filter { $0.name == ref }
        if named.isEmpty {
            named = devices.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        }
        switch named.count {
            case 1:
                return named[0]
            case 0:
                throw ToolError("No device \"\(ref)\" in the working set. Available: \(devices.map(\.name).joined(separator: ", "))")
            default:
                throw ToolError("Several devices are named \"\(ref)\"; use the id instead")
        }
    }

    private func workingSetResult() -> [String: Any] {
        annotated([
            "activeConfiguration": store.activeConfigurationName.isEmpty ? NSNull() : store.activeConfigurationName,
            "devices": store.devices.map { device in
                [
                    "id": device.id.uuidString,
                    "name": device.name,
                    "isEnabled": device.isEnabled,
                    "isConnectable": device.isConnectable,
                    "rssi": device.rssi,
                    "advertisedServiceUUIDs": device.advertisedServiceUUIDs,
                    "serviceCount": device.services.count,
                ] as [String: Any]
            },
        ])
    }

    private static let clientSuppliedNote = """
        The connected app uploaded its own configuration, which is what it is being served right now. \
        Working-set and configuration edits apply once it disconnects or clears it.
        """

    /// Adds the notes an agent needs to interpret a working-set change: when it
    /// will not be visible to the simulator right now.
    private func annotated(_ json: [String: Any]) -> [String: Any] {
        var json = json
        if server.clientSuppliedConfiguration != nil {
            json["note"] = Self.clientSuppliedNote
        } else if modeController.mode != .mock {
            json["note"] = "The provider is in \(modeController.mode.title) mode; switch to mock with set_mode to serve the working set."
        }
        return json
    }

    // MARK: - Capture

    private func startCapture(_ args: [String: Any]) throws -> [String: Any] {
        guard !isSavingCapture else {
            throw ToolError("A capture is being saved; wait for capture_save to finish")
        }
        let filter = CaptureFilter(advertisingService: args["advertisingService"] as? String ?? "")
        // Both run in order on the session's queue, so this restarts cleanly.
        capture.stop()
        capture.start(serviceUUIDs: filter.requestedServiceUUIDs)
        return [
            "recording": true,
            "hint": "Wait a few seconds for advertisements, then call capture_results.",
        ]
    }

    private func captureFilter(_ args: [String: Any]) -> CaptureFilter {
        CaptureFilter(
            onlyConnectable: args["onlyConnectable"] as? Bool ?? false,
            showUnnamed: args["includeUnnamed"] as? Bool ?? false,
            nameContains: args["nameContains"] as? String ?? "",
            advertisingService: args["advertisingService"] as? String ?? ""
        )
    }

    private func captureResults(_ args: [String: Any]) throws -> [String: Any] {
        let limit = try args["limit"].map { try ControlDTO.int($0, field: "limit") } ?? 50
        let matching = capture.devices.filter(captureFilter(args).matches)
        return [
            "recording": capture.isRunning,
            "totalSeen": capture.devices.count,
            "matching": matching.count,
            "devices": matching.prefix(max(0, limit)).map(ControlDTO.capturedDevice),
        ]
    }

    private func saveCapture(_ args: [String: Any], progress: ToolProgress?, completion: @escaping ToolCompletion) {
        guard !isSavingCapture else {
            completion(.failure(ToolError("A capture is already being saved")))
            return
        }

        let name: String
        let selected: [CapturedDevice]
        do {
            let rawName = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? CaptureFilter.defaultConfigurationName()
            name = try newConfigurationName(rawName, replace: args["replace"] as? Bool ?? false)
            if let ids = args["deviceIds"] {
                let wanted = try ControlDTO.stringArray(ids, field: "deviceIds")
                let byID = Dictionary(capture.devices.map { ($0.id.lowercased(), $0) }) { first, _ in first }
                let missing = wanted.filter { byID[$0.lowercased()] == nil }
                guard missing.isEmpty else {
                    throw ToolError("Not in the capture: \(missing.joined(separator: ", "))")
                }
                selected = wanted.compactMap { byID[$0.lowercased()] }
            } else {
                selected = capture.devices.filter(captureFilter(args).matches)
            }
            guard !selected.isEmpty else {
                throw ToolError(capture.devices.isEmpty
                    ? "Nothing captured; call capture_start and wait a few seconds first"
                    : "No captured device matches; check capture_results or pass includeUnnamed")
            }
        } catch let error as ToolError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(ToolError(error.localizedDescription)))
            return
        }

        let select = args["select"] as? Bool ?? true
        let finish: ([MockDevice]) -> Void = { [self] devices in
            completion(.success(storeConfiguration(name: name, devices: devices, select: select)))
        }

        guard args["inspect"] as? Bool ?? true else {
            capture.stop()
            finish(selected.map { $0.makeMockDevice() })
            return
        }

        isSavingCapture = true
        var progressObserver: AnyCancellable?
        if let progress {
            progressObserver = capture.$inspectionProgress
                .filter(\.isActive)
                .removeDuplicates()
                .sink { state in
                    progress(Double(state.currentIndex), Double(state.total), "\(state.deviceName): \(state.phase)")
                }
        }
        capture.inspectDevices(selected) { [self] devices in
            progressObserver?.cancel()
            isSavingCapture = false
            capture.stop()
            finish(devices)
        }
    }

    // MARK: - Passthrough

    private func passthroughActivity() -> [String: Any] {
        let activity = server.passthroughActivity
        let formatter = ISO8601DateFormatter()
        var json: [String: Any] = [
            "mode": modeController.mode.rawValue,
            "trafficActive": activity.trafficActive,
            "devices": activity.devices.map { device in
                [
                    "id": device.id,
                    "name": device.displayName,
                    "lastOperation": device.lastOperation,
                    "lastDetail": device.lastDetail,
                    "lastAt": formatter.string(from: device.lastAt),
                    "operationCount": device.count,
                    "isActive": device.isActive,
                ] as [String: Any]
            },
        ]
        if modeController.mode != .passthrough {
            json["note"] = "Activity is only recorded in passthrough mode."
        }
        return json
    }
}
