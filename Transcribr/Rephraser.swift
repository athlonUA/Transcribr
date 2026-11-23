import Foundation

/// Deterministic cleanup applied to every rephrased text, whatever the model returned.
/// The prompt asks for the same constraints, but a prompt is a request, not a guarantee.
enum RephraseSanitizer {
    /// - "ё"/"Ё" become "е"/"Е".
    /// - Long dashes (em dash U+2014, en dash U+2013, horizontal bar U+2015) become a plain
    ///   hyphen-minus. Surrounding spaces are kept, so " — " turns into " - ".
    static func sanitize(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("ё", "е"), ("Ё", "Е"),
            ("\u{2014}", "-"), ("\u{2013}", "-"), ("\u{2015}", "-"),
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OpenAIErrorHint {
    /// Plain "OpenAI error <code>: <body>", plus a hint when the failure looks like the model
    /// being retired or unavailable to this key (400/404 mentioning the model), so it isn't
    /// mistaken for a bad API key.
    static func describe(statusCode: Int, body: String) -> String {
        var message = "OpenAI error \(statusCode): \(body.prefix(200))"
        if statusCode == 400 || statusCode == 404, body.localizedCaseInsensitiveContains("model") {
            message += " (the model may be retired or unavailable for this API key)"
        }
        return message
    }
}

enum RephraseError: LocalizedError {
    case invalidResponse
    case emptyResult
    case serverError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from OpenAI."
        case .emptyResult:
            return "OpenAI returned an empty rephrase."
        case .serverError(let code, let body):
            return OpenAIErrorHint.describe(statusCode: code, body: body)
        }
    }
}

/// Rewrites a transcript in simple words via the OpenAI Chat Completions API.
final class Rephraser {
    /// Replacement for `gpt-4o-mini`, which shuts down 2027-01-14. No `temperature` is sent:
    /// OpenAI's docs don't confirm the parameter for this model, and the default is fine here.
    static let model = "gpt-6-luna"
    static let systemPrompt = """
    You rewrite transcripts of spoken language in simple words.
    Rules:
    - Keep the language of the input text. Do not translate.
    - Keep the meaning, facts, names, numbers and the order of ideas. Do not add anything new and do not drop anything important.
    - Use short sentences, plain everyday words and simple wording. Remove filler words, repetitions and false starts.
    - Never use the letter "ё"; always write "е" instead.
    - Never use long dashes (em dash or en dash). Use a comma, a period or a plain hyphen "-" instead.
    - Output only the rewritten text, with no preface, comments or quotes.
    """

    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }

    static func makeRequestBody(for text: String) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Extracts and sanitises the assistant message from a Chat Completions response body.
    static func parseResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw RephraseError.invalidResponse
        }
        let cleaned = RephraseSanitizer.sanitize(content)
        guard !cleaned.isEmpty else { throw RephraseError.emptyResult }
        return cleaned
    }

    func rephrase(_ text: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeRequestBody(for: text)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RephraseError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RephraseError.serverError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try Self.parseResponse(data)
    }
}
