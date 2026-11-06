import Foundation

/// How Replay mode plays a loaded recording. Persisted; changing it restarts
/// a connected client's run.
struct ReplayOptions: Equatable {
    enum Matching: String, CaseIterable {
        /// Every recorded app message is waited for, in recorded order.
        case strict
        /// App requests are answered on demand and notifications follow the
        /// recorded timeline (see `RelaxedReplayResponder`).
        case relaxed
    }

    static let speeds: [Double] = [1, 2, 5, 10]

    var matching: Matching = .strict
    /// Divides every recorded delay; the wait for the app is not scaled.
    var speed: Double = 1
    /// Moves a Concept2 PM5's clock to the time of each run, so a replayed
    /// workout is logged as a new result (see `ReplayScript.shiftingPM5Times`).
    var pm5CurrentTime = true

    private static let matchingKey = "ReplayMatching"
    private static let speedKey = "ReplaySpeed"
    private static let pm5CurrentTimeKey = "ReplayPM5CurrentTime"

    static func load(from defaults: UserDefaults = .standard) -> ReplayOptions {
        var options = ReplayOptions()
        if let raw = defaults.string(forKey: matchingKey), let matching = Matching(rawValue: raw) {
            options.matching = matching
        }
        let speed = defaults.double(forKey: speedKey)
        if speed > 0 { options.speed = speed }
        if defaults.object(forKey: pm5CurrentTimeKey) != nil {
            options.pm5CurrentTime = defaults.bool(forKey: pm5CurrentTimeKey)
        }
        return options
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(matching.rawValue, forKey: Self.matchingKey)
        defaults.set(speed, forKey: Self.speedKey)
        defaults.set(pm5CurrentTime, forKey: Self.pm5CurrentTimeKey)
    }
}

/// Builds a fresh responder for every client session, so the PM5 clock shift
/// uses the time the run starts. Statuses from a replaced run are dropped.
/// Restarts replace the whole `ReplayRunResponder` (`MockServer.replaceReplayResponder`,
/// which also re-sends the app's active scan).
final class ReplayRunResponder: ReplayResponder {
    private let makeResponder: (_ onStatus: @escaping (ReplayRunStatus) -> Void) -> ReplayResponder
    private let onStatus: (ReplayRunStatus) -> Void
    private let lock = NSLock()
    // Guarded by `lock`
    private var current: ReplayResponder?
    private var currentToken = 0

    init(
        makeResponder: @escaping (_ onStatus: @escaping (ReplayRunStatus) -> Void) -> ReplayResponder,
        onStatus: @escaping (ReplayRunStatus) -> Void
    ) {
        self.makeResponder = makeResponder
        self.onStatus = onStatus
        onStatus(.waitingForClient)
    }

    func begin(send: @escaping ([String: Any]) -> Void) {
        lock.lock()
        let previous = current
        currentToken += 1
        let token = currentToken
        lock.unlock()
        previous?.reset()

        let responder = makeResponder { [weak self] status in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.currentToken == token
            self.lock.unlock()
            if isCurrent { self.onStatus(status) }
        }
        lock.lock()
        current = responder
        lock.unlock()
        responder.begin(send: send)
    }

    func handle(_ message: [String: Any]) {
        lock.lock()
        let responder = current
        lock.unlock()
        responder?.handle(message)
    }

    func reset() {
        lock.lock()
        let responder = current
        current = nil
        currentToken += 1
        lock.unlock()
        responder?.reset()
        onStatus(.waitingForClient)
    }
}
