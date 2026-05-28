# Transcribr

A macOS menu bar app that records:

- the microphone, and
- the system audio mix (anything that plays on this Mac — browser, music, video calls, games, notifications),

into a single `.m4a` (AAC) file, then optionally transcribes the result via OpenAI
(Whisper or GPT-4o-transcribe) and auto-copies the transcript to the clipboard.

## Recording

- macOS 13.0+, Apple Silicon native.
- SwiftUI + `MenuBarExtra` (no Dock icon — `LSUIElement = YES`).
- Mic via `AVAudioEngine.inputNode`.
- System audio via `ScreenCaptureKit` (`SCStream` with `capturesAudio = true`).
- Real-time mix via a custom `AVAudioMixerNode`; the engine is muted at the main mixer so nothing plays back through the speakers.
- A canonical mix format (48 kHz / stereo / Float32 non-interleaved) is enforced end-to-end across the engine, the tap, the player node and the file, so AAC encoding never resamples on an unspecified path.
- The tap deep-copies each render buffer and dispatches AAC encoding to a dedicated writer queue, keeping the audio render thread free of disk I/O.
- A 2-second watchdog aborts the recording with a clear error if `SCStream` starts but delivers no audio samples — this enforces the "no mic-only file" spec requirement against silent SCK stalls.
- `AVAudioEngineConfigurationChange` (e.g. plugging/unplugging Bluetooth mid-recording) stops the recording with a user-visible error rather than silently truncating.
- Custom 5-bar animated waveform tray icon (template `NSImage` redrawn at 12 fps by a `Timer.publish` while recording); same icon is reused in the popover header for visual consistency.

## Transcription

After a recording is saved (or any audio file is picked from disk), transcription is **manual**:

- **Transcribe Last Recording** button uses the most recent recording's URL.
- **Choose File…** opens an `NSOpenPanel` for any `.m4a` / `.mp3` / `.mp4` / `.wav`.

The transcript is:

- written next to the audio file as a sibling `.txt` (same stem), and
- immediately copied to the system pasteboard.

The popover banner shows the state — `Transcribing audio…` (with progress), `Transcription copied` (with a `Copy Again` button), or `Transcription failed` with the underlying error.

### Settings

Inside the popover, the `Transcription Settings` disclosure exposes:

- **API key** — a `SecureField` for the OpenAI key (stored in `UserDefaults`). The adjacent `Clear` button wipes it; clicking anywhere in the popover outside the field defocuses it (visible confirmation that the value is saved).
- **Model picker** — pick one of:
  - `whisper-1` — Whisper v2 (2022), baseline.
  - `gpt-4o-mini-transcribe` — **default**. Newer than Whisper v2, half the price, better accuracy.
  - `gpt-4o-transcribe` — best quality, same price as `whisper-1`.

There is a one-shot `.env` migration on the very first launch: if `OPENAI_API_KEY` is set in the process environment or found at `~/.transcribr/.env` / `~/Documents/Transcribr/.env` (also `~/Projects/Transcribr/.env` in `DEBUG` builds), it is imported into `UserDefaults` and an `envMigrationDone` flag is set. After that, `.env` is never re-consulted — clearing the key in the popover sticks across restarts.

Upload size is capped pre-flight at **25 MB** (OpenAI's hard limit) with a clear error rather than a confusing server-side rejection. Multipart filenames are sanitised to keep the boundary well-formed even when picking an arbitrary file via Choose File….

## Build & run

```bash
xcodebuild -project Transcribr.xcodeproj -scheme Transcribr \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Transcribr-*/Build/Products/Debug/Transcribr.app
```

Or open `Transcribr.xcodeproj` in Xcode and hit Run.

## Required permissions

Recording requires **two** macOS permissions (Start Record stays disabled until both are granted):

1. **Microphone** — granted in-process. When you click Start Record for the first time, macOS shows a TCC prompt with the usage description string; one click grants.
2. **Screen Recording** — required by `ScreenCaptureKit` to capture system audio. Two-step:
   - Click the **Request Screen Recording Access** button in the popover banner. macOS adds Transcribr to System Settings → Privacy & Security → Screen Recording and shows a notification directing you there.
   - Enable Transcribr in that pane, then **restart the app**. macOS does not propagate a freshly-granted screen-recording permission to an already-running process — long-standing OS behaviour, not a bug.

Transcription only needs a valid OpenAI API key — no extra system permission.

## Tests

```bash
xcodebuild -project Transcribr.xcodeproj -scheme Transcribr \
  -configuration Debug -destination 'platform=macOS' test
```

Current coverage: **29 unit tests** across two suites.

`AudioRecorderTests` (22):
- File-name format, single-digit padding.
- Microphone permission status mapping (all four `AVAuthorizationStatus` cases).
- `formatsAreEquivalent` helper (sample rate / channel count / interleaving / identical).
- `canonicalFormat` invariants.
- `formatDuration` for zero, seconds-only, minutes, padding, hours, negative, sub-second, NaN, ±Infinity, 24h, week-long.
- `makePCMBuffer` passthrough, sample-rate conversion, converter reuse and recreate (tests construct synthetic `CMSampleBuffer`s and feed them through the real conversion code path).

`RecordsDirectoryStoreTests` (7):
- Defaults, init with/without stored value, persistence round-trip across re-init, directory creation, idempotency.

The wired-up audio capture path (engine pulling from the HAL + SCStream samples + mixed AAC encode) and the real OpenAI HTTP call are out of scope for `xcodebuild test` — they need live TCC permissions, audio hardware, and network. Verify those manually using the matrix below.

## Manual test plan

After granting both permissions and restarting, run through this matrix. For each row, record ~10 seconds while speaking and playing system audio, then play back the resulting `.m4a` from your records directory (default `~/Documents/Transcribr/`).

| # | Scenario | Output device | Source of system audio | My voice recorded | System audio recorded | Result |
|---|---|---|---|---|---|---|
| 1 | Basic | Built-in speakers | _(silence)_ | Yes / No | N/A | Pass / Fail |
| 2 | Basic | Built-in speakers | Music player (Apple Music / Spotify) | Yes / No | Yes / No | Pass / Fail |
| 3 | Basic | Built-in speakers | Browser video (YouTube) | Yes / No | Yes / No | Pass / Fail |
| 4 | Basic | Wired headphones | Music player | Yes / No | Yes / No | Pass / Fail |
| 5 | Basic | Wired headphones | Browser video | Yes / No | Yes / No | Pass / Fail |
| 6 | Basic | Bluetooth headphones | Music player | Yes / No | Yes / No | Pass / Fail |
| 7 | Basic | Bluetooth headphones | Browser video | Yes / No | Yes / No | Pass / Fail |

Optional extras (smoke, not gates):

- Messenger or video call (Telegram, WhatsApp, Zoom, Google Meet)
- Native macOS notification sound (e.g. a Calendar alert during recording)
- A game's audio output
- A second simultaneous source (music + video at the same time)

**Pass criterion**: on playback, both your voice **and** whatever system audio was playing at the time are clearly audible in the same file.

For transcription, after one of the rows passes: paste an API key in Transcription Settings → press **Transcribe Last** → confirm the green `Transcription copied` banner and that pasting (Cmd-V) into a text editor produces the transcript.

## Known limitations

- **Bluetooth + microphone input quality.** When a Bluetooth headset is selected as the input device, macOS may switch the link into HFP profile (16 kHz mono telephony). The mic track will then be 16 kHz; the system-audio track captured by `SCStream` is unaffected (still 48 kHz stereo, pre-HAL). This is a macOS Bluetooth limitation — for best mic quality, use the built-in mic or a wired/USB mic and keep BT for output only.
- **Screen Recording permission needs a restart** after the user first enables it in System Settings. macOS does not propagate the new permission to a running process. The app detects this and shows a banner.
- **Recording stops on audio-device changes**: if you plug or unplug headphones/Bluetooth mid-recording, the engine emits `AVAudioEngineConfigurationChange`. The app stops the recording with an explicit error rather than continuing to write silence into a half-broken graph. Restart the recording after the device change settles.
- **Acoustic echo when not wearing headphones**: if the system audio plays through speakers, the mic also picks it up acoustically in addition to the digital `SCStream` capture. The file is still correct, but the system audio portion may sound slightly louder/echoey. Headphones avoid this.
- **OpenAI 25 MB upload cap.** Transcription rejects files over 25 MB pre-flight with a clear error. At the default 128 kbps AAC that's roughly 25 minutes of audio — for longer recordings, trim or split before transcribing.
- **API key is stored in `UserDefaults` plaintext** (`~/Library/Preferences/com.transcribr.Transcribr.plist`). Convenient for a local dev app but inappropriate for a shipped binary — a production version should migrate this storage to Keychain.
- **Ad-hoc code signing reshuffles TCC.** Building from Xcode produces a new CDHash on every source change, and macOS's TCC database keys Screen Recording grants by CDHash for ad-hoc-signed apps. Practical upshot: each rebuild may require re-granting Screen Recording (toggle in Settings → restart). Real Developer ID signing (TeamID-based) eliminates this churn for shipped builds.
- **No MP3 export.** Recording output is AAC `.m4a` only; MP3 can be added later via `AVAssetExportSession` or `ffmpeg`.
- **End-of-recording tail**: when End Record is clicked, the last few buffers already scheduled on `AVAudioPlayerNode` are dropped. Acceptable for an MVP.
- **Distribution signing not configured.** Project builds with "Sign to Run Locally" (ad-hoc). For notarized Developer ID distribution, set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = "Developer ID Application"` in `project.pbxproj` for the Release configuration. The `com.apple.security.device.audio-input` entitlement is already in place for the hardened-runtime path.

## Fallback if `ScreenCaptureKit` ever fails on a system

If on some specific macOS/hardware combination `SCStream` consistently fails or delivers silence, the fallback is a **virtual audio driver** that exposes the system mix as an input device:

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) — free, open-source, kernel extension.
- [Loopback](https://rogueamoeba.com/loopback/) — paid, GUI for routing.

In that mode both mic and virtual-loopback inputs would be captured via `AVAudioEngine` (aggregate device or two `AVCaptureSession` inputs), and `ScreenCaptureKit` would not be required. Not implemented in this MVP because the native path works on supported macOS 13+ systems.
