import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var ble: BleManager
    @EnvironmentObject private var chat: ChatOrchestrator
    @ObservedObject private var settings = SettingsStore.shared

    @State private var url = ""
    @State private var model = ""
    @State private var systemPrompt = ""
    @State private var testResult = ""
    @State private var testing = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("大模型服务器（OpenAI 兼容 / llama-server）") {
                TextField("URL", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名", text: $model)
                TextField("系统提示词", text: $systemPrompt, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                HStack {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(testing ? "测试中…" : "测试连接") { runTest() }
                        .disabled(testing)
                }
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("运行状态") {
                LabeledContent("蓝牙", value: ble.state.rawValue)
                LabeledContent("MTU", value: "\(ble.mtu)")
                LabeledContent("语音识别", value: chat.speechStatusText)
                LabeledContent("最近 STATUS", value: ble.lastStatus)
            }

            Section("使用说明") {
                Text("手机与电脑需在同一网络（例如电脑连接手机热点）。llama-server 需监听 0.0.0.0:8080，并在 Windows 防火墙放行该端口。")
                Text("首次运行需允许：蓝牙、语音识别、本地网络。端侧中文识别需在「设置 > 通用 > 键盘/语音」中下载离线语音包。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            guard !loaded else { return }
            url = settings.llmUrl
            model = settings.model
            systemPrompt = settings.systemPrompt
            loaded = true
        }
    }

    private func save() {
        settings.llmUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.systemPrompt = systemPrompt
        testResult = "已保存"
    }

    private func runTest() {
        save()
        testing = true
        testResult = "测试中…"
        Task { @MainActor in
            testResult = await chat.testLlm(url: settings.llmUrl, model: settings.model)
            testing = false
        }
    }
}
