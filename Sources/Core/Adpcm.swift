import Foundation

/* IMA ADPCM 4:1 —— 与固件 adpcm.c 同一位流约定：
   - 160B ADPCM <-> 320 样本 PCM（16kHz/16bit/mono）
   - 低 nibble 在前（偶数样本）
   - step/index 表逐值照抄固件（部分档位与教科书 IMA 表不同，两端必须一致）
   - 编码器符号位必须写入 nibble 的 bit3 */
enum AdpcmTables {
    static let step: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 25, 28, 31, 34,
        37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 98, 107, 118, 130, 143, 157,
        173, 190, 209, 229, 252, 277, 304, 334, 367, 402, 442, 486, 535, 588, 647, 711,
        782, 860, 946, 1041, 1145, 1259, 1385, 1523, 1676, 1843, 2028, 2230, 2453, 2698, 2968, 3265,
        3592, 3951, 4346, 4781, 5259, 5785, 6363, 6999, 7699, 8469, 9316, 10248, 11273, 12400, 13640, 15004,
        16504, 18155, 19970, 21967, 24164, 26581, 29239, 32163, 35379,
    ]

    static let index: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
    ]
}

final class AdpcmDecoder {
    private var prev = 0
    private var idx = 0

    func reset() {
        prev = 0
        idx = 0
    }

    /// 解码一段 ADPCM（字节数为奇数时忽略最后一个字节），返回 PCM 样本
    func decode(_ input: [UInt8]) -> [Int16] {
        var pred = prev
        var index = idx
        var out: [Int16] = []
        out.reserveCapacity(input.count * 2)

        for byte in input {
            for j in 0..<2 {
                let nib = j == 0 ? Int(byte & 0x0F) : Int(byte >> 4)
                let step = AdpcmTables.step[index]
                var diffq = step >> 3
                if nib & 4 != 0 { diffq += step }
                if nib & 2 != 0 { diffq += step >> 1 }
                if nib & 1 != 0 { diffq += step >> 2 }
                pred = (nib & 8 != 0) ? pred - diffq : pred + diffq
                if pred > 32767 { pred = 32767 }
                if pred < -32768 { pred = -32768 }
                index += AdpcmTables.index[nib]
                if index < 0 { index = 0 }
                if index > 88 { index = 88 }
                out.append(Int16(pred))
            }
        }

        prev = pred
        idx = index
        return out
    }
}

final class AdpcmEncoder {
    private var prev = 0
    private var idx = 0

    func reset() {
        prev = 0
        idx = 0
    }

    /// 编码偶数个 PCM 样本，返回 n/2 字节
    func encode(_ pcm: [Int16]) -> [UInt8] {
        guard pcm.count >= 2 else { return [] }
        var pred = prev
        var index = idx
        var out = [UInt8](repeating: 0, count: pcm.count / 2)
        var bi = 0
        var s = 0

        while s + 1 < pcm.count {
            var byte = 0
            for j in 0..<2 {
                let cur = Int(pcm[s + j])
                var diff = cur - pred
                let sign = diff < 0
                if diff < 0 { diff = -diff }
                let step = AdpcmTables.step[index]
                var nib = 0
                if diff >= step { nib |= 4; diff -= step }
                if diff >= (step >> 1) { nib |= 2; diff -= step >> 1 }
                if diff >= (step >> 2) { nib |= 1 }

                var diffq = step >> 3
                if nib & 4 != 0 { diffq += step }
                if nib & 2 != 0 { diffq += step >> 1 }
                if nib & 1 != 0 { diffq += step >> 2 }
                pred = sign ? pred - diffq : pred + diffq
                if pred > 32767 { pred = 32767 }
                if pred < -32768 { pred = -32768 }

                index += AdpcmTables.index[nib]
                if index < 0 { index = 0 }
                if index > 88 { index = 88 }

                if sign { nib |= 8 }
                if j == 0 { byte = nib } else { byte |= nib << 4 }
            }
            out[bi] = UInt8(truncatingIfNeeded: byte)
            bi += 1
            s += 2
        }

        prev = pred
        idx = index
        return out
    }
}
