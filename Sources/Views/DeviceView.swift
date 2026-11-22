import SwiftUI

@MainActor
struct DeviceView: View {
    @EnvironmentObject private var ble: BleManager
    @State private var volume: Double = 80

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusRow

                HStack(spacing: 8) {
                    Button(ble.state == .scanning ? "停止扫描" : "扫描设备") {
                        ble.toggleScan()
                    }
                    .buttonStyle(.borderedProminent)

                    if ble.isConnected {
                        Button("GET_INFO") { ble.sendCmd("GET_INFO") }
                            .buttonStyle(.bordered)
                        Button("断开", role: .destructive) { ble.disconnect() }
                            .buttonStyle(.bordered)
                    }
                }

                deviceList
                micMeter
                volumeControl
                logBox
            }
            .padding(12)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ble.isConnected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.state.rawValue).font(.subheadline)
                if !ble.infoText.isEmpty {
                    Text(ble.infoText).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("MTU \(ble.mtu)").font(.caption).foregroundStyle(.secondary)
            Text("帧 \(ble.micFrames)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设备").font(.caption).foregroundStyle(.secondary)
            if ble.devices.isEmpty {
                Text(ble.state == .scanning ? "搜索 AI-Badge-BLE…" : "点「扫描设备」开始")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(ble.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name.isEmpty ? "AI-Badge-BLE" : device.name)
                            Text("\(device.id.uuidString.prefix(8))  RSSI \(device.rssi)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("连接") { ble.connect(device.id) }
                            .buttonStyle(.bordered)
                            .disabled(ble.state == .connecting || ble.isConnected)
                    }
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var micMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("上行麦克风电平").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", ble.micLevel * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, ble.micLevel))
                .tint(.green)
        }
    }

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("挂件音量 \(Int(volume))").font(.caption).foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { editing in
                if !editing {
                    ble.sendCmd("SET_VOL=\(Int(volume))")
                }
            })
            .disabled(!ble.isConnected)
        }
    }

    private var logBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("日志").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ble.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 130)
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
