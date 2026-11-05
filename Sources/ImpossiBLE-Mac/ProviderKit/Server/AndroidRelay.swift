import Foundation
import Security

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

    @Published public private(set) var status: Status = .off
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var token: String

    /// The helper's pid while it runs.
    public var pid: pid_t? { process.map(\.processIdentifier) }

    private let server: MockServer
    private let defaults: UserDefaults
    private let helperURL: URL?
    private var process: Process?

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
            token = Self.makeToken()
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
                if let helper, self?.process === helper { self?.status = .listening }
            }
        }
        helper.terminationHandler = { [weak self, weak helper] ended in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, let helper, self.process === helper else { return }
                self.helperEnded(status: ended.terminationStatus)
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

    public func stop() {
        guard let helper = process else {
            status = .off
            return
        }
        process = nil
        server.setRelayPid(nil)
        helper.terminate()
        status = .off
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
    /// started again; a configuration error or a taken port is not retried.
    private func helperEnded(status code: Int32) {
        process = nil
        server.setRelayPid(nil)
        switch code {
            case Self.exitPortInUse:
                status = .blocked("port \(Self.port) is in use")
            case Self.exitUsage:
                status = .failed("impossible-relay rejected its configuration")
            default:
                status = .off
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
