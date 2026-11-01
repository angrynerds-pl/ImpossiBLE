import SwiftUI
import AppKit

/// Passthrough's record control: a start/stop button showing whether traffic
/// is being recorded, the current file once one opened, and the folder.
struct PassthroughRecordingBar: View {
    let state: PassthroughRecordingState
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Label(
                    state.isRecording ? "Stop Recording" : "Record",
                    systemImage: state.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .foregroundStyle(state.isRecording ? Color.red : Color.primary)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(state.isRecording
                  ? "Stop writing traffic to a recording"
                  : "Write traffic to a JSON recording that Replay can play back")
            if let path = state.path {
                RecordingFileLabel(path: path)
            } else if state.isRecording {
                Text("Waiting for traffic…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            RecordingsFolderButton(directory: PassthroughRecordingState.directory)
        }
    }
}

/// A recording's file name, with a button revealing it in Finder.
struct RecordingFileLabel: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text((path as NSString).lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

/// Opens a recordings folder in Finder, creating it if nothing was recorded yet.
struct RecordingsFolderButton: View {
    let directory: String

    var body: some View {
        Button {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Open \(directory) in Finder")
    }
}
