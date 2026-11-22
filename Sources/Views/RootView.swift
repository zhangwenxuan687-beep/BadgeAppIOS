import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var ble: BleManager
    @EnvironmentObject private var chat: ChatOrchestrator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                DeviceView()
                    .tabItem { Label("设备", systemImage: "dot.radiowaves.left.and.right") }
                PreviewView()
                    .tabItem { Label("预览", systemImage: "camera") }
                ChatView()
                    .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AI Badge")
                .font(.headline)
            Text(ble.isConnected ? "MTU \(ble.mtu)" : ble.state.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(chat.phase)
                .font(.caption)
                .foregroundStyle(ble.isConnected ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}
