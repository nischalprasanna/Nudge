import Foundation

/// A cloud model that answers with JSON matching a schema. Lets the planner swap providers.
protocol JSONModelClient {
    /// Short name shown on screen and in logs, e.g. "Gemini (gemini-3.5-flash-lite)".
    var displayName: String { get }
    func completeJSON(system: String, userText: String, imageJPEG: Data?, schema: [String: Any]) async throws -> Data
}

extension ClaudeClient: JSONModelClient {
    var displayName: String { "Claude (\(ClaudeClient.model))" }
}

/// Minimal client for the Google Gemini API (raw HTTPS).
///
/// The free tier often answers "high demand" (503), so each request walks a short list of
/// fast models with a tight timeout instead of waiting on one.
struct GeminiClient: JSONModelClient {
    /// Vision-capable models, tried in order. In testing, 3.1 flash-lite recognised a wrong
    /// press where the faster 3.5 flash-lite missed it, so it goes first despite being slower.
    static let models = ["gemini-3.1-flash-lite", "gemini-3.5-flash-lite", "gemini-flash-lite-latest"]

    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case blocked
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(let status, let message):
                switch status {
                case 400, 401, 403: return "The Gemini key was rejected. \(message)"
                case 429: return "The free Gemini quota is used up for now."
                case 503: return "Gemini is overloaded right now."
                default: return "Cloud error \(status): \(message)"
                }
            case .blocked: return "The cloud model declined this request."
            case .badResponse: return "The cloud model sent an answer Nudge could not read."
            }
        }
    }

    let apiKey: String
    private let session: URLSession

    var displayName: String { "Gemini (\(Self.models[0]))" }

    /// Reads the key that the build copied from Config/Secrets.xcconfig. Nil if it is not set.
    init?() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "paste-your-key-here" else { return nil }
        apiKey = trimmed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func completeJSON(system: String, userText: String, imageJPEG: Data?, schema: [String: Any]) async throws -> Data {
        var parts: [[String: Any]] = []
        if let imageJPEG {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": imageJPEG.base64EncodedString()]])
        }
        parts.append(["text": userText])

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema,
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = ClientError.badResponse
        // Two passes over the model list: overloads on the free tier usually clear within a second or two.
        for pass in 0..<2 {
            if pass > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            for model in Self.models {
                try Task.checkCancellation()
                var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.httpBody = bodyData
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
                    guard http.statusCode == 200 else {
                        let error = ClientError.http(status: http.statusCode, message: Self.errorMessage(from: data))
                        // Bad key or bad request: no other model will help.
                        if [400, 401, 403].contains(http.statusCode) { throw error }
                        lastError = error
                        continue
                    }
                    return try Self.extractJSON(from: data)
                } catch let error as ClientError {
                    if case .http(let status, _) = error, [400, 401, 403].contains(status) { throw error }
                    lastError = error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Timeout or dropped connection: try the next model.
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private static func extractJSON(from data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }
        guard let candidates = object["candidates"] as? [[String: Any]], let first = candidates.first else {
            // No candidates means the prompt was blocked.
            throw ClientError.blocked
        }
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw ClientError.badResponse }
        // Skip any "thought" parts; the answer is the plain text.
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty, let json = text.data(using: .utf8) else { throw ClientError.badResponse }
        return json
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return "unknown error" }
        return String(message.prefix(160))
    }
}
