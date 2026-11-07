import Foundation

/// Relaxed replay, for apps whose traffic is not byte-for-byte repeatable
/// (polling timers, Set-ordered subscriptions, wall-clock data in writes).
/// Each client request is answered on demand with the replies the recording
/// paired with the most similar recorded request; everything else —
/// notifications, advertisements, disconnects — plays on the recorded
/// timeline, which only waits for the first recorded request of each kind
/// ("anchors"), in any order.
///
/// Mirrors the library's CBSReplayRelaxedPlayer (CBSReplayRelaxed.m); keep the
/// two in step. All state is confined to a private serial queue; scheduled
/// callbacks check `generation`.
final class RelaxedReplayResponder: ReplayResponder {
    static let anchorTimeout: TimeInterval = ScriptedReplayResponder.fromClientTimeout
    /// How far after a request its reply may come and still be paired with it.
    private static let replyWindow: TimeInterval = 30
    /// Unused requests of a group searched for an identical value.
    private static let valueLookahead = 64
    /// A peripheral keeps advertising until the app connects to it: its last
    /// advertisement is repeated this often (real time) while the app scans,
    /// since apps drop a device that stops advertising (ErgData after 2 s).
    private static let advertisingInterval: TimeInterval = 1

    /// Request type → reply types, and the keys a reply shares with its request.
    private static let replyRules: [String: (types: Set<String>, keys: [String])] = [
        "connect": (["didConnect", "didFailConnect"], ["id"]),
        "cancel": (["didDisconnect"], ["id"]),
        "discoverServices": (["didDiscoverServices"], ["id"]),
        "discoverIncludedServices": (["didDiscoverIncludedServices"], ["id"]),
        "discoverCharacteristics": (["didDiscoverCharacteristics"], ["id", "serviceId"]),
        "discoverDescriptors": (["didDiscoverDescriptors"], ["id", "characteristicId"]),
        "read": (["didUpdateValue"], ["id", "characteristicId"]),
        "readDescriptor": (["didUpdateDescriptorValue"], ["id", "descriptorId"]),
        "write": (["didWriteValue"], ["id", "characteristicId"]),
        "writeDescriptor": (["didWriteDescriptorValue"], ["id", "descriptorId"]),
        "setNotify": (["didUpdateNotification"], ["id", "characteristicId"]),
        "readRSSI": (["didReadRSSI"], ["id"]),
        "openL2CAP": (["didOpenL2CAP"], ["id"]),
    ]

    private final class Request {
        let entry: ReplayScript.Entry
        var group = ""
        var value: [UInt8]?
        var signature: String?
        var replies: [ReplayScript.Entry] = []
        /// A leading chunk of a CSAFE frame: only claims its write confirmation.
        var chunk = false
        var used = false

        init(entry: ReplayScript.Entry) {
            self.entry = entry
        }

        var description: String {
            var text = entry.type
            if let uuid = entry.characteristicUUID { text += " \(uuid)" }
            if let signature { text += " CSAFE \(signature)" }
            return text + " (seq \(entry.seq))"
        }
    }

    private let script: ReplayScript
    private let speed: Double
    private let channels: [String: String]
    private let onStatus: (ReplayRunStatus) -> Void
    private let queue = DispatchQueue(label: "impossible.replay.relaxed")

    private var requests: [Request] = []
    private var groups: [String: [Request]] = [:]
    private var anchors: [Request] = []
    private var timeline: [ReplayScript.Entry] = []

    // Guarded by `queue`
    private var send: (([String: Any]) -> Void)?
    private var generation = 0
    private var isRunning = false
    private var isAnswering = false
    private var waiting = false
    /// When the wait for the current anchor times out. Kept while the app
    /// sends other messages, so a polling app cannot postpone it forever.
    private var waitDeadline: (seq: Int, date: Date)?
    private var seenGroups = Set<String>()
    private var groupCursor: [String: Int] = [:]
    private var lastUsed: [String: Request] = [:]
    private var appFrames: [String: [UInt8]] = [:]
    private var position = 0
    private var delayedPosition = -1
    private var anchorCursor = 0
    private var anchorReference = 0
    private var previousTimestamp: Date?
    private var answered = 0
    private var unmatched = 0
    private var timer: DispatchSourceTimer?
    private var scanning = false
    private var advertising: [String: [String: Any]] = [:]
    /// Peripherals the app connected to: like a real one, they stop advertising.
    private var connected: Set<String> = []
    private var advertisingTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - channels: request characteristic UUID prefix → response prefix.
    ///   - onStatus: progress updates, called on a private queue.
    init(
        script: ReplayScript,
        speed: Double = 1,
        channels: [String: String] = ["CE060021": "CE060022"],
        onStatus: @escaping (ReplayRunStatus) -> Void
    ) {
        self.script = script
        self.speed = speed > 0 ? speed : 1
        self.channels = channels
        self.onStatus = onStatus
        prepare()
        onStatus(.waitingForClient)
    }

    func begin(send: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            stopRun()
            self.send = send
            startRun()
        }
    }

    func handle(_ message: [String: Any]) {
        queue.async { [self] in
            guard isAnswering else { return }
            answer(message)
            if waiting { runTimeline() }
        }
    }

    func reset() {
        queue.async { [self] in
            stopRun()
            send = nil
            onStatus(.waitingForClient)
        }
    }

    // MARK: - Preprocessing

    private func responseChannel(for message: [String: Any]) -> String? {
        guard message["type"] as? String == "write",
              let id = message["characteristicId"] as? String else { return nil }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let uuid = parts[parts.count - 2].uppercased()
        return channels.first { uuid.hasPrefix($0.key) }?.value
    }

    private static func group(for message: [String: Any], signature: String?) -> String {
        let relevant = message.filter { $0.key != "value" && $0.key != "valueB64" && !$0.key.hasPrefix("_") }
        let data = (try? JSONSerialization.data(withJSONObject: relevant, options: [.sortedKeys])) ?? Data()
        let base = String(decoding: data, as: UTF8.self)
        return signature.map { "\(base)|\($0)" } ?? base
    }

    private static func isRequest(_ type: String) -> Bool {
        replyRules[type] != nil || type == "scan"
    }

    private static func wantsResponse(_ message: [String: Any]) -> Bool {
        (message["writeType"] as? Int) == 0
    }

    private static func bytes(of message: [String: Any]) -> [UInt8]? {
        guard let value = message["value"] as? String ?? message["valueB64"] as? String,
              let data = Data(base64Encoded: value) else { return nil }
        return Array(data)
    }

    /// CoreBluetooth answers each discoverCharacteristics on a service with every
    /// characteristic discovered on it so far, so a recording of an app that asks
    /// several times holds growing lists. The app's requests come in a different
    /// order on every run (ErgData iterates a Set), and a short list leaves
    /// characteristics it asked for undiscovered: every reply carries the
    /// service's complete list, as the device's final state.
    static func completingDiscoveredCharacteristics(_ entries: [ReplayScript.Entry]) -> [ReplayScript.Entry] {
        func key(_ message: [String: Any]) -> String {
            "\(message["id"] ?? "")|\(message["serviceId"] ?? "")"
        }
        let replies = entries.filter { $0.direction == .toClient && $0.type == "didDiscoverCharacteristics" }
        var lists: [String: [Any]] = [:]
        var seen: [String: Set<String>] = [:]
        for reply in replies {
            let service = key(reply.message)
            for case let characteristic as [String: Any] in reply.message["characteristics"] as? [Any] ?? [] {
                guard let id = characteristic["id"] as? String, seen[service, default: []].insert(id).inserted else { continue }
                lists[service, default: []].append(characteristic)
            }
        }
        return entries.map { entry in
            guard entry.direction == .toClient, entry.type == "didDiscoverCharacteristics" else { return entry }
            var message = entry.message
            message["characteristics"] = lists[key(message)] ?? []
            return ReplayScript.Entry(seq: entry.seq, timestamp: entry.timestamp, direction: entry.direction,
                                      message: message, type: entry.type)
        }
    }

    private func prepare() {
        let entries = Self.completingDiscoveredCharacteristics(script.entries)
        var claimed = Set<Int>()
        var frames: [String: [UInt8]] = [:]
        var openFrames: [String: Request] = [:] // "<peripheral>|<response prefix>"

        for (index, entry) in entries.enumerated() {
            let message = entry.message
            if entry.direction == .toClient {
                if claimed.contains(index) { continue }
                if entry.type == "didUpdateValue", let uuid = entry.characteristicUUID,
                   let frame = openFrames.first(where: { key, _ in
                       let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                       return parts[0] == message["id"] as? String && uuid.hasPrefix(parts[1])
                   })?.value {
                    frame.replies.append(entry)
                    continue
                }
                timeline.append(entry)
                continue
            }

            guard Self.isRequest(entry.type) else { continue }
            let request = Request(entry: entry)
            request.value = Self.bytes(of: message)

            if let response = responseChannel(for: message), let characteristicId = message["characteristicId"] as? String {
                let frameKey = "\(message["id"] as? String ?? "")|\(response)"
                openFrames[frameKey] = nil
                var frame = frames[characteristicId] ?? []
                frame += request.value ?? []
                if frame.last == 0xF2 {
                    frames[characteristicId] = nil
                    request.value = frame
                    request.signature = CSAFE.signature(frame) ?? frame.map { String(format: "%02X", $0) }.joined()
                    openFrames[frameKey] = request
                } else {
                    frames[characteristicId] = frame
                    request.chunk = true
                }
            }
            request.group = Self.group(for: message, signature: request.signature)

            if let rule = Self.replyRules[entry.type],
               entry.type != "write" || Self.wantsResponse(message) {
                for candidateIndex in (index + 1) ..< entries.count {
                    let candidate = entries[candidateIndex]
                    if candidate.timestamp.timeIntervalSince(entry.timestamp) > Self.replyWindow { break }
                    guard candidate.direction == .toClient, !claimed.contains(candidateIndex),
                          rule.types.contains(candidate.type) else { continue }
                    let same = rule.keys.allSatisfy { key in
                        (candidate.message[key] as? NSObject) == (message[key] as? NSObject)
                    }
                    guard same else { continue }
                    claimed.insert(candidateIndex)
                    request.replies.append(candidate)
                    break
                }
            }
            requests.append(request)
        }

        for request in requests {
            request.replies.sort { $0.seq < $1.seq }
            guard !request.chunk else { continue }
            if groups[request.group] == nil {
                anchors.append(request)
            }
            groups[request.group, default: []].append(request)
        }
    }

    // MARK: - Answering (on `queue`)

    private func answer(_ message: [String: Any]) {
        switch message["type"] as? String {
            case "scan": scanning = true
            case "stopScan": scanning = false
            case "connect":
                if let id = message["id"] as? String {
                    advertising[id] = nil
                    connected.insert(id)
                }
            case "cancel": (message["id"] as? String).map { connected.remove($0) }
            default: break
        }
        guard let type = message["type"] as? String, Self.isRequest(type) else { return }
        var value = Self.bytes(of: message)
        var signature: String?

        if let _ = responseChannel(for: message), let characteristicId = message["characteristicId"] as? String {
            var frame = appFrames[characteristicId] ?? []
            frame += value ?? []
            guard frame.last == 0xF2 else {
                // A leading chunk: confirm it so the app sends the rest.
                appFrames[characteristicId] = frame
                if Self.wantsResponse(message) { send?(writeConfirmation(for: message)) }
                return
            }
            appFrames[characteristicId] = nil
            value = frame
            signature = CSAFE.signature(frame) ?? frame.map { String(format: "%02X", $0) }.joined()
        }

        let group = Self.group(for: message, signature: signature)
        seenGroups.insert(group)

        if let request = takeRequest(in: group, value: value) ?? lastUsed[group] {
            lastUsed[group] = request
            answered += 1
            playReplies(request.replies, from: request.entry.timestamp, index: 0, generation: generation)
            return
        }

        unmatched += 1
        if type == "write", Self.wantsResponse(message) {
            send?(writeConfirmation(for: message))
        } else if type == "setNotify" {
            send?([
                "type": "didUpdateNotification", "id": message["id"] ?? "",
                "characteristicId": message["characteristicId"] ?? "",
                "enabled": message["enabled"] ?? false, "error": "",
            ])
        }
    }

    private func writeConfirmation(for write: [String: Any]) -> [String: Any] {
        ["type": "didWriteValue", "id": write["id"] ?? "", "characteristicId": write["characteristicId"] ?? "", "error": ""]
    }

    private func takeRequest(in group: String, value: [UInt8]?) -> Request? {
        guard let candidates = groups[group] else { return nil }
        var cursor = groupCursor[group] ?? 0
        while cursor < candidates.count, candidates[cursor].used { cursor += 1 }
        groupCursor[group] = cursor
        guard cursor < candidates.count else { return nil }

        var chosen = candidates[cursor]
        if let value {
            let end = min(candidates.count, cursor + Self.valueLookahead)
            if let identical = candidates[cursor ..< end].first(where: { !$0.used && $0.value == value }) {
                chosen = identical
            }
        }
        chosen.used = true
        return chosen
    }

    /// Delivers replies at their recorded distances (scaled), chained so their
    /// order cannot change.
    private func playReplies(_ replies: [ReplayScript.Entry], from previous: Date, index: Int, generation: Int) {
        var previous = previous
        var index = index
        while index < replies.count {
            guard generation == self.generation, isAnswering else { return }
            let reply = replies[index]
            let delay = max(0, reply.timestamp.timeIntervalSince(previous)) / speed
            if delay > 0.001 {
                let next = index
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.generation == generation, self.isAnswering else { return }
                    self.send?(reply.message)
                    self.playReplies(replies, from: reply.timestamp, index: next + 1, generation: generation)
                }
                return
            }
            send?(reply.message)
            previous = reply.timestamp
            index += 1
        }
    }

    // MARK: - Timeline (on `queue`)

    private func firstMissingAnchor() -> Request? {
        while anchorCursor < anchors.count, seenGroups.contains(anchors[anchorCursor].group) {
            anchorCursor += 1
        }
        return anchorCursor < anchors.count ? anchors[anchorCursor] : nil
    }

    private func startRun() {
        isRunning = true
        isAnswering = true
        startAdvertising()
        runTimeline()
    }

    private func startAdvertising() {
        let generation = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.advertisingInterval, repeating: Self.advertisingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == generation, self.isAnswering, self.scanning else { return }
            self.advertising.values.forEach { self.send?($0) }
        }
        timer.resume()
        advertisingTimer = timer
    }

    private func runTimeline() {
        guard isRunning else { return }
        waiting = false
        cancelTimer()

        while position < timeline.count {
            let entry = timeline[position]
            if let missing = firstMissingAnchor(), missing.entry.seq < entry.seq {
                wait(for: missing)
                return
            }
            if delayedPosition != position {
                delayedPosition = position
                while anchorReference < anchors.count, anchors[anchorReference].entry.seq < entry.seq {
                    anchorReference += 1
                }
                var reference = previousTimestamp
                if anchorReference > 0 {
                    let anchorTime = anchors[anchorReference - 1].entry.timestamp
                    if reference.map({ anchorTime > $0 }) ?? true { reference = anchorTime }
                }
                let delay = reference.map { max(0, entry.timestamp.timeIntervalSince($0)) / speed } ?? 0
                if delay > 0.001 {
                    if position % 100 == 0 { publishProgress(awaiting: nil) }
                    schedule(after: delay) { [weak self] in self?.runTimeline() }
                    return
                }
            }
            send?(entry.message)
            if entry.type == "didDiscover", let id = entry.message["id"] as? String, !connected.contains(id) {
                advertising[id] = entry.message
            }
            previousTimestamp = entry.timestamp
            position += 1
        }

        if let missing = firstMissingAnchor() {
            wait(for: missing)
            return
        }
        // Passed; requests are still answered.
        isRunning = false
        onStatus(.passed(total: timeline.count))
    }

    private func wait(for anchor: Request) {
        waiting = true
        publishProgress(awaiting: anchor.description)
        if waitDeadline?.seq != anchor.entry.seq {
            waitDeadline = (anchor.entry.seq, Date().addingTimeInterval(Self.anchorTimeout))
        }
        let remaining = max(0, waitDeadline?.date.timeIntervalSinceNow ?? Self.anchorTimeout)
        schedule(after: remaining) { [weak self] in self?.timeOut(anchor) }
    }

    private func timeOut(_ anchor: Request) {
        let step = position + 1
        stopRun()
        onStatus(.failed(
            step: step,
            total: timeline.count,
            reason: "No \(anchor.description) from the app within \(Int(Self.anchorTimeout)) s"
        ))
    }

    private func publishProgress(awaiting: String?) {
        onStatus(.running(step: position + 1, total: timeline.count, awaiting: awaiting))
    }

    private func stopRun() {
        generation += 1
        cancelTimer()
        advertisingTimer?.cancel()
        advertisingTimer = nil
        scanning = false
        advertising.removeAll()
        connected.removeAll()
        isRunning = false
        isAnswering = false
        waiting = false
        waitDeadline = nil
        position = 0
        delayedPosition = -1
        anchorCursor = 0
        anchorReference = 0
        previousTimestamp = nil
        answered = 0
        unmatched = 0
        seenGroups.removeAll()
        groupCursor.removeAll()
        lastUsed.removeAll()
        appFrames.removeAll()
        requests.forEach { $0.used = false }
    }

    private func schedule(after interval: TimeInterval, _ work: @escaping () -> Void) {
        cancelTimer()
        let generation = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == generation else { return }
            self.timer = nil
            work()
        }
        timer.resume()
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
