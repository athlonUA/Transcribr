import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarContentView: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var directoryStore: RecordsDirectoryStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var micMuteService: MicMuteService

    @State private var settingsExpanded: Bool = false
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            permissionsBanner
            recordingButton
            errorBanner
            transcriptionActionButtons
            transcriptionBanner

            Divider()

            transcriptionSettings

            micMuteRow

            Divider()

            Button {
                openDirectory()
            } label: {
                Label("Open Records Directory", systemImage: "folder")
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                changeDirectory()
            } label: {
                Label("Change Records Directory…", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(MenuRowButtonStyle())

            currentDirectoryView

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(12)
        .frame(width: 320)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                apiKeyFocused = false
            }
        )
        .onAppear {
            Task { @MainActor in
                await recorder.refreshPermissions()
                // Re-check Accessibility every time the popover opens. TCC has no callback
                // for the user toggling the switch, so popover-open is our natural retry.
                micMuteService.start()
            }
        }
    }

    /// Inline recorder row tucked under `Transcription Settings`, sharing its visual group
    /// (no divider between). On `Change hotkey` the right half flips to "Press shortcut…
    /// Cancel" via `isCapturingHotkey`. No separate sheet / Settings window — popover already
    /// has key window focus, which is what `NSEvent.addLocalMonitorForEvents` needs.
    @ViewBuilder
    private var micMuteRow: some View {
        HStack(spacing: 6) {
            Image(systemName: micMuteService.isMuted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(micMuteService.isMuted ? .red : .primary)
                .frame(width: 14)
            Text("Mic Mute:")
                .font(.caption)
            if micMuteService.isCapturingHotkey {
                Text("Press shortcut…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    micMuteService.cancelCapture()
                }
                .controlSize(.small)
            } else {
                Text(micMuteService.hotkey.description)
                    .font(.caption.monospaced())
                Spacer()
                Button("Change hotkey") {
                    // Completion fires for both success and Esc/cancel paths; we don't need
                    // either branch — @Published `hotkey` and `isCapturingHotkey` already
                    // trigger the view refresh.
                    micMuteService.startCapture { _ in }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var transcriptionActionButtons: some View {
        HStack(spacing: 6) {
            Button {
                if let url = recorder.currentURL {
                    recorder.transcribe(audioURL: url)
                }
            } label: {
                Label("Transcribe Last", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(
                recorder.currentURL == nil
                || recorder.state == .recording
                || recorder.transcriptionState == .transcribing
            )

            Button {
                chooseAndTranscribeFile()
            } label: {
                Label("Choose File…", systemImage: "doc")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(recorder.transcriptionState == .transcribing)
        }
    }

    private var transcriptionSettings: some View {
        DisclosureGroup(isExpanded: $settingsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenAI API Key")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        SecureField("sk-…", text: $settingsStore.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .focused($apiKeyFocused)
                        Button("Clear") {
                            settingsStore.apiKey = ""
                            apiKeyFocused = false
                        }
                        .controlSize(.small)
                        .disabled(settingsStore.apiKey.isEmpty)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settingsStore.transcriptionModel) {
                        ForEach(TranscriptionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.caption)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Transcription Settings", systemImage: "key")
                .font(.caption.bold())
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Header waveform reflects only recording state; the mute slash stays in the
            // menu-bar tray icon where it's always visible.
            WaveformBarsIcon(isAnimating: recorder.isRecording, isMuted: false)
            Text("Transcribr")
                .font(.headline)
            Spacer()
            if recorder.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    if let startedAt = recorder.recordingStartedAt {
                        TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                            Text(AudioRecorder.formatDuration(context.date.timeIntervalSince(startedAt)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    } else {
                        Text("REC")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recorder.micPermission == .denied {
                // Informational only — recordings still work, but skip the voice track.
                // Screen Recording remains the only blocking permission (see canStart).
                permissionBanner(
                    title: "Microphone access denied",
                    detail: "Recordings will capture system audio only. Grant access in System Settings to include your voice.",
                    actions: [
                        .init(label: "Open System Settings", action: {
                            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        }),
                    ]
                )
            }
            if !micMuteService.hasAccessibility {
                // Mirrors the Screen Recording banner shape: TCC prompt button first, deep-link
                // fallback second. Re-check is implicit — `.onAppear` re-runs `start()` every
                // time the popover opens, so toggling the System Settings switch and reopening
                // the popover is the natural retry.
                permissionBanner(
                    title: "Accessibility access required",
                    detail: "Enable Transcribr in System Settings → Privacy & Security → Accessibility.",
                    actions: [
                        .init(label: "Request Accessibility Access", action: {
                            _ = micMuteService.requestAccessibilityIfNeeded()
                        }),
                        .init(label: "Open System Settings", action: {
                            micMuteService.openAccessibilitySettings()
                        }),
                    ]
                )
            }
            switch recorder.screenPermission {
            case .granted:
                EmptyView()
            case .notDetermined:
                permissionBanner(
                    title: "Screen Recording access required",
                    detail: "Enable Transcribr in System Settings → Privacy & Security → Screen Recording, then restart the app.",
                    actions: [
                        .init(label: "Request Screen Recording Access", action: {
                            recorder.requestScreenRecordingAccess()
                        }),
                    ]
                )
            case .denied:
                permissionBanner(
                    title: "Screen Recording access required",
                    detail: "Enable Transcribr in System Settings → Privacy & Security → Screen Recording, then restart the app.",
                    actions: [
                        .init(label: "Request Screen Recording Access", action: {
                            recorder.requestScreenRecordingAccess()
                        }),
                        .init(label: "Open System Settings", action: {
                            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        }),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = recorder.lastError, !recorder.isRecording {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var transcriptionBanner: some View {
        switch recorder.transcriptionState {
        case .idle:
            EmptyView()
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                if let progress = recorder.transcriptionProgress, progress.total > 1 {
                    Text("Transcribing chunk \(progress.current) of \(progress.total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Transcribing audio…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.10))
            .cornerRadius(6)
        case .completed(let url):
            HStack {
                Text("Transcription copied")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                Spacer()
                Button("Copy again") {
                    copyTranscription(from: url)
                }
                .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.10))
            .cornerRadius(6)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription failed")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var recordingButton: some View {
        switch recorder.state {
        case .starting:
            busyButton(title: "Starting…", tint: .green)
        case .stopping:
            // The auto-restart path uses `.stopping` as its cancellation window — surface a
            // real button there so the user can abandon a route-change restart they don't
            // want. User-initiated stops show the plain busy spinner.
            if recorder.autoRestartInProgress {
                cancelRestartButton
            } else {
                busyButton(title: "Stopping…", tint: .red)
            }
        case .recording:
            Button {
                recorder.stop()
            } label: {
                Label("End Record", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(.red)
            .buttonStyle(.borderedProminent)
        case .idle:
            Button {
                recorder.start()
            } label: {
                Label("Start Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(.green)
            .buttonStyle(.borderedProminent)
            .disabled(!recorder.canStart)
        }
    }

    private var cancelRestartButton: some View {
        Button {
            recorder.cancelAutoRestart()
        } label: {
            Label("Switching device — Cancel", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(.orange)
        .buttonStyle(.borderedProminent)
    }

    private func busyButton(title: String, tint: Color) -> some View {
        Button(action: {}) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(tint)
        .buttonStyle(.borderedProminent)
        .disabled(true)
    }

    private var currentDirectoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Saving to:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(directoryStore.directory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct BannerAction: Identifiable {
        var id: String { label }
        let label: String
        let action: () -> Void
    }

    private func permissionBanner(title: String, detail: String, actions: [BannerAction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(actions) { entry in
                    Button(entry.label, action: entry.action)
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(6)
    }

    private func openDirectory() {
        try? FileManager.default.createDirectory(
            at: directoryStore.directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(directoryStore.directory)
    }

    private func changeDirectory() {
        guard recorder.state == .idle else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a directory to save audio recordings"
        panel.directoryURL = directoryStore.directory

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryStore.update(to: url)
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyTranscription(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func chooseAndTranscribeFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Transcribe"
        panel.message = "Choose an audio file to transcribe"
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav]

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder.transcribe(audioURL: url)
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowButtonContent(configuration: configuration)
    }
}

private struct MenuRowButtonContent: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(background)
            )
            .contentShape(Rectangle())
    }

    private var background: Color {
        guard isEnabled, configuration.isPressed else { return .clear }
        return Color.primary.opacity(0.18)
    }
}
