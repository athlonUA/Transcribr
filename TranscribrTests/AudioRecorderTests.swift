import AVFoundation
import CoreMedia
import XCTest
@testable import Transcribr

final class AudioRecorderTests: XCTestCase {
    // MARK: - File name

    func test_generateFileName_followsExpectedFormat() {
        let timeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 28,
            hour: 11, minute: 45, second: 30
        ))!

        let name = AudioRecorder.generateFileName(at: date, timeZone: timeZone)

        XCTAssertEqual(name, "recording-2026-05-28-11-45-30.m4a")
    }

    func test_generateFileName_padsSingleDigitComponents() {
        let timeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 5,
            hour: 3, minute: 4, second: 9
        ))!

        let name = AudioRecorder.generateFileName(at: date, timeZone: timeZone)

        XCTAssertEqual(name, "recording-2026-01-05-03-04-09.m4a")
    }

    // MARK: - mapMicStatus

    func test_mapMicStatus_translatesAVAuthorizationStatusCorrectly() {
        XCTAssertEqual(AudioRecorder.mapMicStatus(.notDetermined), .undetermined)
        XCTAssertEqual(AudioRecorder.mapMicStatus(.authorized), .granted)
        XCTAssertEqual(AudioRecorder.mapMicStatus(.denied), .denied)
        XCTAssertEqual(AudioRecorder.mapMicStatus(.restricted), .denied)
    }

    // MARK: - formatsAreEquivalent

    func test_formatsAreEquivalent_returnsTrueForIdenticalFormats() {
        let a = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        XCTAssertTrue(AudioRecorder.formatsAreEquivalent(a, b))
    }

    func test_formatsAreEquivalent_distinguishesSampleRate() {
        let a = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        XCTAssertFalse(AudioRecorder.formatsAreEquivalent(a, b))
    }

    func test_formatsAreEquivalent_distinguishesChannelCount() {
        let a = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertFalse(AudioRecorder.formatsAreEquivalent(a, b))
    }

    func test_formatsAreEquivalent_distinguishesInterleaving() {
        let interleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let nonInterleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        XCTAssertNotEqual(interleaved.isInterleaved, nonInterleaved.isInterleaved)
        XCTAssertFalse(AudioRecorder.formatsAreEquivalent(interleaved, nonInterleaved))
    }

    // MARK: - formatDuration

    func test_formatDuration_zero() {
        XCTAssertEqual(AudioRecorder.formatDuration(0), "00:00")
    }

    func test_formatDuration_secondsOnly() {
        XCTAssertEqual(AudioRecorder.formatDuration(5), "00:05")
    }

    func test_formatDuration_minutesAndSeconds() {
        XCTAssertEqual(AudioRecorder.formatDuration(83), "01:23")
    }

    func test_formatDuration_padsMinutesToTwoDigits() {
        XCTAssertEqual(AudioRecorder.formatDuration(9 * 60 + 4), "09:04")
    }

    func test_formatDuration_switchesToHoursFormatPastOneHour() {
        XCTAssertEqual(AudioRecorder.formatDuration(3600), "1:00:00")
        XCTAssertEqual(AudioRecorder.formatDuration(3661), "1:01:01")
        XCTAssertEqual(AudioRecorder.formatDuration(2 * 3600 + 30 * 60 + 5), "2:30:05")
    }

    func test_formatDuration_clampsNegativeToZero() {
        XCTAssertEqual(AudioRecorder.formatDuration(-3), "00:00")
    }

    func test_formatDuration_floorsSubSecondValues() {
        XCTAssertEqual(AudioRecorder.formatDuration(1.99), "00:01")
    }

    func test_formatDuration_handlesNaN() {
        XCTAssertEqual(AudioRecorder.formatDuration(.nan), "00:00")
    }

    func test_formatDuration_handlesInfinity() {
        XCTAssertEqual(AudioRecorder.formatDuration(.infinity), "00:00")
        XCTAssertEqual(AudioRecorder.formatDuration(-.infinity), "00:00")
    }

    func test_formatDuration_handlesVeryLargeValues() {
        let oneDay: TimeInterval = 24 * 3600
        XCTAssertEqual(AudioRecorder.formatDuration(oneDay), "24:00:00")
        let oneWeek: TimeInterval = 7 * 24 * 3600
        XCTAssertEqual(AudioRecorder.formatDuration(oneWeek), "168:00:00")
    }

    // MARK: - canonicalFormat

    func test_canonicalFormat_is48kStereoFloat32NonInterleaved() {
        let f = AudioRecorder.canonicalFormat
        XCTAssertEqual(f.sampleRate, 48_000)
        XCTAssertEqual(f.channelCount, 2)
        XCTAssertEqual(f.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(f.isInterleaved)
    }

    // MARK: - makePCMBuffer

    func test_makePCMBuffer_returnsBuffer_whenInputAndTargetFormatsMatch() throws {
        let format = AudioRecorder.canonicalFormat
        let frames: AVAudioFrameCount = 1024
        let cmBuffer = try Self.makeAudioSampleBuffer(
            format: format,
            frameCount: frames,
            fill: { channel, frame in Float(frame) / Float(frames) * (channel == 0 ? 1.0 : -1.0) }
        )

        var converter: AVAudioConverter?
        let result = AudioRecorder.makePCMBuffer(
            from: cmBuffer,
            targetFormat: format,
            converter: &converter
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.frameLength, frames)
        XCTAssertNil(converter, "Converter must not be created when input format already matches target")
        XCTAssertEqual(result?.format.sampleRate, format.sampleRate)
        XCTAssertEqual(result?.format.channelCount, format.channelCount)

        // Spot-check sample data round-trips
        if let data = result?.floatChannelData {
            XCTAssertEqual(data[0][0], 0.0, accuracy: 1e-6)
            XCTAssertEqual(data[0][Int(frames) - 1], Float(frames - 1) / Float(frames), accuracy: 1e-6)
            XCTAssertEqual(data[1][0], 0.0, accuracy: 1e-6)
        }
    }

    func test_makePCMBuffer_createsConverter_whenSampleRatesDiffer() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let target = AudioRecorder.canonicalFormat
        let frames: AVAudioFrameCount = 441
        let cmBuffer = try Self.makeAudioSampleBuffer(
            format: inputFormat,
            frameCount: frames,
            fill: { _, _ in 0.5 }
        )

        var converter: AVAudioConverter?
        let result = AudioRecorder.makePCMBuffer(
            from: cmBuffer,
            targetFormat: target,
            converter: &converter
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format.sampleRate, target.sampleRate)
        XCTAssertEqual(result?.format.channelCount, target.channelCount)
        XCTAssertNotNil(converter, "Converter must be created when input/output formats differ")
        XCTAssertGreaterThan(result?.frameLength ?? 0, 0)
        // The resampler holds some tail samples internally for the next call, so output for a
        // single 441-frame input is less than the theoretical 480 (= 441 * 48000/44100). Sanity
        // bounds rather than exact equality.
        let expectedFrames = Double(frames) * 48_000.0 / 44_100.0
        let observedFrames = Double(result?.frameLength ?? 0)
        XCTAssertGreaterThan(observedFrames, expectedFrames * 0.85,
                             "Resampler should produce most of the expected output frames")
        XCTAssertLessThan(observedFrames, expectedFrames * 1.15,
                          "Resampler output frame count must stay close to input * (targetSR / inputSR)")
    }

    func test_makePCMBuffer_reusesConverter_whenInputFormatStaysSame() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let target = AudioRecorder.canonicalFormat
        let cmBuffer1 = try Self.makeAudioSampleBuffer(format: inputFormat, frameCount: 441, fill: { _, _ in 0.1 })
        let cmBuffer2 = try Self.makeAudioSampleBuffer(format: inputFormat, frameCount: 441, fill: { _, _ in 0.2 })

        var converter: AVAudioConverter?
        _ = AudioRecorder.makePCMBuffer(from: cmBuffer1, targetFormat: target, converter: &converter)
        let firstConverter = converter
        XCTAssertNotNil(firstConverter)

        _ = AudioRecorder.makePCMBuffer(from: cmBuffer2, targetFormat: target, converter: &converter)
        XCTAssertTrue(converter === firstConverter,
                      "Converter must be reused across calls when the input format is unchanged")
    }

    func test_makePCMBuffer_recreatesConverter_whenInputFormatChanges() throws {
        let target = AudioRecorder.canonicalFormat
        let format44k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let format16k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let cmBuffer44 = try Self.makeAudioSampleBuffer(format: format44k, frameCount: 441, fill: { _, _ in 0.1 })
        let cmBuffer16 = try Self.makeAudioSampleBuffer(format: format16k, frameCount: 160, fill: { _, _ in 0.1 })

        var converter: AVAudioConverter?
        _ = AudioRecorder.makePCMBuffer(from: cmBuffer44, targetFormat: target, converter: &converter)
        let first = converter

        _ = AudioRecorder.makePCMBuffer(from: cmBuffer16, targetFormat: target, converter: &converter)
        let second = converter

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "Converter must be rebuilt when input format changes")
        XCTAssertEqual(second?.inputFormat.sampleRate, 16_000)
    }

    // MARK: - MultipartFilename

    func test_multipartFilename_passesThroughNormal() {
        XCTAssertEqual(MultipartFilename.sanitize("recording-2026-05-28.m4a"), "recording-2026-05-28.m4a")
    }

    func test_multipartFilename_stripsCRLF() {
        XCTAssertEqual(MultipartFilename.sanitize("bad\rname\n.m4a"), "badname.m4a")
    }

    func test_multipartFilename_replacesQuoteWithUnderscore() {
        XCTAssertEqual(MultipartFilename.sanitize("with\"quote.m4a"), "with_quote.m4a")
    }

    func test_multipartFilename_combinesAllCases() {
        XCTAssertEqual(
            MultipartFilename.sanitize("\"weird\rname\n.m4a"),
            "_weirdname.m4a"
        )
    }

    // MARK: - EnvLoader.parseValue

    func test_envLoader_parsesSimpleKeyValue() throws {
        let path = try writeTempEnv("OPENAI_API_KEY=sk-abc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(EnvLoader.parseValue(forKey: "OPENAI_API_KEY", path: path), "sk-abc")
    }

    func test_envLoader_stripsCarriageReturnFromCRLFFile() throws {
        // Windows-edited .env files use CRLF. A trailing `\r` silently smuggled into the
        // API key would cause OpenAI auth to fail with no obvious user-facing cause.
        let path = try writeTempEnv("OPENAI_API_KEY=sk-abc\r\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(EnvLoader.parseValue(forKey: "OPENAI_API_KEY", path: path), "sk-abc")
    }

    func test_envLoader_handlesDoubleQuotedValue() throws {
        let path = try writeTempEnv("KEY=\"value with spaces\"\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(EnvLoader.parseValue(forKey: "KEY", path: path), "value with spaces")
    }

    func test_envLoader_handlesSingleQuotedValue() throws {
        let path = try writeTempEnv("KEY='value'\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(EnvLoader.parseValue(forKey: "KEY", path: path), "value")
    }

    func test_envLoader_skipsCommentsAndBlanks() throws {
        let path = try writeTempEnv("""
        # this is a comment

        KEY=value

        # another comment
        OTHER=ignored
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(EnvLoader.parseValue(forKey: "KEY", path: path), "value")
    }

    func test_envLoader_returnsNilForMissingKey() throws {
        let path = try writeTempEnv("OTHER=value\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(EnvLoader.parseValue(forKey: "MISSING", path: path))
    }

    func test_envLoader_returnsNilForMissingFile() {
        XCTAssertNil(EnvLoader.parseValue(forKey: "ANY", path: "/nonexistent/.env"))
    }

    private func writeTempEnv(_ content: String) throws -> String {
        let path = NSTemporaryDirectory() + "envloader-test-\(UUID().uuidString).env"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - ChunkPlanner

    func test_chunkPlan_aacUsesSizeBasedWhenUnderDurationCap() {
        // 22 MB exactly worth of bytes at 22 KB/s → sizeBased = 1000 s, under 1200 cap.
        let plan = ChunkPlanner.plan(
            totalBytes: 22 * 1024 * 1024,
            totalSeconds: 1000,
            useReencode: false
        )
        XCTAssertEqual(plan.chunkDurationSeconds, 1000, accuracy: 1)
        XCTAssertEqual(plan.advanceSeconds, 997, accuracy: 1)
    }

    func test_chunkPlan_aacCapsAtDurationLimitForLowBitrate() {
        // 81.8 MB, 113 min @ ~96 kbps — the production case that surfaced the 1400 s cap.
        // bytesPerSecond ≈ 12651, sizeBased ≈ 1823 s, but capped at 1200.
        let plan = ChunkPlanner.plan(
            totalBytes: 81 * 1024 * 1024 + 8 * 100 * 1024,
            totalSeconds: 113 * 60,
            useReencode: false
        )
        XCTAssertEqual(plan.chunkDurationSeconds, 1200, accuracy: 1)
        XCTAssertEqual(plan.advanceSeconds, 1197, accuracy: 1)
    }

    func test_chunkPlan_reencodeUsesFixedShorterTarget() {
        // useReencode = true → always reencodeChunkTargetSeconds, regardless of input math.
        let plan = ChunkPlanner.plan(
            totalBytes: 100 * 1024 * 1024,
            totalSeconds: 6000,
            useReencode: true
        )
        XCTAssertEqual(plan.chunkDurationSeconds, 600, accuracy: 1)
        XCTAssertEqual(plan.advanceSeconds, 597, accuracy: 1)
    }

    func test_chunkPlan_handlesZeroDurationByFallingBackToCap() {
        let plan = ChunkPlanner.plan(
            totalBytes: 0,
            totalSeconds: 0,
            useReencode: false
        )
        XCTAssertEqual(plan.chunkDurationSeconds, 1200, accuracy: 1)
    }

    func test_chunkPlan_advanceIsPositive() {
        let plan = ChunkPlanner.plan(
            totalBytes: 22 * 1024 * 1024,
            totalSeconds: 1200,
            useReencode: false
        )
        XCTAssertGreaterThan(plan.advanceSeconds, 0)
        XCTAssertLessThan(plan.advanceSeconds, plan.chunkDurationSeconds)
    }

    // MARK: - CMSampleBuffer helper

    /// Builds a Float32 PCM CMSampleBuffer for tests.
    private static func makeAudioSampleBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> CMSampleBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "TestHelper", code: 1)
        }
        pcm.frameLength = frameCount

        if format.isInterleaved {
            guard let data = pcm.floatChannelData?[0] else {
                throw NSError(domain: "TestHelper", code: 2)
            }
            let ch = Int(format.channelCount)
            for frame in 0..<Int(frameCount) {
                for channel in 0..<ch {
                    data[frame * ch + channel] = fill(channel, frame)
                }
            }
        } else {
            guard let data = pcm.floatChannelData else {
                throw NSError(domain: "TestHelper", code: 3)
            }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    data[channel][frame] = fill(channel, frame)
                }
            }
        }

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let fd = formatDescription else {
            throw NSError(domain: "TestHelper", code: 4, userInfo: [NSLocalizedDescriptionKey: "CMAudioFormatDescriptionCreate failed: \(fmtStatus)"])
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sb = sampleBuffer else {
            throw NSError(domain: "TestHelper", code: 5, userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferCreate failed: \(createStatus)"])
        }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        guard setStatus == noErr else {
            throw NSError(domain: "TestHelper", code: 6, userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferSetDataBufferFromAudioBufferList failed: \(setStatus)"])
        }

        return sb
    }
}
