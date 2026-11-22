import Foundation
import CoreBluetooth

/* Lab7 挂件 BLE 协议常量（与固件 badge-ble/ble.c、Android BadgeBle.kt 逐字段一致）
   - 服务 6E400001-…；特征 0002 AUD_UP(Notify) / 0003 AUD_DOWN(WriteNR)
     / 0004 IMG(Notify) / 0005 CMD(Write) / 0006 STATUS(Notify)
   - 多字节字段统一小端 */
enum BadgeProtocol {
    static let deviceName = "AI-Badge-BLE"

    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let audUp = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let audDown = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let img = CBUUID(string: "6E400004-B5A3-F393-E0A9-E50E24DCCA9E")
    static let cmd = CBUUID(string: "6E400005-B5A3-F393-E0A9-E50E24DCCA9E")
    static let status = CBUUID(string: "6E400006-B5A3-F393-E0A9-E50E24DCCA9E")

    /* AUD_DOWN: [op][data] */
    static let ttsBegin: UInt8 = 0x01
    static let ttsData: UInt8 = 0x02
    static let ttsEnd: UInt8 = 0x03

    /* IMG: [fid:u16][flags:u8][total:u32][off:u32][data]，头 11B */
    static let imgHeaderSize = 11
    static let imgFirst: UInt8 = 0x01
    static let imgLast: UInt8 = 0x02
    static let imgSnapshot: UInt8 = 0x04

    /* 16kHz / 16bit / mono，20ms = 320 样本 = 160B ADPCM */
    static let sampleRate = 16_000
    static let frameSamples = 320
    static let adpcmBytes = 160

    /* 固件 GC0308：QQVGA 160x120 RGB565（小端），380 字节/行 */
    static let imageWidth = 160
    static let imageHeight = 120
}
