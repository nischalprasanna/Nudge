import Foundation

/// Minimal client for the Anthropic Messages API (raw HTTPS; there is no official Swift SDK).
struct ClaudeClient {
    /// Cloud model used for planning and for reading icon-only screens.
    static let model = "claude-opus-5-5"
    /// Low effort keeps interactive calls fast; the planning task is small.
    static let effort = "low"

    enum ClientError: LocalizedError {
        case missingKey
        case http(status: Int, message: String)
        case refused
        case truncated
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: return "No API key is set."
            case .http(let status, let message):
                switch status {
                case 401: return "The API key was rejected."
                case 429: return "The cloud model is rate limited. Try again in a moment."
                default: return "Cloud error \(status): \(message)"
                }
            case .refused: return "The cloud model declined this request."
            case .truncated: return "The cloud model's answer was cut off."
            case .badResponse: return "The cloud model sent an answer Nudge could not read."
            }
        }
    }

    let apiKey: String
    private let session: URLSession

    /// Reads the key that the build copied from Config/Secrets.xcconfig. Nil if it is not set.
    init?() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "AnthropicAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "paste-your-key-here" else { return nil }
        apiKey = trimmed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Sends one request and returns the model's JSON answer, constrained to `schema`.
    func completeJSON(system: String, userText: String, imageJPEG: Data?, schema: [String: Any]) async throws -> Data {
        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()],
            ])
        }
        content.append(["type": "text", "text": userText])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": Self.effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            // If a safety classifier declines, the API retries on a fallback model in the same call.
            "fallbacks": "default",
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = ClientError.badResponse
        // One retry for transient failures (overload, server errors, dropped connection).
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
                guard http.statusCode == 200 else {
                    let error = ClientError.http(status: http.statusCode, message: Self.errorMessage(from: data))
                    if http.statusCode >= 500 || http.statusCode == 429 {
                        lastError = error
                        continue
                    }
                    throw error
                }
                return try Self.extractJSON(from: data)
            } catch let error as ClientError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func extractJSON(from data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }
        let stopReason = object["stop_reason"] as? String
        if stopReason == "refusal" { throw ClientError.refused }
        if stopReason == "max_tokens" { throw ClientError.truncated }
        guard let blocks = object["content"] as? [[String: Any]] else { throw ClientError.badResponse }
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty, let json = text.data(using: .utf8) else { throw ClientError.badResponse }
        return json
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return "unknown error" }
        return message
    }
}
