import Foundation

/* 全局设置：LLM 服务器 / 模型 / 系统提示词（UserDefaults 持久化）
   默认值与 Android Settings.kt 保持一致 */
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let llmUrl = "llm_url"
        static let model = "model"
        static let systemPrompt = "sys"
    }

    @Published var llmUrl: String {
        didSet { defaults.set(llmUrl, forKey: Key.llmUrl) }
    }

    @Published var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }

    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Key.systemPrompt) }
    }

    private init() {
        llmUrl = defaults.string(forKey: Key.llmUrl)
            ?? "http://172.20.10.4:8080/v1/chat/completions"
        model = defaults.string(forKey: Key.model) ?? "qwen3-vl"
        systemPrompt = defaults.string(forKey: Key.systemPrompt)
            ?? "你是佩戴在用户胸前的AI助手「小星」，回答口语化，一般100到200字，不要用markdown和列表。"
    }
}
