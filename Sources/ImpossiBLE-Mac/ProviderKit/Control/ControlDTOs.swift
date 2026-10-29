import Foundation

/// A tool failure reported back to the agent as an `isError` result.
struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Agent-facing JSON for the mock model. The persisted `Codable` form is not
/// used on the wire on purpose: it encodes values as base64 and properties as a
/// bitmask, which agents get wrong. Here values are hex (or UTF-8 text) and
/// properties, pairing, and security are names.
enum ControlDTO {
    // MARK: - Names

    static let propertyNames: [(name: String, rawValue: UInt)] = [
        ("broadcast", 0x01),
        ("read", 0x02),
        ("writeWithoutResponse", 0x04),
        ("write", 0x08),
        ("notify", 0x10),
        ("indicate", 0x20),
        ("authenticatedSignedWrites", 0x40),
        ("extendedProperties", 0x80),
    ]

    static let pairingModeNames: [(name: String, mode: PairingMode)] = [
        ("none", .none), ("justWorks", .justWorks), ("passkey", .passkey),
    ]

    static let securityLevelNames: [(name: String, level: SecurityLevel)] = [
        ("none", .none), ("encryptionRequired", .encryptionRequired),
    ]

    // MARK: - Encoding

    static func configurationSummary(_ config: MockConfiguration, isActive: Bool) -> [String: Any] {
        [
            "id": config.id.uuidString,
            "name": config.name,
            "builtIn": config.isBuiltIn,
            "active": isActive,
            "deviceCount": config.devices.count,
        ]
    }

    static func configuration(_ config: MockConfiguration, isActive: Bool) -> [String: Any] {
        var json = configurationSummary(config, isActive: isActive)
        json["devices"] = config.devices.map(device)
        return json
    }

    static func device(_ device: MockDevice) -> [String: Any] {
        var json: [String: Any] = [
            "id": device.id.uuidString,
            "name": device.name,
            "rssi": device.rssi,
            "isConnectable": device.isConnectable,
            "isEnabled": device.isEnabled,
            "advertisedServiceUUIDs": device.advertisedServiceUUIDs,
            "pairingMode": name(of: device.pairingMode),
            "services": device.services.map(service),
        ]
        if device.pairingMode == .passkey {
            json["passkey"] = device.passkey
        }
        if let data = device.manufacturerData {
            json["manufacturerData"] = hex(data)
        }
        return json
    }

    static func service(_ service: MockService) -> [String: Any] {
        [
            "uuid": service.uuid,
            "isPrimary": service.isPrimary,
            "characteristics": service.characteristics.map(characteristic),
        ]
    }

    static func characteristic(_ ch: MockCharacteristic) -> [String: Any] {
        var json: [String: Any] = [
            "uuid": ch.uuid,
            "properties": propertyNames.filter { ch.properties & $0.rawValue != 0 }.map(\.name),
            "securityLevel": name(of: ch.securityLevel),
            "descriptors": ch.descriptors.map(descriptor),
        ]
        addValue(ch.value, to: &json)
        return json
    }

    static func descriptor(_ desc: MockDescriptor) -> [String: Any] {
        var json: [String: Any] = ["uuid": desc.uuid]
        addValue(desc.value, to: &json)
        return json
    }

    static func capturedDevice(_ device: CapturedDevice) -> [String: Any] {
        var json: [String: Any] = [
            "id": device.id,
            "name": device.displayName,
            "hasName": device.hasName,
            "rssi": device.rssi ?? NSNull(),
            "isConnectable": device.isConnectable,
            "advertisedServiceUUIDs": device.advertisedServiceUUIDs,
            "seenCount": device.seenCount,
        ]
        if let data = device.manufacturerData {
            json["manufacturerData"] = hex(data)
        }
        return json
    }

    static func activityEvent(_ event: MockActivityEvent, deviceNames: [String: String], formatter: ISO8601DateFormatter) -> [String: Any] {
        var json: [String: Any] = [
            "seq": event.sequence,
            "at": formatter.string(from: event.date),
            "kind": event.kind,
        ]
        if let deviceID = event.deviceID {
            json["deviceId"] = deviceID
            if let name = deviceNames[deviceID] {
                json["device"] = name
            }
        }
        if let service = event.serviceUUID {
            json["service"] = service
        }
        if let characteristic = event.characteristicUUID {
            json["characteristic"] = characteristic
        }
        if let descriptor = event.descriptorUUID {
            json["descriptor"] = descriptor
        }
        if let detail = event.detail {
            json["detail"] = detail
        }
        addValue(event.value, to: &json)
        return json
    }

    static func failureRule(_ rule: MockFailureRule, deviceNames: [String: String]) -> [String: Any] {
        var json: [String: Any] = [
            "id": rule.id,
            "operation": rule.operation.rawValue,
            "deviceId": rule.deviceID,
            "remaining": rule.remaining.map { $0 as Any } ?? "untilCleared",
        ]
        if let name = deviceNames[rule.deviceID] {
            json["device"] = name
        }
        if let characteristic = rule.characteristicUUID {
            json["characteristic"] = characteristic
        }
        switch rule.behavior {
            case .error(let message, let attError):
                json["behavior"] = "error"
                json["error"] = message
                if rule.operation == .read || rule.operation == .write {
                    json["attError"] = attError
                }
            case .noResponse:
                json["behavior"] = "noResponse"
        }
        return json
    }

    static func pm5State(_ state: PM5State) -> [String: Any] {
        func field(_ field: PM5State.Field?) -> Any {
            guard let field else { return NSNull() }
            return field.name ?? "unknown(\(field.raw))"
        }
        var json: [String: Any] = [
            "summary": state.summary,
            "operationalState": field(state.operationalState),
            "workoutState": field(state.workoutState),
            "rowingState": field(state.rowingState),
            "workoutType": field(state.workoutType),
            "intervalType": field(state.intervalType),
            "displayType": field(state.displayType),
            "displayUnits": field(state.displayUnits),
            "batteryPercent": state.batteryPercent.map { $0 as Any } ?? NSNull(),
        ]
        if let screen = state.screenCommand {
            json["lastScreenCommand"] = [
                "screenType": field(screen.type),
                "value": screen.value,
                "status": field(screen.status),
            ]
        }
        return json
    }

    private static func addValue(_ value: Data?, to json: inout [String: Any]) {
        guard let value else { return }
        json["value"] = hex(value)
        if let text = printableText(value) {
            json["valueText"] = text
        }
    }

    private static func name(of mode: PairingMode) -> String {
        pairingModeNames.first { $0.mode == mode }?.name ?? "none"
    }

    private static func name(of level: SecurityLevel) -> String {
        securityLevelNames.first { $0.level == level }?.name ?? "none"
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    /// The value as text when it is plain printable UTF-8, so agents can read
    /// strings like manufacturer names without decoding hex themselves.
    /// Trailing NULs are dropped: fixed-size string fields are padded with them.
    private static func printableText(_ data: Data) -> String? {
        let trimmed = data.prefix { $0 != 0 }
        guard !trimmed.isEmpty, data.dropFirst(trimmed.count).allSatisfy({ $0 == 0 }),
              let text = String(data: trimmed, encoding: .utf8) else { return nil }
        let printable = text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
        }
        return printable ? text : nil
    }

    // MARK: - Decoding

    /// Applies the keys present in `json` on top of `base`, so the same code
    /// creates devices (base: a default device) and patches them (base: the
    /// existing one). `services`, when present, replaces the whole tree.
    static func applyDevice(_ json: [String: Any], to base: MockDevice) throws -> MockDevice {
        var device = base
        if let name = json["name"] {
            device.name = try string(name, field: "name")
        }
        if let rssi = json["rssi"] {
            device.rssi = try int(rssi, field: "rssi")
        }
        if let connectable = json["isConnectable"] {
            device.isConnectable = try bool(connectable, field: "isConnectable")
        }
        if let enabled = json["isEnabled"] {
            device.isEnabled = try bool(enabled, field: "isEnabled")
        }
        if let uuids = json["advertisedServiceUUIDs"] {
            device.advertisedServiceUUIDs = try stringArray(uuids, field: "advertisedServiceUUIDs").map(normalizedUUID)
        }
        if json.keys.contains("manufacturerData") {
            device.manufacturerData = try optionalHex(json["manufacturerData"], field: "manufacturerData")
        }
        if let mode = json["pairingMode"] {
            let raw = try string(mode, field: "pairingMode")
            guard let match = pairingModeNames.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) else {
                throw ToolError("pairingMode must be one of: \(pairingModeNames.map(\.name).joined(separator: ", "))")
            }
            device.pairingMode = match.mode
        }
        if let passkey = json["passkey"] {
            let value = try string(passkey, field: "passkey")
            guard value.count == 6, value.allSatisfy(\.isNumber) else {
                throw ToolError("passkey must be exactly six digits")
            }
            device.passkey = value
        }
        if let services = json["services"] {
            guard let list = services as? [[String: Any]] else {
                throw ToolError("services must be an array of objects")
            }
            device.services = try list.enumerated().map { try decodeService($1, path: "services[\($0)]") }
        }
        return device
    }

    private static func decodeService(_ json: [String: Any], path: String) throws -> MockService {
        var service = MockService()
        service.uuid = try requiredUUID(json, path: path)
        if let primary = json["isPrimary"] {
            service.isPrimary = try bool(primary, field: "\(path).isPrimary")
        }
        if let chars = json["characteristics"] {
            guard let list = chars as? [[String: Any]] else {
                throw ToolError("\(path).characteristics must be an array of objects")
            }
            service.characteristics = try list.enumerated().map {
                try decodeCharacteristic($1, path: "\(path).characteristics[\($0)]")
            }
        }
        return service
    }

    private static func decodeCharacteristic(_ json: [String: Any], path: String) throws -> MockCharacteristic {
        var ch = MockCharacteristic()
        ch.uuid = try requiredUUID(json, path: path)
        if let properties = json["properties"] {
            ch.properties = try decodeProperties(properties, field: "\(path).properties")
        }
        ch.value = try decodeValue(json, path: path)
        if let level = json["securityLevel"] {
            let raw = try string(level, field: "\(path).securityLevel")
            guard let match = securityLevelNames.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) else {
                throw ToolError("\(path).securityLevel must be one of: \(securityLevelNames.map(\.name).joined(separator: ", "))")
            }
            ch.securityLevel = match.level
        }
        if let descs = json["descriptors"] {
            guard let list = descs as? [[String: Any]] else {
                throw ToolError("\(path).descriptors must be an array of objects")
            }
            ch.descriptors = try list.enumerated().map {
                try decodeDescriptor($1, path: "\(path).descriptors[\($0)]")
            }
        }
        return ch
    }

    private static func decodeDescriptor(_ json: [String: Any], path: String) throws -> MockDescriptor {
        var desc = MockDescriptor()
        desc.uuid = try requiredUUID(json, path: path)
        desc.value = try decodeValue(json, path: path)
        return desc
    }

    /// Accepts property names or the raw CBCharacteristicProperties bitmask.
    private static func decodeProperties(_ value: Any, field: String) throws -> UInt {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.uintValue
        }
        let names = try stringArray(value, field: field)
        return try names.reduce(0) { mask, name in
            guard let match = propertyNames.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolError("\(field): unknown property \"\(name)\"; use \(propertyNames.map(\.name).joined(separator: ", "))")
            }
            return mask | match.rawValue
        }
    }

    /// `value` is hex; `valueText` is UTF-8 text. Both may be given when they
    /// agree — the encoder emits both, so a device read with get_device can be
    /// sent back unchanged — but conflicting ones are refused.
    static func decodeValue(_ json: [String: Any], path: String) throws -> Data? {
        let hexValue = json["value"].flatMap { $0 is NSNull ? nil : $0 }
        let textValue = json["valueText"].flatMap { $0 is NSNull ? nil : $0 }
        switch (hexValue, textValue) {
            case (nil, nil):
                return nil
            case (let hex?, nil):
                return try optionalHex(hex, field: "\(path).value")
            case (nil, let text?):
                return Data(try string(text, field: "\(path).valueText").utf8)
            case (let hex?, let text?):
                let data = try optionalHex(hex, field: "\(path).value")
                guard let data, printableText(data) == (try string(text, field: "\(path).valueText")) else {
                    throw ToolError("\(path): value and valueText disagree; give only one")
                }
                return data
        }
    }

    private static func requiredUUID(_ json: [String: Any], path: String) throws -> String {
        guard let raw = json["uuid"] else {
            throw ToolError("\(path).uuid is required")
        }
        let uuid = normalizedUUID(try string(raw, field: "\(path).uuid"))
        guard !uuid.isEmpty else {
            throw ToolError("\(path).uuid must not be empty")
        }
        return uuid
    }

    private static func normalizedUUID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: - Primitive coercion

    static func string(_ value: Any, field: String) throws -> String {
        guard let string = value as? String else {
            throw ToolError("\(field) must be a string")
        }
        return string
    }

    static func bool(_ value: Any, field: String) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ToolError("\(field) must be a boolean")
        }
        return number.boolValue
    }

    static func int(_ value: Any, field: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ToolError("\(field) must be a number")
        }
        return number.intValue
    }

    static func stringArray(_ value: Any, field: String) throws -> [String] {
        guard let strings = value as? [String] else {
            throw ToolError("\(field) must be an array of strings")
        }
        return strings
    }

    /// Hex with optional `0x` prefix and space, colon, or dash separators.
    static func optionalHex(_ value: Any?, field: String) throws -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        var digits = try string(value, field: field)
        if digits.lowercased().hasPrefix("0x") {
            digits.removeFirst(2)
        }
        digits.removeAll { $0 == " " || $0 == ":" || $0 == "-" }
        guard digits.count.isMultiple(of: 2) else {
            throw ToolError("\(field) must be hex with an even number of digits")
        }
        var data = Data(capacity: digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                throw ToolError("\(field) must be hex with an even number of digits")
            }
            data.append(byte)
            index = next
        }
        return data
    }
}
