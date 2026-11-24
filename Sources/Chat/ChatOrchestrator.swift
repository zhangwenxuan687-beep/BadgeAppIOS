import Foundation
import Combine

/* 对话编排（对照 Android ChatOrchestrator）：
   挂件麦克风(ADPCM 上行) -> 端侧 ASR -> llama-server SSE -> 切句
   -> 系统 TTS 取 PCM -> ADPCM 编码 -> BLE 下发挂件喇叭
   协议要点：一轮只发一次 BEGIN（固件会清空播放队列并复位解码状态），
   句子间连续 DATA，最后 END；ADPCM 编码状态跨句持续。 */
@MainActor
final class ChatOrchestrator: ObservableObject {
    static let shared = ChatOrchestrator()

    struct Msg: Identifiable {
        let id = UUID()
        let role: String          // "user" / "assistant"
        var text: String
    }

    @Published private(set) var chatLog: [Msg] = []
    @Published private(set) var phase = "初始化…"
    @Published private(set) var listening = false
    @Published private(set) var busy = false
    @Published private(set) var metrics = ""
    @Published private(set) var speechStatusText = "检测中…"

    private let ble = BleManager.shared
    private let settings = SettingsStore.shared
    private let speech = SpeechRecognizer()
    private let tts = TtsSpeaker()
    private let encoder = AdpcmEncoder()

    private var history: [(String, String)] = []
    private var turnTask: Task<Void, Never>?
    private var turnAbort = false
    private var pendingText = ""
    private var speechAuthorized = false
    private var finishingSpeech = false
    private var notice: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        ble.onMicPcm = { [weak self] pcm, _ in
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.speech.append(pcm)
            }
        }
        ble.onStatus = { [weak self] object in
            Task { @MainActor in self?.handleStatus(object) }
        }
        ble.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshPhase() }
            }
            .store(in: &cancellables)

        Task { await setupSpeech() }
    }

    /* ---------------- 初始化 ---------------- */

    private func setupSpeech() async {
        let status = await SpeechRecognizer.requestAuthorization()
        switch status {
        case .authorized:
            speechAuthorized = true
            speechStatusText = speech.onDeviceAvailable
                ? "已授权 · 端侧识别"
                : "已授权 · 需联网识别（无离线中文包）"
        default:
            speechAuthorized = false
            speechStatusText = "未授权"
            notice = "语音识别未授权：设置 > 隐私与安全性 > 语音识别"
        }
        refreshPhase()
    }

    private func refreshPhase() {
        if let notice {
            phase = notice
            return
        }
        if !ble.isConnected {
            phase = "未连接挂件"
        } else if !speechAuthorized {
            phase = "语音识别未授权"
        } else if busy {
            phase = "对话进行中"
        } else if listening {
            phase = "拾音中…"
        } else {
            phase = "就绪（按住说话）"
        }
    }

    /* ---------------- 说话 ---------------- */

    func startMic() {
        guard ble.isConnected, speechAuthorized, !listening, !busy, !finishingSpeech else { return }
        notice = nil
        turnAbort = false
        listening = true
        phase = "拾音中…"
        speech.begin()
        ble.sendCmd("START_MIC")
    }

    func stopMicAndChat() {
        guard listening else { return }
        listening = false
        finishingSpeech = true
        phase = "识别中…"
        ble.sendCmd("STOP_MIC")

        Task { @MainActor in
            let text = await speech.finish()
            finishingSpeech = false
            if turnAbort { return }
            if text.isEmpty {
                notice = "未识别到语音"
                refreshPhase()
                return
            }
            notice = nil
            chatLog.append(Msg(role: "user", text: text))
            startTurn(userText: text)
        }
    }

    func abortTurn(_ reason: String) {
        turnAbort = true
        turnTask?.cancel()
        turnTask = nil
        ble.sendCmd("AUDIO_FLUSH")
        tts.stop()
        speech.cancel()
        listening = false
        finishingSpeech = false
        busy = false
        if let last = chatLog.indices.last,
           chatLog[last].role == "assistant", chatLog[last].text.isEmpty {
            chatLog[last].text = "（已打断）"
        }
        notice = reason
        phase = reason
    }

    private func startTurn(userText: String) {
        turnTask?.cancel()
        turnTask = Task { @MainActor [weak self] in
            await self?.performTurn(userText: userText)
        }
    }

    /* ---------------- 对话轮 ---------------- */

    private func performTurn(userText: String) async {
        busy = true
        turnAbort = false
        pendingText = ""
        notice = nil
        encoder.reset()
        tts.stop()
        chatLog.append(Msg(role: "assistant", text: ""))

        let started = Date()
        var full = ""
        var firstDeltaMs = -1

        var messages: [(String, String)] = [("system", settings.systemPrompt)]
        messages.append(contentsOf: history.suffix(8).map { ($0.0, $0.1) })
        messages.append(("user", userText))

        let client = LlmClient(url: settings.llmUrl, model: settings.model)
        var first = true

        ble.sendTtsBegin()

        do {
            for try await delta in client.stream(messages: messages) {
                if turnAbort || Task.isCancelled { break }
                if first {
                    first = false
                    firstDeltaMs = Int(Date().timeIntervalSince(started) * 1000)
                    phase = "生成中…"
                }
                full += delta
                if let last = chatLog.indices.last {
                    chatLog[last].text = full
                }
                await feedSplitter(delta)
            }

            if !turnAbort && !Task.isCancelled {
                let tail = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingText = ""
                if !tail.isEmpty { await speak(tail) }
                ble.sendTtsEnd()
            }
        } catch {
            if !turnAbort {
                notice = "LLM错误: \(error.localizedDescription)"
            }
        }

        let answer = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if !answer.isEmpty {
            history.append(("user", userText))
            history.append(("assistant", answer))
            if history.count > 16 { history.removeFirst(history.count - 16) }
        }

        let firstText = firstDeltaMs < 0 ? "-" : "\(firstDeltaMs)"
        let totalText = Int(Date().timeIntervalSince(started) * 1000)
        metrics = "首字 \(firstText)ms | 全轮 \(totalText)ms"
        busy = false
        if !turnAbort { turnTask = nil }
        refreshPhase()
    }

    /* ---------------- 切句 + TTS 下发 ---------------- */

    private func feedSplitter(_ delta: String) async {
        pendingText += delta

        while !turnAbort && !Task.isCancelled {
            if let index = pendingText.firstIndex(where: { "。！？!?；;\n".contains($0) }) {
                let end = pendingText.index(after: index)
                let sentence = String(pendingText[..<end])
                pendingText = String(pendingText[end...])
                await speak(sentence)
                continue
            }

            if pendingText.count > 60 {
                var cut: String.Index?
                var count = 0
                var cursor = pendingText.startIndex
                while cursor < pendingText.endIndex {
                    if count >= 40, pendingText[cursor] == "，" || pendingText[cursor] == "," {
                        cut = pendingText.index(after: cursor)
                        break
                    }
                    cursor = pendingText.index(after: cursor)
                    count += 1
                }
                let end = cut ?? pendingText.index(pendingText.startIndex, offsetBy: 60)
                let sentence = String(pendingText[..<end])
                pendingText = String(pendingText[end...])
                await speak(sentence)
                continue
            }
            break
        }
    }

    private func speak(_ raw: String) async {
        guard !turnAbort, !Task.isCancelled else { return }

        let cleaned = raw
            .replacingOccurrences(of: "[*_#`>~\\[\\]]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let pcm = await tts.synthesize(cleaned)
        guard !pcm.isEmpty else { return }

        var offset = 0
        var sent = 0
        var frame = [Int16](repeating: 0, count: BadgeProtocol.frameSamples)
        while offset < pcm.count {
            if turnAbort || Task.isCancelled { return }
            let n = min(BadgeProtocol.frameSamples, pcm.count - offset)
            for i in 0..<BadgeProtocol.frameSamples {
                frame[i] = i < n ? pcm[offset + i] : 0    // 尾块补零
            }
            let adpcm = encoder.encode(frame)
            ble.sendTtsData(adpcm)
            offset += BadgeProtocol.frameSamples
            sent += 1
            // 先给 25 帧（500ms）预缓冲，之后按 2 倍速（10ms/帧）发送：
            // 固件播放队列有 1MB 缓冲，发送略快于播放才能扛住 BLE 调度抖动，
            // 否则任何一点延迟都会让播放队列饿死（喇叭断断续续）
            if sent > 25 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    /* ---------------- 状态事件 ---------------- */

    private func handleStatus(_ object: [String: Any]) {
        switch object["ev"] as? String {
        case "tpos":
            abortTurn("挂件侧打断")
        case "state":
            if (object["v"] as? String) == "mic_off", listening {
                listening = false
                speech.cancel()
            }
        case "err":
            notice = "设备错误: \(object["msg"] as? String ?? "")"
            refreshPhase()
        default:
            break
        }
    }

    /* ---------------- 设置页：测试 LLM 连接 ---------------- */

    func testLlm(url: String, model: String) async -> String {
        let started = Date()
        var reply = ""
        let client = LlmClient(url: url, model: model)
        do {
            for try await delta in client.stream(messages: [("user", "只回复两个字：正常")]) {
                reply += delta
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return "LLM测试OK(\(ms)ms): \(String(reply.prefix(20)))"
        } catch {
            return "LLM测试失败: \(error.localizedDescription)"
        }
    }
}
