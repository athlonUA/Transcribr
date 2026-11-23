import XCTest
@testable import Transcribr

final class WaveformBarsIconTests: XCTestCase {
    func test_resolve_recordingWinsOverProcessing() {
        XCTAssertEqual(IconActivity.resolve(isRecording: true, isProcessing: true), .recording)
        XCTAssertEqual(IconActivity.resolve(isRecording: true, isProcessing: false), .recording)
    }

    func test_resolve_processingWhenNotRecording() {
        XCTAssertEqual(IconActivity.resolve(isRecording: false, isProcessing: true), .processing)
    }

    func test_resolve_idleWhenNothingRunning() {
        XCTAssertEqual(IconActivity.resolve(isRecording: false, isProcessing: false), .idle)
    }

    func test_barHeight_idleIsTheStaticSilhouette() {
        let heights = (0..<5).map { WaveformBarsIcon.barHeight(index: $0, tick: 7, activity: .idle) }
        XCTAssertEqual(heights, [4, 8, 12, 8, 4])
    }

    func test_barHeight_processingStaysInsideIconAndMoves() {
        var seen = Set<CGFloat>()
        for tick in 0..<60 {
            for i in 0..<5 {
                let h = WaveformBarsIcon.barHeight(index: i, tick: UInt64(tick), activity: .processing)
                XCTAssertGreaterThanOrEqual(h, 3)
                XCTAssertLessThanOrEqual(h, 14)
                seen.insert(h)
            }
        }
        XCTAssertGreaterThan(seen.count, 10, "processing animation should actually change heights")
    }

    func test_barHeight_processingDiffersFromRecordingAtSameTick() {
        let rec = (0..<5).map { WaveformBarsIcon.barHeight(index: $0, tick: 5, activity: .recording) }
        let proc = (0..<5).map { WaveformBarsIcon.barHeight(index: $0, tick: 5, activity: .processing) }
        XCTAssertNotEqual(rec, proc)
    }

    func test_barHeight_recordingKeepsOriginalPulseRange() {
        for tick in 0..<60 {
            for i in 0..<5 {
                let base: [CGFloat] = [4, 8, 12, 8, 4]
                let h = WaveformBarsIcon.barHeight(index: i, tick: UInt64(tick), activity: .recording)
                XCTAssertGreaterThanOrEqual(h, base[i] * 0.75 - 0.001)
                XCTAssertLessThanOrEqual(h, base[i] + 0.001)
            }
        }
    }

    func test_accessibilityLabel_coversProcessing() {
        XCTAssertEqual(WaveformBarsIcon.accessibilityLabel(activity: .processing, isMuted: false), "Transcribr: transcribing")
        XCTAssertEqual(WaveformBarsIcon.accessibilityLabel(activity: .processing, isMuted: true), "Transcribr: transcribing, microphone muted")
        XCTAssertEqual(WaveformBarsIcon.accessibilityLabel(activity: .idle, isMuted: false), "Transcribr: idle")
    }
}
