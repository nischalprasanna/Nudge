import Foundation

/// Minimal client for the OpenAI Chat Completions API (raw HTTPS).
struct OpenAIClient: JSONModelClient {
    /// Cloud model used for planning and for reading icon-only screens.
    static let model = "gpt-6-luna"
    /// In testing, "low" answered in about 2 seconds and got all planning cases right,
    /// including spotting a wrong press. Supported: none, low, medium, high, xhigh.
    static let reasoningEffort = "low"

    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case refused
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(let status, let message):
                switch status {
                case 401, 403: return "The OpenAI key was rejected."
                case 429: return "The OpenAI account is rate limited or out of credit."
                default: return "Cloud error \(status): \(message)"
                }
            case .refused: return "The cloud model declined this request."
            case .badResponse: return "The cloud model sent an answer Nudge could not read."
            }
        }
    }

    let apiKey: String
    private let session: URLSession

    var displayName: String { "OpenAI (\(Self.model))" }

    /// Reads the key that the build copied from Config/Secrets.xcconfig. Nil if it is not set.
    init?() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "paste-your-key-here" else { return nil }
        apiKey = trimmed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func completeJSON(system: String, userText: String, imageJPEG: Data?, schema: [String: Any]) async throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": userText]]
        if let imageJPEG {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"],
            ])
        }

        let body: [String: Any] = [
            "model": Self.model,
            "reasoning_effort": Self.reasoningEffort,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "plan_step", "strict": true, "schema": schema],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = ClientError.badResponse
        // One retry for transient failures (rate limit, server error, timeout, dropped connection).
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            try Task.checkCancellation()
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func extractJSON(from data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw ClientError.badResponse
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw ClientError.refused }
        guard let text = message["content"] as? String, !text.isEmpty,
              let json = text.data(using: .utf8) else { throw ClientError.badResponse }
        return json
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return "unknown error" }
        return String(message.prefix(160))
    }
}

/// Tries several cloud providers in order, so one provider having a bad moment does not stop a task.
struct FallbackClient: JSONModelClient {
    let clients: [JSONModelClient]

    var displayName: String {
        guard let first = clients.first else { return "No cloud model" }
        return clients.count > 1 ? "\(first.displayName) + \(clients.count - 1) backup" : first.displayName
    }

    func completeJSON(system: String, userText: String, imageJPEG: Data?, schema: [String: Any]) async throws -> Data {
        var lastError: Error = CancellationError()
        for client in clients {
            try Task.checkCancellation()
            do {
                return try await client.completeJSON(system: system, userText: userText,
                                                     imageJPEG: imageJPEG, schema: schema)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
