import Foundation
import AVFoundation

/* 手机端 TTS：AVSpeechSynthesizer.write 取到 PCM -> 线性重采样到 16kHz ->
   IMA ADPCM 编码 -> 经 BLE 下发给挂件喇叭（与 Android PhoneTts 等价）
   注意：write(_:toBufferCallback:) 只在真机可用。 */
final class TtsSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 合成整句，返回 16kHz / 16bit / mono PCM
    func synthesize(_ text: String) async -> [Int16] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: "zh-Hans")
            ?? AVSpeechSynthesisVoice(language: "zh")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0

        let context = SynthesisContext()

        return await withCheckedContinuation { (continuation: CheckedContinuation<[Int16], Never>) in
            context.attach(continuation)
            synthesizer.write(utterance) { buffer in
                context.push(buffer)
            }
            // 兜底：异常情况下避免永久挂起
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                context.finish()
            }
        }
    }
}

/* 收集一段语音的所有 buffer（可能分多块），最后一次性重采样到 16k，
   避免逐块重采样在边界产生不连续。 */
private final class SynthesisContext {
    private let lock = NSLock()
    private var mono: [Float] = []
    private var sourceRate: Double = 0
    private var continuation: CheckedContinuation<[Int16], Never>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<[Int16], Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func push(_ rawBuffer: AVAudioBuffer?) {
        guard let rawBuffer, let buffer = rawBuffer as? AVAudioPCMBuffer else { return }
        if buffer.frameLength == 0 {
            finish()
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if sourceRate == 0 { sourceRate = buffer.format.sampleRate }
        appendMono(buffer)
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let samples = mono
        let rate = sourceRate
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        let pcm = Self.resample(samples, from: rate, to: Double(BadgeProtocol.sampleRate))
        continuation?.resume(returning: pcm)
    }

    private func appendMono(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        if let data = buffer.floatChannelData {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono.append(sum / Float(channels))
            }
        } else if let data = buffer.int16ChannelData {
            for i in 0..<frames {
                var sum = 0
                for c in 0..<channels { sum += Int(data[c][i]) }
                mono.append(Float(sum / channels) / 32768.0)
            }
        } else if let data = buffer.int32ChannelData {
            for i in 0..<frames {
                var sum = 0
                for c in 0..<channels { sum += Int(data[c][i]) }
                mono.append(Float(sum / channels) / 2147483648.0)
            }
        }
    }

    private static func resample(_ input: [Float], from: Double, to: Double) -> [Int16] {
        guard !input.isEmpty, from > 0 else { return [] }

        func clamp(_ v: Float) -> Int16 {
            Int16(max(-32768, min(32767, v * 32767.0)))
        }

        if abs(from - to) < 1 {
            return input.map(clamp)
        }

        let ratio = to / from
        let outCount = Int(Double(input.count) * ratio)
        guard outCount > 0 else { return [] }

        var out = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let position = Double(i) / ratio
            let i0 = Int(position)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = Float(position - Double(i0))
            let value = input[i0] * (1 - frac) + input[i1] * frac
            out[i] = clamp(value)
        }
        return out
    }
}
