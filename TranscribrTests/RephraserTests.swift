import XCTest
@testable import Transcribr

final class RephraserTests: XCTestCase {
    // MARK: - Sanitizer

    func test_sanitize_replacesYoInBothCases() {
        XCTAssertEqual(RephraseSanitizer.sanitize("Ещё всё идёт. ЁЛКА"), "Еще все идет. ЕЛКА")
    }

    func test_sanitize_replacesLongDashesWithHyphen() {
        XCTAssertEqual(RephraseSanitizer.sanitize("Это \u{2014} просто"), "Это - просто")
        XCTAssertEqual(RephraseSanitizer.sanitize("1\u{2013}2"), "1-2")
        XCTAssertEqual(RephraseSanitizer.sanitize("a\u{2015}b"), "a-b")
    }

    func test_sanitize_leavesPlainHyphenAndOtherTextUntouched() {
        XCTAssertEqual(RephraseSanitizer.sanitize("кто-то пришел"), "кто-то пришел")
    }

    func test_sanitize_trimsWhitespace() {
        XCTAssertEqual(RephraseSanitizer.sanitize("  текст\n"), "текст")
    }

    // MARK: - Request

    func test_requestBody_hasModelSystemPromptAndUserText() throws {
        let data = try Rephraser.makeRequestBody(for: "привет")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, Rephraser.model)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], Rephraser.systemPrompt)
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "привет")
    }

    func test_requestBody_doesNotSendTemperature() throws {
        let data = try Rephraser.makeRequestBody(for: "x")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["temperature"])
    }

    // MARK: - Error hint

    func test_errorHint_addedForModelProblems() {
        let text = OpenAIErrorHint.describe(statusCode: 404, body: "The model `x` does not exist")
        XCTAssertTrue(text.contains("retired or unavailable"))
    }

    func test_errorHint_notAddedForAuthOrUnrelatedErrors() {
        XCTAssertFalse(OpenAIErrorHint.describe(statusCode: 401, body: "Incorrect API key").contains("retired"))
        XCTAssertFalse(OpenAIErrorHint.describe(statusCode: 400, body: "bad file").contains("retired"))
        XCTAssertFalse(OpenAIErrorHint.describe(statusCode: 500, body: "model overloaded").contains("retired"))
    }

    // MARK: - Model resolution

    func test_resolve_defaultsToGptTranscribe() {
        XCTAssertEqual(TranscriptionModel.resolve(stored: nil, migrationDone: false), .gptTranscribe)
        XCTAssertEqual(TranscriptionModel.resolve(stored: "garbage", migrationDone: true), .gptTranscribe)
    }

    func test_resolve_migratesOldDefaultOnlyOnce() {
        XCTAssertEqual(
            TranscriptionModel.resolve(stored: "gpt-4o-mini-transcribe", migrationDone: false),
            .gptTranscribe
        )
        XCTAssertEqual(
            TranscriptionModel.resolve(stored: "gpt-4o-mini-transcribe", migrationDone: true),
            .gpt4oMiniTranscribe
        )
    }

    func test_resolve_keepsOtherExplicitChoices() {
        XCTAssertEqual(TranscriptionModel.resolve(stored: "whisper-1", migrationDone: false), .whisper1)
        XCTAssertEqual(TranscriptionModel.resolve(stored: "gpt-4o-transcribe", migrationDone: false), .gpt4oTranscribe)
    }

    // MARK: - Response

    func test_parseResponse_returnsSanitizedContent() throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"Всё хорошо \u2014 идём"}}]}"#
        XCTAssertEqual(try Rephraser.parseResponse(Data(body.utf8)), "Все хорошо - идем")
    }

    func test_parseResponse_malformedJSONThrowsInvalidResponse() {
        XCTAssertThrowsError(try Rephraser.parseResponse(Data("nope".utf8))) { error in
            guard case RephraseError.invalidResponse = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func test_parseResponse_noChoicesThrowsInvalidResponse() {
        XCTAssertThrowsError(try Rephraser.parseResponse(Data(#"{"choices":[]}"#.utf8)))
    }

    func test_parseResponse_blankContentThrowsEmptyResult() {
        let body = #"{"choices":[{"message":{"content":"  \n"}}]}"#
        XCTAssertThrowsError(try Rephraser.parseResponse(Data(body.utf8))) { error in
            guard case RephraseError.emptyResult = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: - Output file

    func test_rephrasedFileURL_sitsNextToAudioWithSuffix() {
        let audio = URL(fileURLWithPath: "/tmp/recs/recording-2026-01-01-10-00-00.m4a")
        XCTAssertEqual(
            AudioRecorder.rephrasedFileURL(for: audio).path,
            "/tmp/recs/recording-2026-01-01-10-00-00-rephrased.txt"
        )
    }
}
