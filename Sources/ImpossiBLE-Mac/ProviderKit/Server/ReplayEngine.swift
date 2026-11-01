import Foundation
import ImpossiBLEPassthroughCore

/// Decides what Replay mode answers to the connected client.
///
/// The engine records every client message first, then hands it here. Per
/// client session the responder gets a `send` closure it may call any number
/// of times, from any queue — in reply to a message or on its own schedule.
/// Sent messages are recorded as `toClient` entries. Sends arriving after the
/// session ended are dropped, so a slow responder can never reach the next
/// client.
protocol ReplayResponder: AnyObject {
    /// A client session began. Called on the transport's I/O queue.
    func begin(send: @escaping ([String: Any]) -> Void)
    /// A client message. Called on the transport's I/O queue.
    func handle(_ message: [String: Any])
    /// The client went away (disconnect, takeover, or stop), or the responder
    /// is being replaced; drop session state. Called on the I/O queue.
    func reset()
}

/// Records and answers nothing: the client sees a powered-on central that never
/// discovers anything.
final class SilentReplayResponder: ReplayResponder {
    func begin(send: @escaping ([String: Any]) -> Void) {}
    func handle(_ message: [String: Any]) {}
    func reset() {}
}

/// Replay mode's counterpart to `CBSPassthroughBridge`: instead of reaching
/// real hardware it writes the client's traffic to a recording (same format as
/// Passthrough's opt-in recording) and delegates answers to a `ReplayResponder`.
///
/// Every member must be called on the transport's I/O queue.
final class ReplayEngine {
    static let defaultDirectory = "/tmp/impossible-replay-recordings"

    private(set) var responder: ReplayResponder = SilentReplayResponder()

    private let recorder: CBSWireRecorder
    private let performOnIOQueue: (@escaping () -> Void) -> Void
    private let send: ([String: Any]) -> Void
    private let onReceived: (_ type: String, _ count: Int) -> Void
    private var session = 0
    private var sessionActive = false
    private var receivedCount = 0

    /// - Parameters:
    ///   - performOnIOQueue: hops onto the transport's I/O queue.
    ///   - send: delivers a message to the client; called on the I/O queue.
    ///   - onFileOpened: a new session recording was created; called on the
    ///     recorder's private queue.
    ///   - onReceived: a client message was recorded; called on the I/O queue.
    init(
        directory: String = ReplayEngine.defaultDirectory,
        performOnIOQueue: @escaping (@escaping () -> Void) -> Void,
        send: @escaping ([String: Any]) -> Void,
        onFileOpened: @escaping (String) -> Void,
        onReceived: @escaping (_ type: String, _ count: Int) -> Void
    ) {
        recorder = CBSWireRecorder(directory: directory, filePrefix: "replay")
        recorder.fileOpenedHandler = onFileOpened
        self.performOnIOQueue = performOnIOQueue
        self.send = send
        self.onReceived = onReceived
    }

    /// A client connected; starts a responder session.
    func begin() {
        session += 1
        sessionActive = true
        let session = session
        responder.begin { [weak self] message in
            guard let self else { return }
            self.performOnIOQueue {
                guard self.session == session else { return }
                self.recorder.recordMessage(message, direction: CBSWireDirectionToClient)
                self.send(message)
            }
        }
    }

    func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        recorder.recordMessage(message, direction: CBSWireDirectionFromClient)
        receivedCount += 1
        onReceived(type, receivedCount)
        responder.handle(message)
    }

    /// Swaps the responder; a connected client's session restarts on the new
    /// one right away.
    func replaceResponder(_ newResponder: ReplayResponder) {
        responder.reset()
        responder = newResponder
        session += 1
        if sessionActive {
            begin()
        }
    }

    /// Ends the session: the next client message records into a fresh file.
    func reset() {
        session += 1
        sessionActive = false
        receivedCount = 0
        responder.reset()
        recorder.finish()
    }
}
