import SwiftUI
import AppKit
import SimBridgeServer
import SimBridgeShell

/// The standalone app's control panel: a title header and an app footer
/// wrapped around `ImpossiBLESection`, which carries the actual provider UI.
public struct MockMenuContent: View {
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var activity: PassthroughActivityMonitor
    @ObservedObject var controller: ModeTransitionController<ImpossiBLEMode>
    var control: ProviderControlServer?
    var relay: AndroidRelay?
    var onDismiss: (() -> Void)?
    var onOpenCapture: (() -> Void)?
    var onOpenDevice: ((UUID) -> Void)?
    @State private var dismissOnDeactivate = ShellPreferences.dismissControlWindowOnDeactivate
    // Launch-at-login lives in a launchd plist, not UserDefaults. Mirror it in
    // view state so the toggle reflects taps immediately instead of re-reading
    // the (non-observable) filesystem.
    @State private var launchAtLogin = MockMenuContent.launchAgent.isEnabled
    @State private var settingsAck = ""
    @State private var ackClear: DispatchWorkItem?
    private static let launchAgent = LaunchAtLogin(label: "com.impossible.ble-mac")

    public init(
        store: MockStore,
        server: MockServer,
        transport: ProtocolServer,
        activity: PassthroughActivityMonitor,
        controller: ModeTransitionController<ImpossiBLEMode>,
        control: ProviderControlServer? = nil,
        relay: AndroidRelay? = nil,
        onDismiss: (() -> Void)? = nil,
        onOpenCapture: (() -> Void)? = nil,
        onOpenDevice: ((UUID) -> Void)? = nil
    ) {
        self.store = store
        self.server = server
        self.transport = transport
        self.activity = activity
        self.controller = controller
        self.control = control
        self.relay = relay
        self.onDismiss = onDismiss
        self.onOpenCapture = onOpenCapture
        self.onOpenDevice = onOpenDevice
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ImpossiBLESection(
                store: store,
                server: server,
                transport: transport,
                activity: activity,
                controller: controller,
                onDismiss: onDismiss,
                onOpenCapture: onOpenCapture,
                onOpenDevice: onOpenDevice
            )
            if let relay, relay.isEnabled {
                Divider()
                AndroidRelayRow(relay: relay, transport: transport)
            }
            Divider()
            footer
        }
        .background(Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(nsImage: FontAwesome.brandImage(FontAwesome.bluetoothB, size: 18))
                .foregroundStyle(statusColor)
                .frame(width: ImpossiBLESection.statusIconColumnWidth, alignment: .center)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("ImpossiBLE Mock")
                    .font(.headline)
                if !appVersion.isEmpty {
                    Text(appVersion)
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var statusColor: Color {
        ImpossiBLESection.statusColor(mode: controller.mode, status: transport.status)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.current
    }

    // MARK: - Footer

    /// Briefly shows a one-line receipt in the footer after a preference changes.
    private func acknowledge(_ message: String) {
        ackClear?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            settingsAck = message
        }
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.3)) {
                settingsAck = ""
            }
        }
        ackClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            IconToggle(
                systemImage: "power",
                help: "Launch ImpossiBLE Mock automatically at login",
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { _, newValue in
                Self.launchAgent.setEnabled(newValue)
                acknowledge(newValue ? "Will launch at login" : "Won’t launch at login")
            }

            IconToggle(
                systemImage: "eye.slash",
                help: "Hide this panel when you switch to another app",
                isOn: $dismissOnDeactivate
            )
            .onChange(of: dismissOnDeactivate) { _, newValue in
                ShellPreferences.dismissControlWindowOnDeactivate = newValue
                acknowledge(newValue ? "Panel auto-hides" : "Panel stays open")
            }

            if let control {
                AgentControlToggle(control: control, acknowledge: acknowledge)
            }

            if let relay {
                AndroidRelayToggle(relay: relay, acknowledge: acknowledge)
            }

            Spacer()

            if !settingsAck.isEmpty {
                Text(settingsAck)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            Spacer()

            // The app delegate stops the server on any quit path.
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// Footer toggle for MCP agent control, with a dot while an agent is connected.
private struct AgentControlToggle: View {
    @ObservedObject var control: ProviderControlServer
    let acknowledge: (String) -> Void

    var body: some View {
        IconToggle(
            systemImage: "terminal",
            help: helpText,
            isOn: Binding(
                get: { control.isEnabled },
                set: { newValue in
                    control.setEnabled(newValue)
                    acknowledge(newValue ? "Agents can control ImpossiBLE" : "Agent control off")
                }
            )
        )
        .overlay(alignment: .topTrailing) {
            if control.isEnabled && control.connectedAgents > 0 {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .offset(x: -2, y: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var helpText: String {
        guard control.isEnabled else {
            return "Let AI agents control ImpossiBLE over MCP (impossible-mcp)"
        }
        switch control.status {
            case .blocked(let reason), .failed(let reason):
                return "Agent control (MCP) unavailable: \(reason)"
            default:
                let count = control.connectedAgents
                let agents = count == 0 ? "no agent connected" : "\(count) agent\(count == 1 ? "" : "s") connected"
                return "Agent control (MCP) on — \(agents)"
        }
    }
}

/// Footer toggle for the Android relay.
private struct AndroidRelayToggle: View {
    @ObservedObject var relay: AndroidRelay
    let acknowledge: (String) -> Void

    var body: some View {
        IconToggle(
            systemImage: "iphone.gen3.radiowaves.left.and.right",
            help: "Let the Android emulator reach ImpossiBLE through a loopback relay on port 7700",
            isOn: Binding(
                get: { relay.isEnabled },
                set: { newValue in
                    relay.setEnabled(newValue)
                    acknowledge(newValue ? "Android relay on" : "Android relay off")
                }
            )
        )
    }
}

/// Relay state and the token the Android library must present.
private struct AndroidRelayRow: View {
    @ObservedObject var relay: AndroidRelay
    @ObservedObject var transport: ProtocolServer

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .frame(width: ImpossiBLESection.statusIconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Android relay")
                    .font(.caption.weight(.medium))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !relay.token.isEmpty {
                    Text("Token \(relay.token)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relay.token, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(relay.token.isEmpty)
            .help("Copy the relay token")
            .accessibilityLabel("Copy the relay token")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var clientConnected: Bool {
        guard let pid = relay.pid, let client = transport.connectedClient else { return false }
        return client.pid == pid
    }

    private var statusText: String {
        switch relay.status {
            case .off: "Off"
            case .starting: "Starting"
            case .listening: clientConnected ? "Client connected" : "Listening on 127.0.0.1:7700"
            case .blocked(let reason): "Blocked: \(reason)"
            case .failed(let reason): "Failed: \(reason)"
        }
    }

    private var statusColor: Color {
        switch relay.status {
            case .listening: clientConnected ? .green : .blue
            case .starting, .off: .gray
            case .blocked: .orange
            case .failed: .red
        }
    }
}
