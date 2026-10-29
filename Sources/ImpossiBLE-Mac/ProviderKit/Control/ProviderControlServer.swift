import Foundation
import SimBridgeShell

/// Lets AI agents drive the provider over MCP: switch modes, manage mock
/// configurations and the working set, record real devices, and watch
/// passthrough traffic. Agents launch the bundled `impossible-mcp` shim, which
/// pipes MCP's stdio transport to `socketPath`.
///
/// Main-thread only, like the store and mode controller it drives.
public final class ProviderControlServer: ObservableObject {
    public enum Status: Equatable {
        case stopped
        case listening
        case blocked(String)
        case failed(String)
    }

    public static let socketPath = "/tmp/impossible-control.sock"
    public static let enabledKey = "AgentControlEnabled"

    @Published public private(set) var status: Status = .stopped
    @Published public private(set) var connectedAgents = 0
    /// Persisted; on unless the user turned it off in the panel.
    @Published public private(set) var isEnabled: Bool

    private let tools: ProviderTools
    private let socket: ControlSocketServer

    public init(store: MockStore, server: MockServer, modeController: ModeTransitionController<ProviderMode>) {
        let tools = ProviderTools(store: store, server: server, modeController: modeController)
        self.tools = tools
        socket = ControlSocketServer(path: Self.socketPath) { send in
            MCPSession(tools: tools, send: send)
        }
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true

        socket.onStatusChange = { [weak self] status in
            self?.status = switch status {
                case .stopped: .stopped
                case .listening: .listening
                case .blocked(let reason): .blocked(reason)
                case .failed(let reason): .failed(reason)
            }
        }
        socket.onClientCountChange = { [weak self] count in
            self?.connectedAgents = count
        }
    }

    /// Starts listening when enabled.
    public func start() {
        guard isEnabled else { return }
        socket.start()
    }

    public func stop(completion: (() -> Void)? = nil) {
        tools.stop()
        socket.stop(completion: completion)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            socket.start()
        } else {
            stop()
        }
    }
}
