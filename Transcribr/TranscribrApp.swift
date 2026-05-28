import AppKit
import Combine
import SwiftUI

@main
struct TranscribrApp: App {
    @StateObject private var directoryStore: RecordsDirectoryStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var recorder: AudioRecorder

    init() {
        let dirStore = RecordsDirectoryStore()
        let settings = SettingsStore()
        _directoryStore = StateObject(wrappedValue: dirStore)
        _settingsStore = StateObject(wrappedValue: settings)
        _recorder = StateObject(wrappedValue: AudioRecorder(
            directoryStore: dirStore,
            settingsStore: settings
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                recorder: recorder,
                directoryStore: directoryStore,
                settingsStore: settingsStore
            )
        } label: {
            WaveformBarsIcon(isAnimating: recorder.isRecording)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Custom 5-bar waveform icon used everywhere in the UI — both as the menu bar tray icon and in
/// the popover header — so the visual stays consistent.
///
///   - Idle:      five rounded vertical bars with a symmetric short-tall-tallest-tall-short
///                pattern, mimicking SF Symbol `waveform` proportions. Static.
///   - Animating: each bar pulses gently around its base height (75–100%) with a phase offset
///                between bars, giving a slow travelling-wave effect. Driven by a shared
///                `Timer.publish` at 12 fps; `@State` bumps on each tick, body re-renders a fresh
///                `NSImage` with `cacheMode = .never`.
///
/// The body always returns a single `Image` (no `TimelineView` wrapper) — that's important
/// because `MenuBarExtra` rasterises the label to `NSStatusItem.button.image`, and a non-`Image`
/// label sometimes breaks the popover click target.
struct WaveformBarsIcon: View {
    let isAnimating: Bool
    @State private var tick: UInt64 = 0

    var body: some View {
        Image(nsImage: isAnimating ? Self.animatedImage(tick: tick) : Self.idleImage)
            .accessibilityLabel(isAnimating ? "Transcribr: recording" : "Transcribr: idle")
            .onReceive(Self.timerPublisher) { _ in
                if isAnimating {
                    tick = tick &+ 1
                }
            }
    }

    private static let timerPublisher = Timer
        .publish(every: 1.0 / 12.0, on: .main, in: .common)
        .autoconnect()

    private static let barCount: Int = 5
    private static let barWidth: CGFloat = 2.0
    private static let barSpacing: CGFloat = 1.5
    private static let totalHeight: CGFloat = 14
    /// Symmetric "tall-in-the-middle" pattern matching SF Symbol `waveform` proportions.
    private static let baseBarHeights: [CGFloat] = [4, 8, 12, 8, 4]
    private static let cyclesPerSecond: Double = 0.7
    /// Subtle pulse: each bar swings between 75% and 100% of its base height.
    private static let pulseMin: Double = 0.75
    private static let pulseRange: Double = 0.25

    private static var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    private static let idleImage: NSImage = {
        let size = NSSize(width: totalWidth, height: totalHeight)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for i in 0..<barCount {
                drawBar(index: i, height: baseBarHeights[i])
            }
            return true
        }
        img.isTemplate = true
        return img
    }()

    private static func animatedImage(tick: UInt64) -> NSImage {
        let t = (Double(tick) / 12.0) * 2.0 * .pi * cyclesPerSecond
        let size = NSSize(width: totalWidth, height: totalHeight)

        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill() // template — re-tinted by the menu bar / surrounding view.
            for i in 0..<barCount {
                let phase = Double(i) * 0.9
                let normalized = (sin(t + phase) + 1.0) / 2.0
                let pulse = pulseMin + pulseRange * normalized
                let height = baseBarHeights[i] * CGFloat(pulse)
                drawBar(index: i, height: height)
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
}
