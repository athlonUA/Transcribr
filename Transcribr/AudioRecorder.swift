import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

enum MicrophonePermission: Equatable {
    case undetermined
    case granted
    case denied
}

enum ScreenCapturePermission: Equatable {
    case notDetermined
    case granted
    case denied
}

enum RecorderState: Equatable {
    case idle
    case starting
    case recording
    case stopping
}

enum TranscriptionState: Equatable {
    case idle
    case transcribing
    case completed(URL)
    case failed(String)
}

struct TranscriptionProgress: Equatable {
    let current: Int
    let total: Int
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case whisper1 = "whisper-1"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case gpt4oTranscribe = "gpt-4o-transcribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper1: return "Whisper v2 — baseline"
        case .gpt4oMiniTranscribe: return "GPT-4o mini — recommended"
        case .gpt4oTranscribe: return "GPT-4o — best quality"
        }
    }
}

/// `UserDefaults` is plaintext on disk; a shipped product should migrate the API key to Keychain.
final class SettingsStore: ObservableObject {
    static let apiKeyDefaultsKey = "transcribr.openAIAPIKey"
    static let modelDefaultsKey = "transcribr.transcriptionModel"
    /// Without this flag, clearing the API key from the popover would be silently undone on
    /// the next launch as long as `.env` still exists.
    static let envMigrationDoneKey = "transcribr.envMigrationDone"

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.apiKeyDefaultsKey) }
    }

    @Published var transcriptionModel: TranscriptionModel {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: Self.modelDefaultsKey) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? ""
        let migrationDone = UserDefaults.standard.bool(forKey: Self.envMigrationDoneKey)

        if !stored.isEmpty {
            self.apiKey = stored
        } else if !migrationDone, let migrated = EnvLoader.loadOpenAIKey(), !migrated.isEmpty {
            UserDefaults.standard.set(migrated, forKey: Self.apiKeyDefaultsKey)
            self.apiKey = migrated
        } else {
            self.apiKey = ""
        }
        // Marked unconditionally so a later popover-clear sticks regardless of which branch above ran.
        UserDefaults.standard.set(true, forKey: Self.envMigrationDoneKey)

        let rawModel = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
        self.transcriptionModel = TranscriptionModel(rawValue: rawModel ?? "") ?? .gpt4oMiniTranscribe
    }
}

final class AudioRecorder: NSObject, ObservableObject {
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    static let systemAudioWatchdogSeconds: TimeInterval = 2.0
    static let didRequestScreenRecordingKey = "transcribr.didRequestScreenRecording"
    static let maxPendingPlayerBuffers: Int = 50

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var micPermission: MicrophonePermission
    @Published private(set) var screenPermission: ScreenCapturePermission
    @Published private(set) var lastError: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var transcriptionState: TranscriptionState = .idle
    @Published private(set) var transcriptionProgress: TranscriptionProgress?
    /// True while `handleAudioConfigurationChange` is between `.stopping` and the next
    /// `.recording`. The UI swaps the generic "Stopping…/Starting…" busy spinner for an
    /// active Cancel button so the user can abandon a restart they don't want.
    @Published private(set) var autoRestartInProgress: Bool = false

    private let directoryStore: RecordsDirectoryStore
    private let settingsStore: SettingsStore
    private var session: RecordingSession?
    private var watchdogTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?
    /// Set by `cancelAutoRestart()` from the UI; consumed by `handleAudioConfigurationChange`
    /// after `performStop()` returns. Reset on every restart entry so a stale Cancel from a
    /// previous restart attempt never leaks into the next one.
    private var autoRestartCancelRequested: Bool = false
    /// MainActor-isolated. Persisted to disk + clipboard after every chunk so a crash mid-run
    /// leaves the in-progress transcript already saved.
    private var currentAccumulatedText: String = ""

    var canStart: Bool {
        // Mic is optional — a denied mic just makes the session system-audio-only via
        // `buildSession`'s `micEnabled = false` branch. Only screen permission is mandatory,
        // because that's the floor: without it we can't capture system audio at all.
        state == .idle && screenPermission == .granted
    }

    init(directoryStore: RecordsDirectoryStore, settingsStore: SettingsStore) {
        self.directoryStore = directoryStore
        self.settingsStore = settingsStore
        self.micPermission = AudioRecorder.mapMicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        // Fast hint only — `CGPreflightScreenCaptureAccess()` lies in both directions; the
        // authoritative probe via `SCShareableContent` runs from `refreshPermissions()`.
        self.screenPermission = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        super.init()
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func mapMicStatus(_ status: AVAuthorizationStatus) -> MicrophonePermission {
        switch status {
        case .notDetermined: return .undetermined
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    static func generateFileName(at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "recording-\(formatter.string(from: date)).m4a"
    }

    static func formatsAreEquivalent(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "00:00" }
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @MainActor
    func refreshPermissions() async {
        refreshMicPermission()
        screenPermission = await probeScreenAccess()
    }

    /// Sync-only mic probe — `AVCaptureDevice.authorizationStatus(for: .audio)` is a cheap TCC
    /// query (<1ms). Split out so `performStart`'s warm path can refresh mic without paying for
    /// the slow `SCShareableContent` probe.
    @MainActor
    private func refreshMicPermission() {
        micPermission = AudioRecorder.mapMicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    #if DEBUG
    /// Test-only seam: forces specific permission values so unit tests can assert the
    /// `canStart` truth table without depending on the running machine's actual TCC state.
    /// Guarded by `#if DEBUG` so production builds can't accidentally route around the real
    /// permission probes.
    @MainActor
    func overridePermissionsForTesting(mic: MicrophonePermission, screen: ScreenCapturePermission) {
        micPermission = mic
        screenPermission = screen
    }
    #endif

    private func probeScreenAccess() async -> ScreenCapturePermission {
        do {
            // We only need to know IF we have access, not what's shareable — and we never read
            // `.windows` from the result. The `(true, true)` filter pair skips desktop windows
            // and off-screen windows, shaving 100-500ms on systems with many open windows.
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return .granted
        } catch {
            let didRequest = UserDefaults.standard.bool(forKey: Self.didRequestScreenRecordingKey)
            return didRequest ? .denied : .notDetermined
        }
    }

    @MainActor
    func requestScreenRecordingAccess() {
        UserDefaults.standard.set(true, forKey: Self.didRequestScreenRecordingKey)
        _ = CGRequestScreenCaptureAccess()
        Task { @MainActor [weak self] in
            await self?.refreshPermissions()
        }
    }

    @MainActor
    func start() {
        guard state == .idle else { return }
        state = .starting
        lastError = nil
        Task { @MainActor [weak self] in
            await self?.performStart()
        }
    }

    @MainActor
    func stop() {
        guard state == .recording else { return }
        state = .stopping
        Task { @MainActor [weak self] in
            await self?.performStop()
        }
    }

    /// `silentWatchdog` mutes the 2-s "no system audio" watchdog banner — used by the auto-
    /// restart path to honour the "no misleading error mid route-change" contract. The
    /// watchdog still stops a session that never received SC audio; it just doesn't surface
    /// why. Permanent failures from `buildSession` (screen permission revoked, no display)
    /// stay visible via `lastError` so the user can act on them.
    @MainActor
    private func performStart(silentWatchdog: Bool = false) async {
        // Warm-start optimization: refresh mic synchronously (cheap), but only probe screen
        // access via `SCShareableContent` if we don't already believe it's granted. The slow
        // probe enumerates shareable displays/windows and dominates the cold-start time —
        // running it on every start, including auto-restarts after a route change, adds
        // hundreds of ms of avoidable latency. If permission was revoked between recordings
        // the `buildSession` `SCShareableContent` call below will throw, surfacing the error
        // via the standard `Failed to start recording` path.
        refreshMicPermission()
        if screenPermission != .granted {
            screenPermission = await probeScreenAccess()
        }

        if micPermission == .undetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micPermission = granted ? .granted : .denied
        }
        // Mic is optional — denied permission just means the file holds system audio only;
        // `buildSession` skips the mic-input wiring when `micPermission != .granted`. Screen
        // recording remains the only mandatory permission (see `canStart`).

        if screenPermission == .notDetermined {
            UserDefaults.standard.set(true, forKey: Self.didRequestScreenRecordingKey)
            _ = CGRequestScreenCaptureAccess()
            await refreshPermissions()
        }

        guard screenPermission == .granted else {
            lastError = "Screen Recording permission is required to capture system audio. Enable Transcribr in System Settings → Privacy & Security → Screen Recording, then restart Transcribr."
            state = .idle
            return
        }

        do {
            let newSession = try await buildSession()
            session = newSession
            installConfigChangeObserver(for: newSession.engine)
            startWatchdog(silent: silentWatchdog)
            currentURL = newSession.fileURL
            recordingStartedAt = Date()
            // Don't clobber a still-running transcription from a prior recording.
            if transcriptionState != .transcribing {
                transcriptionState = .idle
                transcriptionProgress = nil
            }
            isRecording = true
            state = .recording
        } catch {
            // Recovery path for the warm-start optimization above: if we skipped the slow
            // screen probe assuming `screenPermission == .granted` but permission was revoked
            // between recordings, `buildSession`'s `SCShareableContent` call throws an opaque
            // error. Re-probe here so the banner shows the actionable "enable in System
            // Settings" message instead of a generic SC failure. The re-probe only runs on
            // the failure path so the happy-path latency win is preserved.
            if screenPermission == .granted {
                screenPermission = await probeScreenAccess()
                if screenPermission != .granted {
                    lastError = "Screen Recording permission is required to capture system audio. Enable Transcribr in System Settings → Privacy & Security → Screen Recording, then restart Transcribr."
                    state = .idle
                    return
                }
            }
            lastError = "Failed to start recording: \(error.localizedDescription)"
            state = .idle
        }
    }

    @MainActor
    private func performStop() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        removeConfigChangeObserver()

        if let session {
            if let stream = session.scStream {
                try? await stream.stopCapture()
            }
            session.playerNode.stop()
            session.customMixer.removeTap(onBus: 0)
            session.engine.stop()
            await session.finalize()
        }
        session = nil

        isRecording = false
        recordingStartedAt = nil
        state = .idle
    }

    /// Validates the API key BEFORE flipping to `.transcribing` so a missing-key tap goes
    /// straight to `.failed` without the popover briefly flashing the spinner.
    @MainActor
    func transcribe(audioURL: URL) {
        guard transcriptionState != .transcribing else { return }
        guard !settingsStore.apiKey.isEmpty else {
            transcriptionState = .failed("OpenAI API key is not set. Open Transcription Settings in the popover and paste your key.")
            return
        }
        transcriptionState = .transcribing
        transcriptionProgress = nil
        Task { @MainActor [weak self] in
            await self?.runTranscription(audioURL: audioURL)
        }
    }

    @MainActor
    private func runTranscription(audioURL: URL) async {
        let apiKey = settingsStore.apiKey
        let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        // Don't pre-delete `txtURL` — if the very first chunk fails we want any prior
        // `.txt` from an earlier successful run on the same audio to stay intact.
        currentAccumulatedText = ""

        do {
            let service = TranscriptionService(
                apiKey: apiKey,
                model: settingsStore.transcriptionModel.rawValue
            )
            _ = try await service.transcribe(
                audioFile: audioURL,
                progress: { [weak self] current, total in
                    Task { @MainActor [weak self] in
                        self?.transcriptionProgress = TranscriptionProgress(current: current, total: total)
                    }
                },
                onChunkText: { [weak self] chunkText in
                    Task { @MainActor [weak self] in
                        self?.appendChunkText(chunkText, txtURL: txtURL)
                    }
                }
            )
            // Every chunk has already been written + clipboard'd via `onChunkText`.
            transcriptionProgress = nil
            transcriptionState = .completed(txtURL)
        } catch let TranscriptionError.partialFailure(_, completed, total, underlying) {
            transcriptionProgress = nil
            if currentAccumulatedText.isEmpty {
                transcriptionState = .failed("Transcription failed on first chunk: \(underlying.localizedDescription)")
            } else {
                let annotation = "\n\n[Transcription stopped after chunk \(completed) of \(total): \(underlying.localizedDescription)]"
                try? (currentAccumulatedText + annotation).write(to: txtURL, atomically: true, encoding: .utf8)
                transcriptionState = .failed("Got \(completed) of \(total) chunks before \(underlying.localizedDescription). Partial transcript saved to \(txtURL.lastPathComponent) and copied to clipboard.")
            }
        } catch {
            transcriptionProgress = nil
            transcriptionState = .failed("Transcription failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func appendChunkText(_ text: String, txtURL: URL) {
        if !currentAccumulatedText.isEmpty {
            currentAccumulatedText += " "
        }
        currentAccumulatedText += text

        try? currentAccumulatedText.write(to: txtURL, atomically: true, encoding: .utf8)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentAccumulatedText, forType: .string)
    }

    @MainActor
    private func buildSession() async throws -> RecordingSession {
        let directory = try directoryStore.ensureDirectoryExists()
        let fileURL = Self.uniqueFileURL(in: directory)

        // Probe screen permission before allocating any audio resources so a missing-permission
        // throw doesn't leak a half-built engine. `(true, true)` skips desktop wallpaper +
        // off-screen windows; we only read `.displays` so window enumeration is pure waste.
        let scContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let display = scContent.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? scContent.displays.first
        guard let display else { throw RecorderError.noDisplayAvailable }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Mic is wired whenever permission is granted. On built-in speakers anything the
        // speakers play will bleed into the mic and end up in the file twice — once digitally
        // via SCStream, once via the mic. We accept that trade-off rather than auto-muting:
        // recording yourself talking on a silent system is a more common use case than
        // transcribing system audio without headphones, and pre-muting the mic would silently
        // drop the user's voice in the former case. Apple's VPIO (AEC) was tried and didn't
        // help — it references the unit's own output path, not the system mixer's playback.
        var micEnabled = micPermission == .granted

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let customMixer = AVAudioMixerNode()

        engine.attach(playerNode)
        engine.attach(customMixer)

        if micEnabled {
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
                engine.connect(engine.inputNode, to: customMixer, format: inputFormat)
            } else {
                // BT HFP / flaky USB mics sometimes report a zero-channel input format.
                // Degrade silently to system-audio-only rather than failing the whole session.
                micEnabled = false
            }
        }
        engine.connect(playerNode, to: customMixer, format: Self.canonicalFormat)
        engine.connect(customMixer, to: engine.mainMixerNode, format: Self.canonicalFormat)
        engine.mainMixerNode.outputVolume = 0

        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.canonicalFormat.sampleRate,
            AVNumberOfChannelsKey: Int(Self.canonicalFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000,
        ]
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: fileSettings,
            commonFormat: Self.canonicalFormat.commonFormat,
            interleaved: Self.canonicalFormat.isInterleaved
        )

        let session = RecordingSession(
            engine: engine,
            playerNode: playerNode,
            customMixer: customMixer,
            canonicalFormat: Self.canonicalFormat,
            fileURL: fileURL,
            audioFile: audioFile,
            maxPendingPlayerBuffers: Self.maxPendingPlayerBuffers
        )

        customMixer.installTap(onBus: 0, bufferSize: 4096, format: Self.canonicalFormat) { buffer, _ in
            session.enqueueWrite(buffer)
        }

        let scConfig = SCStreamConfiguration()
        scConfig.capturesAudio = true
        scConfig.excludesCurrentProcessAudio = true
        scConfig.sampleRate = Int(Self.canonicalFormat.sampleRate)
        scConfig.channelCount = Int(Self.canonicalFormat.channelCount)
        scConfig.width = 2
        scConfig.height = 2
        scConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scOutput = ScreenCaptureOutput { [weak session] sampleBuffer in
            session?.handleSystemAudioSample(sampleBuffer)
        }
        let scDelegate = ScreenCaptureDelegate { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleScreenStreamStop(with: error)
            }
        }
        let scStream = SCStream(filter: filter, configuration: scConfig, delegate: scDelegate)
        try scStream.addStreamOutput(scOutput, type: .audio, sampleHandlerQueue: session.sampleQueue)
        try scStream.addStreamOutput(scOutput, type: .screen, sampleHandlerQueue: session.sampleQueue)

        // Anything that throws past this point must clean up local resources so we never leak
        // a zero-byte `.m4a` on disk.
        do {
            engine.prepare()
            try engine.start()
            playerNode.play()
            try await scStream.startCapture()
        } catch {
            playerNode.stop()
            customMixer.removeTap(onBus: 0)
            engine.stop()
            await session.finalize()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        session.attachStream(scStream, output: scOutput, delegate: scDelegate)
        return session
    }

    private static func uniqueFileURL(in directory: URL) -> URL {
        let base = directory.appendingPathComponent(generateFileName())
        let fm = FileManager.default
        if !fm.fileExists(atPath: base.path) {
            return base
        }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for n in 2...999 {
            let candidate = directory.appendingPathComponent("\(stem)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }

    @MainActor
    private func handleScreenStreamStop(with error: Error) {
        guard state == .recording else { return }
        state = .stopping
        lastError = "Screen capture stopped: \(error.localizedDescription)"
        Task { @MainActor [weak self] in
            await self?.performStop()
        }
    }

    /// `silent` suppresses the banner if no system audio arrives within the window — the
    /// recording is still stopped (we never want to keep a zero-audio session running), but the
    /// user is not informed. Used by the auto-restart path so a slow device hand-off doesn't
    /// surface a misleading "no system audio" error mid-route-change.
    @MainActor
    private func startWatchdog(silent: Bool = false) {
        watchdogTask?.cancel()
        let deadlineNanos = UInt64(Self.systemAudioWatchdogSeconds * 1_000_000_000)
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: deadlineNanos)
            guard !Task.isCancelled, let self else { return }
            guard self.state == .recording else { return }
            guard let session = self.session else { return }
            guard !session.didReceiveAnyAudio() else { return }

            self.state = .stopping
            if !silent {
                self.lastError = "No system audio samples were received within \(Int(Self.systemAudioWatchdogSeconds))s. Re-toggle Screen Recording for Transcribr in System Settings → Privacy & Security → Screen Recording, then restart the app."
            }
            await self.performStop()
        }
    }

    @MainActor
    private func installConfigChangeObserver(for engine: AVAudioEngine) {
        removeConfigChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // The outer `[weak self]` is load-bearing: without it the inner Task's `[weak self]`
            // would resolve against the enclosing method's strong `self`, dragging a strong
            // capture of `AudioRecorder` (non-Sendable) into the `@Sendable` Task closure.
            Task { @MainActor [weak self] in
                await self?.handleAudioConfigurationChange()
            }
        }
    }

    /// Auto-restart on `AVAudioEngineConfigurationChange` (headphones plugged in/removed,
    /// AirPods (dis)connected, default device switched). The engine just had its input format
    /// pulled out from under it — we finalize the current `.m4a` and spin up a fresh session
    /// bound to whatever the system has routed to now. The user gets N short files per
    /// session (one per device change) instead of one mixed-rate file AAC can't represent.
    ///
    /// During `.stopping` the UI offers a Cancel button (`cancelAutoRestart()`); we check
    /// `autoRestartCancelRequested` after `performStop()` and skip the restart if set. After
    /// we commit to `.starting` the user has to wait until the new session reaches
    /// `.recording` and use the normal Stop button.
    ///
    /// `lastError` is cleared before `performStart` so a stale message from earlier doesn't
    /// linger. On `performStart` failure (screen permission revoked, no display, SC throw)
    /// the new error stays put — permanent failures must remain visible. A revoked mic is
    /// NOT a failure: `buildSession` just sets `micEnabled = false` and the session keeps
    /// recording system audio. The previous file is finalized on disk regardless.
    ///
    /// Re-entrancy: `guard state == .recording` debounces stacked changes — any change firing
    /// while we're mid-restart is ignored; once we re-enter `.recording` a fresh change
    /// triggers another restart.
    @MainActor
    private func handleAudioConfigurationChange() async {
        guard state == .recording else { return }
        autoRestartCancelRequested = false
        autoRestartInProgress = true
        state = .stopping
        await performStop()

        guard Self.shouldStartAfterRestart(state: state, cancelRequested: autoRestartCancelRequested) else {
            autoRestartInProgress = false
            return
        }

        state = .starting
        lastError = nil
        // `silentWatchdog: true` keeps the 2-s "no system audio" watchdog from surfacing a
        // banner mid route-change. Sync failures inside `performStart` still set `lastError`
        // and we deliberately don't wipe it — permanent revocations must remain visible.
        await performStart(silentWatchdog: true)
        autoRestartInProgress = false
    }

    /// Sets the cancel flag consumed by `handleAudioConfigurationChange` after `performStop()`
    /// returns. Only takes effect while an auto-restart is actually in progress — a stray call
    /// while recording normally is a no-op.
    @MainActor
    func cancelAutoRestart() {
        guard autoRestartInProgress else { return }
        autoRestartCancelRequested = true
    }

    /// Pure decision function — given `state` (after `performStop` returns) and the cancel
    /// flag, should the auto-restart proceed to `performStart`? Extracted so the restart's
    /// state-machine policy is unit-testable without spinning up a real `AVAudioEngine`.
    static func shouldStartAfterRestart(state: RecorderState, cancelRequested: Bool) -> Bool {
        state == .idle && !cancelRequested
    }

    @MainActor
    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    static func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        targetFormat: AVAudioFormat,
        converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var asbd = asbdPointer.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return nil
        }
        inputBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        if formatsAreEquivalent(inputFormat, targetFormat) {
            return inputBuffer
        }

        let conv: AVAudioConverter
        if let existing = converter,
           formatsAreEquivalent(existing.inputFormat, inputFormat),
           formatsAreEquivalent(existing.outputFormat, targetFormat) {
            conv = existing
        } else {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                return nil
            }
            converter = newConverter
            conv = newConverter
        }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(frameCount) * targetFormat.sampleRate / inputFormat.sampleRate)
        ) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        conv.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if conversionError != nil { return nil }
        return outputBuffer
    }
}

private final class RecordingSession {
    let engine: AVAudioEngine
    let playerNode: AVAudioPlayerNode
    let customMixer: AVAudioMixerNode
    let canonicalFormat: AVAudioFormat
    let fileURL: URL

    let writerQueue = DispatchQueue(label: "transcribr.writer", qos: .userInitiated)
    let sampleQueue = DispatchQueue(label: "transcribr.scstream.audio", qos: .userInitiated)

    private let firstSampleReceived = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let pendingPlayerBuffers = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let maxPendingPlayerBuffers: Int

    nonisolated(unsafe) private var audioFile: AVAudioFile?
    nonisolated(unsafe) private var converter: AVAudioConverter?

    private(set) var scStream: SCStream?
    private var scStreamOutput: ScreenCaptureOutput?
    private var scStreamDelegate: ScreenCaptureDelegate?

    init(
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode,
        customMixer: AVAudioMixerNode,
        canonicalFormat: AVAudioFormat,
        fileURL: URL,
        audioFile: AVAudioFile,
        maxPendingPlayerBuffers: Int
    ) {
        self.engine = engine
        self.playerNode = playerNode
        self.customMixer = customMixer
        self.canonicalFormat = canonicalFormat
        self.fileURL = fileURL
        self.audioFile = audioFile
        self.maxPendingPlayerBuffers = maxPendingPlayerBuffers
    }

    func attachStream(_ stream: SCStream, output: ScreenCaptureOutput, delegate: ScreenCaptureDelegate) {
        self.scStream = stream
        self.scStreamOutput = output
        self.scStreamDelegate = delegate
    }

    func enqueueWrite(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.deepCopyFloat32NonInterleaved(buffer) else { return }
        writerQueue.async { [weak self] in
            guard let self, let file = self.audioFile else { return }
            try? file.write(from: copy)
        }
    }

    func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio else {
            return
        }
        guard let pcm = AudioRecorder.makePCMBuffer(
            from: sampleBuffer,
            targetFormat: canonicalFormat,
            converter: &converter
        ) else { return }

        // Drop samples rather than grow memory unbounded if the player queue backs up.
        let current = pendingPlayerBuffers.withLock { $0 }
        if current >= maxPendingPlayerBuffers {
            return
        }
        pendingPlayerBuffers.withLock { $0 += 1 }
        playerNode.scheduleBuffer(pcm, at: nil, options: []) { [weak self] in
            self?.pendingPlayerBuffers.withLock { $0 -= 1 }
        }
        firstSampleReceived.withLock { $0 = true }
    }

    func didReceiveAnyAudio() -> Bool {
        firstSampleReceived.withLock { $0 }
    }

    func finalize() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerQueue.async { [weak self] in
                self?.audioFile = nil
                cont.resume()
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sampleQueue.async { [weak self] in
                self?.converter = nil
                cont.resume()
            }
        }
    }

    private static func deepCopyFloat32NonInterleaved(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.isInterleaved == false,
              let srcChannels = buffer.floatChannelData else {
            return nil
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        guard let dstChannels = copy.floatChannelData else { return nil }

        let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(dstChannels[channel], srcChannels[channel], bytesPerChannel)
        }
        return copy
    }
}

private enum RecorderError: LocalizedError {
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for screen capture."
        }
    }
}

private final class ScreenCaptureOutput: NSObject, SCStreamOutput {
    let onAudio: (CMSampleBuffer) -> Void

    init(onAudio: @escaping (CMSampleBuffer) -> Void) {
        self.onAudio = onAudio
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onAudio(sampleBuffer)
    }
}

private final class ScreenCaptureDelegate: NSObject, SCStreamDelegate {
    let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

enum EnvLoader {
    static func loadOpenAIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }
        let home = NSHomeDirectory()
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? (home + "/Documents")
        var candidates = [
            home + "/.transcribr/.env",
            documents + "/Transcribr/.env",
        ]
        #if DEBUG
        // Stripped from Release so a shipped binary can't be coaxed into reading arbitrary
        // user-home paths.
        candidates.append(home + "/Projects/Transcribr/.env")
        #endif
        for path in candidates {
            if let value = parseValue(forKey: "OPENAI_API_KEY", path: path), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func parseValue(forKey key: String, path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        // `.whitespacesAndNewlines` strips the trailing `\r` from CRLF-terminated files;
        // plain `.whitespaces` would smuggle the `\r` into the API key.
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key else { continue }
            var value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}

enum MultipartFilename {
    /// CR/LF would split the multipart header and inject arbitrary form-data parts; `"`
    /// would close the quoted-string parameter early.
    static func sanitize(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "_")
    }
}

/// Pure chunk-duration math, separated from `TranscriptionService.splitIntoChunks` so it can
/// be unit-tested without `AVAssetExportSession`.
enum ChunkPlanner {
    struct Plan: Equatable {
        let chunkDurationSeconds: Double
        let overlapSeconds: Double
        var advanceSeconds: Double { chunkDurationSeconds - overlapSeconds }
    }

    /// Passthrough takes `min(bytes-budget seconds, duration cap)`. Re-encode uses a fixed
    /// shorter target since the AppleM4A preset's bitrate is independent of the source.
    static func plan(
        totalBytes: Int,
        totalSeconds: Double,
        useReencode: Bool,
        chunkTargetBytes: Int = 22 * 1024 * 1024,
        chunkTargetSeconds: Double = 1200,
        reencodeChunkTargetSeconds: Double = 600,
        overlapSeconds: Double = 3.0
    ) -> Plan {
        let chunkSec: Double
        if useReencode {
            chunkSec = reencodeChunkTargetSeconds
        } else if totalSeconds > 0, totalBytes > 0 {
            let bytesPerSecond = Double(totalBytes) / totalSeconds
            let sizeBased = Double(chunkTargetBytes) / bytesPerSecond
            chunkSec = min(sizeBased, chunkTargetSeconds)
        } else {
            chunkSec = chunkTargetSeconds
        }
        return Plan(chunkDurationSeconds: chunkSec, overlapSeconds: overlapSeconds)
    }
}

private final class TranscriptionService {
    /// OpenAI's hard upload cap.
    static let maxFileSizeBytes: Int = 25 * 1024 * 1024
    /// 3 MB margin under the 25 MB cap because AAC frame alignment makes the per-chunk byte
    /// count unpredictable from a duration estimate.
    static let chunkTargetBytes: Int = 22 * 1024 * 1024
    /// GPT-4o transcription models cap each request at 1400 audio-seconds (~23 min); Whisper-1
    /// has no documented cap but we apply this uniformly.
    static let maxRequestSeconds: Double = 1400
    static let chunkTargetSeconds: Double = 1200
    /// Overlap between adjacent chunks. AAC frame-aligned passthrough cuts at sample
    /// boundaries — without overlap, a word straddling the boundary gets sliced and Whisper
    /// drops it from both sides. Mild text duplication around the boundary is the trade-off.
    static let chunkOverlapSeconds: Double = 3.0
    /// AppleM4A re-encode runs at a higher bitrate than typical source recordings, so the
    /// re-encode path uses a shorter chunk to stay under 25 MB.
    static let reencodeChunkTargetSeconds: Double = 600

    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// `onChunkText` fires once per chunk (and once for single-shot) so the caller can persist
    /// transcripts incrementally — a crash mid-run leaves everything completed so far on disk.
    /// If a chunk upload fails, `TranscriptionError.partialFailure` is thrown; the caller has
    /// already received every completed chunk's text via `onChunkText` by then.
    func transcribe(
        audioFile: URL,
        progress: @escaping (Int, Int) -> Void,
        onChunkText: @escaping (String) -> Void
    ) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: audioFile.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0

        let asset = AVURLAsset(url: audioFile)
        let totalDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(totalDuration)

        let sizeFits = size <= Self.maxFileSizeBytes
        let durationFits = totalSeconds.isFinite && totalSeconds <= Self.maxRequestSeconds

        if sizeFits && durationFits {
            progress(1, 1)
            let text = try await uploadAudioFile(audioFile)
            onChunkText(text)
            return text
        }

        let useReencode = try await !Self.isAACSource(asset)
        let chunkURLs = try await splitIntoChunks(
            sourceFile: audioFile,
            asset: asset,
            totalDuration: totalDuration,
            useReencode: useReencode
        )
        defer {
            for url in chunkURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        guard !chunkURLs.isEmpty else {
            throw TranscriptionError.chunkingFailed("Chunking produced no segments.")
        }

        var transcripts: [String] = []
        for (idx, chunkURL) in chunkURLs.enumerated() {
            progress(idx + 1, chunkURLs.count)
            do {
                let text = try await uploadAudioFile(chunkURL)
                transcripts.append(text)
                onChunkText(text)
            } catch {
                let partial = transcripts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                throw TranscriptionError.partialFailure(
                    partialText: partial,
                    completedChunks: idx,
                    totalChunks: chunkURLs.count,
                    underlying: error
                )
            }
        }
        return transcripts.joined(separator: " ")
    }

    /// Heuristic codec detection — reads the first audio track's `formatDescriptions` and
    /// returns `true` iff the codec is MPEG-4 AAC. The fast happy path: anything we record
    /// ourselves is AAC, so passthrough is selected.
    private static func isAACSource(_ asset: AVURLAsset) async throws -> Bool {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return false }
        let formats = try await track.load(.formatDescriptions)
        for fd in formats {
            let cmFormat = fd
            if let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat) {
                if asbdPointer.pointee.mFormatID == kAudioFormatMPEG4AAC {
                    return true
                }
            }
        }
        return false
    }

    private func uploadAudioFile(_ audioFile: URL) async throws -> String {
        let audioData = try Data(contentsOf: audioFile)
        let boundary = "Boundary-\(UUID().uuidString)"
        let safeFilename = MultipartFilename.sanitize(audioFile.lastPathComponent)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n")
        body.append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")
        body.append("--\(boundary)--\r\n")

        let (data, response) = try await session.upload(for: request, from: body)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.serverError(statusCode: http.statusCode, body: bodyText)
        }

        struct Decoded: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(Decoded.self, from: data)
        return decoded.text
    }

    /// Splits `sourceFile` into N temporary `.m4a` chunks. Two paths:
    ///
    /// - **Passthrough** (`useReencode = false`, default for AAC sources): `AVAssetExport`
    ///   copies AAC frames byte-for-byte. Chunk length picked from both the bytes-per-second
    ///   estimate and the GPT-4o 1400 s duration cap, whichever is shorter.
    /// - **Re-encode** (`useReencode = true`, for `.wav` / `.mp3` and other non-AAC sources):
    ///   `AVAssetExportPresetAppleM4A` transcodes to AAC; chunks shortened to
    ///   `reencodeChunkTargetSeconds` so the higher re-encode bitrate doesn't overshoot 25 MB.
    ///
    /// Adjacent chunks **overlap** by `chunkOverlapSeconds` so words spanning a sample-aligned
    /// cut survive in at least one chunk. Slight text duplication around the boundary is the
    /// trade-off and is acceptable for voice transcripts.
    private func splitIntoChunks(
        sourceFile: URL,
        asset: AVURLAsset,
        totalDuration: CMTime,
        useReencode: Bool
    ) async throws -> [URL] {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
        let totalBytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let totalSeconds = CMTimeGetSeconds(totalDuration)

        guard totalSeconds.isFinite, totalSeconds > 0, totalBytes > 0 else {
            throw TranscriptionError.chunkingFailed("Could not read duration or size of the audio file.")
        }

        let plan = ChunkPlanner.plan(
            totalBytes: totalBytes,
            totalSeconds: totalSeconds,
            useReencode: useReencode,
            chunkTargetBytes: Self.chunkTargetBytes,
            chunkTargetSeconds: Self.chunkTargetSeconds,
            reencodeChunkTargetSeconds: Self.reencodeChunkTargetSeconds,
            overlapSeconds: Self.chunkOverlapSeconds
        )
        let chunkDuration = CMTime(seconds: plan.chunkDurationSeconds, preferredTimescale: 600)
        let overlap = CMTime(seconds: plan.overlapSeconds, preferredTimescale: 600)

        guard CMTimeCompare(chunkDuration, overlap) > 0 else {
            throw TranscriptionError.chunkingFailed("Computed chunk duration (\(plan.chunkDurationSeconds)s) is not larger than the overlap window (\(plan.overlapSeconds)s); cannot make forward progress.")
        }

        let preset = useReencode ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough
        var urls: [URL] = []
        var startTime = CMTime.zero

        do {
            while CMTimeCompare(startTime, totalDuration) < 0 {
                let remaining = CMTimeSubtract(totalDuration, startTime)
                let thisChunkDuration = CMTimeCompare(remaining, chunkDuration) < 0 ? remaining : chunkDuration

                guard CMTimeCompare(thisChunkDuration, .zero) > 0 else {
                    throw TranscriptionError.chunkingFailed("Chunk duration collapsed to zero mid-loop.")
                }

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("transcribr-chunk-\(UUID().uuidString).m4a")

                try await exportChunk(
                    asset: asset,
                    timeRange: CMTimeRange(start: startTime, duration: thisChunkDuration),
                    to: tempURL,
                    preset: preset
                )
                urls.append(tempURL)

                // Non-last chunks back up by `overlap` so the next chunk's start sits in the
                // previous chunk's tail. The last chunk has no "next" to overlap with.
                let advance: CMTime
                if CMTimeCompare(remaining, chunkDuration) < 0 {
                    advance = thisChunkDuration
                } else {
                    advance = CMTimeSubtract(thisChunkDuration, overlap)
                }
                guard CMTimeCompare(advance, .zero) > 0 else {
                    throw TranscriptionError.chunkingFailed("Chunk advance step was zero; refusing to loop forever.")
                }
                startTime = CMTimeAdd(startTime, advance)
            }
        } catch {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        return urls
    }

    private func exportChunk(
        asset: AVAsset,
        timeRange: CMTimeRange,
        to outputURL: URL,
        preset: String
    ) async throws {
        // AVAssetExportSession refuses to overwrite, and a stale file from a killed previous
        // run could theoretically sit at the UUID path.
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw TranscriptionError.chunkingFailed("AVAssetExportSession unavailable for preset \(preset).")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = timeRange

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    cont.resume(returning: ())
                case .failed:
                    cont.resume(throwing: exportSession.error
                        ?? TranscriptionError.chunkingFailed("Export session failed without an underlying error."))
                case .cancelled:
                    cont.resume(throwing: TranscriptionError.chunkingFailed("Export cancelled."))
                default:
                    cont.resume(throwing: TranscriptionError.chunkingFailed("Export ended in unexpected state \(exportSession.status.rawValue)."))
                }
            }
        }
    }

}

private enum TranscriptionError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, body: String)
    case fileTooLarge(sizeBytes: Int, limitBytes: Int)
    case chunkingFailed(String)
    case partialFailure(partialText: String, completedChunks: Int, totalChunks: Int, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from OpenAI."
        case .serverError(let code, let body):
            let trimmed = body.prefix(200)
            return "OpenAI error \(code): \(trimmed)"
        case .fileTooLarge(let size, let limit):
            let sizeMB = Double(size) / 1_048_576
            let limitMB = Double(limit) / 1_048_576
            return String(format: "Audio file is %.1f MB — OpenAI's transcription API rejects anything over %.0f MB and automatic chunking did not produce uploadable pieces.", sizeMB, limitMB)
        case .chunkingFailed(let detail):
            return "Could not split the audio file into chunks: \(detail)"
        case .partialFailure(_, let done, let total, let underlying):
            return "Transcribed \(done) of \(total) chunks before failure: \(underlying.localizedDescription)"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
