import Foundation
import Security

/// Allows `limit` starts within a sliding `window`.
struct RestartBudget {
    let limit: Int
    let window: TimeInterval
    private var starts: [Date] = []

    init(limit: Int = 5, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    mutating func consume(now: Date = Date()) -> Bool {
        starts.removeAll { now.timeIntervalSince($0) >= window }
        guard starts.count < limit else { return false }
        starts.append(now)
        return true
    }

    mutating func reset() { starts.removeAll() }
}

/// Runs the bundled `impossible-relay` helper while the user has the Android
/// relay switched on. The helper listens on 127.0.0.1 and forwards clients that
/// present the token to the provider's Unix socket.
///
/// Main-thread only, like the other panel models.
public final class AndroidRelay: ObservableObject {
    public enum Status: Equatable {
        case off
        case starting
        case listening
        case blocked(String)
        case failed(String)
    }

    public static let enabledKey = "AndroidRelayEnabled"
    public static let tokenKey = "AndroidRelayToken"
    static let port = 7700
    private static let exitUsage: Int32 = 64
    private static let exitPortInUse: Int32 = 75
    /// A just-stopped helper may still hold the port for a moment.
    static let portRetryLimit = 5
    static let portRetryDelay: TimeInterval = 0.3

    @Published public private(set) var status: Status = .off
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var token: String

    /// The helper's pid while it runs.
    public var pid: pid_t? { process.map(\.processIdentifier) }

    private let server: MockServer
    private let defaults: UserDefaults
    private let helperURL: URL?
    private var process: Process?
    private var restartBudget = RestartBudget()
    private var portRetries = 0

    public init(server: MockServer, defaults: UserDefaults = .standard, helperURL: URL? = AndroidRelay.bundledHelperURL()) {
        self.server = server
        self.defaults = defaults
        self.helperURL = helperURL
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        token = defaults.string(forKey: Self.tokenKey) ?? ""
    }

    /// Next to the app's executable under Contents/Helpers, or beside the
    /// binary in an SPM build folder.
    public static func bundledHelperURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/impossible-relay"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("impossible-relay"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts the helper when enabled.
    public func start() {
        guard isEnabled, process == nil else { return }
        guard let helperURL else {
            status = .failed("impossible-relay not found")
            return
        }
        if token.isEmpty {
            guard let fresh = Self.makeToken() else {
                status = .failed("could not generate a token")
                return
            }
            token = fresh
            defaults.set(token, forKey: Self.tokenKey)
        }
        let helper = Process()
        helper.executableURL = helperURL
        helper.environment = ["IMPOSSIBLE_RELAY_TOKEN": token, "IMPOSSIBLE_RELAY_PORT": String(Self.port)]
        let output = Pipe()
        helper.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self, weak helper] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard text.contains("listening") else { return }
            DispatchQueue.main.async {
                guard let helper, let self, self.process === helper else { return }
                self.portRetries = 0
                self.status = .listening
            }
        }
        helper.terminationHandler = { [weak self, weak helper] ended in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, let helper, self.process === helper else { return }
                self.helperEnded(status: ended.terminationStatus, reason: ended.terminationReason)
            }
        }
        do {
            try helper.run()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        process = helper
        status = .starting
        server.setRelayPid(helper.processIdentifier)
    }

    /// Returns once the helper has exited, so a following start() finds the port free.
    public func stop() {
        portRetries = 0
        guard let helper = process else {
            status = .off
            return
        }
        process = nil
        server.setRelayPid(nil)
        helper.terminate()
        let deadline = Date().addingTimeInterval(2)
        while helper.isRunning && Date() < deadline { usleep(20_000) }
        if helper.isRunning {
            kill(helper.processIdentifier, SIGKILL)
            helper.waitUntilExit()
        }
        status = .off
    }

    /// Replaces the token. A running helper is restarted so it presents the new one.
    public func regenerateToken() {
        guard let fresh = Self.makeToken() else {
            status = .failed("could not generate a token")
            return
        }
        let wasRunning = process != nil
        stop()
        token = fresh
        defaults.set(fresh, forKey: Self.tokenKey)
        restartBudget.reset()
        if wasRunning { start() }
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// A helper that exits on its own (for instance after a SIGTERM from outside) is
    /// started again, at most `RestartBudget` times a minute; a configuration error
    /// is not retried, and a taken port only briefly.
    private func helperEnded(status code: Int32, reason: Process.TerminationReason) {
        process = nil
        server.setRelayPid(nil)
        switch code {
            case Self.exitPortInUse where reason == .exit:
                guard portRetries >= Self.portRetryLimit else {
                    portRetries += 1
                    status = .starting
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.portRetryDelay) { [weak self] in self?.start() }
                    return
                }
                portRetries = 0
                status = .blocked("port \(Self.port) is in use")
            case Self.exitUsage where reason == .exit:
                status = .failed("impossible-relay rejected its configuration")
            default:
                guard restartBudget.consume() else {
                    let how = reason == .uncaughtSignal ? "signal \(code)" : "status \(code)"
                    status = .failed("impossible-relay keeps exiting (\(how))")
                    return
                }
                status = .off
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    typealias RandomFill = (Int, UnsafeMutableRawPointer) -> OSStatus

    static func makeToken(random: RandomFill = { SecRandomCopyBytes(kSecRandomDefault, $0, $1) }) -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard random(bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
