import Foundation
import CoreBluetooth
import UIKit

struct BadgeDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
}

/* BLE 中央设备封装（对照 Android BadgeBle.kt）：
   - 扫描广播名 AI-Badge-BLE -> 连接 -> 发现服务/特征 -> 使能三个 Notify
   - AUD_UP: [seq:u16][ADPCM160B] -> 逐帧解码（固件每帧独立重置编码器）-> onMicPcm
   - IMG: 11B 分片头 -> 按 fid 重组 -> 出图（RGB565 或 JPEG）
   - STATUS: JSON -> onStatus
   - 写队列串行化（CMD 带响应 / AUD_DOWN 无响应），按 canSendWriteWithoutResponse 排空
   注：iOS 不提供主动请求 MTU 的 API，CoreBluetooth 会自动协商（ESP32 通常 185） */
final class BleManager: NSObject, ObservableObject {
    static let shared = BleManager()

    enum ConnState: String {
        case idle = "未连接"
        case scanning = "扫描中"
        case connecting = "连接中"
        case connected = "已连接"
    }

    @Published private(set) var state: ConnState = .idle
    @Published private(set) var devices: [BadgeDevice] = []
    @Published private(set) var logs: [String] = []
    @Published private(set) var micFrames = 0
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var mtu = 23
    @Published private(set) var lastStatus = ""
    @Published private(set) var infoText = ""
    @Published var image: UIImage?

    /// 上行 PCM（320 样本/帧）与序号
    var onMicPcm: (([Int16], UInt16) -> Void)?
    /// STATUS JSON 事件
    var onStatus: (([String: Any]) -> Void)?

    private struct PendingWrite {
        let characteristic: CBCharacteristic
        let data: Data
        let type: CBCharacteristicWriteType
    }

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var discovered: [UUID: (CBPeripheral, Int)] = [:]
    private var writeQueue: [PendingWrite] = []
    private var waitingResponse = false

    private var imgBuf: [UInt8]?
    private var imgFid: UInt16 = 0
    private var imgTotal = 0

    private let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    var isConnected: Bool { state == .connected }

    private func log(_ text: String) {
        logs.append("\(logFormatter.string(from: Date())) \(text)")
        if logs.count > 60 { logs.removeFirst(logs.count - 60) }
    }

    /* ---------------- 扫描 / 连接 ---------------- */

    func toggleScan() {
        if state == .scanning { stopScan() } else { startScan() }
    }

    func startScan() {
        guard central.state == .poweredOn else {
            log("蓝牙不可用（\(central.state.rawValue)）")
            return
        }
        devices.removeAll()
        discovered.removeAll()
        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("扫描中…")
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ id: UUID) {
        guard let entry = discovered[id] else { return }
        stopScan()
        state = .connecting
        target = entry.0
        log("连接 \(id.uuidString.prefix(8)) …")
        central.connect(entry.0, options: nil)
    }

    func disconnect() {
        guard let p = target else { return }
        central.cancelPeripheralConnection(p)
    }

    /* ---------------- 写（CMD / AUD_DOWN） ---------------- */

    func sendCmd(_ cmd: String) {
        guard let ch = characteristics[BadgeProtocol.cmd],
              let data = cmd.data(using: .ascii) ?? cmd.data(using: .utf8) else { return }
        enqueue(ch, data, .withResponse)
    }

    func sendTtsBegin() {
        sendTtsOp(BadgeProtocol.ttsBegin)
    }

    func sendTtsEnd() {
        sendTtsOp(BadgeProtocol.ttsEnd)
    }

    /// 发送一块 TTS ADPCM（通常 160B）
    func sendTtsData(_ adpcm: [UInt8]) {
        guard let ch = characteristics[BadgeProtocol.audDown] else { return }
        var data = Data([BadgeProtocol.ttsData])
        data.append(contentsOf: adpcm)
        if let p = target,
           data.count > p.maximumWriteValueLength(for: .withoutResponse) {
            log("AUD_DOWN \(data.count)B 超过单包上限，丢弃")
            return
        }
        enqueue(ch, data, .withoutResponse)
    }

    private func sendTtsOp(_ op: UInt8) {
        guard let ch = characteristics[BadgeProtocol.audDown] else { return }
        enqueue(ch, Data([op]), .withoutResponse)
    }

    private func enqueue(_ characteristic: CBCharacteristic, _ data: Data,
                         _ type: CBCharacteristicWriteType) {
        guard state == .connected else { return }
        if writeQueue.count >= 512 {         // 约 10s 音频，积压保护
            log("写队列溢出，丢弃新包")
            return
        }
        writeQueue.append(PendingWrite(characteristic: characteristic, data: data, type: type))
        drainWriteQueue()
    }

    private func drainWriteQueue() {
        guard let peripheral = target, state == .connected else { return }

        while let item = writeQueue.first {
            if item.type == .withResponse {
                if waitingResponse { return }
                writeQueue.removeFirst()
                waitingResponse = true
                peripheral.writeValue(item.data, for: item.characteristic, type: .withResponse)
                return
            }
            guard peripheral.canSendWriteWithoutResponse else { return }
            writeQueue.removeFirst()
            peripheral.writeValue(item.data, for: item.characteristic, type: .withoutResponse)
        }
    }

    /* ---------------- 通知解析 ---------------- */

    private func handleAudio(_ data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)
        let seq = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let payload = Array(bytes.dropFirst(2))

        // 固件 audio_task 每帧 adpcm_reset 后独立编码 -> 解码端也逐帧复位
        let pcm = AdpcmDecoder().decode(payload)
        micFrames += 1
        micLevel = Self.rmsLevel(pcm)
        onMicPcm?(pcm, seq)
    }

    private func handleImage(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= BadgeProtocol.imgHeaderSize else { return }

        let fid = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let flags = bytes[2]
        let total = Int(Self.u32(bytes, 3))
        let offset = Int(Self.u32(bytes, 7))

        if flags & BadgeProtocol.imgFirst != 0 {
            guard total > 0, total <= 2_000_000 else {
                log("IMG total 异常 = \(total)")
                return
            }
            imgBuf = [UInt8](repeating: 0, count: total)
            imgFid = fid
            imgTotal = total
        }

        guard fid == imgFid, var buffer = imgBuf else { return }   // 旧帧残片丢弃

        let payload = bytes.count - BadgeProtocol.imgHeaderSize
        if offset >= 0, payload > 0, offset + payload <= imgTotal {
            buffer.replaceSubrange(offset..<(offset + payload),
                                   with: bytes[BadgeProtocol.imgHeaderSize...])
        }
        imgBuf = buffer

        if flags & BadgeProtocol.imgLast != 0 {
            let frame = buffer
            imgBuf = nil
            imgFid = 0
            imgTotal = 0
            if let decoded = Self.decodeImage(frame) {
                image = decoded
            } else {
                log("图像解码失败 \(frame.count)B")
            }
        }
    }

    private func handleStatus(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        lastStatus = text
        log("STATUS \(text)")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let ev = obj["ev"] as? String {
            if ev == "mtu", let v = obj["v"] as? Int, v >= 23 {
                mtu = v
            }
            if ev == "info" {
                let fw = obj["fw"] as? String ?? "?"
                let board = obj["board"] as? String ?? "?"
                infoText = "\(fw) / \(board)"
            }
        }
        onStatus?(obj)
    }

    /* ---------------- 工具 ---------------- */

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o])
            | (UInt32(b[o + 1]) << 8)
            | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    private static func rmsLevel(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        var acc = 0.0
        for s in pcm {
            let v = Double(s) / 32768.0
            acc += v * v
        }
        return min(1.0, sqrt(acc / Double(pcm.count)) * 4.0)
    }

    /// 固件图像有两种格式：真实帧为 160x120 RGB565 **大端**裸数据；故障注入测试图为 JPEG
    private static func decodeImage(_ data: [UInt8]) -> UIImage? {
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            return UIImage(data: Data(data))
        }
        return rgb565Image(data)
    }

    private static func rgb565Image(_ data: [UInt8]) -> UIImage? {
        let width = BadgeProtocol.imageWidth
        let height = BadgeProtocol.imageHeight
        guard data.count >= width * height * 2 else { return nil }

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var si = 0
        var di = 0
        for _ in 0..<(width * height) {
            // esp32-camera 输出为大端字节序（与 PC 端控制台 dtype=">u2" 一致）
            let value = (UInt16(data[si]) << 8) | UInt16(data[si + 1])
            let r5 = UInt8((value >> 11) & 0x1F)
            let g6 = UInt8((value >> 5) & 0x3F)
            let b5 = UInt8(value & 0x1F)
            rgba[di] = (r5 << 3) | (r5 >> 2)
            rgba[di + 1] = (g6 << 2) | (g6 >> 4)
            rgba[di + 2] = (b5 << 3) | (b5 >> 2)
            rgba[di + 3] = 255
            si += 2
            di += 4
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/* ---------------- CBCentralManagerDelegate ---------------- */

extension BleManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("蓝牙就绪")
        case .poweredOff:
            log("蓝牙未开启")
            if state != .connected { state = .idle }
        case .unauthorized:
            log("蓝牙权限被拒绝")
        case .unsupported:
            log("设备不支持蓝牙")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let adv = advertisementData
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name == BadgeProtocol.deviceName || services.contains(BadgeProtocol.service) else { return }

        let id = peripheral.identifier
        discovered[id] = (peripheral, RSSI.intValue)

        if let idx = devices.firstIndex(where: { $0.id == id }) {
            devices[idx].rssi = RSSI.intValue
        } else {
            devices.append(BadgeDevice(id: id, name: name, rssi: RSSI.intValue))
            devices.sort { $0.rssi > $1.rssi }
            log("发现 \(name.isEmpty ? "AI-Badge-BLE" : name) RSSI=\(RSSI.intValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("GATT 已连接")
        state = .connected
        peripheral.delegate = self
        peripheral.discoverServices([BadgeProtocol.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("连接失败：\(error?.localizedDescription ?? "未知")")
        target = nil
        state = .idle
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral == target {
            log("已断开\(error.map { "：\($0.localizedDescription)" } ?? "")")
            target = nil
            characteristics.removeAll()
            writeQueue.removeAll()
            waitingResponse = false
            imgBuf = nil
            micLevel = 0
            mtu = 23
            state = .idle
        }
    }
}

/* ---------------- CBPeripheralDelegate ---------------- */

extension BleManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("发现服务失败：\(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == BadgeProtocol.service }) else {
            log("未找到目标服务（固件 GATT 未注册？）")
            return
        }
        peripheral.discoverCharacteristics(
            [BadgeProtocol.audUp, BadgeProtocol.audDown, BadgeProtocol.img,
             BadgeProtocol.cmd, BadgeProtocol.status],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { log("发现特征失败：\(error.localizedDescription)"); return }

        for ch in service.characteristics ?? [] {
            characteristics[ch.uuid] = ch
        }
        mtu = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        log("特征就绪 MTU≈\(mtu)，使能 Notify…")

        for uuid in [BadgeProtocol.audUp, BadgeProtocol.img, BadgeProtocol.status] {
            if let ch = characteristics[uuid] {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("Notify 使能失败 \(characteristic.uuid.uuidString.prefix(8))：\(error.localizedDescription)")
        } else {
            log("Notify 已使能 \(characteristic.uuid.uuidString.prefix(8))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("Notify 读取失败：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == BadgeProtocol.audUp {
            handleAudio(data)
        } else if characteristic.uuid == BadgeProtocol.img {
            handleImage(data)
        } else if characteristic.uuid == BadgeProtocol.status {
            handleStatus(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        waitingResponse = false
        if let error {
            log("写失败 \(characteristic.uuid.uuidString.prefix(8))：\(error.localizedDescription)")
        }
        drainWriteQueue()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWriteQueue()
    }
}
