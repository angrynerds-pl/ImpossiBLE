import SwiftUI

/// Shown above the passthrough activity while the app is connected to a PM5:
/// an on/off switch for the remote and, when on, the PM5's buttons.
struct PM5RemotePanel: View {
    @ObservedObject var remote: PM5Remote

    private let keyRow: [PM5Key] = [.a, .b, .c, .d, .e]
    private let functionRow: [PM5Key] = [.units, .display, .menu]

    var body: some View {
        if let connection = remote.connections.first {
            VStack(alignment: .leading, spacing: 8) {
                header(connection)
                if remote.isEnabled {
                    if connection.isReady {
                        buttons(connection)
                    } else {
                        Text("Waiting for the app to subscribe to PM5 responses…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !remote.lastResult.isEmpty {
                        Text(remote.lastResult)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    private func header(_ connection: PM5Connection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.rower")
                .foregroundStyle(remote.isEnabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("PM5 Remote")
                    .font(.caption.weight(.semibold))
                Text(remote.connections.count > 1 ? "\(connection.name) (+\(remote.connections.count - 1))" : connection.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if remote.pendingCount > 0 {
                ProgressView()
                    .controlSize(.mini)
            }
            Toggle("", isOn: Binding(get: { remote.isEnabled }, set: { remote.setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Send button presses to the PM5 alongside the connected app")
        }
    }

    private func buttons(_ connection: PM5Connection) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(keyRow, id: \.self) { key in
                    keyButton(key, connection: connection)
                }
            }
            HStack(spacing: 6) {
                ForEach(functionRow, id: \.self) { key in
                    keyButton(key, connection: connection)
                }
            }
        }
    }

    private func keyButton(_ key: PM5Key, connection: PM5Connection) -> some View {
        Button {
            remote.press(key, deviceID: connection.id)
        } label: {
            Text(key.title)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Press \(key.title) on the PM5")
    }
}
