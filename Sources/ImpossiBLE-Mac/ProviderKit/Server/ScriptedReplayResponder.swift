import Foundation

/// Progress of a scripted replay run, as shown in the panel.
enum ReplayRunStatus: Equatable {
    /// No script loaded.
    case idle
    case waitingForClient
    case running(step: Int, total: Int, awaiting: String?)
    case passed(total: Int)
    case failed(step: Int, total: Int, reason: String)
}

/// Plays a `ReplayScript` against the connected client, one entry at a time in
/// `seq` order. Before each entry it waits for the timestamp distance to the
/// previous one; then a `toClient` entry is sent as recorded, and a
/// `fromClient` entry blocks until the client sends a matching message (see
/// `ReplayScript.Entry.matches`), failing the run after `fromClientTimeout`.
///
/// Client messages are buffered, so one that arrives early — while a delay or
/// an earlier entry is pending — still matches later. Messages the script never
/// asks for are ignored, as is anything sent while no run is in progress. After
/// the run passes or fails, the client is no longer answered (its traffic is
/// still recorded by the engine). A run starts with every client session, and
/// `start()` restarts it from the first entry.
///
/// All state is confined to a private serial queue; every scheduled callback
/// checks `generation`, so nothing from a previous session fires into the next.
final class ScriptedReplayResponder: ReplayResponder {
    static let fromClientTimeout: TimeInterval = 60

    private let script: ReplayScript
    private let onStatus: (ReplayRunStatus) -> Void
    private let queue = DispatchQueue(label: "impossible.replay.player")

    // Guarded by `queue`
    private var send: (([String: Any]) -> Void)?
    private var generation = 0
    private var index = 0
    /// The entry whose leading delay has already elapsed.
    private var delayedIndex = -1
    private var awaiting = false
    private var isRunning = false
    private var pending: [[String: Any]] = []
    private var timer: DispatchSourceTimer?

    /// - Parameter onStatus: progress updates, called on a private queue.
    init(script: ReplayScript, onStatus: @escaping (ReplayRunStatus) -> Void) {
        self.script = script
        self.onStatus = onStatus
        onStatus(.waitingForClient)
    }

    func begin(send: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            stopRun()
            self.send = send
            startRun()
        }
    }

    /// Restarts the run from the first entry for the current client session.
    /// No-op without one.
    func start() {
        queue.async { [self] in
            guard send != nil else { return }
            stopRun()
            startRun()
        }
    }

    func handle(_ message: [String: Any]) {
        queue.async { [self] in
            guard isRunning else { return }
            pending.append(message)
            guard awaiting, takePending(matching: script.entries[index]) else { return }
            awaiting = false
            cancelTimer()
            index += 1
            run()
        }
    }

    func reset() {
        queue.async { [self] in
            stopRun()
            send = nil
            onStatus(.waitingForClient)
        }
    }

    // MARK: - Run loop (on `queue`)

    private func startRun() {
        isRunning = true
        run()
    }

    /// Advances as far as possible without waiting; returns once a delay, a
    /// client message, or the end of the script is reached. Iterative rather
    /// than recursive, so long runs of zero-delay entries cannot grow the stack.
    private func run() {
        let entries = script.entries
        while index < entries.count {
            let entry = entries[index]

            if delayedIndex != index {
                delayedIndex = index
                let delay = script.delay(before: index)
                if delay > 0 {
                    publishProgress()
                    schedule(after: delay) { [weak self] in self?.run() }
                    return
                }
            }

            switch entry.direction {
                case .toClient:
                    send?(entry.message)
                    index += 1
                case .fromClient:
                    if takePending(matching: entry) {
                        index += 1
                    } else {
                        awaiting = true
                        publishProgress()
                        schedule(after: Self.fromClientTimeout) { [weak self] in self?.timeOut() }
                        return
                    }
            }
        }
        isRunning = false
        onStatus(.passed(total: entries.count))
    }

    private func timeOut() {
        let entry = script.entries[index]
        awaiting = false
        isRunning = false
        onStatus(.failed(
            step: index + 1,
            total: script.entries.count,
            reason: "No \(entry.type) from the app within \(Int(Self.fromClientTimeout)) s (seq \(entry.seq))"
        ))
    }

    private func takePending(matching entry: ReplayScript.Entry) -> Bool {
        guard let matchIndex = pending.firstIndex(where: entry.matches) else { return false }
        pending.remove(at: matchIndex)
        return true
    }

    private func publishProgress() {
        onStatus(.running(
            step: index + 1,
            total: script.entries.count,
            awaiting: awaiting ? script.entries[index].type : nil
        ))
    }

    private func stopRun() {
        generation += 1
        cancelTimer()
        index = 0
        delayedIndex = -1
        awaiting = false
        isRunning = false
        pending.removeAll()
    }

    /// One timer at a time is enough: a delay and a match timeout never overlap.
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
