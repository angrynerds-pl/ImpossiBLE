import Foundation

/// One thing that happened in mock mode: a request from the simulator app, a
/// value an agent pushed, or a failure that was injected. Agents read these to
/// check what the app under test actually did.
struct MockActivityEvent {
    let sequence: Int
    let date: Date
    let kind: String
    let deviceID: String?
    let serviceUUID: String?
    let characteristicUUID: String?
    let descriptorUUID: String?
    let value: Data?
    let detail: String?
}

/// Bounded, so a long session with a chatty app cannot grow it without limit.
/// Sequence numbers keep increasing across trims and clears, so a reader that
/// polls with `after:` never sees an event twice.
struct MockActivityLog {
    static let capacity = 2000

    private(set) var events: [MockActivityEvent] = []
    private var nextSequence = 1

    var lastSequence: Int { nextSequence - 1 }

    mutating func append(
        _ kind: String,
        deviceID: String? = nil,
        serviceUUID: String? = nil,
        characteristicUUID: String? = nil,
        descriptorUUID: String? = nil,
        value: Data? = nil,
        detail: String? = nil
    ) {
        events.append(MockActivityEvent(
            sequence: nextSequence,
            date: Date(),
            kind: kind,
            deviceID: deviceID,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            descriptorUUID: descriptorUUID,
            value: value,
            detail: detail
        ))
        nextSequence += 1
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    mutating func clear() {
        events.removeAll()
    }

    func events(after sequence: Int, limit: Int) -> [MockActivityEvent] {
        Array(events.lazy.filter { $0.sequence > sequence }.prefix(limit))
    }
}

/// Requests a failure can be injected into.
enum MockOperation: String, CaseIterable {
    case connect
    case discoverServices
    case discoverCharacteristics
    case read
    case write
    case readDescriptor
    case writeDescriptor
    case setNotify
    case readRSSI

    /// Whether a rule for this operation can be narrowed to one characteristic.
    var isCharacteristicLevel: Bool {
        switch self {
            case .read, .write, .readDescriptor, .writeDescriptor, .setNotify: true
            default: false
        }
    }
}

/// A failure armed by an agent and consumed by the next matching request.
struct MockFailureRule {
    enum Behavior {
        /// Answer with an error. `attError` is a `CBATTError` code; it is only
        /// carried for reads and writes, the requests whose wire replies have
        /// an error domain.
        case error(message: String, attError: Int)
        /// Never answer, like a device that went silent.
        case noResponse
    }

    let id: Int
    let operation: MockOperation
    let deviceID: String
    /// Uppercased; nil matches every characteristic of the device.
    let characteristicUUID: String?
    let behavior: Behavior
    /// nil keeps the rule armed until it is cleared.
    var remaining: Int?

    /// How the rule shows up in the activity log.
    var summary: String {
        switch behavior {
            case .error(let message, _): "injected failure: \(message)"
            case .noResponse: "injected failure: no response"
        }
    }

    func matches(_ operation: MockOperation, deviceID: String, characteristicUUID: String?) -> Bool {
        guard operation == self.operation, deviceID == self.deviceID else { return false }
        guard let wanted = self.characteristicUUID else { return true }
        return characteristicUUID?.uppercased() == wanted
    }
}

/// The characteristic id the simulator library uses on the wire, built exactly
/// like discovery builds it: `peripheral:serviceUUID:serviceIndex:charUUID:charIndex`.
struct MockCharacteristicAddress {
    let deviceID: String
    let serviceUUID: String
    let characteristicUUID: String
    let wireID: String
}

extension MockDevice {
    /// Finds a characteristic by UUID, optionally within one service. UUIDs
    /// compare case-insensitively; a UUID found in several services needs the
    /// service to disambiguate.
    func characteristicAddress(service: String?, characteristic: String) throws -> MockCharacteristicAddress {
        let wantedService = service?.uppercased()
        let wantedCharacteristic = characteristic.uppercased()
        var matches: [MockCharacteristicAddress] = []
        for (serviceIndex, svc) in services.enumerated() {
            if let wantedService, svc.uuid.uppercased() != wantedService { continue }
            for (charIndex, ch) in svc.characteristics.enumerated() where ch.uuid.uppercased() == wantedCharacteristic {
                let deviceID = id.uuidString
                matches.append(MockCharacteristicAddress(
                    deviceID: deviceID,
                    serviceUUID: svc.uuid,
                    characteristicUUID: ch.uuid,
                    wireID: "\(deviceID):\(svc.uuid):\(serviceIndex):\(ch.uuid):\(charIndex)"
                ))
            }
        }
        switch matches.count {
            case 1:
                return matches[0]
            case 0:
                let scope = service.map { "service \($0) of " } ?? ""
                throw ToolError("No characteristic \(characteristic) in \(scope)\(name)")
            default:
                let services = matches.map(\.serviceUUID).joined(separator: ", ")
                throw ToolError("Characteristic \(characteristic) exists in several services of \(name) (\(services)); pass service")
        }
    }
}
