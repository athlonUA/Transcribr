import AppKit
import ApplicationServices
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import os

/// Global microphone mute service.
///
/// Owns three pieces of OS plumbing:
/// - **CoreAudio HAL**: read/write the default input device's mute state (or fall back to
///   `volumeScalar = 0` on devices like the MacBook built-in mic that don't expose a hardware
///   mute property). Listens to default-input-device changes so external observers see the
///   right state when the user plugs in a USB mic.
/// - **CGEventTap** (`.cgSessionEventTap`, `.headInsertEventTap`): intercepts global key-down
///   events on the mach-port thread, matches them against the user's hotkey, and toggles the
///   mute on the main thread when a match consumes the event. Re-enables itself on
///   `tapDisabledByTimeout` / `tapDisabledByUserInput`.
/// - **NSEvent local monitor**: drives the in-popover hotkey recorder. Local-only because the
///   recorder UI lives in the popover and we don't want the keystrokes to escape the focused
///   window. Auto-cancels on `willResignActive` so the recorder can't get "stuck" if the user
///   alt-tabs away mid-capture.
///
/// Singleton + `ObservableObject`: the singleton form is required by the API contract and is
/// what the CGEventTap C callback dereferences via `Unmanaged`; `ObservableObject` is what
/// SwiftUI views bind to. Same instance, two access paths.
final class MicMuteService: ObservableObject {
    static let shared = MicMuteService()

    static let hotkeyKey = "transcribr.micMute.hotkey"
    /// Pre-mute volume so unmute can restore it on devices that fell back to the volume path.
    static let savedVolumeKey = "transcribr.micMute.savedVolume"

    @Published private(set) var isMuted: Bool = false
    @Published private(set) var hasAccessibility: Bool = false
    @Published private(set) var isCapturingHotkey: Bool = false

    /// Read on the mach-port thread (tap callback) and written from the main thread (recorder
    /// completion). `OSAllocatedUnfairLock` guarantees atomic visibility — same pattern used
    /// in `RecordingSession.firstSampleReceived` (AudioRecorder.swift).
    private let hotkeyStorage: OSAllocatedUnfairLock<Hotkey>

    /// SwiftUI binds to the published state on this object; mutating `hotkey` from the main
    /// thread fires `objectWillChange` so the popover row re-renders with the new label.
    /// Setter is main-thread only — every callsite is reached via `@MainActor` (recorder
    /// handler) or `MainActor.run`. `Hotkey.init` is the sole sanitisation point; the setter
    /// trusts that any `Hotkey` value already has its flag bits masked.
    var hotkey: Hotkey {
        get { hotkeyStorage.withLock { $0 } }
        set {
            hotkeyStorage.withLock { $0 = newValue }
            persistHotkey(newValue)
            objectWillChange.send()
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var defaultInputListenerInstalled = false

    private var localMonitor: Any?
    private var captureCompletion: ((Hotkey?) -> Void)?
    private var resignActiveObserver: NSObjectProtocol?

    private init() {
        var initial = Hotkey.default
        if let data = UserDefaults.standard.data(forKey: Self.hotkeyKey),
           let stored = try? JSONDecoder().decode(Hotkey.self, from: data) {
            initial = stored
        }
        self.hotkeyStorage = OSAllocatedUnfairLock(initialState: initial)
    }

    // MARK: - Public API

    /// Idempotent. Call from app lifecycle (`TranscribrApp.init` / popover `.onAppear`) — first
    /// call sets up everything; subsequent calls re-check Accessibility and create the tap if
    /// permission was just granted. Cheap when already running (a few HAL lookups).
    @MainActor
    func start() {
        let trusted = AccessibilityChecker.isTrusted()
        hasAccessibility = trusted
        if trusted {
            installTap()
            installDefaultInputDeviceListener()
            refreshMutedStateFromHAL()
        } else {
            // Permission was revoked since last `start()` — tear down the now-defunct tap so
            // the banner state matches reality.
            removeTap()
        }
    }

    /// Resolves the current default input device **once** and uses the same `AudioDeviceID`
    /// for both the read and the write — a second resolution between calls would race against
    /// a concurrent device hand-off.
    @MainActor
    func toggle() {
        guard let deviceID = CoreAudioMuteController.defaultInputDeviceID() else { return }
        let currentlyMuted = CoreAudioMuteController.readMuteState(deviceID: deviceID)
        CoreAudioMuteController.setMuteState(
            !currentlyMuted,
            deviceID: deviceID,
            fallbackKey: Self.savedVolumeKey
        )
        // Re-read instead of assuming the write succeeded: some HALs silently ignore mute
        // writes (e.g. a mic that lost connection between calls). UI must reflect truth.
        isMuted = CoreAudioMuteController.readMuteState(deviceID: deviceID)
    }

    @MainActor
    func startCapture(completion: @escaping (Hotkey?) -> Void) {
        // Drop any previous capture's completion silently — caller switching capture state
        // mid-recording shouldn't get a phantom nil callback.
        captureCompletion = nil
        cleanupCaptureMonitors()

        isCapturingHotkey = true
        captureCompletion = completion

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleCaptureEvent(event)
        }
        // The popover loses key window when the user alt-tabs / clicks outside; without this
        // the recorder stays "armed" forever and never sees the next keystroke.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelCapture()
            }
        }
    }

    @MainActor
    func cancelCapture() {
        guard isCapturingHotkey else { return }
        let completion = captureCompletion
        captureCompletion = nil
        cleanupCaptureMonitors()
        isCapturingHotkey = false
        completion?(nil)
    }

    /// `true` if Accessibility is already granted. Otherwise shows the system prompt that
    /// directs the user into System Settings. The function returns synchronously — TCC has no
    /// callback when the user actually flips the toggle, so callers (typically the banner)
    /// must re-check via `start()` after the user returns to the app.
    @MainActor
    @discardableResult
    func requestAccessibilityIfNeeded() -> Bool {
        let trusted = AccessibilityChecker.isTrusted()
        hasAccessibility = trusted
        if trusted {
            return true
        }
        AccessibilityChecker.promptForTrust()
        return false
    }

    /// Direct deep-link to the Accessibility privacy pane. Used by the banner's secondary
    /// button when the user has already dismissed the system prompt and just wants to get to
    /// the toggle.
    @MainActor
    func openAccessibilitySettings() {
        AccessibilityChecker.openSystemSettings()
    }

    // MARK: - Private

    private func cleanupCaptureMonitors() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        if let obs = resignActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            resignActiveObserver = nil
        }
    }

    @MainActor
    private func handleCaptureEvent(_ event: NSEvent) -> NSEvent? {
        // Esc always cancels — by convention, regardless of modifier state. Means a user
        // genuinely wanting Cmd+Esc cannot record it; an acceptable trade for a clear escape
        // hatch from the recorder.
        if event.keyCode == 53 {
            cancelCapture()
            return nil
        }
        let keyCode = Int64(event.keyCode)
        // NSEvent.modifierFlags bit layout is intentionally compatible with CGEventFlags for
        // the modifier bits (.shift / .control / .option / .command / .function), so masking
        // through `Hotkey.modifierMask` is well-defined.
        let flags = UInt64(event.modifierFlags.rawValue) & Hotkey.modifierMask
        guard Hotkey.isValidForGlobal(keyCode: keyCode, flags: flags) else {
            // Reject silently; keep recorder open. We still consume the event so the rejected
            // letter doesn't leak into whatever control was focused inside the popover.
            return nil
        }
        let newHotkey = Hotkey(keyCode: keyCode, flags: flags)
        hotkey = newHotkey

        let completion = captureCompletion
        captureCompletion = nil
        cleanupCaptureMonitors()
        isCapturingHotkey = false
        completion?(newHotkey)
        return nil
    }

    @MainActor
    private func installTap() {
        guard tap == nil else { return }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: userInfo
        ) else {
            // `tapCreate` returns nil when Accessibility is missing. We already checked via
            // `AXIsProcessTrusted` upstream, but TCC can race with us; treat nil as "no
            // access" so the banner stays accurate.
            hasAccessibility = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        self.tap = newTap
        self.runLoopSource = source
    }

    @MainActor
    private func removeTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
            tap = nil
        }
    }

    @MainActor
    private func installDefaultInputDeviceListener() {
        guard !defaultInputListenerInstalled else { return }
        defaultInputListenerInstalled = true
        CoreAudioMuteController.addDefaultInputDeviceListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshMutedStateFromHAL()
            }
        }
    }

    @MainActor
    private func refreshMutedStateFromHAL() {
        guard let deviceID = CoreAudioMuteController.defaultInputDeviceID() else {
            isMuted = false
            return
        }
        isMuted = CoreAudioMuteController.readMuteState(deviceID: deviceID)
    }

    private func persistHotkey(_ hotkey: Hotkey) {
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: Self.hotkeyKey)
        }
    }

    // MARK: - CGEventTap callback (C function pointer)

    /// `@convention(c)` — no closure captures allowed. The `userInfo` pointer passed at tap
    /// creation is the unmanaged `self`, which we recover here to dispatch back to the live
    /// service. We deliberately do not hop to main inside this callback: re-enabling a
    /// disabled tap must happen synchronously, and reading the hotkey lock is cheap.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<MicMuteService>.fromOpaque(refcon).takeUnretainedValue()

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The kernel disables the tap if our callback ever runs long or the user holds a
            // mouse button down — re-enable immediately. Per Apple's guidance, this is the
            // only way to recover.
            if let tap = service.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let current = service.hotkeyStorage.withLock { $0 }
            let eventFlags = event.flags.rawValue
            let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if eventKeyCode == current.keyCode,
               (eventFlags & Hotkey.modifierMask) == (current.flags & Hotkey.modifierMask) {
                DispatchQueue.main.async {
                    service.toggle()
                }
                return nil // consume — don't let the keystroke leak to focused app
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

// MARK: - Accessibility

/// Thin wrapper around the TCC Accessibility APIs. Kept file-private because the only caller
/// is `MicMuteService` and there's no value in adding a protocol shim for two functions.
private enum AccessibilityChecker {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func promptForTrust() {
        // `kAXTrustedCheckOptionPrompt` is a `CFString!` constant; its underlying value is the
        // literal "AXTrustedCheckOptionPrompt". Using the literal directly sidesteps the
        // Unmanaged<CFString> ergonomics.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - CoreAudio

/// Encapsulates the CoreAudio HAL property dance. Stateless — all entry points take an
/// `AudioDeviceID` so the caller can resolve the device once per logical operation (read +
/// write) and avoid races with default-input changes.
private enum CoreAudioMuteController {
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func readMuteState(deviceID: AudioDeviceID) -> Bool {
        if let mute = readMuteProperty(deviceID: deviceID) {
            return mute
        }
        if let vol = readVolumeScalar(deviceID: deviceID) {
            return vol == 0
        }
        return false
    }

    static func setMuteState(_ muted: Bool, deviceID: AudioDeviceID, fallbackKey: String) {
        if setMuteProperty(deviceID: deviceID, muted: muted) {
            return
        }
        setVolumeFallback(deviceID: deviceID, muted: muted, fallbackKey: fallbackKey)
    }

    /// Listens for default-input-device changes. Handler invoked on the main queue. We never
    /// remove this listener — the service lives for the process lifetime.
    static func addDefaultInputDeviceListener(handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - Mute property (preferred path)

    private static func muteAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }

    private static func readMuteProperty(deviceID: AudioDeviceID) -> Bool? {
        // Try the master element first, fall back to channel 1 — some devices expose mute
        // only on the per-channel element, not the aggregate "main".
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var addr = muteAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return nil
    }

    private static func setMuteProperty(deviceID: AudioDeviceID, muted: Bool) -> Bool {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var addr = muteAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                deviceID, &addr, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value
            )
            if status == noErr {
                return true
            }
        }
        return false
    }

    // MARK: - Volume fallback (built-in mic path)

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readVolumeScalar(deviceID: AudioDeviceID) -> Float32? {
        var addr = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr else {
            return nil
        }
        return vol
    }

    private static func setVolumeFallback(deviceID: AudioDeviceID, muted: Bool, fallbackKey: String) {
        var addr = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr,
              settable.boolValue else { return }

        if muted {
            // Only save the pre-mute volume if it's > 0. Otherwise the user could end up
            // permanently locked at 0: first mute saves 0 → unmute restores 0 → repeat.
            if let currentVol = readVolumeScalar(deviceID: deviceID), currentVol > 0 {
                UserDefaults.standard.set(Double(currentVol), forKey: fallbackKey)
            }
            var zero: Float32 = 0
            _ = AudioObjectSetPropertyData(
                deviceID, &addr, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &zero
            )
        } else {
            let saved = UserDefaults.standard.double(forKey: fallbackKey)
            var restore = Float32(saved > 0 ? saved : 1.0)
            _ = AudioObjectSetPropertyData(
                deviceID, &addr, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &restore
            )
        }
    }
}
