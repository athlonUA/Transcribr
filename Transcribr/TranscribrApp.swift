import AppKit
import Combine
import SwiftUI

@main
struct TranscribrApp: App {
    @StateObject private var directoryStore: RecordsDirectoryStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var recorder: AudioRecorder
    /// `MicMuteService.shared` is the singleton dereferenced by the CGEventTap C callback;
    /// wrapping it in `@StateObject` is what gives the menu-bar label and popover row their
    /// SwiftUI observation. Same instance, two access paths.
    @StateObject private var micMuteService = MicMuteService.shared

    init() {
        let dirStore = RecordsDirectoryStore()
        let settings = SettingsStore()
        _directoryStore = StateObject(wrappedValue: dirStore)
        _settingsStore = StateObject(wrappedValue: settings)
        let audioRecorder = AudioRecorder(directoryStore: dirStore, settingsStore: settings)
        _recorder = StateObject(wrappedValue: audioRecorder)

        // Wire the Quick Record hotkey and install the event tap at launch: the popover's
        // `.onAppear` only runs once the user opens it, and the hotkeys must work before that.
        let muteService = MicMuteService.shared
        muteService.onQuickRecordHotkey = { [weak audioRecorder] in
            audioRecorder?.toggleQuickRecord()
        }
        Task { @MainActor in
            muteService.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                recorder: recorder,
                directoryStore: directoryStore,
                settingsStore: settingsStore,
                micMuteService: micMuteService
            )
        } label: {
            WaveformBarsIcon(
                isAnimating: recorder.isRecording,
                isProcessing: recorder.isTranscriptionBusy,
                isMuted: micMuteService.isMuted
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The body must return a single `Image` — `MenuBarExtra` rasterises the label to
/// `NSStatusItem.button.image`, and wrapping the image in a `TimelineView` or other container
/// breaks the popover click target on some macOS versions.
enum IconActivity: Equatable {
    case idle
    /// Pulsing bars.
    case recording
    /// Transcription and/or rephrase in flight: bars sweep as a travelling wave.
    case processing

    /// Recording wins when both are true (a new recording can start while the previous one is
    /// still being transcribed) because it is the state the user must be able to see.
    static func resolve(isRecording: Bool, isProcessing: Bool) -> IconActivity {
        if isRecording { return .recording }
        return isProcessing ? .processing : .idle
    }
}

struct WaveformBarsIcon: View {
    let isAnimating: Bool
    var isProcessing: Bool = false
    let isMuted: Bool
    @State private var tick: UInt64 = 0

    private var activity: IconActivity {
        IconActivity.resolve(isRecording: isAnimating, isProcessing: isProcessing)
    }

    var body: some View {
        Image(nsImage: activity == .idle
            ? Self.idleImage(muted: isMuted)
            : Self.animatedImage(tick: tick, muted: isMuted, activity: activity))
            .accessibilityLabel(Self.accessibilityLabel(activity: activity, isMuted: isMuted))
            .onReceive(Self.timerPublisher) { _ in
                if activity != .idle {
                    tick = tick &+ 1
                }
            }
    }

    static func accessibilityLabel(activity: IconActivity, isMuted: Bool) -> String {
        switch (activity, isMuted) {
        case (.recording, true): return "Transcribr: recording, microphone muted"
        case (.recording, false): return "Transcribr: recording"
        case (.processing, true): return "Transcribr: transcribing, microphone muted"
        case (.processing, false): return "Transcribr: transcribing"
        case (.idle, true): return "Transcribr: microphone muted"
        case (.idle, false): return "Transcribr: idle"
        }
    }

    /// Pure so the motion is unit-testable without rendering. Recording pulses the base
    /// silhouette; processing sweeps a wave across equal-ish bars (opposite direction, larger
    /// amplitude) so the two states read differently at menu-bar size.
    static func barHeight(index: Int, tick: UInt64, activity: IconActivity) -> CGFloat {
        switch activity {
        case .idle:
            return baseBarHeights[index]
        case .recording:
            let t = (Double(tick) / 12.0) * 2.0 * .pi * cyclesPerSecond
            let normalized = (sin(t + Double(index) * 0.9) + 1.0) / 2.0
            return baseBarHeights[index] * CGFloat(pulseMin + pulseRange * normalized)
        case .processing:
            let t = (Double(tick) / 12.0) * 2.0 * .pi * processingCyclesPerSecond
            let normalized = (sin(t - Double(index) * 1.1) + 1.0) / 2.0
            return processingMinHeight + (totalHeight - processingMinHeight) * CGFloat(normalized)
        }
    }

    private static let timerPublisher = Timer
        .publish(every: 1.0 / 12.0, on: .main, in: .common)
        .autoconnect()

    private static let barCount: Int = 5
    private static let barWidth: CGFloat = 2.0
    private static let barSpacing: CGFloat = 1.5
    private static let totalHeight: CGFloat = 14
    private static let baseBarHeights: [CGFloat] = [4, 8, 12, 8, 4]
    private static let cyclesPerSecond: Double = 0.7
    private static let pulseMin: Double = 0.75
    private static let pulseRange: Double = 0.25
    private static let muteSlashLineWidth: CGFloat = 1.5
    private static let processingCyclesPerSecond: Double = 1.2
    private static let processingMinHeight: CGFloat = 3

    private static var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    private static let idleImagePlain: NSImage = makeIdleImage(muted: false)
    private static let idleImageMuted: NSImage = makeIdleImage(muted: true)

    private static func idleImage(muted: Bool) -> NSImage {
        muted ? idleImageMuted : idleImagePlain
    }

    private static func makeIdleImage(muted: Bool) -> NSImage {
        let size = NSSize(width: totalWidth, height: totalHeight)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for i in 0..<barCount {
                drawBar(index: i, height: baseBarHeights[i])
            }
            if muted {
                drawMuteSlash()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func animatedImage(tick: UInt64, muted: Bool, activity: IconActivity) -> NSImage {
        let size = NSSize(width: totalWidth, height: totalHeight)

        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for i in 0..<barCount {
                drawBar(index: i, height: barHeight(index: i, tick: tick, activity: activity))
            }
            if muted {
                drawMuteSlash()
            }
            return true
        }
        img.isTemplate = true
        img.cacheMode = .never
        return img
    }

    private static func drawBar(index: Int, height: CGFloat) {
        let x = CGFloat(index) * (barWidth + barSpacing)
        let y = (totalHeight - height) / 2
        let rect = NSRect(x: x, y: y, width: barWidth, height: height)
        NSBezierPath(
            roundedRect: rect,
            xRadius: barWidth / 2,
            yRadius: barWidth / 2
        ).fill()
    }

    private static func drawMuteSlash() {
        // Single black template-stroke from top-left to bottom-right. The menu bar will tint
        // it the system foreground (black/white) automatically because the parent image is
        // marked `isTemplate = true`.
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = muteSlashLineWidth
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 0, y: totalHeight))
        path.line(to: NSPoint(x: totalWidth, y: 0))
        path.stroke()
    }
}
