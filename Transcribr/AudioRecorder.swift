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

/// Persists the OpenAI API key and the chosen transcription model in `UserDefaults`. On first
/// launch, if `UserDefaults` is empty and an `.env` with `OPENAI_API_KEY` exists at one of the
/// known locations, the key is migrated into `UserDefaults` so the user doesn't have to re-enter
/// it. After that the `.env` is no longer consulted — the popover's settings section is the
/// single source of truth.
///
/// `UserDefaults` is plaintext on disk under `~/Library/Preferences/`. That's adequate for a
/// local development app; a shipped product should migrate this storage to Keychain.
final class SettingsStore: ObservableObject {
    static let apiKeyDefaultsKey = "transcribr.openAIAPIKey"
    static let modelDefaultsKey = "transcribr.transcriptionModel"
    /// One-shot flag — set to `true` after a successful `.env` → `UserDefaults` migration so the
    /// migration never re-runs. Without this, clearing the API key from the popover would be
    /// undone on next launch as long as `.env` still exists.
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
        // Mark migration done in every init path so `.env` is never re-consulted after the
        // first launch — including the branch where UserDefaults already holds a key. Without
        // this, a user who clears the key in the popover and then restarts could see `.env`
        // silently re-import the old value.
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

    private let directoryStore: RecordsDirectoryStore
    private let settingsStore: SettingsStore
    private var session: RecordingSession?
    private var watchdogTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?

    var canStart: Bool {
        state == .idle && micPermission != .denied && screenPermission == .granted
    }

    init(directoryStore: RecordsDirectoryStore, settingsStore: SettingsStore) {
        self.directoryStore = directoryStore
        self.settingsStore = settingsStore
        self.micPermission = AudioRecorder.mapMicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        // Fast hint at init only. `CGPreflightScreenCaptureAccess()` is known to return false
        // even when the user has granted Screen Recording in System Settings — the reliable
        // check is `SCShareableContent` which we run from `refreshPermissions()` on first
        // popover open and at every Start.
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
        micPermission = AudioRecorder.mapMicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        screenPermission = await probeScreenAccess()
    }

    private func probeScreenAccess() async -> ScreenCapturePermission {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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

    @MainActor
    private func performStart() async {
        await refreshPermissions()

        if micPermission == .undetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micPermission = granted ? .granted : .denied
        }
        guard micPermission == .granted else {
            lastError = "Microphone access is required to record audio."
            state = .idle
            return
        }

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
            startWatchdog()
            currentURL = newSession.fileURL
            recordingStartedAt = Date()
            transcriptionState = .idle
            isRecording = true
            state = .recording
        } catch {
            lastError = "Failed to start recording: \(error.localizedDescription)"
            state = .idle
        }
    }

    @MainActor
    private func performStop() async {
        // state is already .stopping (set synchronously by `stop()` / event handlers).
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

    /// Public entry point — UI invokes this when the user clicks "Transcribe Last Recording" or
    /// "Choose File…". Transcription is no longer auto-started after stop.
    @MainActor
    func transcribe(audioURL: URL) {
        Task { @MainActor [weak self] in
            await self?.runTranscription(audioURL: audioURL)
        }
    }

    @MainActor
    private func runTranscription(audioURL: URL) async {
        let apiKey = settingsStore.apiKey
        guard !apiKey.isEmpty else {
            transcriptionState = .failed("OpenAI API key is not set. Open Transcription Settings in the popover and paste your key.")
            return
        }

        transcriptionState = .transcribing

        do {
            let service = TranscriptionService(
                apiKey: apiKey,
                model: settingsStore.transcriptionModel.rawValue
            )
            let text = try await service.transcribe(audioFile: audioURL)
            let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: txtURL, atomically: true, encoding: .utf8)

            // Auto-copy the transcript to the clipboard so the user can paste immediately.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            transcriptionState = .completed(txtURL)
        } catch {
            transcriptionState = .failed("Transcription failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func buildSession() async throws -> RecordingSession {
        let directory = try directoryStore.ensureDirectoryExists()
        let fileURL = Self.uniqueFileURL(in: directory)

        // Probe screen recording permission (and resolve the display filter) before allocating
        // any audio resources. If permission is missing this throws cleanly with nothing to
        // clean up.
        let scContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display = scContent.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? scContent.displays.first
        guard let display else { throw RecorderError.noDisplayAvailable }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let customMixer = AVAudioMixerNode()

        engine.attach(playerNode)
        engine.attach(customMixer)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.invalidInputDevice
        }
        engine.connect(engine.inputNode, to: customMixer, format: inputFormat)
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

        // Now actually start engine + stream. Anything that throws past this point must
        // clean up local resources (file, tap, engine) so we never leak a zero-byte .m4a.
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
        // Pathological fallback: append UUID prefix.
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

    @MainActor
    private func startWatchdog() {
        watchdogTask?.cancel()
        let deadlineNanos = UInt64(Self.systemAudioWatchdogSeconds * 1_000_000_000)
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: deadlineNanos)
            guard !Task.isCancelled, let self else { return }
            guard self.state == .recording else { return }
            guard let session = self.session else { return }
            guard !session.didReceiveAnyAudio() else { return }

            self.state = .stopping
            self.lastError = "No system audio samples were received within \(Int(Self.systemAudioWatchdogSeconds))s. Re-toggle Screen Recording for Transcribr in System Settings → Privacy & Security → Screen Recording, then restart the app."
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
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.state = .stopping
                self.lastError = "Audio device configuration changed mid-recording (input or output switched). Recording stopped to avoid a truncated file."
                await self.performStop()
            }
        }
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

        // Backpressure: if the player's internal buffer queue is too deep (slow consumer or
        // engine stall), drop further samples rather than grow memory unbounded.
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
    case invalidInputDevice
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .invalidInputDevice:
            return "No audio input device available."
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

// MARK: - .env loader
//
// Resolves `OPENAI_API_KEY` from, in priority order:
//   1. Process env var (set via Xcode scheme or shell when launching from terminal).
//   2. ~/.transcribr/.env
//   3. ~/Documents/<records-dir>/.env  (where the user keeps recordings)
//   4. /Users/<current-user>/Projects/Transcribr/.env (development convenience).
//
// In a shipped app this should be replaced with Keychain — `.env` lookups are a dev-only
// affordance and live outside the app bundle so the key is never embedded in the binary.

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
        // Development convenience: pick up the project-root .env when the app is launched
        // from Xcode's DerivedData. Stripped from Release builds so a shipped binary can't
        // be tricked into reading arbitrary user-home paths.
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
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}

// MARK: - OpenAI Whisper transcription

private final class TranscriptionService {
    /// OpenAI's documented hard limit on the `/v1/audio/transcriptions` upload.
    static let maxFileSizeBytes: Int = 25 * 1024 * 1024

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

    func transcribe(audioFile: URL) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: audioFile.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxFileSizeBytes else {
            throw TranscriptionError.fileTooLarge(sizeBytes: size, limitBytes: Self.maxFileSizeBytes)
        }

        let audioData = try Data(contentsOf: audioFile)
        let boundary = "Boundary-\(UUID().uuidString)"
        let safeFilename = Self.sanitizeMultipartFilename(audioFile.lastPathComponent)

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

    /// Strips characters that would break the `filename="..."` token of the multipart body:
    /// CR/LF (would split the header), `"` (closes the quoted-string early).
    static func sanitizeMultipartFilename(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "_")
    }
}

private enum TranscriptionError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, body: String)
    case fileTooLarge(sizeBytes: Int, limitBytes: Int)

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
            return String(format: "Audio file is %.1f MB — OpenAI's transcription API rejects anything over %.0f MB. Trim or split the recording before transcribing.", sizeMB, limitMB)
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
