import Foundation

/* OpenAI 兼容 LLM 客户端（llama-server /v1/chat/completions，SSE 流式）
   与 Android LlmClient 一致：逐行解析 "data: {...}" 的 delta.content */
final class LlmClient {
    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let url: String
    private let model: String

    init(url: String, model: String) {
        self.url = url
        self.model = model
    }

    func stream(messages: [(String, String)]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let requestURL = URL(string: url) else {
                        throw ClientError(message: "URL 无效")
                    }

                    var request = URLRequest(url: requestURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer sk-lab7", forHTTPHeaderField: "Authorization")

                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.0, "content": $0.1] },
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        throw ClientError(message: "HTTP \(http.statusCode)")
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
