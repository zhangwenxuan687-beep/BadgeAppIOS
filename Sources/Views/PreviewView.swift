import SwiftUI

@MainActor
struct PreviewView: View {
    @EnvironmentObject private var ble: BleManager

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button("开始预览") { ble.sendCmd("START_PREVIEW") }
                    .buttonStyle(.borderedProminent)
                Button("停止") { ble.sendCmd("STOP_PREVIEW") }
                    .buttonStyle(.bordered)
                Button("抓拍") { ble.sendCmd("SNAPSHOT") }
                    .buttonStyle(.bordered)
            }
            .disabled(!ble.isConnected)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))

                if let image = ble.image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(6)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("无画面")
                            .foregroundStyle(.secondary)
                        Text("连接挂件后点「开始预览」或「抓拍」")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("固件为 GC0308 160×120 RGB565（真实帧），摄像头故障时回传内置 JPEG 测试图。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
