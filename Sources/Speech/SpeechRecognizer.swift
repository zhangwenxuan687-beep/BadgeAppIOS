import Foundation
import Speech
import AVFoundation

/* 端侧语音识别：把挂件上行 ADPCM 解码出的 16kHz PCM 直接喂给
   SFSpeechAudioBufferRecognitionRequest（优先 requiresOnDeviceRecognition）
   不占用手机麦克风，音频帧来自 BLE。 */
final class SpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(BadgeProtocol.sampleRate),
        channels: 1,
        interleaved: false
    )!

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let lock = NSLock()
    private var latest = ""
    private var finished = true
    private var finishContinuation: CheckedContinuation<String, Never>?
    /// 自适应增益：上行 4bit ADPCM 解码后电平常偏低，按帧 RMS 平滑提增益
    private var agcGain: Float = 1.0

    var onDeviceAvailable: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func begin() {
        cancel()

        guard let recognizer, recognizer.isAvailable else {
            lock.lock(); finished = true; lock.unlock()
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        lock.lock()
        latest = ""
        finished = false
        finishContinuation = nil
        agcGain = 1.0
        lock.unlock()

        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock()
                self.latest = text
                self.lock.unlock()
                if result.isFinal { self.resumeFinish() }
            }
            if error != nil { self.resumeFinish() }
        }
    }

    /// 追加一帧 320 样本 PCM
    func append(_ pcm: [Int16]) {
        guard let req = request, !pcm.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(pcm.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count)

        // 帧级 RMS -> 目标电平 0.12，增益 1~6 倍，0.8/0.2 平滑避免抽吸
        var energy: Double = 0
        for s in pcm { let v = Double(s) / 32768.0; energy += v * v }
        let rms = Float((energy / Double(pcm.count)).squareRoot())
        let want: Float = rms > 0.0005 ? min(max(0.12 / rms, 1.0), 6.0) : agcGain
        agcGain = agcGain * 0.8 + want * 0.2
        let gain = agcGain

        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<pcm.count {
                channel[i] = max(-1, min(1, Float(pcm[i]) / 32768.0 * gain))
            }
        }
        req.append(buffer)
    }

    /// 结束拾音并等待最终识别文本（最多 4 秒兜底）
    func finish() async -> String {
        guard let req = request else { return "" }

        // 末尾补 300ms 静音：给识别器收尾时间，明显减少「最后几个字被吞」
        let silenceFrames = AVAudioFrameCount(Double(BadgeProtocol.sampleRate) * 0.3)
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: silenceFrames) {
            silence.frameLength = silenceFrames
            if let ch = silence.floatChannelData?[0] {
                for i in 0..<Int(silenceFrames) { ch[i] = 0 }
            }
            req.append(silence)
        }
        req.endAudio()

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            lock.lock()
            if finished {
                let text = latest
                lock.unlock()
                continuation.resume(returning: text)
                return
            }
            finishContinuation = continuation
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.resumeFinish()
            }
        }

        request = nil
        task = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        resumeFinish()
    }

    private func resumeFinish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = finishContinuation
        finishContinuation = nil
        let text = latest
        lock.unlock()
        continuation?.resume(returning: text)
    }
}
