import Foundation

// MARK: - CSAFE framing

/// CSAFE frames exactly as ErgData builds them: always the extended format,
/// `F0 <dest> <src> <payload> <checksum> F2`, checksum the XOR of the payload,
/// and every byte in F0…F3 stuffed as `F3, byte - F0`.
enum CSAFE {
    static let extendedStart: UInt8 = 0xF0
    static let standardStart: UInt8 = 0xF1
    static let end: UInt8 = 0xF2
    static let stuff: UInt8 = 0xF3
    /// The PM's default address, which ErgData always uses.
    static let pmAddress: UInt8 = 0xFD
    /// ErgData refuses frames longer than this, and so do we.
    static let maxFrameLength = 120

    static func frame(_ payload: [UInt8]) throws -> [UInt8] {
        var frame: [UInt8] = [extendedStart, pmAddress, 0x00]
        let checksum = payload.reduce(0, ^)
        for byte in payload + [checksum] {
            if byte >= extendedStart && byte <= stuff {
                frame += [stuff, byte - extendedStart]
            } else {
                frame.append(byte)
            }
        }
        frame.append(end)
        guard frame.count <= maxFrameLength else {
            throw ToolError("CSAFE frame is \(frame.count) bytes; the PM accepts at most \(maxFrameLength)")
        }
        return frame
    }

    struct Unframed: Equatable {
        /// Status byte first, then the response data, without the checksum.
        let content: [UInt8]
        let checksumValid: Bool
    }

    /// Unstuffs a complete frame (standard or extended) and checks its checksum.
    static func unframe(_ frame: [UInt8]) -> Unframed? {
        guard let first = frame.first, frame.last == end else { return nil }
        let bodyStart: Int
        switch first {
            case standardStart: bodyStart = 1
            case extendedStart: bodyStart = 3
            default: return nil
        }
        guard frame.count >= bodyStart + 2 else { return nil }

        var body: [UInt8] = []
        var index = bodyStart
        while index < frame.count - 1 {
            let byte = frame[index]
            if byte == stuff {
                guard index + 1 < frame.count - 1, frame[index + 1] <= stuff - extendedStart else { return nil }
                body.append(extendedStart + frame[index + 1])
                index += 2
            } else {
                body.append(byte)
                index += 1
            }
        }
        guard let checksum = body.popLast(), !body.isEmpty else { return nil }
        return Unframed(content: body, checksumValid: body.reduce(0, ^) == checksum)
    }
}

// MARK: - PM5 commands

/// The PM5's soft keys, sent as "virtual key" screen-state values — the same
/// mechanism ErgData uses to continue after an undefined rest (key D).
enum PM5Key: String, CaseIterable {
    case a = "A", b = "B", c = "C", d = "D", e = "E"
    case units, display, menu

    var screenValue: UInt8 {
        switch self {
            case .a: 47
            case .b: 48
            case .c: 49
            case .d: 50
            case .e: 51
            case .units: 52
            case .display: 53
            case .menu: 54
        }
    }

    var title: String {
        switch self {
            case .a, .b, .c, .d, .e: rawValue
            case .units: "Units"
            case .display: "Display"
            case .menu: "Menu"
        }
    }
}

/// Workout-screen actions that are not keys.
enum PM5ScreenCommand: String, CaseIterable {
    case prepareToWorkout
    case terminateWorkout
    case rearmWorkout
    case goToMainScreen

    var screenValue: UInt8 {
        switch self {
            case .prepareToWorkout: 1
            case .terminateWorkout: 2
            case .rearmWorkout: 3
            case .goToMainScreen: 6
        }
    }
}

enum PM5Command {
    static let setConfigWrapper: UInt8 = 0x76
    static let setScreenState: UInt8 = 0x13
    static let workoutScreen: UInt8 = 0x01

    /// `SETPMCFG { SETSCREENSTATE workout, value }`, as ErgData's
    /// `buildSetScreenState` emits it.
    static func screenState(_ value: UInt8) -> [UInt8] {
        [setConfigWrapper, 0x04, setScreenState, 0x02, workoutScreen, value]
    }
}

// MARK: - Model shared with the UI and MCP

public struct PM5Connection: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// Connected, both CSAFE characteristics discovered, and the app has
    /// subscribed to responses — the only state in which a command's reply can
    /// be recognized and kept away from the app.
    public let isReady: Bool
}

struct PM5Response {
    let status: UInt8
    let content: [UInt8]
    let frame: [UInt8]
    let checksumValid: Bool
}

struct PM5Injection {
    let deviceID: String?
    let payload: [UInt8]
    let label: String
    let swallowResponse: Bool
    /// Called on the main thread; nil response when it was not awaited.
    let completion: (Result<PM5Response?, ToolError>) -> Void
}

/// Lets the user (panel) and agents (MCP) press PM5 buttons and send CSAFE
/// commands to a real PM5 while the simulator app is connected to it through
/// Passthrough. Off unless switched on. Main-thread only; the work happens in
/// `PM5RemoteEngine` on the server's I/O queue.
public final class PM5Remote: ObservableObject {
    public static let enabledKey = "PM5RemoteEnabled"

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var connections: [PM5Connection] = []
    @Published public private(set) var lastResult = ""
    @Published public private(set) var pendingCount = 0

    /// Wired by `MockServer` to hand work to the engine on its I/O queue.
    var submitToEngine: ((PM5Injection) -> Void)?
    var setEngineEnabled: ((Bool) -> Void)?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        setEngineEnabled?(enabled)
        lastResult = enabled ? "Remote on" : "Remote off"
    }

    func press(_ key: PM5Key, deviceID: String? = nil,
               completion: ((Result<PM5Response?, ToolError>) -> Void)? = nil) {
        submit(payload: PM5Command.screenState(key.screenValue), label: "Key \(key.title)",
               deviceID: deviceID, swallowResponse: true, completion: completion)
    }

    func send(_ command: PM5ScreenCommand, deviceID: String? = nil,
              completion: ((Result<PM5Response?, ToolError>) -> Void)? = nil) {
        submit(payload: PM5Command.screenState(command.screenValue), label: command.rawValue,
               deviceID: deviceID, swallowResponse: true, completion: completion)
    }

    func submit(payload: [UInt8], label: String, deviceID: String?, swallowResponse: Bool,
                completion: ((Result<PM5Response?, ToolError>) -> Void)?) {
        guard isEnabled else {
            completion?(.failure(ToolError("The PM5 remote is off; turn it on in the panel or with pm5_set_remote_enabled")))
            return
        }
        guard let submitToEngine else {
            completion?(.failure(ToolError("The PM5 remote is not available")))
            return
        }
        pendingCount += 1
        submitToEngine(PM5Injection(deviceID: deviceID, payload: payload, label: label,
                                    swallowResponse: swallowResponse) { [weak self] result in
            guard let self else { return }
            pendingCount -= 1
            switch result {
                case .success: lastResult = "\(label): sent"
                case .failure(let error): lastResult = "\(label): \(error.message)"
            }
            completion?(result)
        })
    }

    func publish(_ connections: [PM5Connection]) {
        if connections != self.connections {
            self.connections = connections
        }
    }
}

// MARK: - Engine (server I/O queue)

/// Injects CSAFE frames into the app's live passthrough connection to a PM5.
///
/// The app (ErgData) does no request/response matching — it acts on whatever
/// CSAFE reply arrives — so a reply to an injected command must never reach
/// it. While a command is in flight the engine therefore holds back the app's
/// own command writes, consumes the write confirmations and the matching reply,
/// and passes everything else through untouched. It only starts when the app
/// is between commands: not halfway through writing a frame, and not waiting
/// for a reply.
final class PM5RemoteEngine {
    private struct Peripheral {
        var name = ""
        var isConnected = false
        var commandCharacteristicID: String?
        var responseCharacteristicID: String?
        var responsesSubscribed = false
        /// The app wrote part of a frame; injecting now would split it.
        var appFrameOpen = false
        /// The app finished a frame and has not had its reply yet.
        var appAwaitingReplySince: Date?

        var isReady: Bool {
            isConnected && commandCharacteristicID != nil && responseCharacteristicID != nil && responsesSubscribed
        }
    }

    private struct Active {
        let injection: PM5Injection
        let peripheralID: String
        let commandCharacteristicID: String
        let responseCharacteristicID: String
        var pendingWriteConfirmations: Int
        var heldAppMessages: [[String: Any]] = []
        var responseChunks: [[String: Any]] = []
        var responseBytes: [UInt8] = []
        let token: Int
    }

    static let commandUUIDPrefix = "CE060021"
    static let responseUUIDPrefix = "CE060022"
    /// PM5 writes are chunked like ErgData's fallback (no DLE): 20 bytes fits
    /// the smallest ATT payload.
    static let chunkSize = 20
    static let responseTimeout: TimeInterval = 2
    /// How long to wait for the app to be between commands before going ahead.
    static let idleWait: TimeInterval = 2
    /// A reply the app is waiting for longer than this is assumed lost.
    static let staleReplyAge: TimeInterval = 1.5

    var isEnabled = false

    private var peripherals: [String: Peripheral] = [:]
    private var names: [String: String] = [:]
    private var queue: [PM5Injection] = []
    private var active: Active?
    private var waitingSince: Date?
    private var nextToken = 0

    private let sendToBridge: ([String: Any]) -> Void
    private let sendToApp: ([String: Any]) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let publish: ([PM5Connection]) -> Void
    private let note: (String) -> Void

    init(sendToBridge: @escaping ([String: Any]) -> Void,
         sendToApp: @escaping ([String: Any]) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         publish: @escaping ([PM5Connection]) -> Void,
         note: @escaping (String) -> Void) {
        self.sendToBridge = sendToBridge
        self.sendToApp = sendToApp
        self.schedule = schedule
        self.publish = publish
        self.note = note
    }

    // MARK: Traffic

    /// An app → PM message. Returns true when it is held back for now.
    func appMessage(_ message: [String: Any]) -> Bool {
        guard message["type"] as? String == "write",
              let characteristicID = message["characteristicId"] as? String,
              let peripheralID = peripheralID(forCommandCharacteristic: characteristicID)
        else { return false }

        if active?.peripheralID == peripheralID {
            active?.heldAppMessages.append(message)
            return true
        }
        trackAppWrite(message, peripheralID: peripheralID)
        return false
    }

    /// A PM → app message. Returns true when it is consumed.
    func bridgeMessage(_ message: [String: Any]) -> Bool {
        guard let type = message["type"] as? String, let id = message["id"] as? String else { return false }

        switch type {
            case "didDiscover":
                if let name = message["name"] as? String, !name.isEmpty {
                    names[id] = name
                }
            case "didUpdateName":
                if let name = message["name"] as? String, !name.isEmpty {
                    names[id] = name
                    peripherals[id]?.name = name
                    publishConnections()
                }
            case "didConnect":
                var peripheral = peripherals[id] ?? Peripheral()
                peripheral.isConnected = true
                peripheral.name = names[id] ?? peripheral.name
                peripherals[id] = peripheral
                publishConnections()
            case "didDisconnect", "didFailConnect":
                if active?.peripheralID == id {
                    finish(.failure(ToolError("The PM5 disconnected")))
                }
                peripherals[id] = nil
                publishConnections()
            case "didDiscoverCharacteristics":
                trackCharacteristics(message, peripheralID: id)
            case "didUpdateNotification":
                if let characteristicID = message["characteristicId"] as? String,
                   peripherals[id]?.responseCharacteristicID == characteristicID {
                    peripherals[id]?.responsesSubscribed = (message["enabled"] as? Bool) ?? false
                    publishConnections()
                }
            case "didWriteValue":
                return consumeWriteConfirmation(message, peripheralID: id)
            case "didUpdateValue":
                return handleResponseChunk(message, peripheralID: id)
            default:
                break
        }
        return false
    }

    // MARK: Commands

    func submit(_ injection: PM5Injection) {
        queue.append(injection)
        pump()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            failQueued(ToolError("The PM5 remote was turned off"))
        }
    }

    /// The bridge dropped every connection (client change, mode switch, stop).
    func reset() {
        if active != nil {
            finish(.failure(ToolError("The passthrough connection was reset")), flushHeld: false)
        }
        failQueued(ToolError("The passthrough connection was reset"))
        peripherals.removeAll()
        publishConnections()
    }

    // MARK: Private

    private func pump() {
        guard active == nil, let next = queue.first else { return }
        guard isEnabled else {
            failQueued(ToolError("The PM5 remote is off"))
            return
        }

        let peripheralID: String
        switch resolve(next.deviceID) {
            case .failure(let error):
                queue.removeFirst()
                complete(next, .failure(error))
                pump()
                return
            case .success(let id):
                peripheralID = id
        }

        let peripheral = peripherals[peripheralID]!
        let now = Date()
        let awaitingReply = peripheral.appAwaitingReplySince.map { now.timeIntervalSince($0) < Self.staleReplyAge } ?? false
        if peripheral.appFrameOpen || awaitingReply {
            let since = waitingSince ?? now
            waitingSince = since
            if now.timeIntervalSince(since) < Self.idleWait {
                schedule(0.05) { [weak self] in self?.pump() }
                return
            }
            note("PM5 remote: app stayed busy; sending anyway")
        }
        waitingSince = nil
        queue.removeFirst()
        start(next, peripheralID: peripheralID, peripheral: peripheral)
    }

    private func start(_ injection: PM5Injection, peripheralID: String, peripheral: Peripheral) {
        let frame: [UInt8]
        do {
            frame = try CSAFE.frame(injection.payload)
        } catch {
            complete(injection, .failure(error as? ToolError ?? ToolError("\(error)")))
            pump()
            return
        }

        let chunks = stride(from: 0, to: frame.count, by: Self.chunkSize).map {
            Array(frame[$0..<min($0 + Self.chunkSize, frame.count)])
        }
        nextToken += 1
        let token = nextToken
        active = Active(
            injection: injection,
            peripheralID: peripheralID,
            commandCharacteristicID: peripheral.commandCharacteristicID!,
            responseCharacteristicID: peripheral.responseCharacteristicID!,
            pendingWriteConfirmations: chunks.count,
            token: token
        )
        note("PM5 remote: \(injection.label)")
        for chunk in chunks {
            sendToBridge([
                "type": "write",
                "characteristicId": peripheral.commandCharacteristicID!,
                "value": Data(chunk).base64EncodedString(),
                "writeType": 0,
            ])
        }
        schedule(Self.responseTimeout) { [weak self] in
            guard let self, self.active?.token == token else { return }
            self.finish(.failure(ToolError(injection.swallowResponse
                ? "The PM5 did not answer within \(Int(Self.responseTimeout)) s"
                : "The PM5 did not confirm the write within \(Int(Self.responseTimeout)) s")))
        }
    }

    private func consumeWriteConfirmation(_ message: [String: Any], peripheralID: String) -> Bool {
        guard var current = active, current.peripheralID == peripheralID,
              message["characteristicId"] as? String == current.commandCharacteristicID,
              current.pendingWriteConfirmations > 0
        else { return false }

        current.pendingWriteConfirmations -= 1
        active = current
        if let error = message["error"] as? String, !error.isEmpty {
            finish(.failure(ToolError("Writing to the PM5 failed: \(error)")))
        } else if current.pendingWriteConfirmations == 0 && !current.injection.swallowResponse {
            finish(.success(nil))
        }
        return true
    }

    private func handleResponseChunk(_ message: [String: Any], peripheralID: String) -> Bool {
        guard let characteristicID = message["characteristicId"] as? String,
              peripherals[peripheralID]?.responseCharacteristicID == characteristicID
        else { return false }
        let bytes = (message["value"] as? String).flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) } ?? []

        guard var current = active, current.peripheralID == peripheralID, current.injection.swallowResponse else {
            if bytes.last == CSAFE.end {
                peripherals[peripheralID]?.appAwaitingReplySince = nil
            }
            return false
        }

        current.responseChunks.append(message)
        current.responseBytes += bytes
        active = current
        guard bytes.last == CSAFE.end else { return true }

        if let unframed = CSAFE.unframe(current.responseBytes), unframed.checksumValid,
           unframed.content.count >= 2, unframed.content[1] == current.injection.payload.first {
            let response = PM5Response(status: unframed.content[0], content: unframed.content,
                                       frame: current.responseBytes, checksumValid: true)
            active?.responseChunks.removeAll()
            finish(.success(response))
        } else {
            // Not ours — most likely a late reply to the app's own command.
            current.responseChunks.forEach(sendToApp)
            active?.responseChunks.removeAll()
            active?.responseBytes.removeAll()
            peripherals[peripheralID]?.appAwaitingReplySince = nil
        }
        return true
    }

    private func finish(_ result: Result<PM5Response?, ToolError>, flushHeld: Bool = true) {
        guard let current = active else { return }
        active = nil
        // Anything consumed while waiting that turned out not to be ours goes
        // on to the app, then the app's held commands go on to the PM.
        current.responseChunks.forEach(sendToApp)
        if flushHeld {
            for message in current.heldAppMessages {
                trackAppWrite(message, peripheralID: current.peripheralID)
                sendToBridge(message)
            }
        }
        complete(current.injection, result)
        pump()
    }

    private func complete(_ injection: PM5Injection, _ result: Result<PM5Response?, ToolError>) {
        DispatchQueue.main.async {
            injection.completion(result)
        }
    }

    private func failQueued(_ error: ToolError) {
        let failed = queue
        queue.removeAll()
        waitingSince = nil
        failed.forEach { complete($0, .failure(error)) }
    }

    private func resolve(_ deviceID: String?) -> Result<String, ToolError> {
        let ready = peripherals.filter(\.value.isReady)
        if let deviceID {
            guard let match = peripherals.first(where: {
                $0.key.caseInsensitiveCompare(deviceID) == .orderedSame
                    || $0.value.name.caseInsensitiveCompare(deviceID) == .orderedSame
            }) else {
                return .failure(ToolError("No PM5 \"\(deviceID)\" is connected through passthrough"))
            }
            guard match.value.isReady else {
                return .failure(ToolError("\(match.value.name) is not ready: the app has not subscribed to PM5 responses yet"))
            }
            return .success(match.key)
        }
        switch ready.count {
            case 1:
                return .success(ready.first!.key)
            case 0:
                return .failure(ToolError(peripherals.isEmpty
                    ? "No PM5 is connected. Switch to Passthrough and connect the app to the PM5 first."
                    : "The PM5 is not ready: the app has not subscribed to PM5 responses yet"))
            default:
                return .failure(ToolError("Several PM5s are connected; pass device"))
        }
    }

    private func peripheralID(forCommandCharacteristic characteristicID: String) -> String? {
        peripherals.first { $0.value.commandCharacteristicID == characteristicID }?.key
    }

    private func trackAppWrite(_ message: [String: Any], peripheralID: String) {
        let bytes = (message["value"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let completesFrame = bytes.last == CSAFE.end
        peripherals[peripheralID]?.appFrameOpen = !completesFrame
        if completesFrame {
            peripherals[peripheralID]?.appAwaitingReplySince = Date()
        }
    }

    private func trackCharacteristics(_ message: [String: Any], peripheralID: String) {
        guard let characteristics = message["characteristics"] as? [[String: Any]] else { return }
        for characteristic in characteristics {
            guard let uuid = (characteristic["uuid"] as? String)?.uppercased(),
                  let characteristicID = characteristic["id"] as? String else { continue }
            if uuid.hasPrefix(Self.commandUUIDPrefix) {
                peripherals[peripheralID, default: Peripheral()].commandCharacteristicID = characteristicID
            } else if uuid.hasPrefix(Self.responseUUIDPrefix) {
                peripherals[peripheralID, default: Peripheral()].responseCharacteristicID = characteristicID
            }
        }
        publishConnections()
    }

    private func publishConnections() {
        let connections = peripherals
            .filter { $0.value.isConnected && $0.value.commandCharacteristicID != nil }
            .map { id, peripheral in
                PM5Connection(id: id, name: peripheral.name.isEmpty ? "PM5" : peripheral.name, isReady: peripheral.isReady)
            }
            .sorted { $0.name < $1.name }
        publish(connections)
    }
}
