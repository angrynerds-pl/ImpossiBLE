import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drop target (and click-to-choose button) for the recording Replay mode
/// plays back. Once a file is loaded it shows the validation result and stays
/// a drop target, so a different recording can simply be dropped over it.
struct ReplayScriptDropZone: View {
    let script: ReplayScriptState?
    /// Whether a client is connected that a restart would replay to.
    let canRestart: Bool
    let onLoad: (URL) -> Void
    let onRestart: () -> Void
    let onClear: () -> Void

    @State private var isTargeted = false

    var body: some View {
        Group {
            if let script {
                loadedContent(script)
            } else {
                emptyContent
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            onLoad(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var emptyContent: some View {
        Button(action: chooseFile) {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Drop a passthrough recording")
                    .font(.callout)
                Text("or click to choose a .json file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadedContent(_ script: ReplayScriptState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: script.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(script.isValid ? .green : .red)
                .help(script.isValid ? "Valid recording" : "Invalid recording")
            VStack(alignment: .leading, spacing: 2) {
                Text(script.url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(script.url.path)
                Text(detail(for: script.validity))
                    .font(.caption)
                    .foregroundStyle(script.isValid ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if script.isValid {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!canRestart)
                .help(canRestart ? "Restart the replay from the first entry" : "Restart needs a connected app")
            }
            Button(action: chooseFile) {
                Image(systemName: "doc")
            }
            .buttonStyle(.borderless)
            .help("Choose another recording")
            Button(action: onClear) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Unload recording")
        }
    }

    private func detail(for validity: ReplayScriptState.Validity) -> String {
        switch validity {
            case .valid(let entries, let fromClient, let toClient):
                "\(entries) entries · \(fromClient) from app · \(toClient) to app"
            case .invalid(let message):
                message
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: PassthroughRecordingState.directory, isDirectory: true)
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onLoad(url)
    }
}

/// One line describing where a scripted replay run stands.
struct ReplayRunStatusRow: View {
    let status: ReplayRunStatus

    var body: some View {
        if let content {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: content.icon)
                    .font(.title3)
                    .foregroundStyle(content.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title)
                        .font(.callout)
                    if let detail = content.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if case .running(let step, let total, _) = status {
                        ProgressView(value: Double(step - 1), total: Double(max(total, 1)))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct Content {
        let icon: String
        let tint: Color
        let title: String
        let detail: String?
    }

    private var content: Content? {
        switch status {
            case .idle:
                return nil
            case .ready:
                return Content(icon: "pause.circle", tint: .secondary, title: "Ready to replay",
                               detail: "Choose how to play it, then press Start. Until then the app sees no devices.")
            case .waitingForClient:
                return Content(icon: "hourglass", tint: .secondary, title: "Waiting for the app to connect", detail: nil)
            case .running(let step, let total, let awaiting):
                return Content(
                    icon: "play.circle.fill",
                    tint: .blue,
                    title: "Replaying step \(step) of \(total)",
                    detail: awaiting.map { "Waiting for \($0) from the app" }
                )
            case .passed(let total):
                return Content(icon: "checkmark.circle.fill", tint: .green, title: "Replay finished", detail: "All \(total) entries played")
            case .failed(let step, let total, let reason):
                return Content(icon: "xmark.circle.fill", tint: .red, title: "Replay failed at step \(step) of \(total)", detail: reason)
        }
    }
}

/// How the loaded recording plays — matching, speed, the PM5 clock — and the
/// Start/Stop button.
struct ReplayOptionsRow: View {
    let options: ReplayOptions
    let isStarted: Bool
    let onChange: (ReplayOptions) -> Void
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: binding(\.matching)) {
                    Text("Strict").tag(ReplayOptions.Matching.strict)
                    Text("Relaxed").tag(ReplayOptions.Matching.relaxed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Strict waits for every recorded app message in order. Relaxed answers each request from the recording and only waits for the first request of each kind — for apps that poll or subscribe in varying order, like ErgData.")

                Picker("", selection: binding(\.speed)) {
                    ForEach(ReplayOptions.speeds, id: \.self) { speed in
                        Text("\(Int(speed))×").tag(speed)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Plays recorded delays this much faster. The wait for the app is not shortened.")
            }

            Text(matchingDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: binding(\.pm5CurrentTime)) {
                Text("Move PM5 clock to now")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Rewrites a Concept2 PM5's workout dates and times to the time the run starts, so a replayed workout is logged as a new result instead of a duplicate of the recorded one.")

            HStack {
                Spacer()
                if isStarted {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop answering the app. The recording stays loaded.")
                } else {
                    Button(action: onStart) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Play the recording to the connected app now, and from the top to every app that connects later.")
                }
            }
        }
        .controlSize(.small)
    }

    private var matchingDescription: String {
        switch options.matching {
            case .strict:
                return "Plays the recording exactly: waits for every message the app sent, in the recorded order, and fails if one does not come within 60 s. For flows the app repeats identically every time."
            case .relaxed:
                return "Answers each request the app makes with the reply recorded for it, in whatever order it comes, and plays notifications on the recorded timeline, waiting only for the first request of each kind. For apps that poll or subscribe differently on each run, like ErgData with a PM5."
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReplayOptions, Value>) -> Binding<Value> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { value in
                var changed = options
                changed[keyPath: keyPath] = value
                onChange(changed)
            }
        )
    }
}
