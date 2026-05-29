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
- A 2-second watchdog aborts the recording if `SCStream` starts but delivers no audio samples — this enforces the "no mic-only file" spec requirement against silent SCK stalls. The auto-restart path uses a silent variant of the same watchdog so a slow device hand-off doesn't surface a misleading "no system audio" banner.
- `AVAudioEngineConfigurationChange` (plugging/unplugging headphones, AirPods (dis)connect, default device switched) triggers an **auto-restart**: the current `.m4a` is finalized and a fresh session is spun up on the new device. The user gets N short files per session (one per route change) instead of one mixed-rate file AAC can't represent cleanly. The popover shows a Cancel button during the brief `.stopping` window so the user can abandon a route-change restart they don't want.
- Mic is captured whenever microphone permission is granted, regardless of output device. Apple's Voice Processing IO (AEC) is **not** used — empirically it doesn't cancel system-mixer playback in this pipeline (VPIO references the unit's own output path, not the system mixer). The trade-off: recording without headphones while system audio plays will pick up acoustic echo through the mic. For clean recordings with system audio, use headphones.
- Custom 5-bar animated waveform tray icon (template `NSImage` redrawn at 12 fps by a `Timer.publish` while recording); same icon is reused in the popover header for visual consistency.

## Transcription

After a recording is saved (or any audio file is picked from disk), transcription is **manual**:

- **Transcribe Last Recording** uses the most recent recording's URL.
- **Choose File…** opens an `NSOpenPanel` for any `.m4a` / `.mp3` / `.mp4` / `.wav`.

The transcript is **written incrementally** next to the audio file as a sibling `.txt` (same stem) and copied to the system pasteboard after every successful chunk. If the app is force-quit, crashes, or loses power mid-transcription, everything transcribed up to that point is already on disk.

### Chunked uploads

OpenAI's transcription endpoint imposes **two** independent limits per request:

- **25 MB upload size cap.**
- **1400 audio-seconds duration cap** on `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` (Whisper-1 has no documented duration cap, but we apply the same target across all models for uniform behaviour).

When either is exceeded, the file is automatically split into temporary `.m4a` chunks under `~/var/folders/.../T/` — sized to ~22 MB **and** ≤ 1200 s each (3 s margin under each cap). Adjacent chunks **overlap by 3 seconds**, so words that fall on an AAC frame-aligned cut survive in at least one chunk. The overlap produces mild duplication in the output text, which is acceptable for voice transcripts.

The chunking path:
- **AAC sources** (everything recorded by the app) use `AVAssetExportPresetPassthrough` — AAC frames are copied byte-for-byte, no quality loss, no re-encoding overhead.
- **Non-AAC sources** (e.g. a `.wav` or `.mp3` picked via Choose File) use `AVAssetExportPresetAppleM4A` (re-encode to AAC) with a more conservative 600-second chunk target since the re-encode bitrate is independent of the source.

Each chunk uploads sequentially. After every successful chunk, the running text is appended to the on-disk `.txt` and the clipboard is refreshed. If a later chunk fails (e.g. OpenAI 429 rate-limit), the popover banner shows how many chunks completed and the `.txt` carries an annotation noting the truncation point — earlier chunks' work is never discarded.

Temp chunk files are deleted after the run regardless of success or failure. The original audio file is never modified.

### Settings

Inside the popover, the `Transcription Settings` disclosure exposes:

- **API key** — a `SecureField` for the OpenAI key (stored in `UserDefaults`, plaintext on disk; see Known Limitations). The adjacent `Clear` button wipes it; clicking anywhere in the popover outside the field defocuses it (visible confirmation that the value is saved).
- **Model picker** — pick one of:
  - `whisper-1` — Whisper v2 (2022), baseline.
  - `gpt-4o-mini-transcribe` — **default**. Newer than Whisper v2, half the price, better accuracy.
  - `gpt-4o-transcribe` — best quality, same price as `whisper-1`.

There is a one-shot `.env` migration on the very first launch: if `OPENAI_API_KEY` is set in the process environment or found at `~/.transcribr/.env` / `~/Documents/Transcribr/.env` (also `~/Projects/Transcribr/.env` in `DEBUG` builds), it is imported into `UserDefaults` and an `envMigrationDone` flag is set. After that, `.env` is never re-consulted — clearing the key in the popover sticks across restarts.

## Global mic mute

Independently of recording, the menu-bar app installs a global hotkey that toggles the system's
default input device mute from any foreground application. Default binding: **Fn + ⇧ + `**.
The hotkey is configurable from the popover (`Mic Mute: <combo>  [Change hotkey]` row tucked
under `Transcription Settings`); click `Change hotkey`, press a new combination, and it is
stored in `UserDefaults` immediately. Esc cancels the recorder; plain alphanumeric keys
without any modifier are rejected so the hotkey can't silently swallow letters in other apps.

Mute state surfaces in two places. The menu-bar tray waveform picks up a diagonal slash
whenever the mic is muted (regardless of whether a recording is in progress); the popover
header waveform deliberately does not — it reflects recording state only, so the menu-bar
icon stays the single always-visible mute indicator. Inside the popover, the `Mic Mute` row
uses an SF Symbol microphone (`mic.fill`, switching to a red `mic.slash.fill` while muted).

Implementation: `CGEvent` session-level event tap on the mach-port thread for global capture
(`CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, …)`), CoreAudio HAL property
`kAudioDevicePropertyMute` on `kAudioDevicePropertyScopeInput` for the actual mute, with a
`kAudioDevicePropertyVolumeScalar = 0` fallback for devices like the MacBook built-in mic that
don't expose hardware mute. A `kAudioHardwarePropertyDefaultInputDevice` listener keeps the
published `isMuted` in sync when the user plugs in / unplugs a USB mic mid-session.

## Build & run

```bash
xcodebuild -project Transcribr.xcodeproj -scheme Transcribr \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Transcribr-*/Build/Products/Debug/Transcribr.app
```

Or open `Transcribr.xcodeproj` in Xcode and hit Run.

## Required permissions

- **Screen Recording** is **mandatory** — required by `ScreenCaptureKit` to capture system audio (the floor of every recording). Two-step:
  - Click **Request Screen Recording Access** in the popover banner. macOS adds Transcribr to System Settings → Privacy & Security → Screen Recording and shows a notification directing you there.
  - Enable Transcribr in that pane, then **restart the app**. macOS does not propagate a freshly-granted screen-recording permission to an already-running process — long-standing OS behaviour, not a bug.

- **Microphone** is **optional**. macOS shows a TCC prompt on first Start; granting it adds your voice to every subsequent recording. Denying it (or revoking later in System Settings) doesn't block the app — sessions just capture system audio only.

- **Accessibility** is **optional** — required only by the global mic-mute hotkey. Enable Transcribr in System Settings → Privacy & Security → Accessibility, then re-open the popover so the app re-checks. Without it, the popover shows a banner and the hotkey is inactive; recording continues to work unaffected. Unlike Screen Recording, Accessibility *does* propagate to the running process — no app restart needed, just popover re-open.

Transcription only needs a valid OpenAI API key — no extra system permission.

## Tests

```bash
xcodebuild -project Transcribr.xcodeproj -scheme Transcribr \
  -configuration Debug -destination 'platform=macOS' test
```

Current coverage: **69 unit tests** across three suites.

`AudioRecorderTests` (45):
- File-name format, single-digit padding.
- Microphone permission status mapping (all four `AVAuthorizationStatus` cases).
- `formatsAreEquivalent` helper (sample rate / channel count / interleaving / identical).
- `canonicalFormat` invariants.
- `formatDuration` for zero, seconds-only, minutes, padding, hours, negative, sub-second, NaN, ±Infinity, 24h, week-long.
- `makePCMBuffer` passthrough, sample-rate conversion, converter reuse and recreate (tests construct synthetic `CMSampleBuffer`s and feed them through the real conversion code path).
- `MultipartFilename.sanitize` — passthrough, CRLF stripping, quote replacement, combined edge cases.
- `EnvLoader.parseValue` — simple key/value, CRLF files, quoted values, comment skipping, missing key/file.
- `ChunkPlanner.plan` — AAC size-based, AAC duration-capped, re-encode fixed target, zero-duration fallback, positive advance.
- `shouldStartAfterRestart` — auto-restart decision truth table (state × cancel).
- `canStart` — UI gating truth table (mic optional, screen mandatory).

`RecordsDirectoryStoreTests` (7):
- Defaults, init with/without stored value, persistence round-trip across re-init, directory creation, idempotency.

`HotkeyTests` (17):
- `Hotkey.default` constants, `modifierMask` shape.
- `init(keyCode:flags:)` strips CapsLock + every non-modifier bit.
- JSON round-trip preserves both fields; persisted JSON with extra bits is sanitized on decode.
- `description` rendering for each modifier (Fn, ⌃, ⌥, ⇧, ⌘) and the Apple HIG combined order.
- Unmapped keyCode falls back to `Key <n>`.
- `isValidForGlobal` truth table — rejects plain alphanumeric (letters + digits); accepts Esc / F-keys / Space / unmapped codes / any alphanumeric with at least one real modifier; CapsLock-only does not count as a modifier.

The wired-up audio capture path (engine pulling from the HAL + SCStream samples + mixed AAC encode), the real OpenAI HTTP call, and the CoreAudio/CGEventTap pieces of `MicMuteService` are out of scope for `xcodebuild test` — they need live TCC permissions, audio hardware, network, and an Accessibility grant. Verify those manually using the matrix below.

## Manual test plan

After granting Screen Recording and restarting, run through this matrix. For each row, record ~10 seconds while speaking and playing system audio, then play back the resulting `.m4a` from your records directory (default `~/Documents/Transcribr/`).

| # | Scenario | Output device | Source of system audio | My voice recorded | System audio recorded | Result |
|---|---|---|---|---|---|---|
| 1 | Basic | Built-in speakers | _(silence)_ | Yes | N/A | Pass / Fail |
| 2 | Basic | Built-in speakers | Music player (Apple Music / Spotify) | Yes (echo expected) | Yes | Pass / Fail |
| 3 | Basic | Built-in speakers | Browser video (YouTube) | Yes (echo expected) | Yes | Pass / Fail |
| 4 | Basic | Wired headphones (3.5mm jack) | Music player | Yes | Yes | Pass / Fail |
| 5 | Basic | Wired headphones | Browser video | Yes | Yes | Pass / Fail |
| 6 | Basic | Bluetooth headphones / AirPods | Music player | Yes | Yes | Pass / Fail |
| 7 | Basic | Bluetooth headphones / AirPods | Browser video | Yes | Yes | Pass / Fail |
| 8 | Auto-restart | Plug headphones mid-recording | Music player | Yes (continues across files) | Yes (continues across files) | Pass / Fail |
| 9 | Cancel auto-restart | Plug/unplug headphones, tap **Cancel** during `.stopping` | Music player | N/A | First file finalized; no second session | Pass / Fail |
| 10 | Mic denied | Any | Music player | No (permission denied) | Yes | Pass / Fail |

Optional extras (smoke, not gates):

- Messenger or video call (Telegram, WhatsApp, Zoom, Google Meet) — on speakers expect the remote voice to be echoed into the mic channel.
- Native macOS notification sound (e.g. a Calendar alert during recording).
- A game's audio output.
- A second simultaneous source (music + video at the same time).

**Pass criterion**: on playback, both your voice **and** whatever system audio was playing at the time are clearly audible in the same file. Rows 2 and 3 will additionally show acoustic echo (system audio doubled through the mic) — this is the documented trade-off of recording on speakers without echo cancellation; use headphones to avoid it.

For transcription, after one of the rows passes: paste an API key in Transcription Settings → press **Transcribe Last** → confirm the green `Transcription copied` banner and that pasting (Cmd-V) into a text editor produces the transcript.

## Known limitations

- **Speaker → mic echo without headphones.** When recording with system audio playing through the laptop speakers, the mic picks up the same audio acoustically. The file then contains every system-audio voice twice — once digitally clean via `SCStream`, once delayed/reverbed via the mic. Apple's Voice Processing IO doesn't help (it references the unit's own output path, not the system mixer's playback). For clean recordings with system audio, use headphones. Future fix options: a two-track output mode that doesn't mix mic and system, or vendoring WebRTC's AEC3.
- **Bluetooth + microphone input quality.** When a Bluetooth headset is selected as the input device, macOS may switch the link into HFP profile (16 kHz mono telephony). The mic track will then be 16 kHz; the system-audio track captured by `SCStream` is unaffected (still 48 kHz stereo, pre-HAL). For best mic quality, use the built-in mic or a wired/USB mic and keep BT for output only.
- **Auto-restart produces multiple files per session.** Every `AVAudioEngineConfigurationChange` finalizes the current `.m4a` and starts a fresh one — a session where you toggle headphones four times yields five files. Each file is independently transcribable; their `recording-<timestamp>.m4a` names sort chronologically so they're easy to reassemble in post.
- **Screen Recording permission needs a restart** after the user first enables it in System Settings. macOS does not propagate the new permission to a running process. The app detects this and shows a banner.
- **API key is stored in `UserDefaults` plaintext** (`~/Library/Preferences/com.transcribr.Transcribr.plist`). Convenient for a local dev app but inappropriate for a shipped binary — a production version should migrate this storage to Keychain.
- **Ad-hoc code signing reshuffles TCC.** Building from Xcode produces a new CDHash on every source change, and macOS's TCC database keys Screen Recording grants by CDHash for ad-hoc-signed apps. Practical upshot: each rebuild may require re-granting Screen Recording (toggle in Settings → restart). Real Developer ID signing (TeamID-based) eliminates this churn for shipped builds.
- **No MP3 export.** Recording output is AAC `.m4a` only; MP3 can be added later via `AVAssetExportSession` or `ffmpeg`.
- **End-of-recording tail**: when End Record is clicked, the last few buffers already scheduled on `AVAudioPlayerNode` are dropped. Acceptable for an MVP.
- **Distribution signing not configured.** Project builds with "Sign to Run Locally" (ad-hoc). For notarized Developer ID distribution, set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = "Developer ID Application"` in `project.pbxproj` for the Release configuration. The `com.apple.security.device.audio-input` entitlement is already in place for the hardened-runtime path.
- **Apple Dictation / Siri / Voice Control bypass user-space mute.** Those services run their own private audio pipeline (`corespeechd`, `assistantd`) that reads the microphone hardware directly, ignoring the CoreAudio `kAudioDevicePropertyMute` flag we set. Their built-in Fn+F5 / wake phrase will continue to record your voice even while the mic-mute hotkey reports `isMuted = true`. This is a macOS architectural limitation; there's no workaround short of disabling SIP. The mute *is* effective against every regular consumer of the input device (Zoom, Meet, Discord, browsers, QuickTime, etc.).
- **Built-in MacBook microphone has no hardware mute.** The Apple-supplied built-in mic typically doesn't expose `kAudioDevicePropertyMute` as settable. `MicMuteService` falls back to setting `kAudioDevicePropertyVolumeScalar = 0` and restoring the prior value on unmute (saved to `UserDefaults` only when it was > 0, so the user can't get locked at zero). Effective for the apps above, but System Settings → Sound → Input will show the slider sliding to 0 while muted — that's the fallback at work, not a UI glitch.
- **Ad-hoc codesign + Accessibility behaves like Screen Recording.** Each rebuild produces a new CDHash; TCC keys the Accessibility grant by CDHash for ad-hoc-signed apps, so the grant may need to be re-issued after each `xcodebuild` run. Real Developer ID signing (TeamID-based) eliminates this churn.

## Fallback if `ScreenCaptureKit` ever fails on a system

If on some specific macOS/hardware combination `SCStream` consistently fails or delivers silence, the fallback is a **virtual audio driver** that exposes the system mix as an input device:

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) — free, open-source, kernel extension.
- [Loopback](https://rogueamoeba.com/loopback/) — paid, GUI for routing.

In that mode both mic and virtual-loopback inputs would be captured via `AVAudioEngine` (aggregate device or two `AVCaptureSession` inputs), and `ScreenCaptureKit` would not be required. Not implemented in this MVP because the native path works on supported macOS 13+ systems.

## License

This project is licensed under the MIT License.  
You are free to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, including for commercial purposes. See the [LICENSE](./LICENSE) file for details.
